;;; etaf-md-model.el --- Session state for etaf-md -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; Session state and navigation of the markdown previewer.  A session is a
;; plist of reactive refs: it owns the parsed document, the palette name, the
;; reading width and the error text, and it can exist without any buffer, so
;; scripts and tests drive the same model the mounted application uses.
;;
;; All display values are read through `etaf-md--read' during render,
;; so writing a ref repaints the mounted preview without a refresh call.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'etaf)
(require 'etaf-ui)
(require 'etaf-md-cache)
(require 'etaf-md-theme)
(require 'etaf-md-assets)
(require 'etaf-md-views)

(declare-function etaf-md--child-syntax "etaf-md-node" (type))
(declare-function etaf-md--block-state-prune "etaf-md-env" (session slot))
(declare-function etaf-md--block-state-ref "etaf-md-env" (session identity))
(declare-function etaf-md-open "etaf-md-app" (&optional source))
(declare-function etaf-md--current-session "etaf-md-app" ())
(declare-function etaf-md-qrcode-attach "etaf-md-qrcode" (block))
(declare-function etaf-md-qrcode-request "etaf-md-qrcode" (session))
(declare-function url-unhex-string "url-util" (string))

(define-error 'etaf-md-error "Markdown preview error")

(defcustom etaf-md-width-min 40
  "Narrowest reading measure, in character cells.
`etaf-md-adjust-width' clamps its result to this value."
  :type 'integer
  :group 'etaf-md)

(defcustom etaf-md-width-max 96
  "Widest reading measure, in character cells.
A window wider than this measure keeps the measure and centers the column.
A measure wider than this runs a long way past a comfortable line: at 110
cells a paragraph of Chinese holds more than fifty characters per line."

  :type 'integer
  :group 'etaf-md)

(defcustom etaf-md-toc-side 'left
  "Side of the frame where the `*ETAF Outline*' TOC side window opens.
Set to `left' (the default) or `right'."
  :type '(choice (const :tag "Left" left)
                 (const :tag "Right" right))
  :group 'etaf-md)

(defcustom etaf-md-toc-width 28
  "Width of the `*ETAF Outline*' TOC side window, in character cells.
Clamped between 18 and 52 columns when opened; resize the window anytime
with standard Emacs window controls or mouse drag on the divider."
  :type 'integer
  :group 'etaf-md)

(defconst etaf-md--toc-width-min 18
  "Narrowest width of the TOC side window, in character cells.")

(defconst etaf-md--toc-width-max 52
  "Widest width of the TOC side window, in character cells.")

(defun etaf-md--clamp-toc-width (width)
  "Clamp TOC side-window WIDTH to valid sidebar columns."
  (let ((base (if (integerp width) width etaf-md-toc-width)))
    (max etaf-md--toc-width-min (min etaf-md--toc-width-max base))))

(defcustom etaf-md-flavor nil
  "Default Markdown dialect of `etaf-md-create'.
Nil defers to `etaf-ui-markdown-flavor', which is the widest preset and the one
a reader expects to open a document.  A document may name its own dialect in
its front matter (`flavor: gfm'), and a session's `:flavor' argument overrides
both: the argument, then the document, then this variable."
  :type '(choice (const :tag "The renderer's default" nil)
                 (const :tag "ETAF dialect" etaf)
                 (const :tag "GitHub Flavored Markdown" gfm)
                 (const :tag "CommonMark only" commonmark)
                 (sexp :tag "Feature plist"))
  :group 'etaf-md)

(defconst etaf-md--flavor-line
  "^flavor:[ \t]*\\([a-z][a-z0-9-]*\\)[ \t]*$"
  "Front matter line that names the document's dialect.
Anchors are line anchors: the line sits among the block's other keys.")

(defun etaf-md--document-flavor (text)
  "Return the dialect TEXT's front matter names, or nil.
Only the front matter block is read, so a `flavor:' line further down a
document is body text and cannot change how the rest of it parses."
  (when (and (stringp text)
             ;; `.` stops at a newline, so the block is matched with an
             ;; explicit alternation: a front matter block is several lines.
             (string-match "\\`---[ \t]*\n\\(\\(?:.\\|\n\\)*?\\)\n---" text))
    (let* ((block (match-string 1 text))
           (found (when (string-match etaf-md--flavor-line block)
                    (match-string 1 block))))
      (and found (intern found)))))

(defun etaf-md--flavor-for (session text)
  "Return the dialect SESSION parses TEXT with.
A session's own `:flavor' wins, then the document's front matter, then
`etaf-md-flavor'; nil leaves the choice to `etaf-ui-markdown-parse',
whose default is the widest preset.  One file of a directory can therefore stay
CommonMark while the rest read with everything the renderer knows."
  (or (plist-get session :flavor)
      (etaf-md--document-flavor text)
      etaf-md-flavor))

;;; ---------------------------------------------------------------------------
;;; Refs
;;; ---------------------------------------------------------------------------

(defun etaf-md--ref (session key)
  "Return SESSION's reactive source named KEY."
  (plist-get session key))

(defun etaf-md--read (session key)
  "Return SESSION's current value for KEY, tracked while rendering."
  (etaf-value (etaf-md--ref session key)))

(defun etaf-md--write (session key value)
  "Publish VALUE as SESSION's new value for KEY; return VALUE.
A write that would not change the reading is skipped, because the preview
re-renders on every write."
  (let ((ref (etaf-md--ref session key)))
    (unless (equal (etaf-value ref) value)
      (etaf-set-value ref value))
    value))

;;; ---------------------------------------------------------------------------
;;; Source helpers
;;; ---------------------------------------------------------------------------

(defconst etaf-md--markdown-file-regexp "\\.\\(md\\|markdown\\|mdown\\|mkd\\)\\'"
  "File names this package reads as a markdown document.")

(defun etaf-md--canonical-file (file)
  "Return the canonical path for FILE, resolving symlinks when FILE exists.
Using one canonical key everywhere ensures a symlinked source buffer and its
preview share the same follow session."
  (when (and (stringp file) (not (string-empty-p file)))
    (let ((expanded (expand-file-name file)))
      (if (file-exists-p expanded)
          (file-truename expanded)
        expanded))))

(defun etaf-md--read-source (file)
  "Return FILE's text, signaling `etaf-md-error' on failure."
  (unless (file-readable-p file)
    (signal 'etaf-md-error (list (format "Cannot read file: %s" file))))
  (with-temp-buffer
    (insert-file-contents file)
    (buffer-string)))

(defconst etaf-md--container-open
  "\\`:::\\([[:alpha:]][[:alnum:]-]*\\)[ \t]*\\(?:{\\(.*\\)}[ \t]*\\)?\\'"
  "Shape of a container opening line.")

(defconst etaf-md--container-close "\\`:::\\'"
  "Shape of a container closing line.")

(defun etaf-md--parse-attributes (text)
  "Return TEXT's attribute body as a keyword plist.
A quoted value keeps its spaces; a bare value ends at the next blank; a name
without `=' is a flag set to t."
  (let ((position 0) (length (length text)) (result nil))
    (while (< position length)
      (cond
       ((memq (aref text position) '(?\s ?\t))
        (setq position (1+ position)))
       (t
        (let ((start position))
          (while (and (< position length)
                      (not (memq (aref text position) '(?\s ?\t ?=))))
            (setq position (1+ position)))
          (let ((key (intern (format ":%s" (substring text start position)))))
            (if (and (< position length) (eq (aref text position) ?=))
                (progn
                  (setq position (1+ position))
                  (if (and (< position length) (eq (aref text position) ?\"))
                      (let ((end (1+ position)))
                        (while (and (< end length) (not (eq (aref text end) ?\")))
                          (setq end (1+ end)))
                        (setq result
                              (plist-put result key (substring text (1+ position) end)))
                        (setq position (min length (1+ end))))
                    (let ((end position))
                      (while (and (< end length)
                                  (not (memq (aref text end) '(?\s ?\t))))
                        (setq end (1+ end)))
                      (setq result
                            (plist-put result key (substring text position end)))
                      (setq position end))))
              (setq result (plist-put result key t))))))))
    result))

(defun etaf-md--shift-blocks (blocks offset)
  "Return BLOCKS with their source ranges moved by OFFSET."
  (mapcar
   (lambda (block)
     (let ((copy (copy-sequence block)))
       (dolist (key '(:begin :end))
         (when (integerp (plist-get copy key))
           (setf (plist-get copy key) (+ offset (plist-get copy key)))))
       (when (eq (plist-get copy :type) 'container)
         (setf (plist-get copy :children)
               (etaf-md--shift-blocks (plist-get copy :children) offset)))
       copy))
   blocks))

(defconst etaf-md--child-marker
  "\\`@\\([[:alpha:]][[:alnum:]-]*\\)\\(?:[ \t]+\\(.*\\)\\)?\\'"
  "Shape of a child marker: a name, then a title or `{attrs}'.")

(defun etaf-md--child-marker-attrs (rest)
  "Return the attribute plist the rest of a child marker line writes.
`{...}' is the ordinary attribute body; any other text is the child's title,
which is the one attribute every child type names its own line with."
  (cond
   ((or (null rest) (string-empty-p (string-trim rest))) nil)
   ((string-match "\\`[ \t]*{\\(.*\\)}[ \t]*\\'" rest)
    (etaf-md--parse-attributes (match-string 1 rest)))
   (t (list :title (string-trim rest)))))

(defun etaf-md--parse-marker-children (name text flavor base)
  "Return NAME's children from TEXT, one per `@type' marker.
A marker starts a line at the container's own level; its rest is the child's
title or `{attrs}', and the child runs to the next marker or to the end of
TEXT.  A `:::' inside a child is nested content, never a sibling, and a marker
inside a fence stays code.  BASE is where TEXT starts in the page."
  (let ((offset 0) (line-number 0) (fence nil) (depth 0)
        (markers nil) (preamble nil))
    (dolist (line (split-string text "\n"))
      (setq line-number (1+ line-number))
      (let ((line-start offset)
            (line-end (+ offset (length line))))
        (cond
         ((string-match "\\`[ \t]*\\(```+\\|~~~+\\)" line)
          (let ((marker (match-string 1 line)))
            (if fence
                (when (string= fence marker) (setq fence nil))
              (setq fence marker))))
         (fence nil)
         ((and (zerop depth) (string-match etaf-md--child-marker line))
          (push (list :name (match-string 1 line)
                      :attrs (etaf-md--child-marker-attrs (match-string 2 line))
                      :start line-start
                      :end line-end)
                markers))
         ((and (null markers)
               (not (string-empty-p (string-trim line))))
          (unless preamble
            (setq preamble (cons line-number line))))
         ((string-match etaf-md--container-close line)
          (when (> depth 0) (cl-decf depth)))
         ((string-match etaf-md--container-open line)
          (cl-incf depth)))
        (setq offset (1+ line-end))))
    (setq markers (nreverse markers))
    (cond
     ((null markers)
      (signal 'etaf-md-error
              (list (if preamble
                        (format "%s: line %d comes before its first @ marker: %S"
                                name (car preamble) (cdr preamble))
                      (format "%s needs at least one @ marker" name)))))
     (preamble
      (signal 'etaf-md-error
              (list (format "%s: line %d comes before its first @ marker: %S"
                            name (car preamble) (cdr preamble)))))
     (t
      (cl-loop
       for rest on markers
       for marker = (car rest)
       for next = (cadr rest)
       for body-start = (min (length text) (1+ (plist-get marker :end)))
       for body-end = (if next (plist-get next :start) (length text))
       for parsed = (etaf-md--parse (substring text body-start body-end) flavor)
       collect (list :type 'container
                     :name (plist-get marker :name)
                     :attrs (plist-get marker :attrs)
                     :children (etaf-md--shift-blocks
                                (plist-get parsed :children)
                                (+ base body-start))
                     :begin (+ base (plist-get marker :start))
                     :end (+ base body-end)
                     :source (substring text
                                        (plist-get marker :start)
                                        body-end)))))))

(defun etaf-md--chat-split-markers (text)
  "Return TEXT with a blank line around every chat marker line.
Plume writes `{name}' on the line before the message; a paragraph parser
would join them, so the marker gets its own paragraph here."
  (mapconcat
   #'identity
   (cl-loop for line in (split-string text "\n")
            if (string-match-p "\\`{[^}]+}[ \t]*\\'" line)
            append (list "" line "")
            else collect line)
   "\n"))

(defvar etaf-md--footnote-def-collector nil
  "Mutable cell `(ALIST)' collecting footnote definitions during container parse.")

(defvar etaf-md--annotation-def-collector nil
  "Mutable cell `(ALIST)' collecting `[+label]:' defs during container parse.")

