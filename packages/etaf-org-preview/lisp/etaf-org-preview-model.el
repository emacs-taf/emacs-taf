;;; etaf-org-preview-model.el --- Session state for etaf-org-preview -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; Session state of the previewer.  A session is a plist of reactive cells:
;; the parsed document, the palette, the reading measure, the fold state of
;; every headline and the hidden-content switch.  It can exist without any
;; buffer, so scripts and tests drive the same model the mounted application
;; uses.
;;
;; Folding is per section: each headline owns one cell, and the section
;; Component reads that cell while rendering.  Writing one cell therefore
;; repaints one section instead of the document, which is what keeps a fold
;; cheap on a large file and what the update report checks.
;;
;; Media is resolved when a document is loaded or refreshed: a lone link to a
;; local image becomes a media descriptor with its pixel size, so the render
;; path never touches the disk.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'filenotify)
(require 'etaf)
(require 'etaf-ui)
(require 'etaf-org-preview-theme)
(require 'etaf-org-preview-parse)
(require 'etaf-org-preview-views)

(define-error 'etaf-org-preview-error "Org preview error")

(defcustom etaf-org-preview-theme 'auto
  "Initial palette of `etaf-org-preview-create'.
`auto' derives the document colors from the active frame's own faces and
paints no page background.  `dark', `light' and `sepia' select a fixed
palette, including its page background."
  :type '(choice (const :tag "Follow the Emacs theme" auto)
                 (const :tag "Dark page" dark)
                 (const :tag "Light page" light)
                 (const :tag "Sepia page" sepia))
  :group 'etaf-org-preview)

(defcustom etaf-org-preview-width-min 40
  "Narrowest reading measure, in character cells."
  :type 'integer
  :group 'etaf-org-preview)

(defcustom etaf-org-preview-width-max 96
  "Widest reading measure, in character cells."
  :type 'integer
  :group 'etaf-org-preview)

(defcustom etaf-org-preview-image-max-height 24
  "Tallest image, in text lines."
  :type 'integer
  :group 'etaf-org-preview)

(defconst etaf-org-preview--measure-gutter 2
  "Character cells kept blank on each side of the reading measure.")

;;; ---------------------------------------------------------------------------
;;; Refs
;;; ---------------------------------------------------------------------------

(defun etaf-org-preview--ref (session key)
  "Return SESSION's reactive source named KEY."
  (plist-get session key))

(defun etaf-org-preview--read (session key)
  "Return SESSION's current value for KEY, tracked while rendering."
  (etaf-value (etaf-org-preview--ref session key)))

(defun etaf-org-preview--write (session key value)
  "Publish VALUE as SESSION's new value for KEY and return it."
  (let ((ref (etaf-org-preview--ref session key)))
    (unless (equal (etaf-value ref) value)
      (etaf-set-value ref value))
    value))

;;; ---------------------------------------------------------------------------
;;; Source and media
;;; ---------------------------------------------------------------------------

(defun etaf-org-preview--remote-url-p (target)
  "Return non-nil when TARGET is a remote resource."
  (string-match-p "\\`[a-zA-Z][a-zA-Z0-9+.-]*://" target))

(defun etaf-org-preview--read-source (file)
  "Return FILE's text, signaling `etaf-org-preview-error' on failure."
  (unless (file-readable-p file)
    (signal 'etaf-org-preview-error (list (format "Cannot read file: %s" file))))
  (with-temp-buffer
    (insert-file-contents file)
    (buffer-string)))

(defun etaf-org-preview--parse-text (text session)
  "Parse TEXT for SESSION, mapping parse failures onto its own error type."
  (condition-case error
      (etaf-org-preview--parse text
                               :file (plist-get session :file))
    (error (signal 'etaf-org-preview-error (cdr error)))))

(defun etaf-org-preview--link-file (target dir)
  "Return TARGET as an absolute file name relative to DIR, or nil.
A link may carry a search suffix (`::*Headline'); only the file part is
resolved here."
  (let* ((raw (if (string-prefix-p "file:" target)
                  (substring target 5)
                target))
         (path (car (split-string raw "::")))
         (path (if (string-prefix-p "attachment:" (or path ""))
                   (substring path 11)
                 path)))
    (when (and path (not (string-empty-p path))
               (not (etaf-org-preview--remote-url-p path)))
      (expand-file-name path (or dir default-directory)))))

(defun etaf-org-preview--image-size (path)
  "Return (WIDTH . HEIGHT) of the image at PATH, or nil."
  (when (and path (file-readable-p path))
    (let ((size (ignore-errors (image-size (create-image path) t))))
      (when (and size (consp size) (numberp (car size)) (numberp (cdr size)))
        size))))

(defun etaf-org-preview--lone-link (block)
  "Return the single link of a paragraph BLOCK, or nil."
  (when (eq (plist-get block :type) 'paragraph)
    (let ((inlines (cl-remove-if
                    (lambda (node)
                      (and (eq (plist-get node :type) 'text)
                           (string-blank-p (or (plist-get node :text) ""))))
                    (plist-get block :inlines))))
      (and (= 1 (length inlines))
           (eq (plist-get (car inlines) :type) 'link)
           (car inlines)))))

(defun etaf-org-preview--resolve-media-block (block session)
  "Return BLOCK with a media descriptor when it shows one file."
  (let ((link (etaf-org-preview--lone-link block)))
    (if (and link
             (memq (plist-get link :kind) '(file other attachment)))
        (let* ((target (plist-get link :target))
               (path (etaf-org-preview--link-file target (plist-get session :dir)))
               (extension (and path (downcase (or (file-name-extension path) ""))))
               (image (member extension etaf-org-preview--image-extensions))
               (video (member extension etaf-org-preview--video-extensions))
               (size (and image (etaf-org-preview--image-size path))))
          (if (or image video)
              (plist-put block :media
                         (list :path path
                               :kind (if image 'image 'video)
                               :exists (and path (file-exists-p path))
                               :width (car size)
                               :height (cdr size)
                               :attrs (plist-get block :attrs)
                               :alt (plist-get (plist-get block :attrs) :alt)))
            block))
      block)))

(defun etaf-org-preview--resolve-media-blocks (blocks session)
  "Return BLOCKS with media descriptors resolved for SESSION."
  (mapcar
   (lambda (block)
     (setq block (etaf-org-preview--resolve-media-block block session))
     (when-let* ((children (plist-get block :blocks)))
       (setq block (plist-put block :blocks
                              (etaf-org-preview--resolve-media-blocks
                               children session))))
     (when-let* ((items (plist-get block :items)))
       (setq block (plist-put block :items
                              (mapcar
                               (lambda (item)
                                 (plist-put item :blocks
                                            (etaf-org-preview--resolve-media-blocks
                                             (plist-get item :blocks) session)))
                               items))))
     block)
   blocks))

(defun etaf-org-preview--resolve-media (document session)
  "Resolve media descriptors of DOCUMENT for SESSION and return it."
  (plist-put document :preamble
             (etaf-org-preview--resolve-media-blocks
              (plist-get document :preamble) session))
  (etaf-org-preview--walk-sections
   (plist-get document :sections)
   (lambda (section)
     (setf (etaf-org-preview-section-body section)
           (etaf-org-preview--resolve-media-blocks
            (etaf-org-preview-section-body section) session))))
  document)

;;; ---------------------------------------------------------------------------
;;; Section cells
;;; ---------------------------------------------------------------------------

(defun etaf-org-preview--walk-sections (sections function)
  "Call FUNCTION on every section in SECTIONS."
  (dolist (section sections)
    (funcall function section)
    (etaf-org-preview--walk-sections
     (etaf-org-preview-section-children section) function)))

(defun etaf-org-preview--build-section-cells (session document)
  "Create or keep SESSION's per-section cells for DOCUMENT.
A refresh keeps the state and the anchor of a section whose id it still sees,
so a commented or archived section stays out of the page after a reload."
  (let* ((existing (plist-get session :sections))
         (cells (make-hash-table :test #'equal)))
    (etaf-org-preview--walk-sections
     (plist-get document :sections)
     (lambda (section)
       (let* ((id (etaf-org-preview-section-id section))
              (old (gethash id existing))
              ;; The preview has no fold control.  A commented or archived
              ;; headline still keeps its body out of the reading page; every
              ;; other section opens, whatever `#+STARTUP' asked for.
              (state (if (or (etaf-org-preview-section-commented section)
                             (etaf-org-preview-section-archived section))
                         'folded
                       'open)))
         (puthash id
                  (list :fold (or (plist-get old :fold)
                                  (etaf-ref state :name 'org-preview-fold)))
                  cells))))
    (plist-put session :sections cells)))

(defun etaf-org-preview--fold-cell (session id)
  "Return SESSION's fold cell of section ID."
  (plist-get (gethash id (plist-get session :sections)) :fold))

(defun etaf-org-preview--fold-state (session id)
  "Return the fold state of SESSION's section ID."
  (when-let* ((cell (etaf-org-preview--fold-cell session id)))
    (etaf-value cell)))

(defun etaf-org-preview-fold (session id state)
  "Set the fold STATE of SESSION's section ID and return SESSION.
STATE is `folded', `children' or `open'.  The section's cell is written, and
`children' also folds its descendants in the same batch so the subtree starts
compact; the reader can open any child afterwards."
  (unless (memq state '(folded children open))
    (signal 'etaf-org-preview-error
            (list (format "Unknown fold state: %S" state))))
  (let ((cell (etaf-org-preview--fold-cell session id)))
    (unless cell
      (signal 'etaf-org-preview-error
              (list (format "Unknown section: %s" id))))
    (if (eq state 'children)
        (etaf-batch
          (when-let* ((section (etaf-org-preview--section-by-id session id)))
            (etaf-org-preview--walk-sections
             (etaf-org-preview-section-children section)
             (lambda (child)
               (when-let* ((child-cell (etaf-org-preview--fold-cell
                                        session
                                        (etaf-org-preview-section-id child))))
                 (etaf-set-value child-cell 'folded)))))
          (etaf-set-value cell state))
      (etaf-set-value cell state)))
  session)

(defun etaf-org-preview-folded-p (session id)
  "Return non-nil when SESSION's section ID is folded."
  (eq (etaf-org-preview--fold-state session id) 'folded))

(defun etaf-org-preview-fold-all (session state)
  "Set every section of SESSION to fold STATE and return SESSION.
The write happens in one batch, so the document repaints once."
  (etaf-batch
    (maphash (lambda (id cell)
               (ignore id)
               (etaf-set-value (plist-get cell :fold) state))
             (plist-get session :sections)))
  session)

(defun etaf-org-preview--cycle-global (session)
  "Advance SESSION to the next document-wide fold state and return it.
The two states are the outline view, where every body is hidden, and the full
view.  Both writes go through one batch so the document repaints once."
  (let ((next (if (eq (plist-get session :global-state) 'content)
                  'overview
                'content)))
    (plist-put session :global-state next)
    (etaf-batch
      (etaf-org-preview--walk-sections
       (plist-get (etaf-org-preview--read session :document) :sections)
       (lambda (section)
         (let ((id (etaf-org-preview-section-id section)))
           (when-let* ((cell (etaf-org-preview--fold-cell session id)))
             (etaf-set-value cell (if (eq next 'content) 'open 'folded)))))))
    next))

(defun etaf-org-preview--section-by-id (session id)
  "Return SESSION's section whose id is ID."
  (let ((found nil))
    (etaf-org-preview--walk-sections
     (plist-get (etaf-org-preview--read session :document) :sections)
     (lambda (section)
       (when (equal (etaf-org-preview-section-id section) id)
         (setq found section))))
    found))

;;; ---------------------------------------------------------------------------
;;; Published entries
;;; ---------------------------------------------------------------------------

(defun etaf-org-preview--digest (value)
  "Return a stable digest of VALUE for packaging entries."
  (let ((print-circle t)
        (print-length nil)
        (print-level nil))
    (secure-hash 'sha1 (prin1-to-string value))))

(defun etaf-org-preview--block-entry (session block published table counts)
  "Return the published entry of BLOCK and record it in TABLE.
PUBLISHED maps the previous publish's keys to entries.  An unchanged block
returns its old entry, so its Component call, hosts and focus stay; COUNTS
keeps two identical blocks in one document distinct."
  (when (fboundp 'etaf-org-preview-typeset-attach)
    (setq block (etaf-org-preview-typeset-attach
                 block (etaf-org-preview--env session))))
  (let* ((digest (concat "b:" (etaf-org-preview--digest block)))
         (occurrence (1+ (gethash digest counts 0)))
         (key (if (= 1 occurrence) digest (format "%s#%d" digest occurrence)))
         (entry (or (gethash key published)
                    (list :key key :block block
                          :view (etaf-node 'etaf-org-preview-block
                                           (list :key key :session session :block block)
                                           nil)))))
    (puthash digest occurrence counts)
    (puthash key entry table)
    entry))

(defun etaf-org-preview--section-entry (session section published table counts)
  "Return the published entry of SECTION and record it in TABLE.
The key covers the heading, its drawers and the keys of every body block and
child section, so an unchanged subtree keeps its Component call while an edit
rebuilds only the sections on its path."
  (let* ((body (mapcar (lambda (block)
                         (etaf-org-preview--block-entry
                          session block published table counts))
                       (cl-remove-if
                        (lambda (block)
                          (eq (plist-get block :type) 'footnote-def))
                        (etaf-org-preview-section-body section))))
         (children (mapcar (lambda (child)
                             (etaf-org-preview--section-entry
                              session child published table counts))
                           (etaf-org-preview-section-children section)))
         (id (etaf-org-preview-section-id section))
         (fold (etaf-org-preview--fold-cell session id))
         (digest (etaf-org-preview--digest
                  (list id
                        (etaf-org-preview-section-level section)
                        (etaf-org-preview-section-todo section)
                        (etaf-org-preview-section-priority section)
                        (etaf-org-preview-section-title section)
                        (etaf-org-preview-section-title-inlines section)
                        (etaf-org-preview-section-tags section)
                        (etaf-org-preview-section-planning section)
                        (etaf-org-preview-section-properties section)
                        (etaf-org-preview-section-logbook section)
                        (etaf-org-preview-section-logbook-text section)
                        (etaf-org-preview-section-archived section)
                        (etaf-org-preview-section-commented section)
                        (mapcar (lambda (entry) (plist-get entry :key)) body)
                        (mapcar (lambda (entry) (plist-get entry :key)) children))))
         (key (concat "s:" digest))
         (old (gethash key published))
         (entry (if (and old (eq (plist-get old :fold) fold))
                    old
                  (list :key key :fold fold :section section :body body :children children
                        :view (etaf-node 'etaf-org-preview-section
                                         (list :key key
                                               :section section
                                               :session session
                                               :fold fold
                                               :body (mapcar (lambda (item)
                                                               (plist-get item :view))
                                                             body)
                                               :children (mapcar (lambda (item)
                                                                   (plist-get item :view))
                                                                 children))
                                         nil)))))
    (puthash key entry table)
    entry))

(defun etaf-org-preview--keyed-document (session document)
  "Return DOCUMENT with its preamble and headline tree replaced by entries.
Every entry carries the Component call it renders, so publishing a document
whose parts did not change hands the runtime the same calls and only the edited
part paints."
  (let* ((published (plist-get session :published))
         (table (make-hash-table :test #'equal))
         (counts (make-hash-table :test #'equal))
         (preamble (mapcar (lambda (block)
                             (etaf-org-preview--block-entry
                              session block published table counts))
                           (plist-get document :preamble)))
         (sections (mapcar (lambda (section)
                             (etaf-org-preview--section-entry
                              session section published table counts))
                           (plist-get document :sections))))
    (plist-put session :published table)
    (plist-put document :preamble-entries preamble)
    (plist-put document :section-entries sections)))

(defun etaf-org-preview--current-text (session)
  "Return the text SESSION currently shows, preferring its source buffer.
An unsaved edit is what the page follows; a file the buffer no longer visits
falls back to the file on disk, and a text session keeps its own text."
  (let* ((buffer (plist-get session :source-buffer))
         (file (plist-get session :file))
         (visiting (and (buffer-live-p buffer)
                        (buffer-local-value 'buffer-file-name buffer)
                        (equal (expand-file-name
                                (buffer-local-value 'buffer-file-name buffer))
                               file))))
    (cond
     ;; An unsaved edit is what the page follows.
     ((and visiting (buffer-modified-p buffer))
      (with-current-buffer buffer
        (buffer-substring-no-properties (point-min) (point-max))))
     ;; Otherwise read the file, so a change written by another program shows.
     (file (etaf-org-preview--read-source file))
     ((buffer-live-p buffer)
      (with-current-buffer buffer
        (buffer-substring-no-properties (point-min) (point-max))))
     (t (or (plist-get session :text) "")))))

(defun etaf-org-preview--install (session contents &optional title)
  "Parse CONTENTS and publish it as SESSION's document; return the document.
The title, the document metadata and the section cells are refreshed together,
so the file, a save and an unsaved edit all take the same path.  TITLE overrides
the document's own title when given."
  (let* ((document (etaf-org-preview--parse-text contents session))
         (options (plist-get document :options))
         (file (plist-get session :file)))
    (plist-put session :text (unless file contents))
    (plist-put session :live-text contents)
    (plist-put session :todo-keywords (plist-get document :todo-keywords))
    (plist-put session :show-tags (plist-get options :tags))
    (plist-put session :toc-depth-base
               (or (plist-get session :toc) (plist-get options :toc)))
    (plist-put session :modified
               (when (and file (file-exists-p file))
                 (format-time-string "更新于 %Y-%m-%d %H:%M"
                                     (file-attribute-modification-time
                                      (file-attributes file)))))
    (plist-put session :env-cache nil)
    (etaf-org-preview--build-section-cells session document)
    (let ((document (etaf-org-preview--keyed-document
                     session
                     (etaf-org-preview--resolve-media document session))))
      (etaf-batch
        (etaf-set-value (etaf-org-preview--ref session :document) document)
        (etaf-set-value (etaf-org-preview--ref session :title)
                        (or title (plist-get document :title)
                            (and file (file-name-base file))
                            "Org 文档"))
        (etaf-set-value (etaf-org-preview--ref session :error) nil))
      (when (fboundp 'etaf-org-preview-typeset-request)
        (etaf-org-preview-typeset-request session))
      document)))

;;; ---------------------------------------------------------------------------
;;; Session
;;; ---------------------------------------------------------------------------

(cl-defun etaf-org-preview-create (&key file text title theme toc)
  "Create a headless preview session and return it.
FILE names an Org document to read; TEXT supplies the document directly.
Exactly one source is required.  TITLE overrides the document title.  THEME
selects a palette and defaults to the value of `etaf-org-preview-theme'.  TOC
overrides the `#+OPTIONS: toc' depth, and nil keeps the document's own value."
  (let* ((file (and file (expand-file-name file)))
         (contents (cond (text text)
                         (file (etaf-org-preview--read-source file))
                         (t (signal 'etaf-org-preview-error
                                    '("etaf-org-preview-create needs :file or :text")))))
         (requested (or theme etaf-org-preview-theme))
         (auto (eq requested 'auto))
         (session (list :file file
                        :text (unless file contents)
                        :live-text contents
                        :dir (if file (file-name-directory file) default-directory)
                        :document (etaf-ref nil :name 'org-preview-document)
                        :title (etaf-ref (or title "") :name 'org-preview-title)
                        :theme-mode (etaf-ref requested :name 'org-preview-theme-mode)
                        :theme-source (etaf-ref (if auto 'frame 'palette)
                                                :name 'org-preview-theme-source)
                        :theme (etaf-ref (if auto (etaf-appearance) requested)
                                         :name 'org-preview-theme)
                        :width (etaf-ref 92 :name 'org-preview-width)
                        :hidden (etaf-ref nil :name 'org-preview-hidden)
                        :toc-visible (etaf-ref t :name 'org-preview-toc)
                        :error (etaf-ref nil :name 'org-preview-error-text)
                        :toc toc
                        :sections (make-hash-table :test #'equal)
                        :published (make-hash-table :test #'equal)
                        :buffer nil)))
    (etaf-org-preview--install session contents title)
    session))

(defun etaf-org-preview-state (session)
  "Return SESSION's state as a detached plist snapshot.
Keys are `:file', `:title', `:author', `:date', `:keywords', `:filetags',
`:theme', `:background', `:width',
`:buffer', `:outline', `:sections', `:blocks', `:footnotes', `:degraded',
`:counts' and `:error'."
  (let* ((document (etaf-org-preview--read session :document))
         (counts (list :todo 0 :done 0 :deadline 0 :overdue 0)))
    (etaf-org-preview--walk-sections
     (plist-get document :sections)
     (lambda (section)
       (let ((todo (etaf-org-preview-section-todo section)))
         (when todo
           (if (eq (cdr (assoc todo (plist-get document :todo-keywords))) 'done)
               (plist-put counts :done (1+ (plist-get counts :done)))
             (plist-put counts :todo (1+ (plist-get counts :todo))))))
       (when (plist-get (etaf-org-preview-section-planning section) :deadline)
         (plist-put counts :deadline (1+ (plist-get counts :deadline))))))
    (list :file (plist-get session :file)
          :title (etaf-org-preview--read session :title)
          :author (plist-get document :author)
          :date (plist-get document :date)
          :keywords (plist-get document :keywords)
          :filetags (plist-get document :filetags)
          :theme (etaf-org-preview--read session :theme)
          :background (when (eq (etaf-org-preview--read session :theme-source)
                                'palette)
                        'palette)
          :width (etaf-org-preview--read session :width)
          :buffer (plist-get session :buffer)
          :outline (copy-tree (plist-get document :outline))
          :sections (length (plist-get document :outline))
          :blocks (plist-get document :blocks)
          :footnotes (mapcar (lambda (footnote)
                               (plist-get footnote :label))
                             (plist-get document :footnotes))
          :degraded (or (plist-get document :degraded) 0)
          :counts counts
          :error (etaf-org-preview--read session :error))))

(defun etaf-org-preview--republish (session)
  "Publish SESSION's current source again and return SESSION.
A palette change repaints pictures drawn for the old colours, so the document
is installed again; unchanged blocks keep their entry and do not repaint."
  (when (or (plist-get session :buffer)
            (plist-get session :file))
    (etaf-org-preview--install session
                               (etaf-org-preview--current-text session)))
  session)

(defun etaf-org-preview-refresh (session)
  "Re-read and re-parse SESSION's document and return SESSION.
A read failure signals `etaf-org-preview-error' and leaves the published
document untouched.  Fold state and reading anchors survive for every section
whose id is still present.  An unsaved source buffer is read as it stands, so
the command never shows the page reverting to the file."
  (etaf-org-preview--install session (etaf-org-preview--current-text session))
  session)

(defun etaf-org-preview-set-theme (session theme)
  "Show SESSION with palette THEME and return SESSION.
THEME is `auto' or one of the fixed palettes; anything else signals
`etaf-org-preview-error'."
  (unless (or (eq theme 'auto) (assq theme etaf-org-preview-themes))
    (signal 'etaf-org-preview-error
            (list (format "Unknown org preview theme: %S" theme))))
  (etaf-batch
    (etaf-org-preview--write session :theme-mode theme)
    (etaf-org-preview--write session :theme
                             (if (eq theme 'auto)
                                 (etaf-appearance)
                               theme))
    (etaf-org-preview--write session :theme-source
                             (if (eq theme 'auto) 'frame 'palette)))
  (etaf-org-preview--republish session)
  session)

(defun etaf-org-preview-cycle-theme (session)
  "Switch SESSION to the next fixed palette and return its name."
  (let* ((themes (mapcar #'car etaf-org-preview-themes))
         (current (etaf-org-preview--read session :theme))
         (tail (cdr (memq current themes))))
    (etaf-org-preview-set-theme session (or (car tail) (car themes)))
    (etaf-org-preview--read session :theme)))

(defun etaf-org-preview-outline (session)
  "Return SESSION's outline as (LEVEL TITLE ID TODO TAGS) entries."
  (copy-tree (plist-get (etaf-org-preview--read session :document) :outline)))

(defun etaf-org-preview-show-toc (session show)
  "Show or hide SESSION's table of contents and return SESSION.
SHOW non-nil displays the contents card at the document's configured depth."
  (etaf-org-preview--write session :toc-visible (and show t))
  session)

(defun etaf-org-preview-show-hidden (session show)
  "Show or hide SESSION's hidden content and return SESSION.
Hidden content is comments, property drawers and metadata lines; SHOW non-nil
reveals it."
  (etaf-org-preview--write session :hidden (and show t))
  session)

(defun etaf-org-preview-adjust-width (session delta)
  "Change SESSION's maximum reading measure by DELTA and return it."
  (let ((width (max etaf-org-preview-width-min
                    (min etaf-org-preview-width-max
                         (+ (etaf-org-preview--read session :width) delta)))))
    (etaf-org-preview--write session :width width)
    width))

;;; ---------------------------------------------------------------------------
;;; Navigation
;;; ---------------------------------------------------------------------------

(defun etaf-org-preview--buffer (session)
  "Return SESSION's buffer, or the current buffer when it is the mount.
A headless session mounted by a script has no `:buffer' of its own, so
navigation inside that mount falls back to the buffer being visited."
  (let ((buffer (plist-get session :buffer)))
    (cond
     ((buffer-live-p buffer) buffer)
     ((etaf-runtime-for-buffer (current-buffer)) (current-buffer))
     (t nil))))

(defun etaf-org-preview--runtime (session)
  "Return SESSION's mounted Runtime, or nil."
  (when-let* ((buffer (etaf-org-preview--buffer session)))
    (etaf-runtime-for-buffer buffer)))

(defun etaf-org-preview--positions (session)
  "Return (ID . POSITION) for every rendered heading of SESSION.
Heading Hosts carry their section id, so the position table comes from the
mounted tree instead of a second index that could drift."
  (let ((runtime (etaf-org-preview--runtime session))
        (result nil))
    (when runtime
      ;; A refit or a theme switch can leave the position table behind the
      ;; last layout; one flush restores it before the lookup.
      (let ((entries (etaf-runtime-host-props-entries runtime)))
        (when (and entries
                   (null (etaf-host-ref-position runtime (car (car entries)))))
          (etaf-runtime-flush runtime)))
      (dolist (entry (etaf-runtime-host-props-entries runtime))
        (let ((id (plist-get (cdr entry) :id)))
          (when (and (stringp id) (string-prefix-p "org-section-" id))
            (when-let* ((position (etaf-host-ref-position runtime (car entry))))
              (push (cons (substring id 12) position) result))))))
    (nreverse result)))

(defun etaf-org-preview--position (session id)
  "Return the buffer position of section ID's heading in SESSION."
  (cdr (assoc id (etaf-org-preview--positions session))))

(defun etaf-org-preview--locate-id (session id)
  "Move point to SESSION's section ID and recenter; return its position."
  (when-let* ((position (etaf-org-preview--position session id)))
    (let ((buffer (etaf-org-preview--buffer session)))
      (when (buffer-live-p buffer)
        (with-current-buffer buffer
          (goto-char position)
          ;; A heading Host starts at its top padding, so settle on the row
          ;; that carries the heading text.
          (skip-chars-forward " \t\n")
          (beginning-of-line)
          (when-let* ((window (get-buffer-window buffer t)))
            (with-selected-window window
              (recenter 0)))))
      position)))

(defun etaf-org-preview--flush (session)
  "Flush SESSION's runtime when it is mounted."
  (when-let* ((runtime (etaf-org-preview--runtime session)))
    (etaf-runtime-flush runtime)))

(defun etaf-org-preview--reveal (id session)
  "Open every ancestor of section ID in SESSION.
Return non-nil when a fold state changed."
  (let ((changed nil))
    (when id
      (dolist (ancestor (etaf-org-preview--ancestor-path session id))
        (unless (eq (etaf-org-preview--fold-state session ancestor) 'open)
          (etaf-org-preview-fold session ancestor 'open)
          (setq changed t))))
    changed))

(defun etaf-org-preview--ancestor-path (session id)
  "Return the ids of ID's ancestors in SESSION, outermost first."
  (let* ((outline (etaf-org-preview-outline session))
         (target (cl-find id outline :key (lambda (entry) (nth 2 entry))
                          :test #'equal))
         (level (and target (nth 0 target)))
         (result nil))
    (when target
      (let ((remaining outline))
        (while (and remaining (> level 1))
          (let ((previous (car (last remaining))))
            (if (equal (nth 2 previous) id)
                (setq remaining (butlast remaining))
              (when (< (nth 0 previous) level)
                (push (nth 2 previous) result)
                (setq level (nth 0 previous)))
              (setq remaining (butlast remaining)))))))
    (nreverse result)))

(defun etaf-org-preview-locate (session index)
  "Move point to SESSION's outline heading INDEX and recenter.
Return the position, or nil when the heading is not visible."
  (let ((entry (nth index (etaf-org-preview-outline session))))
    (when entry
      (let ((id (nth 2 entry)))
        (etaf-org-preview--reveal id session)
        (etaf-org-preview--flush session)
        (etaf-org-preview--locate-id session id)))))

(defun etaf-org-preview--adjacent-heading (session direction)
  "Move point to the next visible heading in DIRECTION.
Going backwards starts from the current section's own heading, so landing on
a heading never makes that same heading count as the previous one."
  (let* ((buffer (etaf-org-preview--buffer session))
         (point-now (if (buffer-live-p buffer)
                        (with-current-buffer buffer (point))
                      0))
         (positions (etaf-org-preview--positions session))
         (current (and (< direction 0)
                       (etaf-org-preview--reading-section session)))
         (reference (or (and current
                             (cdr (assoc current positions)))
                        point-now))
         (target (if (> direction 0)
                     (cl-find-if (lambda (cell) (> (cdr cell) point-now)) positions)
                   (car (last (cl-remove-if-not
                               (lambda (cell) (< (cdr cell) reference))
                               positions))))))
    (when target
      (etaf-org-preview--locate-id session (car target)))))

(defun etaf-org-preview--reading-section (session)
  "Return the id of the section that contains point in SESSION, or nil."
  (let* ((buffer (etaf-org-preview--buffer session))
         (point-now (if (buffer-live-p buffer)
                        (with-current-buffer buffer (point))
                      0))
         (found nil))
    (dolist (cell (etaf-org-preview--positions session))
      (when (<= (cdr cell) point-now)
        (setq found (car cell))))
    found))

;;; ---------------------------------------------------------------------------
;;; Targets and actions
;;; ---------------------------------------------------------------------------

(defun etaf-org-preview--open-url (url)
  "Open URL in the system browser."
  (browse-url url))

(defun etaf-org-preview--open-file (path)
  "Open PATH with the operating system's default application."
  (let ((opener (pcase system-type
                  ('darwin "open")
                  ('gnu/linux "xdg-open")
                  (_ nil))))
    (if (and path opener (executable-find opener))
        (call-process opener nil 0 nil path)
      (find-file-other-window path))))

(defun etaf-org-preview--section-by-title (session title)
  "Return SESSION's section id whose title is TITLE."
  (cl-loop for entry in (etaf-org-preview-outline session)
           when (equal (nth 1 entry) title)
           return (nth 2 entry)))

(defun etaf-org-preview--open-target (session target)
  "Act on link TARGET in SESSION.
In-document anchors jump, files open, URLs use the browser, and a link with a
search suffix opens the target and reveals the heading it names."
  (let* ((kind (etaf-org-preview--link-kind target))
         (dir (plist-get session :dir)))
    (pcase kind
      ('url (etaf-org-preview--open-url target))
      ('mail (etaf-org-preview--open-url target))
      ('headline
       (let ((title (substring target 1)))
         (if-let* ((id (etaf-org-preview--section-by-title session title)))
             (progn (etaf-org-preview--reveal id session)
                    (etaf-org-preview--locate-id session id))
           (message "No heading named %s" title))))
      ('custom-id
       (let ((id (substring target 1)))
         (if (etaf-org-preview--fold-cell session id)
             (progn (etaf-org-preview--reveal id session)
                    (etaf-org-preview--locate-id session id))
           (message "No section with CUSTOM_ID %s" id))))
      ('id
       (if (fboundp 'org-id-find)
           (let ((found (ignore-errors (org-id-find (substring target 3) t))))
             (if found
                 (find-file-other-window (car found))
               (message "Unknown Org id: %s" target)))
         (message "Loading Org is required to resolve id: links")))
      ((or 'file 'other 'attachment)
       (let* ((raw (if (string-prefix-p "file:" target)
                       (substring target 5)
                     target))
              (parts (split-string raw "::"))
              (path (etaf-org-preview--link-file target dir))
              (search (cadr parts)))
         (cond
          ((and path (string-match-p "\\.org\\'" path))
           (if (and search (file-readable-p path)
                    (equal (file-truename path)
                           (ignore-errors (file-truename (or (plist-get session :file) "")))))
               (etaf-org-preview--open-target session (concat "*" (string-trim-left search "[*]")))
             (find-file-other-window path)))
          ((and path (file-exists-p path) (etaf-org-preview--video-or-file-p path))
           (etaf-org-preview--open-file path))
          ((and path (file-exists-p path))
           (find-file-other-window path))
          ((and path (etaf-org-preview--remote-url-p path))
           (browse-url path))
          (t (message "Target not found: %s" target)))))
      (_ (message "This link type cannot be activated: %s" target)))))

(defun etaf-org-preview--video-or-file-p (path)
  "Return non-nil when PATH should open outside Emacs."
  (member (downcase (or (file-name-extension path) ""))
          (append etaf-org-preview--video-extensions '("pdf" "png" "jpg" "jpeg"
                                                       "gif" "svg" "webp"))))

(defun etaf-org-preview--jump-footnote (session label)
  "Move point to footnote LABEL in SESSION's buffer."
  (let* ((document (etaf-org-preview--read session :document))
         (entry (cl-find label (plist-get document :footnotes)
                         :key (lambda (footnote) (plist-get footnote :label))
                         :test #'equal))
         (buffer (etaf-org-preview--buffer session)))
    (if (and entry (buffer-live-p buffer))
        (with-current-buffer buffer
          (goto-char (point-max))
          (when (search-backward (format "[%d] " (plist-get entry :number)) nil t)
            (beginning-of-line)
            (when-let* ((window (get-buffer-window buffer t)))
              (with-selected-window window (recenter 0)))))
      (message "Footnote %s not found" label))))

;;; ---------------------------------------------------------------------------
;;; Rendering environment
;;; ---------------------------------------------------------------------------

(defun etaf-org-preview--display-frame (session)
  "Return the frame showing SESSION, or nil."
  (let ((buffer (plist-get session :buffer)))
    (when (buffer-live-p buffer)
      (when-let* ((window (get-buffer-window buffer t)))
        (window-frame window)))))

(defun etaf-org-preview--page-background (session)
  "Return the page background SESSION paints, or nil for the theme's own."
  (when (eq (etaf-org-preview--read session :theme-source) 'palette)
    (etaf-org-preview-color :bg
                            (cdr (assq (etaf-org-preview--read session :theme)
                                       etaf-org-preview-themes)))))

(defun etaf-org-preview--session-palette (session)
  "Return SESSION's palette alist."
  (if (eq (etaf-org-preview--read session :theme-source) 'palette)
      (cdr (assq (etaf-org-preview--read session :theme)
                 etaf-org-preview-themes))
    (etaf-org-preview--palette-from-faces
     (etaf-org-preview--display-frame session))))

(defun etaf-org-preview--toc-depth (session)
  "Return SESSION's table of contents depth, or nil when hidden."
  (let ((depth (plist-get session :toc-depth-base)))
    (when (and depth (etaf-org-preview--read session :toc-visible))
      depth)))

(defun etaf-org-preview--env-inputs (session)
  "Return the values SESSION's rendering environment is built from.
Reading them is what makes a block follow a palette, width, hidden-content or
title change; the document itself is not here, so publishing it does not hand
every retained block a new environment."
  (list :theme (etaf-org-preview--read session :theme)
        :theme-source (etaf-org-preview--read session :theme-source)
        :appearance (etaf-appearance)
        :frame (etaf-org-preview--display-frame session)
        :width (etaf-org-preview--read session :width)
        :hidden (etaf-org-preview--read session :hidden)
        :toc-visible (etaf-org-preview--read session :toc-visible)
        :title (etaf-org-preview--read session :title)
        :todo-keywords (plist-get session :todo-keywords)
        :show-tags (plist-get session :show-tags)
        :toc-depth (plist-get session :toc-depth-base)
        :modified (plist-get session :modified)))

(defun etaf-org-preview--build-env (session)
  "Build SESSION's rendering environment from its current inputs."
  (list :palette (etaf-org-preview--session-palette session)
        :width (etaf-org-preview--read session :width)
        :background (etaf-org-preview--page-background session)
        :base-pixels (etaf-org-preview--base-pixels)
        :image-max-rows etaf-org-preview-image-max-height
        :todo-keywords (plist-get session :todo-keywords)
        :show-tags (plist-get session :show-tags)
        :toc-depth (etaf-org-preview--toc-depth session)
        :hidden (etaf-org-preview--read session :hidden)
        :hidden-ref (etaf-org-preview--ref session :hidden)
        :fold-ref (lambda (id) (etaf-org-preview--fold-cell session id))
        :fallback-title (etaf-org-preview--read session :title)
        :modified (plist-get session :modified)
        :actions (list :toggle (lambda (id)
                                 (etaf-org-preview--toggle-fold session id))
                         :locate (lambda (id)
                                   (etaf-org-preview--reveal id session)
                                   (etaf-org-preview--locate-id session id))
                         :open (lambda (target)
                                 (etaf-org-preview--open-target session target))
                         :open-file (lambda (path)
                                      (etaf-org-preview--open-file path))
                         :footnote (lambda (label)
                                     (etaf-org-preview--jump-footnote session label))
                         :target (lambda (name)
                                   (etaf-org-preview--jump-target session name))
                       :hidden (lambda ()
                                 (etaf-org-preview-show-hidden
                                  session
                                  (not (etaf-org-preview--read session :hidden)))))))

(defun etaf-org-preview--env (session)
  "Return SESSION's rendering environment, reused until one of its inputs changes.
A block Component reads this plist in its own render, so a palette, width or
hidden-content change reaches it without a document publish."
  (let ((inputs (etaf-org-preview--env-inputs session)))
    (let ((cached (plist-get session :env-cache)))
      (if (equal (car cached) inputs)
          (cdr cached)
        (let ((env (etaf-org-preview--build-env session)))
          (plist-put session :env-cache (cons inputs env))
          env)))))

(defun etaf-org-preview--jump-target (session name)
  "Move point to SESSION's target NAME and recenter.
A target lives in the section that defines it, so a reference reaches the same
place whether the name was written as a radio target or as a plain target."
  (let* ((document (etaf-org-preview--read session :document))
         (section (gethash name (plist-get document :targets)))
         (id (and section (etaf-org-preview-section-id section))))
    (when id
      (etaf-org-preview--reveal id session)
      (etaf-org-preview--flush session)
      (etaf-org-preview--locate-id session id))))

(defun etaf-org-preview--toggle-fold (session id)
  "Advance the fold state of SESSION's section ID.
A section with children cycles folded, children and open; a leaf cycles
folded and open."
  (let* ((section (etaf-org-preview--section-by-id session id))
         (current (etaf-org-preview--fold-state session id))
         (has-children (and section (etaf-org-preview-section-children section)))
         (next (pcase current
                 ('folded (if has-children 'children 'open))
                 ('children 'open)
                 (_ 'folded))))
    (etaf-org-preview-fold session id next)))

;;; ---------------------------------------------------------------------------
;;; Following the source file
;;; ---------------------------------------------------------------------------

(defconst etaf-org-preview--follow-delay 0.25
  "Seconds to wait before a changed source repaints its preview.")

(defvar etaf-org-preview--follow-sessions (make-hash-table :test #'equal)
  "Displayed preview sessions by absolute source file name.")

(defvar etaf-org-preview--follow-watches (make-hash-table :test #'equal)
  "Change watches by absolute source file name.")

(defvar etaf-org-preview--follow-timers (make-hash-table :test #'equal)
  "Pending repaints by absolute source file name.")

;;; ---------------------------------------------------------------------------
;;; Following the source buffer
;;; ---------------------------------------------------------------------------

(defconst etaf-org-preview--live-delay 0.3
  "Seconds of quiet before an unsaved edit repaints its preview.")

(defun etaf-org-preview--live-schedule (session)
  "Schedule SESSION to repaint from its source buffer after the typing pauses."
  (when-let* ((old (plist-get session :live-timer)))
    (cancel-timer old))
  (plist-put session :live-timer
             (run-with-timer
              etaf-org-preview--live-delay nil
              (lambda ()
                (plist-put session :live-timer nil)
                (etaf-org-preview--live-flush session)))))

(defun etaf-org-preview--live-flush (session)
  "Repaint SESSION from its source buffer, or from its file after that closes."
  (let* ((buffer (plist-get session :source-buffer))
         (text (if (buffer-live-p buffer)
                   (with-current-buffer buffer
                     (buffer-substring-no-properties (point-min) (point-max)))
                 (etaf-org-preview--current-text session))))
    (unless (equal text (plist-get session :live-text))
      (condition-case error
          (etaf-org-preview--install session text)
        (error
         (message "Org preview kept its last render: %s"
                  (error-message-string error)))))))

(defun etaf-org-preview--live-changed (&rest _)
  "Schedule the source session of the current buffer to repaint."
  (when-let* ((session (plist-get (buffer-local-value 'etaf-org-preview--live-state
                                                      (current-buffer))
                                  :session)))
    (etaf-org-preview--live-schedule session)))

(defvar-local etaf-org-preview--live-state nil
  "The preview following this buffer, as a plist with its SESSION.")

(defun etaf-org-preview--live-register (session buffer)
  "Make SESSION follow unsaved edits in BUFFER."
  (when (buffer-live-p buffer)
    (etaf-org-preview--live-unregister session)
    (plist-put session :source-buffer buffer)
    (with-current-buffer buffer
      (setq-local etaf-org-preview--live-state (list :session session))
      (add-hook 'after-change-functions #'etaf-org-preview--live-changed nil t)
      (add-hook 'kill-buffer-hook
                (lambda ()
                  (plist-put session :source-buffer nil)
                  (etaf-org-preview--live-schedule session))
                nil t))
    (plist-put session :live-text
               (with-current-buffer buffer
                 (buffer-substring-no-properties (point-min) (point-max))))))

(defun etaf-org-preview--live-unregister (session)
  "Stop SESSION from following its source buffer."
  (let ((buffer (plist-get session :source-buffer)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (remove-hook 'after-change-functions #'etaf-org-preview--live-changed t)
        (kill-local-variable 'etaf-org-preview--live-state)))
    (when-let* ((timer (plist-get session :live-timer)))
      (cancel-timer timer))
    (plist-put session :live-timer nil)
    (plist-put session :source-buffer nil)))

(defun etaf-org-preview--follow-saved ()
  "Repaint the preview of the file being saved, when one is open."
  (when buffer-file-name
    (etaf-org-preview--follow-schedule (expand-file-name buffer-file-name))))

(defun etaf-org-preview--follow-watch (file)
  "Arm, or re-arm, FILE's change watch and return its descriptor."
  (when-let* ((old (gethash file etaf-org-preview--follow-watches)))
    (ignore-errors (file-notify-rm-watch old))
    (remhash file etaf-org-preview--follow-watches))
  (when-let* ((watch
               (condition-case nil
                   (file-notify-add-watch
                    file '(change)
                    (lambda (event)
                      (ignore event)
                      (etaf-org-preview--follow-schedule file)))
                 (file-error nil))))
    (puthash file watch etaf-org-preview--follow-watches)
    watch))

(defun etaf-org-preview--follow-register (session)
  "Make the displayed SESSION follow its source file."
  (when-let* ((path (plist-get session :file)))
    (let ((file (expand-file-name path)))
      (puthash file session etaf-org-preview--follow-sessions)
      (etaf-org-preview--follow-watch file)
      (add-hook 'after-save-hook #'etaf-org-preview--follow-saved t))))

(defun etaf-org-preview--follow-unregister (file)
  "Stop following FILE: drop its watch, pending repaint and session."
  (when-let* ((file (and file (expand-file-name file))))
    (when-let* ((watch (gethash file etaf-org-preview--follow-watches)))
      (ignore-errors (file-notify-rm-watch watch))
      (remhash file etaf-org-preview--follow-watches))
    (when-let* ((timer (gethash file etaf-org-preview--follow-timers)))
      (cancel-timer timer)
      (remhash file etaf-org-preview--follow-timers))
    (remhash file etaf-org-preview--follow-sessions)
    (when (zerop (hash-table-count etaf-org-preview--follow-sessions))
      (remove-hook 'after-save-hook #'etaf-org-preview--follow-saved))))

(defun etaf-org-preview--follow-schedule (file)
  "Repaint FILE's preview once the source changes settle."
  (when (gethash file etaf-org-preview--follow-sessions)
    (when-let* ((pending (gethash file etaf-org-preview--follow-timers)))
      (cancel-timer pending))
    (puthash file
             (run-with-timer etaf-org-preview--follow-delay nil
                             #'etaf-org-preview--follow-repaint file)
             etaf-org-preview--follow-timers)))

(defun etaf-org-preview--follow-repaint (file)
  "Repaint FILE's preview and keep the reader in the same section."
  (remhash file etaf-org-preview--follow-timers)
  (when-let* ((session (gethash file etaf-org-preview--follow-sessions))
              (buffer (plist-get session :buffer))
              ((buffer-live-p buffer)))
    (let ((section (etaf-org-preview--reading-section session)))
      (condition-case error
          (progn
            (etaf-org-preview-refresh session)
            (when-let* ((runtime (etaf-runtime-for-buffer buffer)))
              (etaf-runtime-flush runtime))
            (when section
              (etaf-org-preview--locate-id session section)))
        (etaf-org-preview-error
         (message "Preview kept its last render: %s"
                  (error-message-string error)))))))

(provide 'etaf-org-preview-model)
;;; etaf-org-preview-model.el ends here
