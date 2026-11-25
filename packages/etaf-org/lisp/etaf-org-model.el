;;; etaf-org-model.el --- Session state, publishing, navigation & actions -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; Session state of `etaf-org'.  A session is a plist of reactive cells
;; holding the parsed and derived document, palette, measure, viewport width,
;; per-section fold cells, per-block reactive cells & local widget state,
;; TOC visibility/docking, spoiler toggle, live section filter, peek card,
;; and media lightbox state.
;;
;; Publishing attaches local media sizes, L1 workspace snapshots, cached
;; KaTeX/Mermaid/diagram pictures, and QR codes outside `:render', preserving
;; stable block slots so unchanged blocks never repaint and async results
;; repaint only their owning block.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'etaf)
(require 'etaf-ui)
(require 'etaf-org-cache)
(require 'etaf-org-theme)
(require 'etaf-org-node)
(require 'etaf-org-env)
(require 'etaf-org-parse)
(require 'etaf-org-derive)
(require 'etaf-org-assets)
(require 'etaf-org-typeset)
(require 'etaf-org-qrcode)
(require 'etaf-org-views)

(declare-function etaf-org-open "etaf-org-app" (&optional source))
(declare-function org-id-find "org-id" (id &optional markerp))

(defcustom etaf-org-width-min 40
  "Narrowest reading measure, in character cells."
  :type 'integer
  :group 'etaf-org)

(defcustom etaf-org-width-max 96
  "Widest reading measure, in character cells."
  :type 'integer
  :group 'etaf-org)

(defcustom etaf-org-image-max-height 24
  "Tallest image, in text lines."
  :type 'integer
  :group 'etaf-org)

;;; ---------------------------------------------------------------------------
;;; Reactive Refs
;;; ---------------------------------------------------------------------------

(defun etaf-org--ref (session key)
  "Return SESSION's reactive source named KEY."
  (plist-get session key))

(defun etaf-org--read (session key)
  "Return SESSION's current value for KEY, tracked while rendering."
  (when-let* ((ref (etaf-org--ref session key)))
    (etaf-value ref)))

(defun etaf-org--write (session key value)
  "Publish VALUE as SESSION's new value for KEY and return it."
  (when-let* ((ref (etaf-org--ref session key)))
    (unless (equal (etaf-value ref) value)
      (etaf-set-value ref value)))
  value)

;;; ---------------------------------------------------------------------------
;;; Tree walking & Source reading
;;; ---------------------------------------------------------------------------

(defun etaf-org--walk-sections (sections function)
  "Call FUNCTION on every section in SECTIONS."
  (dolist (section sections)
    (funcall function section)
    (etaf-org--walk-sections (etaf-org-section-children section) function)))

(defun etaf-org--walk-blocks (blocks function)
  "Call FUNCTION on every block in BLOCKS recursively."
  (dolist (block blocks)
    (funcall function block)
    (when-let* ((children (plist-get block :blocks)))
      (etaf-org--walk-blocks children function))
    (dolist (ch (plist-get block :children))
      (when (and (listp ch) (keywordp (car ch)))
        (funcall function ch)
        (when-let* ((kids (plist-get ch :blocks)))
          (etaf-org--walk-blocks kids function))))
    (dolist (item (plist-get block :items))
      (etaf-org--walk-blocks (plist-get item :blocks) function))))

(defun etaf-org--walk-document-blocks (document function)
  "Call FUNCTION on every block across DOCUMENT's preamble and sections."
  (when document
    (etaf-org--walk-blocks (plist-get document :preamble) function)
    (etaf-org--walk-sections
     (plist-get document :sections)
     (lambda (section)
       (etaf-org--walk-blocks (etaf-org-section-body section) function)))))

(defun etaf-org--remote-url-p (target)
  "Return non-nil when TARGET is a remote resource."
  (and (stringp target)
       (string-match-p "\\`[a-zA-Z][a-zA-Z0-9+.-]*://" target)))

(defun etaf-org--read-source (file)
  "Return FILE's text, signaling `etaf-org-error' on failure."
  (unless (file-readable-p file)
    (signal 'etaf-org-error (list (format "Cannot read file: %s" file))))
  (with-temp-buffer
    (insert-file-contents file)
    (buffer-string)))

(defun etaf-org--parse-text (text session &optional live-p)
  "Parse TEXT for SESSION (with optional LIVE-P provisional block closing)."
  (condition-case err
      (let* ((setup-lines (etaf-org-assets-collect-setupfiles session text))
             (doc (etaf-org--parse text
                                   :file (plist-get session :file)
                                   :flavor (plist-get session :flavor)
                                   :setup-lines setup-lines
                                   :live-p live-p)))
        (setq doc (etaf-org-derive doc (plist-get session :today)))
        (let ((bib (etaf-org-assets-load-bibliographies session doc)))
          (plist-put doc :bibliography bib)))
    (etaf-org-error (signal 'etaf-org-error (cdr err)))
    (error (signal 'etaf-org-error (cdr err)))))

;;; ---------------------------------------------------------------------------
;;; Media resolution (publish-time, zero network I/O in headless)
;;; ---------------------------------------------------------------------------

(defun etaf-org--link-file (target dir)
  "Return TARGET as an absolute file name relative to DIR, or nil."
  (let* ((raw (if (string-prefix-p "file:" target)
                  (substring target 5)
                target))
         (path (car (split-string raw "::")))
         (path (if (string-prefix-p "attachment:" (or path ""))
                   (substring path 11)
                 path)))
    (when (and path (not (string-empty-p path))
               (not (etaf-org--remote-url-p path)))
      (expand-file-name path (or dir default-directory)))))

(defun etaf-org--lone-link (block)
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

(defun etaf-org--resolve-media-block (block session)
  "Attach `:media' descriptor onto BLOCK when it displays a single image/video."
  (let ((link (etaf-org--lone-link block)))
    (cond
     ((and link (memq (plist-get link :kind) '(file other attachment)))
      (let* ((target (plist-get link :target))
             (path (etaf-org--link-file target (plist-get session :dir)))
             (ext (and path (downcase (or (file-name-extension path) ""))))
             (image (member ext etaf-org--image-extensions))
             (video (member ext etaf-org--video-extensions))
             (size (and image path (file-exists-p path)
                        (etaf-org-typeset--image-pixels path))))
        (if (or image video)
            (plist-put (copy-sequence block) :media
                       (list :path path
                             :kind (if image 'image 'video)
                             :exists (and path (file-exists-p path))
                             :width (car size)
                             :height (cdr size)
                             :attrs (plist-get block :attrs)
                             :alt (plist-get (plist-get block :attrs) :alt)))
          block)))
     ;; Remote image URL cached on disk (fetched asynchronously only when mounted).
     ((and link (eq (plist-get link :kind) 'url)
           (let ((u (plist-get link :target)))
             (and u (member (downcase (or (file-name-extension
                                           (car (split-string u "[?#]")))
                                          ""))
                            etaf-org--image-extensions))))
      (let* ((url (plist-get link :target))
             (cached (etaf-org-cache-image-path url))
             (size (and cached (etaf-org-typeset--image-pixels cached))))
        (plist-put (copy-sequence block) :media
                   (list :path (or cached url)
                         :remote-url url
                         :kind 'image
                         :exists (and cached (file-exists-p cached))
                         :width (car size)
                         :height (cdr size)
                         :attrs (plist-get block :attrs)
                         :alt (plist-get (plist-get block :attrs) :alt)))))
     (t block))))

(defun etaf-org--attach-block-assets (session document block env &optional section)
  "Attach media, L1 snapshots, cached typeset pictures and QR codes to BLOCK."
  (let ((b (etaf-org--resolve-media-block block session)))
    (setq b (etaf-org-assets-attach-block session document b section))
    (setq b (etaf-org-typeset-attach b env))
    (setq b (etaf-org-qrcode-attach b))
    (when-let* ((kids (plist-get b :blocks)))
      (setq b (plist-put (copy-sequence b) :blocks
                         (mapcar (lambda (k)
                                   (etaf-org--attach-block-assets
                                    session document k env section))
                                 kids))))
    (when-let* ((children (plist-get b :children)))
      (setq b (plist-put (copy-sequence b) :children
                         (mapcar (lambda (ch)
                                   (if (and (listp ch) (keywordp (car ch)))
                                       (etaf-org--attach-block-assets
                                        session document ch env section)
                                     ch))
                                 children))))
    (when-let* ((items (plist-get b :items)))
      (setq b (plist-put (copy-sequence b) :items
                         (mapcar (lambda (it)
                                   (plist-put (copy-sequence it) :blocks
                                              (mapcar (lambda (k)
                                                        (etaf-org--attach-block-assets
                                                         session document k env section))
                                                      (plist-get it :blocks))))
                                 items))))
    b))

;;; ---------------------------------------------------------------------------
;;; Section fold cells & Filtering
;;; ---------------------------------------------------------------------------

(defun etaf-org--build-section-cells (session document)
  "Create or retain SESSION's per-section fold cells for DOCUMENT."
  (let* ((existing (plist-get session :sections))
         (cells (make-hash-table :test #'equal)))
    (etaf-org--walk-sections
     (plist-get document :sections)
     (lambda (section)
       (let* ((id (etaf-org-section-id section))
              (old (and (hash-table-p existing) (gethash id existing)))
              (state (if (or (etaf-org-section-commented section)
                             (etaf-org-section-archived section))
                         'folded
                       'open)))
         (puthash id
                  (list :fold (or (plist-get old :fold)
                                  (etaf-ref state :name 'org-fold)))
                  cells))))
    (plist-put session :sections cells)))

(defun etaf-org--fold-cell (session id)
  "Return SESSION's fold cell of section ID."
  (when-let* ((ht (plist-get session :sections)))
    (plist-get (gethash id ht) :fold)))

(defun etaf-org--fold-state (session id)
  "Return the fold state of SESSION's section ID."
  (when-let* ((cell (etaf-org--fold-cell session id)))
    (etaf-value cell)))

(defun etaf-org--section-by-id (session id)
  "Return SESSION's section struct whose id is ID."
  (let* ((doc (etaf-org--read session :document))
         (ht (plist-get doc :section-by-id)))
    (or (and (hash-table-p ht) (gethash id ht))
        (let ((found nil))
          (etaf-org--walk-sections
           (plist-get doc :sections)
           (lambda (section)
             (when (equal (etaf-org-section-id section) id)
               (setq found section))))
          found))))

(defun etaf-org-fold (session id state)
  "Set the fold STATE of SESSION's section ID and return SESSION.
STATE is `folded', `children' or `open'."
  (unless (memq state '(folded children open))
    (signal 'etaf-org-error (list (format "Unknown fold state: %S" state))))
  (let ((cell (etaf-org--fold-cell session id)))
    (unless cell
      (signal 'etaf-org-error (list (format "Unknown section: %s" id))))
    (if (eq state 'children)
        (etaf-batch
          (when-let* ((section (etaf-org--section-by-id session id)))
            (etaf-org--walk-sections
             (etaf-org-section-children section)
             (lambda (child)
               (when-let* ((child-cell (etaf-org--fold-cell
                                        session (etaf-org-section-id child))))
                 (etaf-set-value child-cell 'folded)))))
          (etaf-set-value cell state))
      (etaf-set-value cell state)))
  session)

(defun etaf-org-folded-p (session id)
  "Return non-nil when SESSION's section ID is folded."
  (eq (etaf-org--fold-state session id) 'folded))

(defun etaf-org-fold-all (session state)
  "Set every section of SESSION to fold STATE in one batch and return SESSION."
  (unless (memq state '(folded children open))
    (signal 'etaf-org-error (list (format "Unknown fold state: %S" state))))
  (etaf-batch
    (maphash (lambda (_id cell)
               (etaf-set-value (plist-get cell :fold) state))
             (plist-get session :sections)))
  session)

(defun etaf-org--toggle-fold (session id)
  "Advance fold state of SESSION's section ID (`folded' -> `children' -> `open')."
  (let* ((section (etaf-org--section-by-id session id))
         (current (etaf-org--fold-state session id))
         (has-children (and section (etaf-org-section-children section)))
         (next (pcase current
                 ('folded (if has-children 'children 'open))
                 ('children 'open)
                 (_ 'folded))))
    (etaf-org-fold session id next)
    next))

(defun etaf-org--cycle-global (session)
  "Cycle document-wide fold state between `overview' and `content'."
  (let ((next (if (eq (plist-get session :global-state) 'overview)
                  'content
                'overview)))
    (plist-put session :global-state next)
    (etaf-org-fold-all session (if (eq next 'content) 'open 'folded))
    next))

(defun etaf-org--section-self-matches-p (section filter)
  "Return non-nil when SECTION itself matches FILTER query string."
  (let ((tokens (split-string (string-trim (or filter "")) "[ \t]+" t))
        (todo (or (etaf-org-section-todo section) ""))
        (prio (or (etaf-org-section-priority section) ""))
        (title (downcase (or (etaf-org-section-title-plain section) "")))
        (tags (mapcar #'downcase (etaf-org-section-effective-tags section)))
        (ok t))
    (dolist (tok tokens)
      (when ok
        (let ((ltok (downcase tok)))
          (cond
           ((string-prefix-p ":" ltok)
            (let ((tag (string-trim ltok ":" ":")))
              (unless (member tag tags) (setq ok nil))))
           ((string-prefix-p "todo:" ltok)
            (unless (equal (downcase todo) (substring ltok 5)) (setq ok nil)))
           ((string-prefix-p "#" ltok)
            (unless (equal (downcase prio) (substring ltok 1)) (setq ok nil)))
           ((string-prefix-p "!" ltok)
            (let ((neg (substring ltok 1)))
              (when (or (string-match-p (regexp-quote neg) title)
                        (member neg tags)
                        (equal (downcase todo) neg))
                (setq ok nil))))
           (t
            (unless (or (string-match-p (regexp-quote ltok) title)
                        (equal (downcase todo) ltok)
                        (member ltok tags))
              (setq ok nil)))))))
    ok))

(defun etaf-org--section-matches-filter-p (section filter)
  "Return non-nil when SECTION or any descendant matches FILTER."
  (or (null filter)
      (string-blank-p filter)
      (etaf-org--section-self-matches-p section filter)
      (cl-some (lambda (child)
                 (etaf-org--section-matches-filter-p child filter))
               (etaf-org-section-children section))))

(defun etaf-org-set-filter (session filter)
  "Set live section FILTER string on SESSION (nil or empty clears it)."
  (let ((norm (and (stringp filter)
                   (not (string-blank-p filter))
                   (string-trim filter))))
    (etaf-org--write session :filter norm))
  session)

(defun etaf-org--clear-filter (session)
  "Clear active section filter on SESSION."
  (etaf-org-set-filter session nil))

;;; ---------------------------------------------------------------------------
;;; Published entries & Per-block reactive slots
;;; ---------------------------------------------------------------------------

(defun etaf-org--digest (value)
  "Return a stable SHA-1 digest of VALUE."
  (let ((print-circle t)
        (print-length nil)
        (print-level nil))
    (secure-hash 'sha1 (prin1-to-string value))))

(defun etaf-org--register-slot-ids (session block slot)
  "Record SLOT in SESSION's `:id-slots' under any `#+NAME:' or `:id' attr."
  (let ((ht (plist-get session :id-slots)))
    (when (hash-table-p ht)
      (when-let* ((bname (plist-get block :block-name)))
        (puthash bname slot ht))
      (when-let* ((aid (plist-get (plist-get block :attrs) :id)))
        (puthash aid slot ht)))))

(defun etaf-org--block-entry (session document block env published table counts &optional section)
  "Return published entry (with stable reactive slot) for BLOCK."
  (let* ((attached (etaf-org--attach-block-assets session document block env section))
         (digest (concat "b:" (etaf-org--digest attached)))
         (occurrence (1+ (gethash digest counts 0)))
         (key (if (= 1 occurrence) digest (format "%s#%d" digest occurrence)))
         (existing (gethash key published))
         (entry
          (if existing
              (progn
                (etaf-org--register-slot-ids session attached (plist-get existing :slot))
                existing)
            (let* ((cell (etaf-ref attached :name 'org-block-cell))
                   (state (etaf-ref nil :name 'org-block-state))
                   (override (etaf-ref nil :name 'org-block-override))
                   (slot (list :key key :cell cell :state state :override override
                               :section section))
                   (view (etaf-node 'etaf-org-block
                                    (list :key key :session session :slot slot)
                                    nil)))
              (etaf-org--register-slot-ids session attached slot)
              (list :key key :block attached :slot slot :view view)))))
    (puthash digest occurrence counts)
    (puthash key entry table)
    entry))

(defun etaf-org--section-entry (session document section env published table counts)
  "Return published entry of SECTION and record its slots."
  (let* ((body-blocks (cl-remove-if
                       (lambda (block) (eq (plist-get block :type) 'footnote-def))
                       (etaf-org-section-body section)))
         (body (mapcar (lambda (block)
                         (etaf-org--block-entry
                          session document block env published table counts section))
                       body-blocks))
         (children (mapcar (lambda (child)
                             (etaf-org--section-entry
                              session document child env published table counts))
                           (etaf-org-section-children section)))
         (id (etaf-org-section-id section))
         (fold (etaf-org--fold-cell session id))
         (digest (etaf-org--digest
                  (list id
                        (etaf-org-section-level section)
                        (etaf-org-section-number section)
                        (etaf-org-section-todo section)
                        (etaf-org-section-priority section)
                        (etaf-org-section-title section)
                        (etaf-org-section-title-inlines section)
                        (etaf-org-section-tags section)
                        (etaf-org-section-planning section)
                        (etaf-org-section-properties section)
                        (etaf-org-section-logbook section)
                        (etaf-org-section-logbook-text section)
                        (etaf-org-section-archived section)
                        (etaf-org-section-commented section)
                        (mapcar (lambda (e) (plist-get e :key)) body)
                        (mapcar (lambda (e) (plist-get e :key)) children))))
         (key (concat "s:" digest))
         (old (gethash key published))
         (entry (if (and old (eq (plist-get old :fold) fold))
                    old
                  (list :key key :fold fold :section section
                        :body body :children children
                        :view (etaf-node 'etaf-org-section
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
    (puthash id body (plist-get session :slots-by-section))
    (puthash key entry table)
    entry))

(defun etaf-org--keyed-document (session document)
  "Replace DOCUMENT's preamble and sections with keyed reactive entries."
  (let* ((published (or (plist-get session :published) (make-hash-table :test #'equal)))
         (table (make-hash-table :test #'equal))
         (counts (make-hash-table :test #'equal))
         (id-slots (make-hash-table :test #'equal))
         (slots-by-sec (make-hash-table :test #'equal))
         (env (etaf-org--env session)))
    (plist-put session :id-slots id-slots)
    (plist-put session :slots-by-section slots-by-sec)
    (let ((preamble (mapcar (lambda (block)
                              (etaf-org--block-entry
                               session document block env published table counts nil))
                            (plist-get document :preamble)))
          (sections (mapcar (lambda (section)
                              (etaf-org--section-entry
                               session document section env published table counts))
                            (plist-get document :sections))))
      (plist-put session :published table)
      (plist-put document :preamble-entries preamble)
      (plist-put document :section-entries sections))))

(defun etaf-org--refresh-block-assets (session)
  "Re-attach assets/pictures on SESSION's existing slots, repainting only diffs."
  (when-let* ((doc (etaf-org--read session :document))
              (published (plist-get session :published)))
    (let ((env (etaf-org--env session))
          (changed nil))
      (etaf-batch
        (maphash
         (lambda (_k entry)
           (when-let* ((slot (plist-get entry :slot))
                       (cell (plist-get slot :cell))
                       (cur (etaf-value cell)))
             (let ((next (etaf-org--attach-block-assets
                          session doc cur env (plist-get slot :section))))
               (unless (equal next cur)
                 (etaf-set-value cell next)
                 (plist-put entry :block next)
                 (setq changed t)))))
         published))
      (when changed
        (etaf-org--flush session)))))

(defun etaf-org--propagate-target (session target-id key value)
  "Propagate reactive state KEY = VALUE to the block slot named TARGET-ID."
  (when-let* ((ht (plist-get session :id-slots))
              (slot (and (hash-table-p ht) (gethash target-id ht)))
              (state-ref (plist-get slot :state)))
    (let ((old (copy-sequence (or (etaf-value state-ref) nil))))
      (etaf-set-value state-ref (plist-put old key value)))))

(defun etaf-org-update-block (session id view)
  "Replace the rendered ETAF View of SESSION's named block ID with VIEW.
Passing nil for VIEW restores the block's normal rendering.  Signals
`etaf-org-error' when ID is not present in SESSION."
  (let* ((ht (plist-get session :id-slots))
         (slot (and (hash-table-p ht) (gethash id ht))))
    (unless slot
      (signal 'etaf-org-error (list (format "Unknown block id: %s" id))))
    (etaf-set-value (plist-get slot :override) view)
    session))

;;; ---------------------------------------------------------------------------
;;; Install & Session Lifecycle
;;; ---------------------------------------------------------------------------

(defun etaf-org--current-text (session)
  "Return the text SESSION currently shows, preferring an unsaved source buffer."
  (let* ((buffer (plist-get session :source-buffer))
         (file (plist-get session :file))
         (visiting (and (buffer-live-p buffer)
                        (buffer-local-value 'buffer-file-name buffer)
                        file
                        (equal (ignore-errors (file-truename
                                               (buffer-local-value 'buffer-file-name buffer)))
                               (ignore-errors (file-truename file))))))
    (cond
     ((and visiting (buffer-modified-p buffer))
      (with-current-buffer buffer
        (buffer-substring-no-properties (point-min) (point-max))))
     (file (etaf-org--read-source file))
     ((buffer-live-p buffer)
      (with-current-buffer buffer
        (buffer-substring-no-properties (point-min) (point-max))))
     (t (or (plist-get session :text) "")))))

(defun etaf-org--request-async-assets (session)
  "Kick off async background asset jobs for a mounted SESSION."
  (when (buffer-live-p (plist-get session :buffer))
    (etaf-org-typeset-request session)
    (etaf-org-qrcode-request session)
    (etaf-org-assets-request session)
    (etaf-org-cache-request-images session)))

(defun etaf-org--install (session contents &optional title live-p)
  "Parse CONTENTS and publish it as SESSION's document; return the document."
  (let* ((document (etaf-org--parse-text contents session live-p))
         (options (plist-get document :options))
         (file (plist-get session :file)))
    (plist-put session :text (unless file contents))
    (plist-put session :live-text contents)
    (plist-put session :todo-keywords (plist-get document :todo-keywords))
    (plist-put session :show-tags (plist-get options :tags))
    (plist-put session :features (plist-get document :features))
    (plist-put session :bibliography (plist-get document :bibliography))
    (plist-put session :abbreviations (plist-get document :abbreviations))
    (plist-put session :toc-depth-base
               (or (plist-get session :toc) (plist-get options :toc)))
    (plist-put session :modified
               (when (and file (file-exists-p file))
                 (format-time-string "更新于 %Y-%m-%d %H:%M"
                                     (file-attribute-modification-time
                                      (file-attributes file)))))
    (plist-put session :env-cache nil)
    (etaf-org--build-section-cells session document)
    (let ((keyed (etaf-org--keyed-document session document)))
      (etaf-batch
        (etaf-set-value (etaf-org--ref session :document) keyed)
        (etaf-set-value (etaf-org--ref session :title)
                        (or title (plist-get keyed :title)
                            (and file (file-name-base file))
                            "Org 文档"))
        (etaf-set-value (etaf-org--ref session :error) nil))
      (etaf-org--request-async-assets session)
      keyed)))

(cl-defun etaf-org-create (&key file text title theme flavor toc today
                                on-link on-media on-action
                                (link-hover t) (heading-underline t))
  "Create a headless Org session and return it.
FILE names an Org document to read; TEXT supplies the document directly.
TITLE overrides the document title; THEME selects `auto', `dark', `light' or
`sepia' (defaulting to `etaf-org-theme'); FLAVOR selects `etaf', `standard'
or a feature plist; TOC overrides `#+OPTIONS: toc' depth; TODAY injects
`(Y M D)' or `YYYY-MM-DD' for deterministic deadline overdue computation;
ON-LINK, ON-MEDIA and ON-ACTION intercept links, media and widget actions;
LINK-HOVER and HEADING-UNDERLINE default to t."
  (etaf-org--load-user-nodes)
  (let* ((file (and file (expand-file-name file)))
         (contents (cond (text text)
                         (file (etaf-org--read-source file))
                         (t (signal 'etaf-org-error
                                    '("etaf-org-create needs :file or :text")))))
         (requested (or theme etaf-org-theme))
         (_ (unless (or (eq requested 'auto) (assq requested etaf-org-themes))
              (signal 'etaf-org-error
                      (list (format "Unknown org theme: %S" requested)))))
         (auto (eq requested 'auto))
         (session (list :file file
                        :text (unless file contents)
                        :live-text contents
                        :dir (if file (file-name-directory file) default-directory)
                        :flavor flavor
                        :today today
                        :toc toc
                        :on-link on-link
                        :on-media on-media
                        :on-action on-action
                        :link-hover (and link-hover t)
                        :heading-underline (and heading-underline t)
                        :document (etaf-ref nil :name 'org-document)
                        :title (etaf-ref (or title "") :name 'org-title)
                        :theme-mode (etaf-ref requested :name 'org-theme-mode)
                        :theme-source (etaf-ref (if auto 'frame 'palette)
                                                :name 'org-theme-source)
                        :theme (etaf-ref (if auto (etaf-appearance) requested)
                                         :name 'org-theme)
                        :width (etaf-ref 92 :name 'org-width)
                        :viewport-width (etaf-ref 96 :name 'org-viewport-width)
                        :hidden (etaf-ref nil :name 'org-hidden)
                        :toc-visible (etaf-ref t :name 'org-toc)
                        :toc-open (etaf-ref nil :name 'org-toc-open)
                        :active-section (etaf-ref nil :name 'org-active-section)
                        :spoilers-revealed (etaf-ref nil :name 'org-spoilers)
                        :filter (etaf-ref nil :name 'org-filter)
                        :peek (etaf-ref nil :name 'org-peek)
                        :lightbox (etaf-ref nil :name 'org-lightbox)
                        :error (etaf-ref nil :name 'org-error-text)
                        :sections (make-hash-table :test #'equal)
                        :published (make-hash-table :test #'equal)
                        :id-slots (make-hash-table :test #'equal)
                        :slots-by-section (make-hash-table :test #'equal)
                        :assets (make-hash-table :test #'equal)
                        :assets-running (make-hash-table :test #'equal)
                        :buffer nil)))
    (etaf-org--install session contents title)
    session))

(defun etaf-org-state (session)
  "Return SESSION's state as a detached plist snapshot."
  (let* ((document (etaf-org--read session :document))
         (counts (copy-sequence (or (plist-get document :counts)
                                    (list :todo 0 :done 0 :deadline 0
                                          :overdue 0 :clock-minutes 0)))))
    (list :file (plist-get session :file)
          :title (etaf-org--read session :title)
          :author (plist-get document :author)
          :date (plist-get document :date)
          :keywords (copy-sequence (plist-get document :keywords))
          :filetags (copy-sequence (plist-get document :filetags))
          :flavor (plist-get document :flavor)
          :theme (etaf-org--read session :theme)
          :theme-mode (etaf-org--read session :theme-mode)
          :background (when (eq (etaf-org--read session :theme-source) 'palette)
                        'palette)
          :width (etaf-org--read session :width)
          :buffer (plist-get session :buffer)
          :outline (copy-tree (plist-get document :outline))
          :sections (length (plist-get document :outline))
          :blocks (plist-get document :blocks)
          :footnotes (mapcar (lambda (footnote) (plist-get footnote :label))
                             (plist-get document :footnotes))
          :citations (copy-sequence (plist-get document :citations))
          :filter (etaf-org--read session :filter)
          :spoilers-revealed (etaf-org--read session :spoilers-revealed)
          :degraded (or (plist-get document :degraded) 0)
          :counts counts
          :error (etaf-org--read session :error))))

(defun etaf-org--republish (session)
  "Republish SESSION's current source (e.g. after theme or style change)."
  (plist-put session :env-cache nil)
  (when (or (plist-get session :buffer)
            (plist-get session :file)
            (plist-get session :text))
    (etaf-org--install session (etaf-org--current-text session)))
  session)

(defun etaf-org-refresh (session)
  "Re-read and re-parse SESSION's document and return SESSION.
A read failure signals `etaf-org-error' and leaves the published document
untouched."
  (etaf-org--install session (etaf-org--current-text session))
  session)

(defun etaf-org-set-theme (session theme)
  "Show SESSION with palette THEME (`auto', `dark', `light', `sepia')."
  (unless (or (eq theme 'auto) (assq theme etaf-org-themes))
    (signal 'etaf-org-error
            (list (format "Unknown org theme: %S" theme))))
  (etaf-batch
    (etaf-org--write session :theme-mode theme)
    (etaf-org--write session :theme
                     (if (eq theme 'auto) (etaf-appearance) theme))
    (etaf-org--write session :theme-source
                     (if (eq theme 'auto) 'frame 'palette)))
  (etaf-org--republish session)
  session)

(defun etaf-org-cycle-theme (&optional session)
  "Cycle SESSION (or current preview) through `dark', `light', `sepia' and `auto'.
Return the new theme mode symbol."
  (let* ((implicit-p (null session))
         (session (or session
                      (etaf-app-state)
                      (user-error "Not an ETAF org preview buffer")))
         (order (append (mapcar #'car etaf-org-themes) '(auto)))
         (current (etaf-org--read session :theme-mode))
         (tail (cdr (memq current order)))
         (next (or (car tail) (car order))))
    (etaf-org-set-theme session next)
    (etaf-org--flush session)
    (when-let* ((toc-buf (plist-get session :toc-buffer))
                ((buffer-live-p toc-buf))
                (rt (etaf-runtime-for-buffer toc-buf)))
      (etaf-runtime-flush rt))
    (when implicit-p
      (message "主题：%s" next))
    next))

(defun etaf-org-outline (session)
  "Return SESSION's outline as `(LEVEL TITLE ID TODO TAGS)' entries."
  (copy-tree (plist-get (etaf-org--read session :document) :outline)))

(defun etaf-org-show-toc (session show)
  "Show or hide SESSION's table of contents and return SESSION."
  (etaf-org--write session :toc-visible (and show t))
  session)

(defun etaf-org-show-hidden (session show)
  "Show or hide SESSION's hidden content and return SESSION."
  (etaf-org--write session :hidden (and show t))
  session)

(defun etaf-org-adjust-width (session delta)
  "Change SESSION's maximum reading measure by DELTA cells and return it."
  (let ((width (max etaf-org-width-min
                    (min etaf-org-width-max
                         (+ (etaf-org--read session :width) delta)))))
    (etaf-org--write session :width width)
    width))

;;; ---------------------------------------------------------------------------
;;; Navigation, Peek & Lightbox
;;; ---------------------------------------------------------------------------

(defun etaf-org--buffer (session)
  "Return SESSION's buffer, or current buffer when mounted headlessly."
  (let ((buffer (plist-get session :buffer)))
    (cond
     ((buffer-live-p buffer) buffer)
     ((etaf-runtime-for-buffer (current-buffer)) (current-buffer))
     (t nil))))

(defun etaf-org--runtime (session)
  "Return SESSION's mounted Runtime, or nil."
  (when-let* ((buffer (etaf-org--buffer session)))
    (etaf-runtime-for-buffer buffer)))

(defun etaf-org--flush (session)
  "Flush SESSION's runtime when mounted."
  (when-let* ((runtime (etaf-org--runtime session)))
    (etaf-runtime-flush runtime)))

(defun etaf-org--positions (session)
  "Return `(ID . POSITION)' for every rendered heading of SESSION."
  (let ((runtime (etaf-org--runtime session))
        (result nil))
    (when runtime
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

(defun etaf-org--position (session id)
  "Return the buffer position of section ID's heading in SESSION."
  (cdr (assoc id (etaf-org--positions session))))

(defun etaf-org--locate-id (session id)
  "Move point to SESSION's section ID (pushing mark) and recenter."
  (when-let* ((position (etaf-org--position session id)))
    (let ((buffer (etaf-org--buffer session)))
      (when (buffer-live-p buffer)
        (with-current-buffer buffer
          (push-mark (point) t)
          (goto-char position)
          (skip-chars-forward " \t\n")
          (beginning-of-line)
          (let ((pt (point)))
            (when-let* ((window (get-buffer-window buffer t)))
              (set-window-point window pt)
              (with-selected-window window
                (goto-char pt)
                (recenter 0))))))
      (etaf-org--write session :active-section id)
      (when-let* ((toc-buf (plist-get session :toc-buffer))
                  ((buffer-live-p toc-buf))
                  (rt (etaf-runtime-for-buffer toc-buf)))
        (etaf-runtime-flush rt))
      position)))

(defun etaf-org--sync-active-section (session &optional force)
  "Update SESSION's `:active-section' ref to match point in its preview buffer.
Runs only when the side-window outline is open unless FORCE is non-nil."
  (when (and session (or force (etaf-org--read session :toc-open)))
    (when-let* ((id (etaf-org--reading-section session)))
      (unless (equal id (etaf-org--read session :active-section))
        (etaf-org--write session :active-section id)
        (when-let* ((toc-buf (plist-get session :toc-buffer))
                    ((buffer-live-p toc-buf))
                    (rt (etaf-runtime-for-buffer toc-buf)))
          (etaf-runtime-flush rt))))))

(defun etaf-org--ancestor-path (session id)
  "Return the ids of ID's ancestors in SESSION, outermost first."
  (let* ((outline (etaf-org-outline session))
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

(defun etaf-org--reveal (id session)
  "Open every ancestor of section ID in SESSION."
  (let ((changed nil))
    (when id
      (dolist (ancestor (etaf-org--ancestor-path session id))
        (unless (eq (etaf-org--fold-state session ancestor) 'open)
          (etaf-org-fold session ancestor 'open)
          (setq changed t))))
    changed))

(defun etaf-org-locate (session index)
  "Move point to SESSION's outline heading INDEX and recenter."
  (let ((entry (nth index (etaf-org-outline session))))
    (when entry
      (let ((id (nth 2 entry)))
        (etaf-org--reveal id session)
        (etaf-org--flush session)
        (etaf-org--locate-id session id)))))

(defun etaf-org--reading-section (session)
  "Return the id of the section that contains point in SESSION, or nil."
  (let* ((buffer (etaf-org--buffer session))
         (point-now (if (buffer-live-p buffer)
                        (with-current-buffer buffer (point))
                      0))
         (found nil))
    (dolist (cell (etaf-org--positions session))
      (when (<= (cdr cell) point-now)
        (setq found (car cell))))
    found))

(defun etaf-org--adjacent-heading (session direction)
  "Move point to the next visible heading in DIRECTION."
  (let* ((buffer (etaf-org--buffer session))
         (point-now (if (buffer-live-p buffer)
                        (with-current-buffer buffer (point))
                      0))
         (positions (etaf-org--positions session))
         (current (and (< direction 0) (etaf-org--reading-section session)))
         (reference (or (and current (cdr (assoc current positions))) point-now))
         (target (if (> direction 0)
                     (cl-find-if (lambda (cell) (> (cdr cell) point-now)) positions)
                   (car (last (cl-remove-if-not
                               (lambda (cell) (< (cdr cell) reference))
                               positions))))))
    (when target
      (etaf-org--locate-id session (car target)))))

(defun etaf-org--host-source-line (session props)
  "Extract 1-based Org source line from host PROPS in SESSION, or nil."
  (when-let* ((id (plist-get props :id))
              ((stringp id)))
    (cond
     ((string-prefix-p "org-section-" id)
      (when-let* ((sec (etaf-org--section-by-id session (substring id 12))))
        (etaf-org-section-line-start sec)))
     ((string-match "\\`org-line-\\([0-9]+\\)-" id)
      (string-to-number (match-string 1 id))))))

(defun etaf-org--source-line-at-point (session)
  "Return 1-based Org source line number corresponding to point in SESSION."
  (let* ((runtime (etaf-org--runtime session))
         (buffer (etaf-org--buffer session))
         (pt (if (buffer-live-p buffer) (with-current-buffer buffer (point)) 1))
         (best-pos -1)
         (best-line 1))
    (when runtime
      (dolist (entry (etaf-runtime-host-props-entries runtime))
        (when-let* ((lstart (etaf-org--host-source-line session (cdr entry)))
                    (pos (etaf-host-ref-position runtime (car entry))))
          (when (and (<= pos pt) (>= pos best-pos))
            (setq best-pos pos best-line lstart)))))
    best-line))

(defun etaf-org--position-for-source-line (session target-line)
  "Return preview buffer position closest to 1-based source TARGET-LINE."
  (let ((runtime (etaf-org--runtime session))
        (best-line -1)
        (best-pos nil))
    (when runtime
      (dolist (entry (etaf-runtime-host-props-entries runtime))
        (when-let* ((lstart (etaf-org--host-source-line session (cdr entry))))
          (when (and (<= lstart target-line) (> lstart best-line))
            (when-let* ((pos (etaf-host-ref-position runtime (car entry))))
              (setq best-line lstart best-pos pos))))))
    best-pos))

;;; ---------------------------------------------------------------------------
;;; Targets, Links, Lightbox & Peek Cards
;;; ---------------------------------------------------------------------------

(defun etaf-org--open-url (url)
  "Open URL in the system browser."
  (browse-url url))

(defun etaf-org--open-file (path)
  "Open PATH with the operating system's default application."
  (let ((opener (pcase system-type
                  ('darwin "open")
                  ('gnu/linux "xdg-open")
                  (_ nil))))
    (if (and path opener (executable-find opener))
        (call-process opener nil 0 nil path)
      (find-file-other-window path))))

(defun etaf-org--video-or-file-p (path)
  "Return non-nil when PATH is a binary media/PDF file."
  (member (downcase (or (file-name-extension path) ""))
          (append etaf-org--video-extensions etaf-org--image-extensions '("pdf"))))

(defun etaf-org--collect-gallery-images (session)
  "Return list of `(:src PATH :caption TEXT)' for all images in SESSION."
  (let ((items nil)
        (seen (make-hash-table :test #'equal)))
    (etaf-org--walk-document-blocks
     (etaf-org--read session :document)
     (lambda (block)
       (when-let* ((media (plist-get block :media))
                   ((eq (plist-get media :kind) 'image))
                   ((plist-get media :exists))
                   (path (plist-get media :path)))
         (unless (gethash path seen)
           (puthash path t seen)
           (push (list :src path
                       :caption (or (plist-get block :caption)
                                    (plist-get media :alt)
                                    (file-name-nondirectory path)))
                 items)))
       (when-let* ((pic (plist-get block :picture))
                   ((file-exists-p pic)))
         (unless (gethash pic seen)
           (puthash pic t seen)
           (push (list :src pic
                       :caption (or (plist-get block :caption)
                                    (file-name-nondirectory pic)))
                 items)))))
    (nreverse items)))

(defun etaf-org--open-lightbox (session path &optional caption)
  "Open SESSION's in-buffer `etaf-media-viewer' lightbox at image PATH."
  (let* ((buf (plist-get session :buffer))
         (win (and (buffer-live-p buf) (get-buffer-window buf t)))
         (frame (and (window-live-p win) (window-frame win)))
         (use-lb (pcase etaf-org-media-lightbox
                   ('t t)
                   ('auto (display-graphic-p frame))
                   (_ nil))))
    (when (and use-lb (buffer-live-p buf) (stringp path) (file-readable-p path))
      (let* ((items (etaf-org--collect-gallery-images session))
             (idx (or (cl-position path items
                                   :key (lambda (it) (plist-get it :src))
                                   :test #'equal)
                      (progn
                        (setq items (append items
                                            (list (list :src path
                                                        :caption (or caption
                                                                     (file-name-nondirectory path))))))
                        (1- (length items))))))
        (etaf-org--write session :lightbox (list :items items :index idx))
        t))))

(defun etaf-org--activate-media (session kind path &optional caption)
  "Handle media activation for KIND (`image' or `video') at PATH in SESSION."
  (let ((cb (plist-get session :on-media)))
    (unless (and (functionp cb) (funcall cb kind path))
      (if (and (eq kind 'image)
               (etaf-org--open-lightbox session path caption))
          t
        (etaf-org--open-file path)))))

(defun etaf-org--section-by-title (session title)
  "Return SESSION's section id whose plain title matches TITLE."
  (cl-loop for entry in (etaf-org-outline session)
           when (equal (nth 1 entry) title)
           return (nth 2 entry)))

(defun etaf-org--find-id-in-workspace (session id)
  "Search SESSION's current document and workspace `.org' files for `:ID: ID'."
  (let* ((doc (etaf-org--read session :document))
         (local (cl-block found
                  (etaf-org--walk-sections
                   (plist-get doc :sections)
                   (lambda (sec)
                     (when (equal (cdr (assoc "ID" (etaf-org-section-properties sec))) id)
                       (cl-return-from found (etaf-org-section-id sec))))))))
    (if local
        (cons 'local local)
      (when (fboundp 'org-id-find)
        (when-let* ((hit (ignore-errors (org-id-find id))))
          (cons 'file (car hit)))))))

(defun etaf-org--open-target (session target)
  "Act on link TARGET in SESSION."
  (let ((cb (plist-get session :on-link)))
    (unless (and (functionp cb) (funcall cb target))
      (let* ((kind (etaf-org--link-kind target))
             (dir (plist-get session :dir)))
        (pcase kind
          ((or 'url 'mail) (etaf-org--open-url target))
          ('headline
           (let ((title (substring target 1)))
             (if-let* ((id (etaf-org--section-by-title session title)))
                 (progn (etaf-org--reveal id session)
                        (etaf-org--flush session)
                        (etaf-org--locate-id session id))
               (message "No heading named %s" title))))
          ('custom-id
           (let ((id (substring target 1)))
             (if (etaf-org--fold-cell session id)
                 (progn (etaf-org--reveal id session)
                        (etaf-org--flush session)
                        (etaf-org--locate-id session id))
               (message "No section with CUSTOM_ID %s" id))))
          ('id
           (let* ((uid (substring target 3))
                  (hit (etaf-org--find-id-in-workspace session uid)))
             (pcase (car hit)
               ('local
                (etaf-org--reveal (cdr hit) session)
                (etaf-org--flush session)
                (etaf-org--locate-id session (cdr hit)))
               ('file (find-file-other-window (cdr hit)))
               (_ (message "Unknown Org id: %s" target)))))
          ('info
           (let ((node (substring target 5)))
             (if (fboundp 'info) (info node) (message "info: %s" node))))
          ('help
           (let ((sym (intern-soft (substring target 5))))
             (if sym (describe-symbol sym) (message "Unknown symbol: %s" target))))
          ((or 'file 'other 'attachment)
           (let* ((raw (if (string-prefix-p "file:" target) (substring target 5) target))
                  (parts (split-string raw "::"))
                  (path (etaf-org--link-file target dir))
                  (search (cadr parts)))
             (cond
              ;; Fuzzy in-document target (`<<target>>', `#+NAME:', or heading title).
              ((and (eq kind 'other) (not (and path (file-exists-p path))))
               (cond
                ((etaf-org--jump-target session target) t)
                ((when-let* ((id (etaf-org--section-by-title session target)))
                   (etaf-org--reveal id session)
                   (etaf-org--flush session)
                   (etaf-org--locate-id session id)))
                (t (message "Target not found: %s" target))))
              ((and path (string-match-p "\\.org\\'" path) (file-readable-p path))
               (if (and search
                        (equal (ignore-errors (file-truename path))
                               (ignore-errors (file-truename (or (plist-get session :file) "")))))
                   (etaf-org--open-target
                    session
                    (if (string-prefix-p "#" search)
                        search
                      (concat "*" (string-trim-left search "[*]"))))
                 (if (fboundp 'etaf-org-open)
                     (let ((buf (etaf-org-open path)))
                       (when (and search (buffer-live-p buf))
                         (with-current-buffer buf
                           (when-let* ((s (etaf-app-state buf)))
                             (etaf-org--open-target
                              s (if (string-prefix-p "#" search)
                                    search
                                  (concat "*" (string-trim-left search "[*]"))))))))
                   (find-file-other-window path))))
              ((and path (file-exists-p path)
                    (member (downcase (or (file-name-extension path) ""))
                            etaf-org--image-extensions))
               (etaf-org--activate-media session 'image path))
              ((and path (file-exists-p path) (etaf-org--video-or-file-p path))
               (etaf-org--activate-media session 'video path))
              ((and path (file-exists-p path))
               (find-file-other-window path))
              ((and path (etaf-org--remote-url-p path))
               (browse-url path))
              (t (message "Target not found: %s" target)))))
          (_ (message "This link type cannot be activated: %s" target)))))))

(defun etaf-org--jump-footnote (session label)
  "Move point to footnote LABEL in SESSION's buffer, saving return position."
  (let* ((document (etaf-org--read session :document))
         (entry (cl-find label (plist-get document :footnotes)
                         :key (lambda (footnote) (plist-get footnote :label))
                         :test #'equal))
         (buffer (etaf-org--buffer session)))
    (if (and entry (buffer-live-p buffer))
        (with-current-buffer buffer
          (plist-put session :footnote-return (point))
          (push-mark (point) t)
          (goto-char (point-max))
          (when (search-backward (format "[%d]" (plist-get entry :number)) nil t)
            (beginning-of-line)
            (when-let* ((window (get-buffer-window buffer t)))
              (with-selected-window window (recenter 0)))))
      (message "Footnote %s not found" label))))

(defun etaf-org--return-from-footnote (session _label)
  "Jump back to the reference point saved before visiting a footnote."
  (let ((pos (plist-get session :footnote-return))
        (buffer (etaf-org--buffer session)))
    (when (and (integerp pos) (buffer-live-p buffer))
      (with-current-buffer buffer
        (goto-char (min pos (point-max)))
        (when-let* ((window (get-buffer-window buffer t)))
          (with-selected-window window (recenter)))))))

(defun etaf-org--jump-target (session name)
  "Move point to SESSION's target NAME (`<<target>>' or `#+NAME:') and recenter."
  (let* ((document (etaf-org--read session :document))
         (targets (plist-get document :targets))
         (section (and (hash-table-p targets) (gethash name targets)))
         (id (and section (etaf-org-section-id section))))
    (when id
      (etaf-org--reveal id session)
      (etaf-org--flush session)
      (etaf-org--locate-id session id))))

(defun etaf-org--peek-citation (session key)
  "Show in-buffer peek card for citation KEY in SESSION."
  (let* ((bib (plist-get session :bibliography))
         (entry (and (hash-table-p bib) (gethash key bib)))
         (body (if entry
                   (string-join
                    (delq nil
                          (list (when-let* ((t0 (plist-get entry :title))) (format "标题：%s" t0))
                                (when-let* ((a0 (plist-get entry :author))) (format "作者：%s" a0))
                                (when-let* ((y0 (plist-get entry :year))) (format "年份：%s" y0))
                                (when-let* ((d0 (plist-get entry :doi))) (format "DOI：%s" d0))))
                    "\n")
                 (format "引用键 @%s（未在本地参考文献库中找到条目）" key))))
    (etaf-org--write session :peek (list :kind "参考文献" :title (concat "@" key) :body body))))

(defun etaf-org--peek-symbol (session name)
  "Show in-buffer peek card for Emacs symbol NAME in SESSION."
  (let* ((data (etaf-org-assets-compute-symbol (list :name name)))
         (body (if (plist-get data :ok)
                   (concat (format "类型：%s" (plist-get data :kind))
                           (when (plist-get data :signature)
                             (format "\n签名：%s" (plist-get data :signature)))
                           (when (plist-get data :doc)
                             (format "\n\n%s" (plist-get data :doc))))
                 (or (plist-get data :error) (format "未找到符号：%s" name)))))
    (etaf-org--write session :peek
                     (list :kind "符号" :title name :body body
                           :target (concat "help:" name)))))

(defun etaf-org--peek-at-point (session)
  "Open or toggle in-buffer peek card for link/footnote/citation at point."
  (let* ((buffer (etaf-org--buffer session))
         (runtime (etaf-org--runtime session))
         (target nil))
    (when (and (buffer-live-p buffer) runtime)
      (with-current-buffer buffer
        (let ((pt (point)))
          (dolist (entry (etaf-runtime-host-props-entries runtime))
            (when-let* ((attrs (plist-get (cdr entry) :attributes))
                        (dt (cdr (assq 'target attrs)))
                        (pos (etaf-host-ref-position runtime (car entry))))
              (when (and (<= pos pt) (<= (- pt pos) 60))
                (setq target dt)))))))
    (cond
     ((null target)
      (if (etaf-org--read session :peek)
          (etaf-org--write session :peek nil)
        (message "光标处没有可速览的链接、脚注或引用")))
     ((string-prefix-p "cite:" target)
      (etaf-org--peek-citation session (substring target 5)))
     ((string-prefix-p "fn:" target)
      (let* ((label (substring target 3))
             (doc (etaf-org--read session :document))
             (fn (cl-find label (plist-get doc :footnotes)
                          :key (lambda (f) (plist-get f :label)) :test #'equal))
             (txt (cond
                   ((plist-get fn :inlines)
                    (etaf-org-inline-plain-text (plist-get fn :inlines)))
                   ((plist-get fn :blocks)
                    (mapconcat (lambda (b)
                                 (or (and (plist-get b :inlines)
                                          (etaf-org-inline-plain-text (plist-get b :inlines)))
                                     (plist-get b :text) ""))
                               (plist-get fn :blocks) "\n"))
                   (t "（无定义）"))))
        (etaf-org--write session :peek
                         (list :kind "脚注" :title (format "[%s]" label) :body txt))))
     ((string-prefix-p "target:" target)
      (let* ((name (substring target 7))
             (doc (etaf-org--read session :document))
             (sec (and (hash-table-p (plist-get doc :targets))
                       (gethash name (plist-get doc :targets)))))
        (etaf-org--write session :peek
                         (list :kind "目标" :title name
                               :body (if sec
                                         (format "位于章节：%s" (etaf-org-section-title-plain sec))
                                       "文档内锚点")
                               :target name))))
     (t
      (let* ((kind (etaf-org--link-kind target))
             (body (pcase kind
                     ('url (format "外部链接：%s" target))
                     ('headline (format "文档标题跳转：%s" (substring target 1)))
                     ('custom-id (format "CUSTOM_ID 锚点：%s" (substring target 1)))
                     (_ (format "链接目标：%s" target)))))
        (etaf-org--write session :peek
                         (list :kind "链接" :title target :body body :target target)))))))

;;; ---------------------------------------------------------------------------
;;; Rendering environment
;;; ---------------------------------------------------------------------------

(defun etaf-org--display-frame (session)
  "Return the frame showing SESSION, or nil."
  (let ((buffer (plist-get session :buffer)))
    (when (buffer-live-p buffer)
      (when-let* ((window (get-buffer-window buffer t)))
        (window-frame window)))))

(defun etaf-org--page-background (session)
  "Return the page background SESSION paints, or nil for frame-derived `auto'."
  (when (eq (etaf-org--read session :theme-source) 'palette)
    (etaf-org-color :bg
                    (cdr (assq (etaf-org--read session :theme)
                               etaf-org-themes)))))

(defun etaf-org--session-palette (session)
  "Return SESSION's palette alist."
  (if (eq (etaf-org--read session :theme-source) 'palette)
      (cdr (assq (etaf-org--read session :theme) etaf-org-themes))
    (etaf-org--palette-from-faces (etaf-org--display-frame session))))

(defun etaf-org--toc-depth (session)
  "Return SESSION's table of contents depth, or nil when hidden."
  (let ((depth (plist-get session :toc-depth-base)))
    (when (and depth (etaf-org--read session :toc-visible))
      depth)))

(defun etaf-org--env-inputs (session)
  "Return the inputs SESSION's rendering environment depends on."
  (list :theme (etaf-org--read session :theme)
        :theme-source (etaf-org--read session :theme-source)
        :appearance (etaf-appearance)
        :frame (etaf-org--display-frame session)
        :width (etaf-org--read session :width)
        :viewport-width (etaf-org--read session :viewport-width)
        :hidden (etaf-org--read session :hidden)
        :toc-visible (etaf-org--read session :toc-visible)
        :spoilers-revealed (etaf-org--read session :spoilers-revealed)
        :filter (etaf-org--read session :filter)
        :peek (etaf-org--read session :peek)
        :lightbox (etaf-org--read session :lightbox)
        :title (etaf-org--read session :title)
        :todo-keywords (plist-get session :todo-keywords)
        :show-tags (plist-get session :show-tags)
        :toc-depth (plist-get session :toc-depth-base)
        :features (plist-get session :features)
        :modified (plist-get session :modified)
        :link-hover (plist-get session :link-hover)
        :styles-count (length etaf-org-styles)))

(defun etaf-org--build-env (session)
  "Build SESSION's rendering environment from its current inputs."
  (list :session session
        :document (etaf-org--read session :document)
        :theme (etaf-org--read session :theme)
        :palette (etaf-org--session-palette session)
        :width (etaf-org--read session :width)
        :viewport-width (etaf-org--read session :viewport-width)
        :background (etaf-org--page-background session)
        :base-pixels (etaf-org--base-pixels)
        :image-max-rows etaf-org-image-max-height
        :todo-keywords (plist-get session :todo-keywords)
        :show-tags (plist-get session :show-tags)
        :features (plist-get session :features)
        :bibliography (plist-get session :bibliography)
        :abbreviations (plist-get session :abbreviations)
        :link-hover (plist-get session :link-hover)
        :heading-underline (plist-get session :heading-underline)
        :toc-depth (etaf-org--toc-depth session)
        :spoilers-revealed (etaf-org--read session :spoilers-revealed)
        :filter (etaf-org--read session :filter)
        :peek (etaf-org--read session :peek)
        :lightbox (etaf-org--read session :lightbox)
        :hidden (etaf-org--read session :hidden)
        :hidden-ref (etaf-org--ref session :hidden)
        :fold-ref (lambda (id) (etaf-org--fold-cell session id))
        :fallback-title (etaf-org--read session :title)
        :modified (plist-get session :modified)
        :actions (list :toggle (lambda (id) (etaf-org--toggle-fold session id))
                       :locate (lambda (id)
                                 (etaf-org--reveal id session)
                                 (etaf-org--flush session)
                                 (etaf-org--locate-id session id))
                       :open (lambda (target) (etaf-org--open-target session target))
                       :open-file (lambda (path) (etaf-org--open-file path))
                       :footnote (lambda (label) (etaf-org--jump-footnote session label))
                       :target (lambda (name) (etaf-org--jump-target session name))
                       :toggle-spoilers (lambda ()
                                          (etaf-org--write
                                           session :spoilers-revealed
                                           (not (etaf-org--read session :spoilers-revealed))))
                       :hidden (lambda ()
                                 (etaf-org-show-hidden
                                  session
                                  (not (etaf-org--read session :hidden)))))))

(defun etaf-org--env (session)
  "Return SESSION's rendering environment, cached until inputs change."
  (let* ((inputs (etaf-org--env-inputs session))
         (cached (plist-get session :env-cache)))
    (if (equal (car cached) inputs)
        (cdr cached)
      (let ((env (etaf-org--build-env session)))
        (plist-put session :env-cache (cons inputs env))
        env))))

(provide 'etaf-org-model)
;;; etaf-org-model.el ends here