(defun etaf-md--line-indent (line)
  "Return LINE's leading space count with tabs counted as four columns."
  (let ((indent 0) (index 0) (len (length line)))
    (while (and (< index len) (memq (aref line index) '(?\s ?\t)))
      (setq indent (+ indent (if (eq (aref line index) ?\t) 4 1))
            index (1+ index)))
    indent))

(defun etaf-md--collect-footnote-defs (text collector)
  "Collect GFM footnote definitions from markdown TEXT into COLLECTOR.
Skips fenced code blocks and keeps only the first definition per label."
  (let ((lines (split-string (replace-regexp-in-string "\r\n?" "\n" text) "\n"))
        (fence nil))
    (while lines
      (let ((line (car lines)))
        (cond
         ((string-match "\\`[ \t]*\\(`\\{3,\\}\\|~\\{3,\\}\\)" line)
          (let ((marker (match-string 1 line))
                (bare (string-match-p "\\`[ \t]*\\'" (substring line (match-end 0)))))
            (cond (fence
                   (when (and bare
                              (eq (aref fence 0) (aref marker 0))
                              (>= (length marker) (length fence)))
                     (setq fence nil)))
                  (t (setq fence marker))))
          (setq lines (cdr lines)))
         (fence
          (setq lines (cdr lines)))
         ((string-match "\\` ? ? ?\\[\\^\\([^]]+\\)\\]:[ \t]*\\(.*\\)\\'" line)
          (let ((label (match-string 1 line))
                (def-lines (list line))
                (rest (cdr lines)))
            (while (and rest
                        (or (string-match-p "\\`[ \t]*\\'" (car rest))
                            (>= (etaf-md--line-indent (car rest)) 4)))
              (push (car rest) def-lines)
              (setq rest (cdr rest)))
            (unless (assoc label (car collector))
              (setcar collector
                      (cons (cons label (mapconcat #'identity (nreverse def-lines) "\n"))
                            (car collector))))
            (setq lines rest)))
         (t
          (setq lines (cdr lines))))))))

(defun etaf-md--heading-plain-text (inlines)
  "Return the concatenated plain text of heading inline NODES."
  (mapconcat
   (lambda (node)
     (pcase (plist-get node :type)
       ((or 'text 'code 'html 'abbreviation) (or (plist-get node :text) ""))
       ((or 'emph 'strong 'strike 'link 'autolink 'mark)
        (etaf-md--heading-plain-text (plist-get node :children)))
       ((or 'subscript 'superscript)
        (or (plist-get node :rendered) (plist-get node :text) ""))
       ('emoji (or (plist-get node :char) (plist-get node :text) ""))
       ('image (or (plist-get node :alt) ""))
       ('break " ")
       ('footnote-ref (format "[%s]" (or (plist-get node :label) "")))
       ('badge (or (plist-get node :content) ""))
       (_ "")))
   inlines ""))

(defun etaf-md--heading-slug (text)
  "Return a stable anchor slug for heading TEXT."
  (let ((slug (downcase (string-trim text))))
    (setq slug (replace-regexp-in-string "[^[:alnum:]\u4e00-\u9fff]+" "-" slug))
    (setq slug (replace-regexp-in-string "\\`-+\\|-+\\'" "" slug))
    (if (string-empty-p slug) "section" slug)))

(defun etaf-md--collect-outline (blocks)
  "Assign unique heading ids across BLOCKS in document order and return outline.
Descends into container blocks so headings before, inside and after containers
appear in document order with unique anchor ids."
  (let ((seen (make-hash-table :test #'equal))
        (used (make-hash-table :test #'equal))
        (outline nil))
    (cl-labels
        ((walk (items)
           (dolist (block items)
             (pcase (plist-get block :type)
               ('heading
                (let* ((text (string-trim
                              (etaf-md--heading-plain-text
                               (plist-get block :children))))
                       (base (etaf-md--heading-slug text))
                       (count (1+ (or (gethash base seen) 0)))
                       (id (if (= count 1) base (format "%s-%d" base count))))
                  (while (gethash id used)
                    (setq count (1+ count)
                          id (format "%s-%d" base count)))
                  (puthash base count seen)
                  (puthash id t used)
                  (plist-put block :id id)
                  (push (list (plist-get block :level) text id) outline)))
               ('container
                (walk (plist-get block :children)))))))
      (walk blocks))
    (nreverse outline)))

(defun etaf-md--renumber-footnotes (blocks)
  "Renumber footnote references in BLOCKS in document order.
Return the list of referenced labels in first-reference order."
  (let ((order nil))
    (cl-labels
        ((visit-inline (node)
           (when (and (listp node) (keywordp (car node)))
             (when (eq (plist-get node :type) 'footnote-ref)
               (let* ((label (plist-get node :label))
                      (existing (cl-position label order :test #'equal))
                      (number (if (numberp existing)
                                  (1+ existing)
                                (1+ (length order)))))
                 (unless (numberp existing)
                   (setq order (append order (list label))))
                 (plist-put node :number number)))
             (dolist (child (plist-get node :children))
               (visit-inline child))))
         (visit-block (block)
           (pcase (plist-get block :type)
             ((or 'heading 'paragraph)
              (dolist (child (plist-get block :children))
                (visit-inline child)))
             ((or 'blockquote 'list-item 'container)
              (visit-blocks (plist-get block :children)))
             ('list
              (dolist (item (plist-get block :items))
                (visit-blocks (plist-get item :children))))
             ('table
              (dolist (cell (plist-get block :header))
                (dolist (child cell) (visit-inline child)))
              (dolist (row (plist-get block :rows))
                (dolist (cell row)
                  (dolist (child cell) (visit-inline child)))))
             ('definition-list
              (dolist (item (plist-get block :items))
                (dolist (child (plist-get item :children))
                  (visit-inline child))
                (dolist (def (plist-get item :definitions))
                  (visit-blocks (plist-get def :children)))))))
         (visit-blocks (items)
           (dolist (block items)
             (visit-block block))))
      (visit-blocks blocks))
    order))

(defun etaf-md--resolve-footnotes (blocks defs flavor)
  "Renumber footnote refs in BLOCKS and return resolved footnote definitions.
DEFS is an alist of (LABEL . RAW-TEXT) collected in document order."
  (let ((ordered (etaf-md--renumber-footnotes blocks)))
    (when (and ordered defs)
      (let ((def-blocks
             (delq nil
                   (mapcar (lambda (label) (cdr (assoc label defs)))
                           ordered))))
        (when def-blocks
          (let* ((refs (mapconcat (lambda (label) (format "[^%s]" label))
                                  ordered " "))
                 (synthetic (concat refs "\n\n"
                                    (mapconcat #'identity def-blocks "\n\n")
                                    "\n"))
                 (parsed (etaf-ui-markdown-parse synthetic flavor)))
            (plist-get parsed :footnotes)))))))

(defun etaf-md--parse-container-body (name text flavor base)
  "Return NAME's children parsed from TEXT, which starts at BASE in the page."
  (if (eq (etaf-md--child-syntax (intern name)) 'markers)
      (etaf-md--parse-marker-children name text flavor base)
    (etaf-md--shift-blocks
     (plist-get (etaf-md--parse
                 (if (equal name "chat")
                     (etaf-md--chat-split-markers text)
                   text)
                 flavor)
                :children)
     base)))

(defun etaf-md--parse-containers (text flavor)
  "Parse TEXT with FLAVOR, reading `:::name {attrs}' containers.
A container runs to the matching close, or to the end of the file for the last
one.  Plain stretches between containers go to the shared Markdown parser, and
their block ranges move to where the stretch sits in TEXT."
  (let* ((top-level (null etaf-md--footnote-def-collector))
         (etaf-md--footnote-def-collector
          (or etaf-md--footnote-def-collector (list nil)))
         (etaf-md--annotation-def-collector
          (or etaf-md--annotation-def-collector (list nil)))
         (offset 0) (plain-start 0) (container nil) (depth 0) (fence nil)
         (result nil) (template nil))
    (cl-flet ((flush (end)
                (when (< plain-start end)
                  (let* ((slice (substring text plain-start end))
                         (parsed (etaf-ui-markdown-parse slice flavor))
                         (blocks (plist-get parsed :children)))
                    (etaf-md--collect-footnote-defs
                     slice etaf-md--footnote-def-collector)
                    (dolist (ann (plist-get parsed :annotations))
                      (unless (assoc (car ann) (car etaf-md--annotation-def-collector))
                        (setcar etaf-md--annotation-def-collector
                                (cons ann (car etaf-md--annotation-def-collector)))))
                    (when (and (null template) (= plain-start 0))
                      (setq template parsed))
                    (setq result
                          (nconc result (etaf-md--shift-blocks
                                         blocks plain-start)))))))
      (dolist (line (split-string text "\n"))
        (let ((line-start offset)
              (line-end (+ offset (length line))))
          (cond
           ;; A fenced block is opaque: a `:::' inside a code sample is the
           ;; sample's text, not an edge of the container around it.  The
           ;; shared parser reads the fence itself; only this scanner has to
           ;; stand aside so the sample cannot open or close a container.
           ((string-match "\\`[ \t]*\\(`\\{3,\\}\\|~\\{3,\\}\\)" line)
            (let ((marker (match-string 1 line))
                  (bare (string-match-p "\\`[ \t]*\\'" (substring line (match-end 0)))))
              (cond (fence
                     ;; Only a bare fence of the same character, at least as
                     ;; long as the opener, ends the block; the sample's own
                     ;; lines stay its text however they look.
                     (when (and bare
                                (eq (aref fence 0) (aref marker 0))
                                (>= (length marker) (length fence)))
                       (setq fence nil)))
                    (t (setq fence marker)))))
           (fence nil)
           ((and (null container) (string-match etaf-md--container-open line))
            ;; Read the name and the attributes before parsing the stretch
            ;; above, because that parse moves the match data.
            (let ((name (match-string 1 line))
                  (attrs (etaf-md--parse-attributes
                          (or (match-string 2 line) ""))))
              (flush line-start)
              (setq container (list :name name
                                    :attrs attrs
                                    :begin line-start
                                    :content-start (min (length text) (1+ line-end)))
                    depth 0)))
           ((and container (string-match etaf-md--container-close line))
            (if (> depth 0)
                (cl-decf depth)
              (progn
                (let ((inner-start (plist-get container :content-start)))
                  (setq result
                        (nconc result
                               (list (list :type 'container
                                           :name (plist-get container :name)
                                           :attrs (plist-get container :attrs)
                                           :children (etaf-md--parse-container-body
                                                      (plist-get container :name)
                                                      (substring text inner-start line-start)
                                                      flavor inner-start)
                                           :begin (plist-get container :begin)
                                           :end line-end
                                           :source (substring text (plist-get container :begin)
                                                              line-end))))))
                (setq container nil
                      plain-start (min (length text) (1+ line-end))))))
           ((and container (string-match etaf-md--container-open line))
            (cl-incf depth)))
          (setq offset (1+ line-end))))
      (if container
          (let ((inner-start (plist-get container :content-start)))
            (setq result
                  (nconc result
                         (list (list :type 'container
                                     :name (plist-get container :name)
                                     :attrs (plist-get container :attrs)
                                     :children (etaf-md--parse-container-body
                                                (plist-get container :name)
                                                (substring text inner-start)
                                                flavor inner-start)
                                     :begin (plist-get container :begin)
                                     :end (length text)
                                     :source (substring text (plist-get container :begin)))))))
        (flush (length text)))
      (let ((document (copy-sequence (or template
                                            (etaf-ui-markdown-parse "" flavor)))))
        (setf (plist-get document :children) result)
        (plist-put document :meta (or (plist-get document :meta) nil))
        (when top-level
          (let* ((outline (etaf-md--collect-outline result))
                 (footnotes (etaf-md--resolve-footnotes
                             result
                             (nreverse (car etaf-md--footnote-def-collector))
                             flavor))
                 (annotations (nreverse (car etaf-md--annotation-def-collector))))
            (setq document (plist-put document :outline outline))
            (setq document (plist-put document :footnotes footnotes))
            (when annotations
              (setq document (plist-put document :annotations annotations)))
            (unless (plist-get document :title)
              (when-let* ((first (car outline)))
                (setq document (plist-put document :title (nth 1 first)))))))
        document))))

(defun etaf-md--container-syntax-p (text)
  "Return non-nil when TEXT has a container line outside a fenced block.
A fence is opened and closed by the same marker, so a `:::` inside a code
sample stays code."
  (let ((fence nil) (found nil))
    (dolist (line (split-string text "\n") found)
      (cond
       ((string-match "\\`[ \t]*\\(```+\\|~~~+\\)" line)
        (let ((marker (match-string 1 line)))
          (if fence
              (when (string= fence marker) (setq fence nil))
            (setq fence marker))))
       ((and (not fence) (string-match "\\`:::" line))
        (setq found t))))))

(defun etaf-md--doc-defs-extract (text)
  "Extract link-reference and abbreviation definition lines from TEXT, or nil.
Skips fenced code blocks.  Cached on the full parse so incremental slice parses
resolve reference links and abbreviations defined elsewhere in the document."
  (let ((len (length text))
        (pos 0)
        (fence nil)
        (defs nil))
    (while (< pos len)
      (let* ((nl (or (string-search "\n" text pos) len))
             (line (substring text pos nl)))
        (cond
         ((string-match "\\`[ \t]*\\(`\\{3,\\}\\|~\\{3,\\}\\)" line)
          (let ((marker (match-string 1 line))
                (bare (string-match-p "\\`[ \t]*\\'" (substring line (match-end 0)))))
            (if fence
                (when (and bare
                           (eq (aref fence 0) (aref marker 0))
                           (>= (length marker) (length fence)))
                  (setq fence nil))
              (setq fence marker))))
         (fence nil)
         ((or (string-match-p "\\` ? ? ?\\[[^^\n]+\\]:[ \t]*" line)
              (string-match-p "\\`\\*\\[[^\n]+\\]:[ \t]*" line))
          (push line defs)))
        (setq pos (1+ nl))))
    (when defs
      (mapconcat #'identity (nreverse defs) "\n"))))

(defun etaf-md--parse (text flavor &optional skip-defs)
  "Parse TEXT with FLAVOR, reporting failures as `etaf-md-error'.
Container syntax is this package's own; everything else is shared with the
other document viewers, and this package keeps its own error type at its
boundary.  When SKIP-DEFS is nil at top level, extracts link/abbreviation
definitions for incremental splice parses."
  (condition-case err
      (let ((parsed
             (if (etaf-md--container-syntax-p text)
                 (etaf-md--parse-containers text flavor)
               (let ((doc (etaf-ui-markdown-parse text flavor)))
                 (when etaf-md--footnote-def-collector
                   (etaf-md--collect-footnote-defs
                    text etaf-md--footnote-def-collector))
                 (when etaf-md--annotation-def-collector
                   (dolist (ann (plist-get doc :annotations))
                     (unless (assoc (car ann) (car etaf-md--annotation-def-collector))
                       (setcar etaf-md--annotation-def-collector
                               (cons ann (car etaf-md--annotation-def-collector))))))
                 doc))))
        (when (and (not skip-defs) (null etaf-md--footnote-def-collector))
          (setq parsed (plist-put (copy-sequence parsed)
                                  :doc-defs (etaf-md--doc-defs-extract text))))
        parsed)
    (etaf-ui-markdown-error
     (signal 'etaf-md-error (cdr err)))))

;;; ---------------------------------------------------------------------------
;;; Session
;;; ---------------------------------------------------------------------------

(defun etaf-md--block-source (block text)
  "Return BLOCK's own source slice in TEXT, or nil without a range."
  (let ((begin (plist-get block :begin))
        (end (plist-get block :end)))
    (and (integerp begin) (integerp end) (<= 0 begin end (length text))
         (substring text begin end))))

(defun etaf-md--session-text (session)
  "Return SESSION's current source text.
The text of the buffer visiting the file when there is one, so an unsaved edit
is what gets published; then the text the session was created with; then the
file's own contents.  A session that has none of them has no text, which reads
as an empty document rather than a failure."
  (let ((source (plist-get session :source-buffer)))
    (cond ((buffer-live-p source)
           (with-current-buffer source
             (buffer-substring-no-properties (point-min) (point-max))))
          ((plist-get session :text))
          ((plist-get session :file)
           (or (ignore-errors
                 (etaf-md--read-source (plist-get session :file)))
               ""))
          (t ""))))

(defun etaf-md--table-skeleton (block)
  "Return BLOCK's table as the pipe-and-dashes source that defines it.
A table with no cells left paints an empty grid, which gives the caret nothing
to stand on; the skeleton is what lets a reader fill it back in."
  (let* ((columns (max 1 (length (or (plist-get block :aligns)
                                     (plist-get block :header)))))
         (cells (number-sequence 1 columns))
         (bar (concat "|" (mapconcat (lambda (_) "     |") cells "")))
         (rule (concat "|" (mapconcat (lambda (_) "-----|") cells ""))))
    (concat bar "\n" rule "\n" bar)))

(defun etaf-md--block-marker (block)
  "Return the source skeleton BLOCK paints when its render has no content.
A heading carries its hashes, a list item its bullet, a quote its angle, a
fence its backticks, a table its pipes and rule: these are the characters the
render folds away, and showing them once the content is gone is what lets a
reader see what is left and type it back."
  (pcase (plist-get block :type)
    ('heading (concat (make-string (max 1 (or (plist-get block :level) 1)) ?#) " "))
    ('list-item (if-let* ((start (plist-get block :start)))
                    (format "%s. " start)
                  "- "))
    ('blockquote "> ")
    ('code-block (let ((info (or (plist-get block :info)
                                 (plist-get block :lang) "")))
                   (if (string-empty-p info) "```" (concat "```" info))))
    ('table (etaf-md--table-skeleton block))
    (_ nil)))

(defun etaf-md--blank-p (value)
  "Return non-nil when VALUE holds no text."
  (string-empty-p (string-trim (or value ""))))

(defun etaf-md--block-content (block text)
  "Return BLOCK's own text in TEXT without its marker and line break.
The rendered cells of a block stand for this text, so an empty result means the
block paints nothing and the page would show a gap where its source sits."
  (when-let* ((begin (plist-get block :begin))
              (end (plist-get block :end))
              ((integerp begin))
              ((integerp end))
              ((<= 0 begin end (length text))))
    (let* ((slice (substring text begin end))
           (marker (etaf-md--block-marker block)))
      (when (and marker (string-prefix-p marker slice))
        (setq slice (substring slice (length marker))))
      (string-trim slice))))

(defun etaf-md--inline-text (node)
  "Return the text NODE paints.
A parsed cell holds a list of inline nodes rather than one node, and an inline
node holds its own children, so this walks whatever shape it is given."
  (cond ((stringp node) node)
        ((null node) "")
        ((and (consp node) (keywordp (car node)))
         (or (plist-get node :text)
             (mapconcat #'etaf-md--inline-text (plist-get node :children) "")))
        ((listp node)
         (mapconcat #'etaf-md--inline-text node ""))
        (t "")))

(defun etaf-md--table-blank-p (block)
  "Return non-nil when BLOCK's table holds no cell text.
Only the pipes, dashes and padding that define the grid are left, so the render
paints an empty grid and the caret has nowhere to stand inside it."
  (cl-every (lambda (row)
              (cl-every (lambda (cell)
                          (etaf-md--blank-p (etaf-md--inline-text cell)))
                        (if (listp row) row nil)))
            (remq nil (cons (plist-get block :header) (plist-get block :rows)))))

(defun etaf-md--block-empty-p (block &optional text)
  "Return non-nil when BLOCK paints no content, so the page must show its marker.
Deleting a heading's text is the case a reader meets first, but the rule holds
for every block that carries a structure: a list item, a quote, a fence and a
table all keep a skeleton in the source once their text is gone, and that
skeleton is what lets the caret stand there and type it back.

The block answers this from its own fields.  A render can run before the
session publishes its text, and a block judged by that text would be painted as
if it had content and keep that paint."
  (and (etaf-md--block-marker block)
       (pcase (plist-get block :type)
         ('table (etaf-md--table-blank-p block))
         ((or 'heading 'list-item 'blockquote 'code-block)
          ;; A quote keeps its text in its children and a heading keeps it in
          ;; `:text'; both answer the same question through the same walk.
          (etaf-md--blank-p (etaf-md--inline-text block)))
         (_ (when text
              (etaf-md--blank-p (etaf-md--block-content block text)))))))

(defconst etaf-md--block-ref-prefix "etaf-md-block-"
  "Prefix of the symbol naming a block's box for point-to-block lookup.")

(defvar etaf-md--slot-counter 0
  "Monotonic counter naming stable block slot symbols.")

(defun etaf-md--make-slot ()
  "Return a unique opaque symbol identifying a stable block slot."
  (make-symbol (format "etaf-md-slot-%d" (cl-incf etaf-md--slot-counter))))

(defun etaf-md--rendered-block (block)
  "Return BLOCK without source range offsets, recursively across containers.
A block's `:begin' and `:end' move when text above it changes, while the block
displays the same content; stripping ranges recursively ensures unchanged
containers stay equal across edits above them."
  (if (not (and (listp block) (keywordp (car block))))
      block
    (let* ((has-range (or (plist-member block :begin) (plist-member block :end)))
           (children (and (eq (plist-get block :type) 'container)
                          (plist-get block :children)))
           (copy (if (or has-range children) (copy-sequence block) block)))
      (when has-range
        (cl-remf copy :end)
        (cl-remf copy :begin))
      (when children
        (setq copy (plist-put copy :children
                              (mapcar #'etaf-md--rendered-block children))))
      copy)))

(defun etaf-md--front-matter-end (text)
  "Return the offset past TEXT's front matter, or 0 when it has none.
Matches only the head of TEXT in O(1) without splitting the whole document."
  (if (and (stringp text)
           (string-match "\\`[ \t]*---[ \t]*\n" text))
      (let ((start (match-end 0)))
        (if (string-match "^[ \t]*\\(?:---\\|\\.\\.\\.\\)[ \t]*\\(?:\n\\|\\'\\)"
                          text start)
            (match-end 0)
          0))
    0))

(defun etaf-md--count-blank-lines (text begin end &optional trailing-eof)
  "Return the blank-line gap in TEXT between offsets BEGIN and END.
Scans in place with zero substring allocations.  When only blank lines lie in
the span, preserves the exact source blank-line count.  When non-block
metadata lines (such as footnote, link or abbreviation definitions) occupy the
span, collapses internal separator blanks between those invisible definitions
instead of stacking one blank row per definition; when TRAILING-EOF is non-nil
returns only blank lines before the first trailing definition."
  (let ((total 0)
        (lead 0)
        (cur 0)
        (seen-nonblank nil)
        (pos (max 0 (or begin 0)))
        (limit (min (length text) (max 0 (or end 0)))))
    (while (< pos limit)
      (let* ((nl (string-search "\n" text pos))
             (line-end (if (and nl (< nl limit)) nl limit))
             (blank t)
             (i pos))
        (while (and blank (< i line-end))
          (unless (memq (aref text i) '(?\s ?\t ?\r))
            (setq blank nil))
          (setq i (1+ i)))
        (if blank
            (progn
              (setq total (1+ total)
                    cur (1+ cur))
              (unless seen-nonblank
                (setq lead (1+ lead))))
          (setq seen-nonblank t
                cur 0))
        (setq pos (1+ line-end))))
    (cond
     ((not seen-nonblank) total)
     (trailing-eof lead)
     (t (max lead cur)))))

(defun etaf-md--attach-block-assets (block env &optional session)
  "Attach cached diagram, QR, image and workspace assets onto BLOCK."
  (when (and env (fboundp 'etaf-md-typeset-attach))
    (setq block (etaf-md-typeset-attach block env)))
  (when (fboundp 'etaf-md-qrcode-attach)
    (setq block (etaf-md-qrcode-attach block)))
  (when (and session (fboundp 'etaf-md-assets-attach))
    (setq block (etaf-md-assets-attach block session)))
  (when (fboundp 'etaf-md-cache-warm-block)
    (etaf-md-cache-warm-block block)
    (let* ((urls (etaf-md-cache--extract-block-urls block))
           (paths (and urls (delq nil (mapcar #'etaf-md-cache-image-path urls)))))
      (when paths
        (setq block (plist-put (copy-sequence block) :cached-images paths)))))
  block)

(defun etaf-md--block-digest (block text)
  "Return a content digest string for BLOCK in TEXT."
  (let ((source (or (etaf-md--block-source block text) ""))
        (asset-sig (when-let* ((ad (plist-get block :asset-data)))
                     (let ((print-circle t) (print-length 12) (print-level 4))
                       (prin1-to-string ad)))))
    (concat (or (and (plist-get block :type)
                     (symbol-name (plist-get block :type)))
                "block")
            ":"
            (secure-hash 'sha1
                         (concat source "\0"
                                 (or (plist-get block :picture) "") "\0"
                                 (or (plist-get block :qr) "") "\0"
                                 (or asset-sig "") "\0"
                                 (mapconcat #'identity
                                            (plist-get block :cached-images) "|"))))))

(defun etaf-md--wide-block-p (block)
  "Return non-nil when BLOCK may break out wider than the prose column."
  (and (listp block)
       (or (eq (plist-get block :type) 'table)
           (etaf-md--figure-block-p block))))

(defun etaf-md--make-entry (session block text trailing widths &optional reuse-entry)
  "Build or update a published block entry for BLOCK with TRAILING blank lines.
When REUSE-ENTRY is supplied, keeps its stable `:slot', `:ref' and `:cell',
updating `:cell' in place only when rendered content changed, and keeping its
`eq' `:view' when `:trailing', figure-block and wide-block status are unchanged."
  (let* ((digest (etaf-md--block-digest block text))
         (figure (and (etaf-md--figure-block-p block) t))
         (wide (and (etaf-md--wide-block-p block) t)))
    (if reuse-entry
        (let* ((slot (plist-get reuse-entry :slot))
               (ref (plist-get reuse-entry :ref))
               (cell (plist-get reuse-entry :cell))
               (old-block (plist-get reuse-entry :block))
               (same-content (and (equal (plist-get reuse-entry :key) digest)
                                  (equal (etaf-md--rendered-block old-block)
                                         (etaf-md--rendered-block block))))
               (same-shell (and (eql (plist-get reuse-entry :trailing) trailing)
                                (eq (plist-get reuse-entry :figure-p) figure)
                                (eq (plist-get reuse-entry :wide-p) wide)))
               (view (if same-shell
                         (plist-get reuse-entry :view)
                       (etaf-md--block-view
                        session slot ref cell block trailing widths))))
          (unless same-content
            (etaf-set-value cell block))
          (when-let* ((states (plist-get session :block-states)))
            (unless (gethash slot states)
              (puthash slot (etaf-ref nil :name 'etaf-md-block-state) states)))
          (list :slot slot :ref ref :cell cell :key digest :block block
                :trailing trailing :figure-p figure :wide-p wide :view view))
      (let* ((slot (etaf-md--make-slot))
             (ref (make-symbol etaf-md--block-ref-prefix))
             (cell (etaf-ref block :name 'etaf-md-block-cell))
             (view (etaf-md--block-view
                    session slot ref cell block trailing widths)))
        (when-let* ((states (plist-get session :block-states)))
          (puthash slot (etaf-ref nil :name 'etaf-md-block-state) states))
        (list :slot slot :ref ref :cell cell :key digest :block block
              :trailing trailing :figure-p figure :wide-p wide :view view)))))

(defun etaf-md--reconcile-slice (session old-entries new-blocks next-begin
                                         text widths env &optional has-footnotes)
  "Reconcile NEW-BLOCKS against OLD-ENTRIES in a local slice.
NEXT-BEGIN is the offset where the block following this slice begins, or
`(length text)' at end of document.  When HAS-FOOTNOTES is non-nil, the
document ends with a dedicated footnotes section that paints its own divider
spacer, so trailing blank lines before EOF are not stacked onto the final
body block.  Two-pass matching keeps exact matches untouched and reuses slots
in place for edited blocks of the same type."
  (let* ((n-new (length new-blocks))
         (n-old (length old-entries))
         (used-old (make-vector n-old nil))
         (matched (make-vector n-new nil))
         (prepared (make-vector n-new nil))
         (trailings (make-vector n-new 0))
         (digests (make-vector n-new nil))
         (old-vec (vconcat old-entries))
         (by-digest (make-hash-table :test #'equal)))
    (dotimes (j n-old)
      (let* ((oe (aref old-vec j))
             (k (plist-get oe :key)))
        (puthash k (nconc (gethash k by-digest) (list j)) by-digest)))
    (let ((rest new-blocks)
          (i 0))
      (while rest
        (let* ((blk (etaf-md--attach-block-assets (car rest) env session))
               (nxt (cadr rest))
               (end (or (plist-get blk :end) (length text)))
               (gap-end (if nxt (or (plist-get nxt :begin) end) next-begin))
               (at-eof (and (null nxt) (>= gap-end (length text))))
               (tr (cond
                    ((and at-eof has-footnotes) 0)
                    ((< end gap-end)
                     (etaf-md--count-blank-lines text end gap-end at-eof))
                    (t 0)))
               (dig (etaf-md--block-digest blk text)))
          (aset prepared i blk)
          (aset trailings i tr)
          (aset digests i dig)
          ;; Pass 1: exact content match by digest + rendered AST.
          (when-let* ((cands (gethash dig by-digest)))
            (let ((hit nil))
              (dolist (j cands)
                (when (and (null hit) (not (aref used-old j))
                           (equal (etaf-md--rendered-block
                                   (plist-get (aref old-vec j) :block))
                                  (etaf-md--rendered-block blk)))
                  (setq hit j)))
              (when hit
                (aset used-old hit t)
                (aset matched i (aref old-vec hit))))))
        (setq rest (cdr rest) i (1+ i))))
    ;; Pass 2: reuse remaining unmatched old slots in order for edited blocks
    ;; (preferring same block type so Components patch Ebox nodes in place).
    (dotimes (i n-new)
      (unless (aref matched i)
        (let ((btype (plist-get (aref prepared i) :type))
              (hit nil))
          (dotimes (j n-old)
            (when (and (null hit) (not (aref used-old j))
                       (eq (plist-get (plist-get (aref old-vec j) :block) :type)
                           btype))
              (setq hit j)))
          (unless hit
            (dotimes (j n-old)
              (when (and (null hit) (not (aref used-old j)))
                (setq hit j))))
          (when hit
            (aset used-old hit t)
            (aset matched i (aref old-vec hit))))))
    ;; Retire unused old slots' interactive container state.
    (dotimes (j n-old)
      (unless (aref used-old j)
        (etaf-md--block-state-prune session (plist-get (aref old-vec j) :slot))))
    ;; Materialize reconciled entries.  Preserve the previous rendered picture
    ;; on an edited mermaid or display-math block (stale-while-revalidate,
    ;; inspired by pele.el) while the replacement SVG renders or while live
    ;; edits are momentarily syntactically incomplete.
    (let (out)
      (dotimes (i n-new)
        (let* ((blk (aref prepared i))
               (reuse (aref matched i)))
          (when (and reuse
                     (bound-and-true-p etaf-md-typeset)
                     (fboundp 'etaf-md-typeset-available-p)
                     (etaf-md-typeset-available-p)
                     (fboundp 'etaf-md--typeset-block-kind)
                     (not (plist-get blk :picture)))
            (let* ((old-blk (plist-get reuse :block))
                   (old-pic (plist-get old-blk :picture))
                   (kind (etaf-md--typeset-block-kind blk))
                   (src (plist-get blk :text)))
              (when (and kind
                         (eq kind (etaf-md--typeset-block-kind old-blk))
                         (stringp src)
                         (not (string-blank-p src))
                         (stringp old-pic)
                         (file-exists-p old-pic))
                (setq blk (plist-put (copy-sequence blk) :picture old-pic)))))
          (push (etaf-md--make-entry session
                                     blk
                                     text
                                     (aref trailings i)
                                     widths
                                     reuse)
                out)))
      (nreverse out))))

(defun etaf-md--shift-entry (entry new-block)
  "Return a copy of ENTRY with shifted NEW-BLOCK, skipping hash and view."
  (let ((copy (copy-sequence entry)))
    (plist-put copy :block new-block)))

(defun etaf-md--publish-entries (session document text splice-info)
  "Return `(ENTRIES LEADING VIEWS-CHANGED)' for DOCUMENT of SESSION.
When SPLICE-INFO is non-nil (from an incremental parse), only the spliced
middle window is hashed and reconciled; unchanged prefix and suffix entries
keep their slots, cells and `eq' views in O(Δ) work."
  (let* ((blocks (plist-get document :children))
         (old-entries (plist-get session :entries))
         (widths (etaf-md--page-widths session (etaf-md--read session :width)))
         (env (etaf-md--env session))
         (front (etaf-md--front-matter-end text))
         (first-begin (if blocks
                          (or (plist-get (car blocks) :begin) (length text))
                        (length text)))
         (leading (if (< front first-begin)
                      (etaf-md--count-blank-lines text front first-begin)
                    0))
         (has-footnotes (and (plist-get document :footnotes) t))
         (entries
          (if (and splice-info old-entries)
              (let* ((head (plist-get splice-info :head))
                     (tail (plist-get splice-info :tail))
                     (mcount (plist-get splice-info :middle-count))
                     (old-prefix (seq-take old-entries head))
                     (old-mid (cl-subseq old-entries head tail))
                     (old-suffix (nthcdr tail old-entries))
                     (new-mid (cl-subseq blocks head (+ head mcount)))
                     (new-suffix-blocks (nthcdr (+ head mcount) blocks))
                     (next-begin (if new-suffix-blocks
                                     (or (plist-get (car new-suffix-blocks) :begin)
                                         (length text))
                                   (length text)))
                     (mid-entries
                      (etaf-md--reconcile-slice
                       session old-mid new-mid next-begin text widths env
                       (and (null new-suffix-blocks) has-footnotes)))
                     (suffix-entries
                      (cl-mapcar #'etaf-md--shift-entry
                                 old-suffix new-suffix-blocks)))
                ;; Re-check the trailing blank lines of entry (head - 1) since
                ;; the boundary right after it may have gained/lost blank lines.
                (when (> head 0)
                  (let* ((prev-cell (last old-prefix))
                         (prev-entry (car prev-cell))
                         (prev-block (plist-get prev-entry :block))
                         (prev-end (or (plist-get prev-block :end) 0))
                         (prev-at-eof (and (null mid-entries) (null suffix-entries)))
                         (after-begin (cond
                                       (mid-entries
                                        (or (plist-get (plist-get (car mid-entries) :block) :begin)
                                            prev-end))
                                       (suffix-entries
                                        (or (plist-get (plist-get (car suffix-entries) :block) :begin)
                                            prev-end))
                                       (t (length text))))
                         (new-tr (cond
                                  ((and prev-at-eof has-footnotes) 0)
                                  ((< prev-end after-begin)
                                   (etaf-md--count-blank-lines text prev-end after-begin prev-at-eof))
                                  (t 0))))
                    (unless (eql new-tr (plist-get prev-entry :trailing))
                      (let* ((slot (plist-get prev-entry :slot))
                             (ref (plist-get prev-entry :ref))
                             (cell (plist-get prev-entry :cell))
                             (updated (copy-sequence prev-entry)))
                        (setq updated (plist-put updated :trailing new-tr))
                        (setq updated
                              (plist-put updated :view
                                         (etaf-md--block-view
                                          session slot ref cell prev-block
                                          new-tr widths)))
                        (setcar prev-cell updated)))))
                (nconc old-prefix mid-entries suffix-entries))
            (etaf-md--reconcile-slice
             session (or old-entries nil) blocks (length text) text widths env
             has-footnotes)))
         (views-changed
          (or (not (= (length entries) (length old-entries)))
              (not (cl-every (lambda (a b)
                               (eq (plist-get a :view) (plist-get b :view)))
                             entries old-entries)))))
    (list entries leading views-changed)))

(defun etaf-md--block-ref-table (entries)
  "Return ENTRIES as a table from each entry's box reference to its slot."
  (let ((table (make-hash-table :test #'eq)))
    (dolist (entry entries)
      (when-let* ((ref (plist-get entry :ref)))
        (puthash ref (plist-get entry :slot) table)))
    table))

(cl-defun etaf-md-create (&key file text title theme flavor on-link on-media
                               (link-hover t) (heading-underline t))
  "Create a headless preview session and return it.
FILE names a markdown document to read; TEXT supplies the document directly
for buffers and tests.  Exactly one source is required.  TITLE overrides the
document title; THEME selects a palette and defaults to the value of
`etaf-md-theme' (`auto' derives the document colors from the active
frame's faces and paints no page background).  FLAVOR selects the markdown
dialect and defaults to `etaf-md-flavor': `gfm' enables the GitHub
extensions and front matter, `commonmark' parses the core only, and a feature
plist may toggle individual extensions.  ON-LINK, when non-nil, is called as
\(funcall ON-LINK URL) on link activation; returning non-nil marks the
activation handled, while nil falls back to the default anchor, browser or
file opening.  ON-MEDIA, when non-nil, is called as (funcall ON-MEDIA KIND
PATH) on media activation, where KIND is `image' or `video' and PATH is the
resolved local file path or remote URL; returning non-nil marks the
activation handled, while nil falls back to inline playback or opening.
LINK-HOVER (default t) controls whether rendered links display a hover
background highlight; nil disables hover highlights while keeping links active.
HEADING-UNDERLINE (default t) controls whether headings draw a bottom rule on
levels 1–2 and underline inline links inside headings; nil suppresses both
while keeping heading links active and body links underlined."
  (when (and on-link (not (functionp on-link)))
    (signal 'etaf-md-error
            (list (format "etaf-md-create: :on-link must be a function: %S"
                          on-link))))
  (when (and on-media (not (functionp on-media)))
    (signal 'etaf-md-error
            (list (format "etaf-md-create: :on-media must be a function: %S"
                          on-media))))
  (let* ((file (and file (etaf-md--canonical-file file)))
         (contents (cond (text text)
                         (file (etaf-md--read-source file))
                         (t (signal 'etaf-md-error
                                    '("etaf-md-create needs :file or :text")))))
         (decided (or flavor
                      (etaf-md--document-flavor contents)
                      etaf-md-flavor))
         (requested (or theme etaf-md-theme))
         (auto (eq requested 'auto))
         (palette (if auto (etaf-md-auto-theme) requested))
         ;; Every field exists before the first parse, because a published
         ;; block call refers to this session and later writes must stay in
         ;; place rather than build a second plist.
         (session (list :file file
                        :text (unless file contents)
                        :flavor decided
                        :features nil
                        :on-link on-link
                        :on-media on-media
                        :link-hover (and link-hover t)
                        :heading-underline (and heading-underline t)
                        :dir (if file (file-name-directory file)
                               default-directory)
                        :document (etaf-ref nil :name 'etaf-md-document)
                        ;; Structural layout ref for `etaf-md-app': written only
                        ;; when the block view list, hero, leading blanks or
                        ;; footnotes change, so editing inside an existing block
                        ;; wakes only that block's Component.
                        :page-structure (etaf-ref nil :name 'etaf-md-page-structure)
                        ;; Incremented when frame appearance changes under `auto'
                        ;; theme so mounted blocks re-render in place.
                        :appearance-rev (etaf-ref 0 :name 'etaf-md-appearance-rev)
                        :entries nil
                        :leading-blanks 0
                        :parsed nil
                        :provisional-fence-span nil
                        :dirty-span nil
                        :live-tick nil
                        :live-text nil
                        :source-buffer nil
                        :follow-scroll nil
                        :follow-scroll-marker nil
                        :follow-scroll-line nil
                        :resize-anchor nil
                        :last-canvas-width nil
                        :fit-cols nil
                        :fit-pixel-width nil
                        :fit-char-width nil
                        :asset-timer nil
                        :assets (make-hash-table :test #'equal)
                        :assets-pending (make-hash-table :test #'equal)
                        :annotations nil
                        :reveal-spoilers (etaf-ref nil :name 'etaf-md-reveal-spoilers)
                        :toc-open (etaf-ref nil :name 'etaf-md-toc-open)
                        :toc-active (etaf-ref 0 :name 'etaf-md-toc-active)
                        :toc-buffer nil
                        :lightbox (etaf-ref nil :name 'etaf-md-lightbox)
                        :link-preview (etaf-ref nil :name 'etaf-md-link-preview)
                        :typeset-pending nil
                        :image-refresh-pending nil
                        :hero-cache nil
                        :footnotes-cache nil
                        ;; Box reference to block slot, for reverse lookup.
                        :block-refs (make-hash-table :test #'eq)
                        ;; Per-block interactive container state refs (allocated
                        ;; when each entry is created, never during `:render').
                        :block-states (make-hash-table :test #'eq)
                        :block-state (etaf-ref nil :name 'etaf-md-block-state)
                        ;; Saved buffer positions for footnote `↩' back-links.
                        :footnote-origins (make-hash-table :test #'equal)
                        ;; The rendering environments shared by the blocks of
                        ;; one appearance (`:base-env-cache' is width-free so
                        ;; prose blocks stay untouched across width resizes).
                        :base-env-cache nil
                        :env-cache nil
                        :title (etaf-ref (or title
                                             (and file
                                                  (file-name-nondirectory file))
                                             "Markdown")
                                        :name 'etaf-md-title)
                        :theme (etaf-ref palette :name 'etaf-md-theme)
                        ;; `auto' derives its surface palette from the active
                        ;; frame's faces and paints no page background; a named
                        ;; palette paints its page.
                        :theme-source (etaf-ref (if auto 'frame 'palette)
                                                :name 'etaf-md-theme-source)
                        :theme-mode (etaf-ref requested :name 'etaf-md-theme-mode)
                        :width (etaf-ref (etaf-md--clamp-width 92) :name 'etaf-md-width)
                        :width-locked (etaf-ref nil :name 'etaf-md-width-locked)
                        :viewport-width (etaf-ref nil :name 'etaf-md-viewport-width)
                        :error (etaf-ref nil :name 'etaf-md-error-text)
                        :buffer nil
                        ;; Cards whose video plays inline; written by
                        ;; activation and read while rendering so a press
                        ;; repaints exactly the video cards.
                        :video-active (etaf-ref nil :name 'etaf-md-video-active)
                        ;; One stable native-playback handle per card key so a
                        ;; repaint re-registers the same handle instead of
                        ;; invalidating the card's activation closure.
                        :video-handles (make-hash-table :test #'equal))))
    (etaf-md--install session contents title)
    session))

(defun etaf-md--video-card (session url occurrence)
  "Return (KEY . HANDLE) for URL's OCCURRENCE in SESSION.
A document can show the same source on several cards; the occurrence number
counts the cards in render order so each owns its own player.  KEY names the
card in SESSION's active-video set and HANDLE registers its player while the
card is playing inline."
  (let* ((table (plist-get session :video-handles))
         (key (list url occurrence))
         (handle (or (and (hash-table-p table) (gethash key table))
                     (let ((new (make-symbol "etaf-md-video")))
                       (when (hash-table-p table)
                         (puthash key new table))
                       new))))
    (cons key handle)))

(defun etaf-md-state (session)
  "Return SESSION's state as a detached plist snapshot.
Keys are `:file', `:title', `:dir', `:theme', `:background', `:width',
`:outline', `:error', `:blocks' (top-level block count, blank rows aside)
and `:footnotes'
\(labels).  `:background' is `palette' when the preview paints its palette's
page background, and nil when it leaves the Emacs theme's background."
  (let ((document (etaf-md--read session :document)))
    (list :file (plist-get session :file)
          :title (etaf-md--read session :title)
          :dir (plist-get session :dir)
          :flavor (plist-get session :flavor)
          :theme (etaf-md--read session :theme)
          :background (when (eq (etaf-md--read session :theme-source) 'palette)
                        'palette)
          :width (etaf-md--read session :width)
          :outline (copy-tree (plist-get document :outline))
          :error (etaf-md--read session :error)
          ;; The published list also carries the blank rows the page paints
          ;; between blocks; a reader counting blocks means the document's own.
          :blocks (cl-count-if (lambda (entry)
                                 (not (eq (plist-get (plist-get entry :block)
                                                     :type)
                                          'blank)))
                               (plist-get document :children))
          :footnotes (mapcar (lambda (footnote) (plist-get footnote :label))
                             (plist-get document :footnotes)))))

(defconst etaf-md--reparse-neighbours 1
  "Unchanged blocks parsed again on each side of an edit.
A block can change shape together with the block next to it: deleting the
blank line between two paragraphs makes them one paragraph, so the parse has
to see them together.")

(defconst etaf-md--fence-regexp "^ *\\(```\\|~~~\\)"
  "Line start of a code fence in markdown source.")

(defun etaf-md--shared-start (old new)
  "Return how many characters OLD and NEW share from the start."
  (let ((common (min (length old) (length new))))
    (let ((result (compare-strings old 0 common new 0 common)))
      (if (eq result t) common (1- (abs result))))))

(defun etaf-md--shared-end (old new limit)
  "Return how many characters at the end of OLD and NEW are the same, up to LIMIT."
  (let ((low 0)
        (high limit))
    (while (< low high)
      (let ((middle (/ (+ low high 1) 2)))
        (if (eq t (compare-strings old (- (length old) middle) nil
                                   new (- (length new) middle) nil))
            (setq low middle)
          (setq high (1- middle)))))
    low))

(defun etaf-md--changed-span (old new)
  "Return (OLD-START OLD-END NEW-END) naming what differs between OLD and NEW.
Both ends are found by comparing the strings, so the cost follows the size of
the edit rather than the size of the document."
  (let* ((start (etaf-md--shared-start old new))
         (tail (etaf-md--shared-end old new (- (min (length old) (length new)) start))))
    (list start (- (length old) tail) (- (length new) tail))))

(defun etaf-md--region-fence-state (text from to)
  "Scan TEXT between FROM and TO for code fences, containers and doc defs.
Returns a plist `(:fence FENCE :depth DEPTH :footnote BOOL :doc-def BOOL)'.
FENCE is nil when balanced or `(CHAR . LEN)' when unclosed; DEPTH is 0 when
`:::' containers are balanced or `unbalanced' / positive when unmatched."
  (let ((pos from)
        (fence nil)
        (depth 0)
        (footnote nil)
        (doc-def nil))
    (while (< pos to)
      (let* ((nl (string-search "\n" text pos))
             (line-end (if (and nl (< nl to)) nl to))
             (line (substring text pos line-end)))
        (cond
         ((string-match "\\`[ \t]*\\(`\\{3,\\}\\|~\\{3,\\}\\)" line)
          (let ((marker (match-string 1 line))
                (bare (string-match-p "\\`[ \t]*\\'"
                                      (substring line (match-end 0)))))
            (if fence
                (when (and bare
                           (eq (car fence) (aref marker 0))
                           (>= (length marker) (cdr fence)))
                  (setq fence nil))
              (setq fence (cons (aref marker 0) (length marker))))))
         (fence nil)
         (t
          (when (string-match etaf-md--container-close line)
            (setq depth (if (and (integerp depth) (> depth 0))
                            (1- depth)
                          'unbalanced)))
          (when (and (integerp depth)
                     (string-match etaf-md--container-open line))
            (setq depth (1+ depth)))
          (when (string-search "[^" line)
            (setq footnote t))
          (when (or (string-match-p "\\` ? ? ?\\[[^^\n]+\\]:[ \t]*" line)
                    (string-match-p "\\`\\*\\[[^\n]+\\]:[ \t]*" line))
            (setq doc-def t))))
        (setq pos (1+ line-end))))
    (list :fence fence :depth depth :footnote footnote :doc-def doc-def)))

(defun etaf-md--blocks-have-heading-p (blocks)
  "Return non-nil when any block in BLOCKS (or inside containers) is a heading."
  (cl-some (lambda (block)
             (pcase (plist-get block :type)
               ('heading t)
               ('container (etaf-md--blocks-have-heading-p
                            (plist-get block :children)))))
           blocks))

(defun etaf-md--recompute-outline-copying (blocks)
  "Recompute unique heading ids across BLOCKS without mutating shared headings.
Returns `(OUTLINE UPDATED-BLOCKS CHANGED-INDICES)'."
  (let ((seen (make-hash-table :test #'equal))
        (used (make-hash-table :test #'equal))
        (outline nil)
        (changed-indices nil))
    (cl-labels
        ((walk-one (block)
           (pcase (plist-get block :type)
             ('heading
              (let* ((text (string-trim
                            (etaf-md--heading-plain-text
                             (plist-get block :children))))
                     (base (etaf-md--heading-slug text))
                     (count (1+ (or (gethash base seen) 0)))
                     (id (if (= count 1) base (format "%s-%d" base count))))
                (while (gethash id used)
                  (setq count (1+ count)
                        id (format "%s-%d" base count)))
                (puthash base count seen)
                (puthash id t used)
                (push (list (plist-get block :level) text id) outline)
                (if (equal (plist-get block :id) id)
                    (cons block nil)
                  (cons (plist-put (copy-sequence block) :id id) t))))
             ('container
              (let ((any nil)
                    (kids nil))
                (dolist (child (plist-get block :children))
                  (let ((res (walk-one child)))
                    (when (cdr res) (setq any t))
                    (push (car res) kids)))
                (if any
                    (cons (plist-put (copy-sequence block) :children (nreverse kids)) t)
                  (cons block nil))))
             (_ (cons block nil)))))
      (let ((updated nil)
            (idx 0))
        (dolist (block blocks)
          (let ((res (walk-one block)))
            (when (cdr res) (push idx changed-indices))
            (push (car res) updated))
          (setq idx (1+ idx)))
        (list (nreverse outline) (nreverse updated) (nreverse changed-indices))))))

(defun etaf-md--splice-parse (session contents old-text old-document
                                      &optional dirty-span live-p)
  "Return splice result plist for CONTENTS, or nil when a whole parse is needed.
When incremental splicing succeeds, returns a plist with `:document', `:head',
`:tail', `:middle-count', `:delta' and `:provisional' (non-nil when a live
unclosed code fence was provisionally closed at the local slice boundary)."
  (let* ((delta (- (length contents) (length old-text)))
         (span (if (and dirty-span
                        (= (- (nth 2 dirty-span) (nth 1 dirty-span)) delta)
                        (<= 0 (nth 0 dirty-span) (nth 1 dirty-span) (length old-text))
                        (<= 0 (nth 0 dirty-span) (nth 2 dirty-span) (length contents)))
                   dirty-span
                 (etaf-md--changed-span old-text contents)))
         (old-start (nth 0 span))
         (old-end (nth 1 span))
         (prev-prov (plist-get session :provisional-fence-span))
         (prov-overlap (and prev-prov
                            (<= old-start (cdr prev-prov))
                            (<= (car prev-prov) old-end)))
         (children (plist-get old-document :children))
         (count (length children)))
    (when prov-overlap
      (setq old-start (min old-start (car prev-prov))
            old-end (max old-end (min (length old-text) (cdr prev-prov)))))
    (when (and (or live-p (null prev-prov))
               children
               (seq-every-p (lambda (block)
                              (and (integerp (plist-get block :begin))
                                   (integerp (plist-get block :end))))
                            children))
      (let* ((front-old (etaf-md--front-matter-end old-text))
             (front-new (etaf-md--front-matter-end contents))
             (first (or (cl-position-if (lambda (block)
                                          (>= (or (plist-get block :end) 0) old-start))
                                        children)
                        count))
             (after (or (cl-position-if (lambda (block)
                                          (> (or (plist-get block :begin) 0) old-end))
                                        children)
                        count))
             (head (max 0 (- first etaf-md--reparse-neighbours)))
             (tail (min count (+ after etaf-md--reparse-neighbours)))
             (from (if (> head 0)
                       (plist-get (nth (1- head) children) :end)
                     front-old))
             (to (if (< tail count)
                     (plist-get (nth tail children) :begin)
                   (length old-text)))
             (to-new (+ to delta)))
        (when (and (= front-old front-new)
                   (>= old-start front-old)
                   (<= from old-start)
                   (<= old-end to)
                   (<= from to-new (length contents)))
          (let* ((old-state (etaf-md--region-fence-state old-text from to))
                 (new-state (etaf-md--region-fence-state contents from to-new))
                 (old-fence (plist-get old-state :fence))
                 (new-fence (plist-get new-state :fence))
                 (old-depth (plist-get old-state :depth))
                 (new-depth (plist-get new-state :depth))
                 (prov-covered (and prev-prov
                                    (<= from (car prev-prov))
                                    (<= (cdr prev-prov) to)))
                 (old-fence-ok (or (null old-fence) prov-covered))
                 (provisional (and live-p
                                   old-fence-ok
                                   new-fence
                                   (eql old-depth 0)
                                   (eql new-depth 0))))
            (when (and old-fence-ok
                       (or (null new-fence) provisional)
                       (eql old-depth 0)
                       (eql new-depth 0)
                       (not (plist-get old-state :footnote))
                       (not (plist-get new-state :footnote))
                       (not (plist-get old-state :doc-def))
                       (not (plist-get new-state :doc-def)))
              (let* ((raw-slice (substring contents from to-new))
                     (slice-len (length raw-slice))
                     (slice-with-close
                      (if provisional
                          (concat raw-slice
                                  (unless (string-suffix-p "\n" raw-slice) "\n")
                                  (make-string (cdr new-fence) (car new-fence))
                                  "\n")
                        raw-slice))
                     (doc-defs (plist-get old-document :doc-defs))
                     (parse-input
                      (if (and doc-defs (not (string-empty-p doc-defs)))
                          (concat slice-with-close "\n\n" doc-defs "\n")
                        slice-with-close))
                     (flavor (etaf-md--flavor-for session contents))
                     (fragment (etaf-md--parse parse-input flavor t))
                     (frag-blocks
                      (cl-remove-if-not
                       (lambda (block)
                         (let ((b (plist-get block :begin)))
                           (and (integerp b) (< b slice-len))))
                       (plist-get fragment :children)))
                     (middle
                      (mapcar (lambda (block)
                                (let* ((b (plist-get block :begin))
                                       (e (min slice-len (plist-get block :end)))
                                       (shifted (car (etaf-md--shift-blocks
                                                      (list block) from))))
                                  (setq shifted (plist-put shifted :begin (+ from b)))
                                  (plist-put shifted :end (+ from e))))
                              frag-blocks))
                     (suffix
                      (mapcar (lambda (block)
                                (let ((copy (copy-sequence block)))
                                  (setq copy (plist-put copy :begin
                                                        (+ delta (plist-get block :begin))))
                                  (plist-put copy :end
                                             (+ delta (plist-get block :end)))))
                              (nthcdr tail children)))
                     (spliced (append (seq-take children head) middle suffix)))
                (when (etaf-md--blocks-ordered-p spliced (length contents))
                  (let* ((old-mid (cl-subseq children head tail))
                         (headings-touched
                          (or (etaf-md--blocks-have-heading-p old-mid)
                              (etaf-md--blocks-have-heading-p middle)))
                         (new-doc (copy-sequence old-document))
                         (full-reconcile nil))
                    (if headings-touched
                        (pcase-let* ((`(,outline ,updated ,changed-idx)
                                      (etaf-md--recompute-outline-copying spliced)))
                          (setq spliced updated)
                          (setq new-doc (plist-put new-doc :outline outline))
                          (when (and (null (cdr (assoc "title" (plist-get new-doc :meta))))
                                     (car outline))
                            (setq new-doc (plist-put new-doc :title (nth 1 (car outline)))))
                          (when (cl-some (lambda (i) (or (< i head) (>= i (+ head (length middle)))))
                                         changed-idx)
                            (setq full-reconcile t)))
                      nil)
                    (setq new-doc (plist-put new-doc :children spliced))
                    (list :document new-doc
                          :head head
                          :tail tail
                          :middle-count (length middle)
                          :delta delta
                          :full-reconcile full-reconcile
                          :provisional
                          (cond
                           (provisional (cons from to-new))
                           ((and prev-prov (not prov-covered))
                            (if (<= to (car prev-prov))
                                (cons (+ (car prev-prov) delta)
                                      (+ (cdr prev-prov) delta))
                              prev-prov))
                           (t nil)))))))))))))

(defun etaf-md--blocks-ordered-p (blocks size)
  "Return non-nil when BLOCKS name increasing ranges inside SIZE characters."
  (let ((edge 0) (ok t))
    (dolist (block blocks)
      (let ((begin (plist-get block :begin))
            (end (plist-get block :end)))
        (unless (and (integerp begin) (integerp end)
                     (<= edge begin) (<= begin end) (<= end size))
          (setq ok nil))
        (setq edge end)))
    ok))

(defun etaf-md--parse-changed (session contents &optional dirty-span live-p)
  "Return `(DOCUMENT . SPLICE-INFO)' for CONTENTS, parsing only what changed.
SPLICE-INFO is non-nil when an incremental splice succeeded without needing
full-document entry reconciliation."
  (let* ((flavor (etaf-md--flavor-for session contents))
         (cached (plist-get session :parsed))
         (same-text (and cached (equal (car cached) contents)
                         (or live-p (null (plist-get session :provisional-fence-span)))))
         (splice nil)
         (document
          (cond
           ((null cached)
            (plist-put session :provisional-fence-span nil)
            (etaf-md--parse contents flavor))
           (same-text
            (cdr cached))
           (t
            (let ((res (etaf-md--splice-parse
                        session contents (car cached) (cdr cached)
                        dirty-span live-p)))
              (if res
                  (progn
                    (plist-put session :provisional-fence-span
                               (plist-get res :provisional))
                    (unless (plist-get res :full-reconcile)
                      (setq splice res))
                    (plist-get res :document))
                (plist-put session :provisional-fence-span nil)
                (etaf-md--parse contents flavor)))))))
    (plist-put session :parsed (cons contents document))
    (cons document splice)))

(defun etaf-md--cancel-asset-timer (session)
  "Cancel any pending debounced async asset timer on SESSION."
  (when-let* ((timer (plist-get session :asset-timer)))
    (when (timerp timer) (cancel-timer timer))
    (plist-put session :asset-timer nil)))

(defun etaf-md--run-async-assets (session)
  "Request missing diagrams, QR codes, workspace assets and remote images."
  (when (fboundp 'etaf-md-typeset-request)
    (etaf-md-typeset-request session))
  (when (fboundp 'etaf-md-qrcode-request)
    (etaf-md-qrcode-request session))
  (when (fboundp 'etaf-md-assets-request)
    (etaf-md-assets-request session))
  (when (and (buffer-live-p (plist-get session :buffer))
             (fboundp 'etaf-md-cache-request-images))
    (etaf-md-cache-request-images session)))

(defun etaf-md--schedule-async-assets (session &optional live-p)
  "Schedule external asset generation for SESSION.
During live typing (LIVE-P non-nil), debounces onto an idle timer so rapid
keystrokes inside formulas, diagrams or QR blocks never flood Chromium or disk."
  (etaf-md--cancel-asset-timer session)
  (if live-p
      (plist-put session :asset-timer
                 (run-with-idle-timer
                  0.25 nil
                  (lambda ()
                    (plist-put session :asset-timer nil)
                    (when (buffer-live-p (plist-get session :buffer))
                      (etaf-md--run-async-assets session)))))
    (when (fboundp 'etaf-md-typeset-request)
      (etaf-md-typeset-request session))
    (when (fboundp 'etaf-md-qrcode-request)
      (etaf-md-qrcode-request session))
    (when (fboundp 'etaf-md-assets-request)
      (etaf-md-assets-request session))
    (when (and (buffer-live-p (plist-get session :buffer))
               (fboundp 'etaf-md-cache-request-images))
      (plist-put session :asset-timer
                 (run-with-timer
                  0.05 nil
                  (lambda ()
                    (plist-put session :asset-timer nil)
                    (when (buffer-live-p (plist-get session :buffer))
                      (etaf-md-cache-request-images session))))))))

(defun etaf-md--install (session contents &optional title dirty-span live-p)
  "Parse CONTENTS and publish it as SESSION's document; return the document.
TITLE overrides the document title; DIRTY-SPAN is an optional `(OLD-BEG OLD-END
NEW-END)' span from `after-change-functions'; LIVE-P is non-nil during unsaved
live typing.  When only an existing block's text changed, updates that block's
own `:cell' ref in place without updating `:page-structure', so `etaf-md-app'
performs zero work and only that single block Component re-renders."
  (let (document)
    (etaf-batch
      (pcase-let* ((`(,parsed . ,splice-info)
                    (etaf-md--parse-changed session contents dirty-span live-p))
                   (pub (etaf-md--publish-entries
                         session parsed contents splice-info))
                   (entries (nth 0 pub))
                   (leading (nth 1 pub))
                   (views-changed (nth 2 pub))
                   (doc (plist-put (copy-sequence parsed) :children entries))
                   (old-struct (etaf-md--read session :page-structure))
                   (meta (plist-get doc :meta))
                   (footnotes (plist-get doc :footnotes))
                   (struct-changed
                    (or (null old-struct)
                        views-changed
                        (not (eql leading (plist-get old-struct :leading)))
                        (not (equal meta (plist-get old-struct :meta)))
                        (not (equal footnotes (plist-get old-struct :footnotes))))))
        (setq document doc)
        (plist-put session :entries entries)
        (plist-put session :leading-blanks leading)
        (plist-put session :features (plist-get doc :features))
        (plist-put session :annotations (plist-get doc :annotations))
        (when views-changed
          (plist-put session :block-refs (etaf-md--block-ref-table entries)))
        (etaf-set-value (etaf-md--ref session :document) doc)
        (when struct-changed
          (etaf-set-value (etaf-md--ref session :page-structure)
                          (list :meta meta
                                :leading leading
                                :items (mapcar (lambda (e)
                                                 (list (plist-get e :slot)
                                                       (plist-get e :wide-p)
                                                       (plist-get e :view)))
                                               entries)
                                :views (mapcar (lambda (e) (plist-get e :view)) entries)
                                :footnotes footnotes)))
        (etaf-md--write session :title
                        (or title
                            (plist-get doc :title)
                            (and (plist-get session :file)
                                 (file-name-nondirectory (plist-get session :file)))
                            "Markdown"))
        (etaf-md--write session :error nil)))
    (etaf-md--schedule-async-assets session live-p)
    document))

(defun etaf-md--publish (session contents &optional dirty-span live-p)
  "Publish CONTENTS as SESSION's document and return SESSION."
  (etaf-md--install session contents nil dirty-span live-p)
  session)

(defun etaf-md-refresh (session)
  "Re-read and re-parse SESSION's document.
Return SESSION.  A read failure signals `etaf-md-error' and leaves the
published document untouched."
  (let* ((file (plist-get session :file))
         (text (if file (etaf-md--read-source file)
                 (or (plist-get session :text) ""))))
    (etaf-md--publish session text)
    ;; See `etaf-md--live-repaint': a scheduled follow compares against
    ;; the text the page already shows.
    (plist-put session :live-text text)
    session))

(defun etaf-md--refresh-block-assets (session)
  "Re-attach newly arrived pictures, QR codes or cached images in place.
Updates only the `:cell' ref of blocks whose asset actually changed, without
reparsing the document or touching any other block."
  (when (buffer-live-p (plist-get session :buffer))
    (let ((env (etaf-md--env session))
          (entries (plist-get session :entries))
          (changed nil))
      (etaf-batch
        (dolist (entry entries)
          (let* ((old-block (plist-get entry :block))
                 (new-block (etaf-md--attach-block-assets old-block env session)))
            (unless (and (equal (plist-get old-block :picture)
                                (plist-get new-block :picture))
                         (equal (plist-get old-block :qr)
                                (plist-get new-block :qr))
                         (equal (plist-get old-block :asset-data)
                                (plist-get new-block :asset-data))
                         (equal (plist-get old-block :cached-images)
                                (plist-get new-block :cached-images))
                         (or (not (eq (plist-get old-block :type) 'container))
                             (equal (plist-get old-block :children)
                                    (plist-get new-block :children))))
              (plist-put entry :block new-block)
              (etaf-set-value (plist-get entry :cell) new-block)
              (setq changed t)))))
      changed)))

(defun etaf-md--republish (session)
  "Repaint SESSION for its current palette/appearance and request missing pictures.
Reuses the cached parse and updates only changed assets in place, bumping
`:appearance-rev' when frame appearance inputs changed so every block repaints
with the new palette without destroying Component instances."
  (when (buffer-live-p (plist-get session :buffer))
    (let ((old-inputs (car (plist-get session :env-cache)))
          (new-inputs (etaf-md--env-inputs session)))
      (unless (equal old-inputs new-inputs)
        (etaf-set-value (etaf-md--ref session :appearance-rev)
                        (1+ (etaf-md--read session :appearance-rev))))
      (etaf-md--refresh-block-assets session)
      (etaf-md--schedule-async-assets session nil)))
  session)

(defun etaf-md-set-theme (session theme)
  "Show SESSION with palette THEME; return SESSION.
THEME is `auto', `dark', `light' or `sepia'; anything else signals
`etaf-md-error'.  Selecting a palette also paints its page
background, while `auto' returns to the face-derived surfaces."
  (unless (or (eq theme 'auto) (assq theme etaf-md-themes))
    (signal 'etaf-md-error
            (list (format "Unknown markdown preview theme: %S" theme))))
  (etaf-batch
    (etaf-md--write session :theme-mode theme)
    (etaf-md--write session :theme
                             (if (eq theme 'auto)
                                 (etaf-md-auto-theme)
                               theme))
    (etaf-md--write session :theme-source
                             (if (eq theme 'auto) 'frame 'palette)))
  (etaf-md--republish session)
  session)

(declare-function etaf-md--current-session "etaf-md-app" ())
(declare-function etaf-md--preview-command-p "etaf-md-app" (symbol buffer))

(defun etaf-md-cycle-theme (&optional session)
  "Switch SESSION (or the current preview) to the next theme mode.
Cycles `dark' -> `light' -> `sepia' -> `auto' and returns the newly selected
mode symbol."
  (declare (completion etaf-md--preview-command-p))
  (interactive)
  (let* ((explicit-p (not (null session)))
         (session (or session
                      (and (fboundp 'etaf-md--current-session)
                           (etaf-md--current-session))
                      (user-error "Not an ETAF markdown preview buffer")))
         (modes (append (mapcar #'car etaf-md-themes) '(auto)))
         (current (etaf-md--read session :theme-mode))
         (tail (cdr (memq current modes)))
         (next (or (car tail) (car modes))))
    (etaf-md-set-theme session next)
    (unless explicit-p
      (message "Theme: %s" next))
    next))

;;; ---------------------------------------------------------------------------
;;; Width and layout fitting
;;; ---------------------------------------------------------------------------

(defun etaf-md--clamp-width (width)
  "Return WIDTH clamped to the supported reading measure."
  (max etaf-md-width-min
       (min etaf-md-width-max (round width))))

(defun etaf-md-adjust-width (session delta)
  "Widen SESSION's maximum reading measure by DELTA cells and return it.
The window may still be narrower than the returned cap, in which case the
column fills the window.  Narrowing binds wide tables and figures to the chosen
reading measure so every block narrows monotonically alongside prose; widening
past `etaf-md-width-max' restores automatic wide-table viewport breakout."
  (let* ((current (etaf-md--read session :width))
         (effective (if (< delta 0)
                        (min current (car (etaf-md--page-widths session current)))
                      current))
         (raw (+ effective delta))
         (width (etaf-md--clamp-width raw)))
    (etaf-batch
      (cond
       ((< delta 0)
        (etaf-md--write session :width-locked t))
       ((and (> delta 0) (> raw etaf-md-width-max))
        (etaf-md--write session :width-locked nil)))
      (etaf-md--write session :width width))
    width))

(defun etaf-md--fit-width (session)
  "Set SESSION's reading measure from the window that shows it.
The stored width is the maximum measure: the column is viewport-relative, so
a later resize narrows it without changing this value.  The window's own
measure excludes the gutter the column keeps on each side.  A headless
session keeps its current width.  Return the width in effect."
  (let* ((buffer (plist-get session :buffer))
         (window (and (buffer-live-p buffer) (get-buffer-window buffer t))))
    (if (window-live-p window)
        (let ((width (etaf-md--clamp-width
                      (- (window-body-width window)
                         (* 2 etaf-md--measure-gutter)))))
          (etaf-md--write session :width width)
          width)
      (etaf-md--read session :width))))

;;; ---------------------------------------------------------------------------
;;; Navigation
;;; ---------------------------------------------------------------------------

(defun etaf-md-outline (session)
  "Return SESSION's outline as a list of (LEVEL TEXT ID)."
  (copy-tree (plist-get (etaf-md--read session :document) :outline)))

(defun etaf-md--heading-match-forward (text)
  "Search forward for heading TEXT at the start of a line.
Return the match start, or nil.  Leading blank characters (including the
display spaces the renderer uses for centering) and container or heading
left borders (`│') may precede the match."
  (let ((found nil))
    (while (and (not found) (search-forward text nil t))
      (let ((line-start (line-beginning-position)))
        (when (string-match-p
               "\\`[ \t│]*\\'"
               (buffer-substring-no-properties line-start (match-beginning 0)))
          (setq found (match-beginning 0)))))
    found))

(defun etaf-md--heading-position-from-bounds (bounds text)
  "Return the buffer position of heading TEXT within host BOUNDS `(BEG . END)'."
  (when (and (consp bounds) (integerp (car bounds)) (integerp (cdr bounds)))
    (let ((beg (max (point-min) (min (point-max) (car bounds))))
          (end (max (point-min) (min (point-max) (cdr bounds)))))
      (save-excursion
        (goto-char beg)
        (if (and (stringp text) (not (string-empty-p text))
                 (search-forward text end t))
            (match-beginning 0)
          beg)))))

(defun etaf-md--heading-positions (session)
  "Return SESSION's heading buffer positions as a list of (INDEX . POSITION).
Prefers each heading's own host ref bounds when mounted, which tracks headings
inside bordered or multi-column containers and omits headings hidden inside
collapsed blocks; falls back to line-order scanning when no runtime is attached."
  (let ((buffer (plist-get session :buffer))
        (outline (etaf-md-outline session)))
    (when (buffer-live-p buffer)
      (let ((runtime (etaf-runtime-for-buffer buffer)))
        (with-current-buffer buffer
          (save-excursion
            (goto-char (point-min))
            (cl-loop for entry in outline
                     for index from 0
                     for ref = (etaf-md--heading-ref (nth 2 entry))
                     for bounds = (and runtime ref
                                       (etaf-host-ref-bounds runtime ref))
                     for position =
                     (if runtime
                         (etaf-md--heading-position-from-bounds
                          bounds (nth 1 entry))
                       (etaf-md--heading-match-forward (nth 1 entry)))
                     when position collect (cons index position))))))))

(defun etaf-md--scrollable-ancestor-p (runtime ref)
  "Return non-nil when REF sits inside a scrolling Host in RUNTIME."
  (let* ((ancestries (etaf-runtime-host-ancestries runtime (list ref)))
         (lineage (cdr (gethash ref ancestries))))
    (cl-some (lambda (anc)
               (memq (plist-get (etaf-runtime-host-props-for runtime anc) :overflow)
                     '(scroll auto)))
             lineage)))

(defvar etaf-md--locating-from-outline nil
  "Non-nil while navigating from a click or activation inside `*ETAF Outline*'.")

(defun etaf-md--toc-row-ref (index)
  "Return the static host ref symbol for TOC row INDEX."
  (when (integerp index)
    (intern (format "etaf-md-toc-row-%d" index))))

(defun etaf-md--apply-outline-viewport (session index keep-viewport saved-line)
  "Position SESSION's outline window for heading INDEX.
When KEEP-VIEWPORT is non-nil (user clicked inside the outline itself), keep
`window-start' pinned to 1-based line SAVED-LINE and only update `window-point'
onto the clicked row so the sidebar never jumps.  Otherwise (preview-driven
navigation), keep `window-start' untouched when INDEX is already visible and
only recenter when INDEX lies outside the outline viewport."
  (when-let* ((obuf (plist-get session :toc-buffer))
              ((buffer-live-p obuf))
              (ort (etaf-runtime-for-buffer obuf))
              ((etaf-runtime-mounted-p ort))
              (owin (get-buffer-window obuf t))
              ((window-live-p owin))
              (ref (etaf-md--toc-row-ref index))
              (pos (etaf-host-ref-position ort ref)))
    (with-current-buffer obuf
      (cond
       (keep-viewport
        (set-window-point owin pos)
        (when (and (integerp saved-line) (> saved-line 0))
          (let ((start-pos (save-excursion
                             (goto-char (point-min))
                             (forward-line (1- saved-line))
                             (point))))
            (set-window-start owin start-pos t))))
       ((pos-visible-in-window-p pos owin)
        (set-window-point owin pos))
       (t
        (set-window-point owin pos)
        (with-selected-window owin
          (goto-char pos)
          (recenter)))))))

(defun etaf-md--sync-outline-viewport (session index &optional keep-viewport)
  "Sync SESSION's open outline buffer to heading INDEX.
Uses INDEX's static host ref so it is never stale inside an `etaf-batch', and
re-applies viewport pinning on `etaf-next-tick' after reactive paint settles."
  (when-let* ((obuf (plist-get session :toc-buffer))
              ((buffer-live-p obuf))
              (ort (etaf-runtime-for-buffer obuf))
              ((etaf-runtime-mounted-p ort)))
    (let* ((owin (get-buffer-window obuf t))
           (saved-line (and (window-live-p owin)
                            (with-current-buffer obuf
                              (line-number-at-pos (window-start owin))))))
      ;; Move window-point immediately onto the target row (already visible on
      ;; outline clicks) so Ebox's flush never tracks a stale off-screen point.
      (etaf-md--apply-outline-viewport session index keep-viewport saved-line)
      (etaf-runtime-flush ort)
      (etaf-md--apply-outline-viewport session index keep-viewport saved-line)
      (etaf-next-tick
       (lambda ()
         (when (eql index (etaf-md--read session :toc-active))
           (etaf-md--apply-outline-viewport
            session index keep-viewport saved-line)))))))

(defun etaf-md-locate (session index)
  "Move point to SESSION's outline heading INDEX and bring it into view.
When SESSION is embedded inside a scrolling Host viewport, scrolls that
viewport so the heading sits at its top without recentering the outer Emacs
window; otherwise recenters the preview window to row 0.  Return the position,
or nil when the heading is not mounted or visible."
  (let* ((buffer (plist-get session :buffer))
         (outline (etaf-md-outline session))
         (entry (and (integerp index) (>= index 0) (nth index outline)))
         (runtime (and (buffer-live-p buffer) (etaf-runtime-for-buffer buffer)))
         (ref (and entry (etaf-md--heading-ref (nth 2 entry))))
         (keep-outline-vp etaf-md--locating-from-outline)
         (in-scroller nil))
    (when (and entry (buffer-live-p buffer))
      (plist-put session :resize-anchor nil)
      (plist-put session :locate-gen (1+ (or (plist-get session :locate-gen) 0)))
      (when (etaf-md--ref session :toc-active)
        (etaf-md--write session :toc-active index)
        (etaf-md--sync-outline-viewport session index keep-outline-vp))
      (when (and runtime (etaf-runtime-mounted-p runtime)
                 ref (etaf-runtime-host-props-for runtime ref))
        (setq in-scroller (etaf-md--scrollable-ancestor-p runtime ref))
        (when in-scroller
          (etaf-scroll-into-view runtime ref 'start)
          (etaf-runtime-flush runtime)))
      (let ((position (cdr (assq index (etaf-md--heading-positions session)))))
        (when position
          (let ((win (get-buffer-window buffer t)))
            (with-current-buffer buffer
              (push-mark (point) t)
              (goto-char position)
              (when (window-live-p win)
                (set-window-point win position)
                (unless in-scroller
                  (with-selected-window win
                    (goto-char position)
                    (recenter 0))))))
          position)))))

(defun etaf-md--adjacent-heading (session direction)
  "Move point to the next outline heading in DIRECTION.
DIRECTION is 1 for forward and -1 for backward.  Return the position moved to,
or nil when there is no heading left."
  (let* ((positions (etaf-md--heading-positions session))
         (buffer (plist-get session :buffer))
         (point-now (if (buffer-live-p buffer)
                        (with-current-buffer buffer (point))
                      0))
         (target
          (if (> direction 0)
              (car (cl-find-if (lambda (cell) (> (cdr cell) point-now)) positions))
            (car (car (last (cl-remove-if-not
                             (lambda (cell) (< (cdr cell) point-now))
                             positions)))))))
    (when target
      (etaf-md-locate session target))))

;;; ---------------------------------------------------------------------------
;;; Opening targets
;;; ---------------------------------------------------------------------------

(defun etaf-md--locate-anchor (session anchor)
  "Move point to SESSION's heading whose anchor is ANCHOR.
ANCHOR may be written the way a document writes it and the way a browser
encodes it, so `#使用 手册' and `#%E4%BD%BF%E7%94%A8' reach the same heading."
  (let ((names (delq nil (list anchor (ignore-errors (url-unhex-string anchor))))))
    (cl-loop for entry in (etaf-md-outline session)
             for index from 0
             when (member (nth 2 entry) names)
             return (etaf-md-locate session index)
             finally (message "No heading matches #%s" anchor))))

(defun etaf-md--locate-pending (buffer anchor)
  "Move point in BUFFER to ANCHOR once its page is painted.
A preview opened from inside a command has not written its page yet, so the
lookup runs after that command: a flush here publishes what the mount built,
and the heading is searched in the text a reader sees."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when-let* ((session (ignore-errors (etaf-md--current-session))))
        (when-let* ((runtime (etaf-runtime-for-buffer buffer)))
          (etaf-runtime-flush runtime))
        (etaf-md--locate-anchor session anchor)))))

(defun etaf-md--open-url (session url)
  "Open URL referenced by SESSION's document.
When SESSION carries an `:on-link' callback, call it with URL first; a non-nil
return value means the caller handled the activation.  Otherwise an
in-document anchor jumps to the matching heading, a URL with a scheme goes
to the browser, and a local path opens in Emacs: a markdown document opens as
its preview, anything else as a file.  A `#fragment' after a local path selects
that heading in the opened preview."
  (let ((handler (plist-get session :on-link)))
    (unless (and handler (funcall handler url))
      (let* ((fragment nil)
             (target (if (string-match "\\`\\([^#]*\\)#\\(.+\\)\\'" url)
                         (prog1 (match-string 1 url)
                           (setq fragment (match-string 2 url)))
                       url)))
        (cond
         ((string-empty-p target)
          (when fragment (etaf-md--locate-anchor session fragment)))
         ((etaf-md--remote-url-p target) (browse-url target))
         (t
          (let ((path (expand-file-name target (or (plist-get session :dir)
                                                   default-directory))))
            (cond
             ((and (string-match-p etaf-md--markdown-file-regexp path)
                   (file-readable-p path))
              (let ((buffer (etaf-md-open path)))
                ;; The heading is found in the painted page, and the paint of a
                ;; page mounted inside a command belongs to the redisplay that
                ;; follows it, so the fragment is applied once that paint is done.
                (when (and fragment (buffer-live-p buffer))
                  (run-at-time 0 nil #'etaf-md--locate-pending buffer fragment))))
             ((file-exists-p path) (find-file-other-window path))
             (t (message "File not found: %s" path))))))))))

(defun etaf-md--open-media (session kind path)
  "Ask SESSION's `:on-media' callback to handle media PATH of KIND.
KIND is `image' or `video'.  Return non-nil when the callback handled the
activation, or nil to run the default media action."
  (when-let* ((handler (plist-get session :on-media)))
    (funcall handler kind path)))

(defun etaf-md--open-file (path)
  "Open PATH with the operating system's default application.
Emacs's `browse-url' routes local non-HTML files back into Emacs, which would
show a video as a binary buffer; media cards therefore ask the desktop to open
the file directly."
  (let ((opener (pcase system-type
                  ('darwin "open")
                  ('gnu/linux "xdg-open")
                  (_ nil))))
    (if (and opener (executable-find opener))
        (call-process opener nil 0 nil path)
      (browse-url-of-file path))))

(defun etaf-md--footnote-ref (label)
  "Return the host ref symbol naming footnote definition LABEL."
  (when (and (stringp label) (not (string-empty-p label)))
    (intern (format "etaf-md-footnote-%s" label))))

(defun etaf-md--jump-footnote (session label)
  "Move point to footnote definition LABEL in SESSION's buffer.
Records the caller's position for the `↩' return control and pushes mark so
`C-u C-SPC' returns to the reference."
  (let* ((buffer (plist-get session :buffer))
         (runtime (and (buffer-live-p buffer) (etaf-runtime-for-buffer buffer)))
         (ref (etaf-md--footnote-ref label))
         (in-scroller nil))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (let ((origin (point)))
          (when-let* ((origins (plist-get session :footnote-origins))
                      ((hash-table-p origins)))
            (puthash label origin origins))
          (when (and runtime (etaf-runtime-mounted-p runtime)
                     ref (etaf-runtime-host-props-for runtime ref))
            (setq in-scroller (etaf-md--scrollable-ancestor-p runtime ref))
            (when in-scroller
              (etaf-scroll-into-view runtime ref 'start)))
          (let ((position
                 (or (and runtime ref (etaf-host-ref-position runtime ref))
                     ;; Fallback when unmounted: search backwards from buffer end
                     ;; so we land on the bottom footnote definition, never on
                     ;; the body reference itself.
                     (save-excursion
                       (goto-char (point-max))
                       (let* ((entry (cl-find label
                                              (plist-get
                                               (etaf-md--read session :document)
                                               :footnotes)
                                              :key (lambda (fn) (plist-get fn :label))
                                              :test #'equal))
                              (needle (format "[%s] "
                                              (or (and entry (plist-get entry :number))
                                                  label))))
                         (when (search-backward needle nil t)
                           (match-beginning 0)))))))
            (if position
                (with-selected-window (or (get-buffer-window buffer t) (selected-window))
                  (with-current-buffer buffer
                    (push-mark origin t)
                    (goto-char position)
                    (unless in-scroller
                      (recenter 0)))
                  position)
              (message "Footnote %s not found" label))))))))

(defun etaf-md--jump-footnote-back (session label)
  "Return from footnote definition LABEL back to its saved reference position."
  (let ((buffer (plist-get session :buffer))
        (origins (plist-get session :footnote-origins)))
    (when (and (buffer-live-p buffer) (hash-table-p origins))
      (if-let* ((origin (gethash label origins)))
          (with-selected-window (or (get-buffer-window buffer t) (selected-window))
            (with-current-buffer buffer
              (push-mark (point) t)
              (goto-char (max (point-min) (min (point-max) origin)))
              (recenter)))
        (message "没有记录脚注 %s 的引用位置" label)))))

;;; ---------------------------------------------------------------------------
;;; Rendering environment
;;; ---------------------------------------------------------------------------

(defun etaf-md--page-background (session)
  "Return the page background SESSION paints, or nil for none.
The session paints its palette's background only after an explicit palette
selection; the face-derived `auto' appearance leaves the active Emacs theme's
background visible instead."
  (when (eq (etaf-md--read session :theme-source) 'palette)
    (etaf-md-color :bg (etaf-md--read session :theme))))

(defun etaf-md--display-frame (session)
  "Return the frame showing SESSION, or nil when it has no window.
A face query answers for a frame, so the palette is derived from the frame the
preview is read in rather than from whichever frame is selected."
  (let ((buffer (plist-get session :buffer)))
    (when (buffer-live-p buffer)
      (when-let* ((window (get-buffer-window buffer t)))
        (window-frame window)))))

(defun etaf-md--session-palette (session)
  "Return SESSION's surface palette, or nil for the named palette colors.
Sessions created with the `auto' theme derive their surfaces from the faces of
the frame showing them, so panels, tables and code blocks match the user's own
theme.  A session that has not selected a palette explicitly uses the
face-derived palette; a named palette returns its own color alist so the shared
renderer never needs a theme name."
  (if (eq (etaf-md--read session :theme-source) 'palette)
      (cdr (assq (etaf-md--read session :theme) etaf-md-themes))
    (etaf-md--palette-from-faces
     (etaf-md--display-frame session))))

(defun etaf-md--frame-surface (frame)
  "Return FRAME's default foreground and background.
The face-derived palette follows these two faces, so a theme switch changes
them and the shared environment is rebuilt instead of keeping the previous
palette.  A session shown in no window derives its palette from the selected
frame, so FRAME nil reads that frame."
  (if frame
      (cons (face-attribute 'default :foreground frame)
            (face-attribute 'default :background frame))
    (cons (face-attribute 'default :foreground)
          (face-attribute 'default :background))))

(defun etaf-md--collect-gallery-images (session)
  "Collect local/cached image items in SESSION for the media lightbox."
  (let ((dir (or (plist-get session :dir) default-directory))
        (items nil)
        (seen (make-hash-table :test #'equal)))
    (cl-labels
        ((add (url caption)
           (when (stringp url)
             (let* ((remote (etaf-md--remote-url-p url))
                    (path (if remote
                              (etaf-md-cache-image-path url)
                            (expand-file-name
                             (if (string-prefix-p "file://" url) (substring url 7) url)
                             dir))))
               (when (and path (file-readable-p path)
                          (eq (etaf-md--media-kind path) 'image)
                          (not (gethash path seen)))
                 (puthash path t seen)
                 (push (list :src path
                             :caption (or (and (stringp caption) (not (string-empty-p caption)) caption)
                                          (file-name-nondirectory path)))
                       items)))))
         (walk-inline (node)
           (when (and (listp node) (keywordp (car node)))
             (when (eq (plist-get node :type) 'image)
               (add (plist-get node :url) (plist-get node :alt)))
             (dolist (ch (plist-get node :children)) (walk-inline ch))))
         (walk-block (b)
           (when (and (listp b) (keywordp (car b)))
             (when-let* ((pic (plist-get b :picture)))
               (add pic (or (plist-get b :lang) "图表")))
             (pcase (plist-get b :type)
               ((or 'paragraph 'heading)
                (dolist (ch (plist-get b :children)) (walk-inline ch)))
               ('container
                (when (equal (plist-get b :name) "image-card")
                  (let ((attrs (plist-get b :attrs)))
                    (add (plist-get attrs :src) (plist-get attrs :title))))
                (dolist (ch (plist-get b :children)) (walk-block ch)))
               ((or 'blockquote 'list-item)
                (dolist (ch (plist-get b :children)) (walk-block ch)))
               ('list
                (dolist (it (plist-get b :items))
                  (dolist (ch (plist-get it :children)) (walk-block ch))))))))
      (dolist (entry (plist-get session :entries))
        (walk-block (plist-get entry :block))))
    (nreverse items)))

(defun etaf-md--open-lightbox (session path &optional caption)
  "Open SESSION's in-buffer `etaf-media-viewer' lightbox at image PATH."
  (let* ((buf (and session (plist-get session :buffer)))
         (win (and (buffer-live-p buf) (get-buffer-window buf t)))
         (frame (and (window-live-p win) (window-frame win)))
         (use-lb (pcase etaf-md-media-lightbox
                   ('t t)
                   ('auto (display-graphic-p frame))
                   (_ nil))))
    (when (and use-lb
               (buffer-live-p buf)
               (stringp path) (file-readable-p path))
      (let* ((items (etaf-md--collect-gallery-images session))
             (idx (or (cl-position path items
                                   :key (lambda (it) (plist-get it :src))
                                   :test #'equal)
                      (progn
                        (setq items (append items
                                            (list (list :src path
                                                        :caption (or caption (file-name-nondirectory path))))))
                        (1- (length items))))))
        (etaf-md--write session :lightbox (list :items items :index idx))
        t))))

(defun etaf-md--base-env-inputs (session)
  "Return the non-width inputs SESSION's base rendering environment depends on.
Excluding `:width', `:width-locked' and viewport columns lets width-independent
prose blocks skip re-rendering across window resizes and column adjustments."
  (let* ((source (etaf-md--read session :theme-source))
         (face-derived (not (eq source 'palette)))
         (frame (etaf-md--display-frame session)))
    (list :theme (etaf-md--read session :theme)
          :source source
          :rev (etaf-md--read session :appearance-rev)
          :background (etaf-md--page-background session)
          :surface (and face-derived (etaf-md--frame-surface frame))
          :appearance (and face-derived (etaf-appearance))
          :dir (plist-get session :dir)
          :features (plist-get session :features)
          :annotations (plist-get session :annotations)
          :reveal-spoilers (etaf-md--read session :reveal-spoilers))))

(defun etaf-md--env-inputs (session)
  "Return the values SESSION's width-aware rendering environment is built from.
Reads `etaf-md--page-widths' (which tracks `etaf-canvas-columns' reactively
when mounted) without double-subscribing to `:viewport-width'."
  (let* ((max-width (etaf-md--read session :width))
         (widths (etaf-md--page-widths session max-width)))
    (list :base (etaf-md--base-env-inputs session)
          :width (car widths)
          :figure-width (cdr widths)
          :width-locked (etaf-md--read session :width-locked))))

(declare-function etaf-md--render-code-block "etaf-md-typeset" (block env))
(declare-function etaf-md--render-math "etaf-md-typeset" (block env))
(declare-function etaf-md-typeset-request "etaf-md-typeset" (session))
(declare-function etaf-md-typeset-attach "etaf-md-typeset" (block env))
(declare-function etaf-md-typeset-available-p "etaf-md-typeset" ())
(declare-function etaf-md--typeset-block-kind "etaf-md-typeset" (block))

(defun etaf-md--build-base-env (session)
  "Build SESSION's width-free rendering environment from its appearance inputs."
  (list :session session
        :theme (etaf-md--read session :theme)
        :palette (etaf-md--session-palette session)
        :background (etaf-md--page-background session)
        :dir (plist-get session :dir)
        :features (plist-get session :features)
        :annotations (plist-get session :annotations)
        :reveal-spoilers (etaf-md--read session :reveal-spoilers)
        :open-url (lambda (url) (etaf-md--open-url session url))
        :open-link (lambda (url) (etaf-md--open-url session url))
        :open-wiki-link (lambda (target anchor label)
                          (etaf-md-assets-open-wiki-link session target anchor label))
        :open-symbol (lambda (name)
                       (etaf-md-assets-open-symbol session name))
        :on-toggle-task (when etaf-md-interactive-checkbox
                          (lambda (block item idx)
                            (etaf-md-assets-toggle-task session block item idx)))
        :open-lightbox (lambda (path &optional caption)
                         (etaf-md--open-lightbox session path caption))
        :link-hover (plist-get session :link-hover)
        :heading-underline (plist-get session :heading-underline)
        :open-media (lambda (kind path) (etaf-md--open-media session kind path))
        :open-file #'etaf-md--open-file
        :render-media #'etaf-md--render-media
        :alert-labels etaf-md--alert-labels
        :video-active-p
        (lambda (key)
          (member key (etaf-md--read session :video-active)))
        :activate-video
        (lambda (key)
          (etaf-set-value
           (etaf-md--ref session :video-active)
           (cons key (etaf-md--read session :video-active))))
        :footnote-jump (lambda (label) (etaf-md--jump-footnote session label))
        :footnote-ref #'etaf-md--footnote-ref
        :footnote-back (lambda (label) (etaf-md--jump-footnote-back session label))
        :on-copy (lambda (_kind _text lines)
                   (message "已复制 %d 行代码" lines))
        ;; A picture costs a program, so only a session with a file may start
        ;; one: the finished render repaints that file's page.
        :render-code-block #'etaf-md--render-code-block
        :render-math #'etaf-md--render-math))

(defun etaf-md--base-env (session)
  "Return SESSION's cached width-free rendering environment."
  (let* ((inputs (etaf-md--base-env-inputs session))
         (cached (plist-get session :base-env-cache)))
    (if (equal (car cached) inputs)
        (cdr cached)
      (let ((env (etaf-md--build-base-env session)))
        (plist-put session :base-env-cache (cons inputs env))
        env))))

(defun etaf-md--build-env (session)
  "Build SESSION's width-aware rendering environment from its current inputs."
  (let* ((base (etaf-md--base-env session))
         (max-width (etaf-md--read session :width))
         (widths (etaf-md--page-widths session max-width)))
    (append (list :width (car widths)
                  :width-locked (etaf-md--read session :width-locked)
                  :figure-width (cdr widths))
            base)))

(defun etaf-md--env (session)
  "Return SESSION's rendering environment, reused until one of its inputs changes.
Width-sensitive blocks read this plist in their own render so tables and figures
follow measure changes; width-independent prose blocks read `etaf-md--base-env'
instead so window resizes never rebuild their VDOM subtrees."
  (let ((inputs (etaf-md--env-inputs session)))
    (let ((cached (plist-get session :env-cache)))
      (if (equal (car cached) inputs)
          (cdr cached)
        (let ((env (etaf-md--build-env session)))
          (plist-put session :env-cache (cons inputs env))
          env)))))

(defun etaf-md--card-env (session env scope)
  "Return ENV with video card identities and per-slot block state for SCOPE.
SCOPE names the pass, so two cards of one source stay distinct while a card
keeps its key across repaints of the same block.  Bridging `:block-state' and
`:set-block-state' to SCOPE's ref gives every block O(1) interactive toggles."
  (let ((occurrences (make-hash-table :test #'equal))
        (copy (copy-sequence env)))
    (setq copy
          (plist-put copy :video-card
                     (lambda (url)
                       (etaf-md--video-card
                        session url
                        (list scope (cl-incf (gethash url occurrences 0)))))))
    (setq copy
          (plist-put copy :block-state
                     (lambda (key &optional default)
                       (let* ((ref (etaf-md--block-state-ref session scope))
                              (alist (and (etaf-ref-p ref) (etaf-value ref)))
                              (cell (and alist (assoc (cons scope key) alist))))
                         (if cell (cdr cell) default)))))
    (setq copy
          (plist-put copy :set-block-state
                     (lambda (key value)
                       (let ((ref (etaf-md--block-state-ref session scope)))
                         (when (etaf-ref-p ref)
                           (let* ((alist (copy-alist (etaf-value ref)))
                                  (full (cons scope key))
                                  (cell (assoc full alist)))
                             (if cell (setcdr cell value)
                               (push (cons full value) alist))
                             (etaf-set-value ref alist))))
                       value)))
    copy))


(provide 'etaf-md-model)
;;; etaf-md-model.el ends here
