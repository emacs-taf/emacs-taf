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
(require 'etaf-md-theme)
(require 'etaf-md-views)

(declare-function etaf-md--child-syntax "etaf-md-node" (type))
(declare-function etaf-md-open "etaf-md-app" (&optional source))
(declare-function etaf-md--current-session "etaf-md-app" ())
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

(defun etaf-md--remote-url-p (url)
  "Return non-nil when URL names a remote resource.
A scheme longer than one letter is a URL, so `mailto:' and `tel:' reach the
browser; a single letter is a Windows drive, and `C:/notes' is a file."
  (string-match-p "\\`[a-zA-Z][a-zA-Z0-9+.-]+:" url))

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
                     :children (plist-get parsed :children)
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

(defun etaf-md--parse-container-body (name text flavor base)
  "Return NAME's children parsed from TEXT, which starts at BASE in the page."
  (if (eq (etaf-md--child-syntax (intern name)) 'markers)
      (etaf-md--parse-marker-children name text flavor base)
    (plist-get (etaf-md--parse
                (if (equal name "chat")
                    (etaf-md--chat-split-markers text)
                  text)
                flavor)
               :children)))

(defun etaf-md--parse-containers (text flavor)
  "Parse TEXT with FLAVOR, reading `:::name {attrs}' containers.
A container runs to the matching close, or to the end of the file for the last
one.  Plain stretches between containers go to the shared Markdown parser, and
their block ranges move to where the stretch sits in TEXT."
  (let ((offset 0) (plain-start 0) (container nil) (depth 0) (fence nil)
        (result nil) (template nil))
    (cl-flet ((flush (end)
                (when (< plain-start end)
                  (let* ((parsed (etaf-ui-markdown-parse
                                  (substring text plain-start end) flavor))
                         (blocks (plist-get parsed :children)))
                    (unless template (setq template parsed))
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

(defun etaf-md--parse (text flavor)
  "Parse TEXT with FLAVOR, reporting failures as `etaf-md-error'.
Container syntax is this package's own; everything else is shared with the
other document viewers, and this package keeps its own error type at its
boundary."
  (condition-case err
      (if (etaf-md--container-syntax-p text)
          (etaf-md--parse-containers text flavor)
        (etaf-ui-markdown-parse text flavor))
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

(defun etaf-md--rendered-block (block)
  "Return BLOCK without the source range it carries.
A block's `:begin' and `:end' move when text above it changes, while the
block displays the same content; comparing what a block displays keeps its
published entry reusable across such an edit."
  (if (or (plist-member block :begin) (plist-member block :end))
      (let ((copy (copy-sequence block)))
        (cl-remf copy :end)
        (cl-remf copy :begin)
        copy)
    block))

(defun etaf-md--gap-blocks (blocks text)
  "Return a blank block for each stretch of blank TEXT holds between BLOCKS.
A blank line is a line the document paints nothing on: the page would leave a
gap where the source holds a line, so a reader who presses RET to start a
paragraph has no row to type on and no cell to stand the caret on.  Painting
one empty row per blank line is what keeps a source offset and the cell it is
painted on in step, which is what lets the caret stay where the reader put it.

A block's range ends after its own final newline, so what the blocks leave
uncovered between them is blank lines and the lines the parser consumes
without a block -- a link reference definition, an abbreviation definition.
Only the blank lines paint, one row each, so the page still shows the file's
own spacing.  A file that ends with a newline ends on an empty line, so that
position gets a row standing for the text past its last character.  An empty
file gets that row."
  (let* ((size (length text))
         (blocks (or blocks nil))
         (front (etaf-md--front-matter-end text))
         (cursor 0)
         (result nil))
    (dolist (block blocks)
      (let ((begin (or (plist-get block :begin) size))
            (end (or (plist-get block :end) cursor)))
        (dolist (row (etaf-md--gap-rows
                      text (if (zerop cursor) (max cursor front) cursor) begin))
          (push row result))
        (setq cursor (max cursor end))))
    (cond ((< cursor size)
           (dolist (row (etaf-md--gap-rows text cursor size))
             (push row result)))
          ((or (= size 0) (eq (aref text (1- size)) ?\n))
           (push (list :type 'blank :begin size :end (1+ size) :lines 1) result)))
    (nreverse result)))

(defun etaf-md--front-matter-end (text)
  "Return the offset past TEXT's front matter, or 0 when it has none.
The parser reads a first line of `---' and a closing `---' or `...' as front
matter; the page shows that as its title, so it paints no rows for those
lines but still paints the blank lines that follow them."
  (let* ((lines (split-string text "\n"))
         (close (and (equal (string-trim (car lines)) "---")
                     (cl-position-if (lambda (line)
                                       (member (string-trim line) '("---" "...")))
                                     (cdr lines)))))
    (if close
        (1+ (length (mapconcat #'identity (cl-subseq lines 0 (+ close 2)) "\n")))
      0)))

(defun etaf-md--gap-rows (text begin end)
  "Return the rows TEXT's gap from BEGIN to END contributes.
A gap holds the lines the parser consumed without a block as well as blank
lines, so each blank line paints one empty row and a metadata line paints
nothing: the page keeps the file's own spacing instead of pulling the next
block up against the last one.  The front matter is the one stretch a caller
leaves out, because the page shows it as its title rather than as lines."
  (let ((rows nil)
        (position begin))
    (while (< position end)
      (let* ((newline (string-match "\n" text position))
             (line-end (if (and newline (< newline end)) newline end)))
        (when (string-blank-p (substring text position line-end))
          (push (list :type 'blank :begin position :end (1+ line-end) :lines 1)
                rows))
        (setq position (1+ line-end))))
    (nreverse rows)))

(defun etaf-md--paintable-blocks (blocks text)
  "Return BLOCKS in source order with their blank stretches filled in as rows.
Both lists are ordered by source position already, so one merge keeps the page
in the order the file holds."
  (let ((blanks (etaf-md--gap-blocks blocks text))
        (result nil))
    (while (or blocks blanks)
      (cond
       ((null blanks) (push (pop blocks) result))
       ((null blocks) (push (pop blanks) result))
       ((<= (or (plist-get (car blocks) :begin) 0)
            (or (plist-get (car blanks) :begin) 0))
        (push (pop blocks) result))
       (t (push (pop blanks) result))))
    (nreverse result)))

(defun etaf-md--block-entries (session document text published)
  "Return DOCUMENT's top-level blocks as keyed publishing entries.
An entry is `(:key KEY :block BLOCK :ref REF :view CALL)'.
KEY names the block's type and a digest of the block's own source, plus an
occurrence number so two identical blocks stay distinct.  A block's source,
not its position, is its identity: a block inserted or removed above it leaves
every unchanged block's key, and therefore its Component instance, alone.

The list also carries a blank block for every stretch of blank the file holds
between its blocks, because the page must paint a row a reader can type on
there; a blank row holds no source text, so its key is its place among them.

PUBLISHED maps the previous publish's keys to their entries.  A block whose
source and parsed content both survive keeps its published entry, CALL
included, so its instance keeps its Scope, Hosts and video handles, and the
list costs one comparison for it instead of a new call."
  (let ((counts (make-hash-table :test #'equal))
        (blank-index 0)
        (entries nil)
        (widths (etaf-md--page-widths
                 session (etaf-md--read session :width)))
        (env (when (fboundp 'etaf-md-typeset-attach)
               (etaf-md--env session))))
    (dolist (block (etaf-md--paintable-blocks
                    (plist-get document :children) text))
      (when env
        (setq block (etaf-md-typeset-attach block env)))
      (when (fboundp 'etaf-md-qrcode-attach)
        (setq block (etaf-md-qrcode-attach block)))
      (let* ((blank (eq (plist-get block :type) 'blank))
             (source (or (etaf-md--block-source block text) ""))
             ;; The picture is part of the block: it is drawn for one palette,
             ;; so a block whose picture changed is a different block and must
             ;; not reuse the entry that still holds the old drawing.
             ;; The palette is part of the block too: a block's view carries
             ;; the colours it was built with, so a palette change must build
             ;; it again rather than hand back the previous page's painting.
             (palette (format "%s|%s|%s"
                              (plist-get env :theme)
                              (plist-get env :background)
                              (plist-get env :ink)))
             (digest (unless blank
                       (concat (or (and (plist-get block :type)
                                        (symbol-name (plist-get block :type)))
                                   "block")
                               ":"
                               (secure-hash 'sha1
                                            (concat source "\0" palette "\0"
                                                    (or (plist-get block :picture) ""))))))
             ;; A blank row paints no source text, so the only thing that tells
             ;; one from another is where it sits among the blank rows.
             (digest (or digest (format "blank:%d" (cl-incf blank-index))))
             (occurrence (1+ (gethash digest counts 0)))
             (key (if (= 1 occurrence) digest (format "%s#%d" digest occurrence)))
             (ref (make-symbol etaf-md--block-ref-prefix))
             (old (and published (gethash key published)))
             (same (and old
                        (equal (etaf-md--rendered-block
                                (plist-get old :block))
                               (etaf-md--rendered-block block)))))
        (puthash digest occurrence counts)
        (push (cond
               ;; Only the call is retained: the block itself is the freshly
               ;; parsed one, so its source offsets follow an edit above it.
               (same (list :key key :block block
                           :ref (plist-get old :ref)
                           :view (plist-get old :view)))
               (t (list :key key :block block
                        :ref ref
                        :view (etaf-md--block-view
                               session key block ref widths))))
              entries)))
    (nreverse entries)))

(defun etaf-md--published-table (entries)
  "Return ENTRIES as a table from each entry's key to the entry."
  (let ((table (make-hash-table :test #'equal)))
    (dolist (entry entries) (puthash (plist-get entry :key) entry table))
    table))

(defun etaf-md--block-ref-table (entries)
  "Return ENTRIES as a table from each entry's box reference to its key."
  (let ((table (make-hash-table :test #'eq)))
    (dolist (entry entries)
      (when-let* ((ref (plist-get entry :ref)))
        (puthash ref (plist-get entry :key) table)))
    table))

(defun etaf-md--keyed-document (session document contents published)
  "Return (KEYED . TABLE) for DOCUMENT parsed from CONTENTS.
KEYED is DOCUMENT with its top-level blocks replaced by publishing entries;
TABLE maps each entry's key to the entry, to be published with the document
and passed back as PUBLISHED by the next parse."
  (let ((entries (etaf-md--block-entries
                  session document contents published)))
    (plist-put session :block-refs (etaf-md--block-ref-table entries))
    (cons (plist-put (copy-sequence document) :children entries)
          (etaf-md--published-table entries))))

(cl-defun etaf-md-create (&key file text title theme flavor)
  "Create a headless preview session and return it.
FILE names a markdown document to read; TEXT supplies the document directly
for buffers and tests.  Exactly one source is required.  TITLE overrides the
document title; THEME selects a palette and defaults to the value of
`etaf-md-theme' (`auto' derives the document colors from the active
frame's faces and paints no page background).  FLAVOR selects the markdown
dialect and defaults to `etaf-md-flavor': `gfm' enables the GitHub
extensions and front matter, `commonmark' parses the core only, and a feature
plist may toggle individual extensions."
  (let* ((file (and file (expand-file-name file)))
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
                        :dir (if file (file-name-directory file)
                               default-directory)
                        :document (etaf-ref nil :name 'etaf-md-document)
                        ;; Publishing entries of the last parse, keyed by block
                        ;; identity; an unchanged block keeps its entry.
                        :published nil
                        ;; Box reference to block key, so a command can find
                        ;; the block the point sits in.
                        :block-refs (make-hash-table :test #'eq)
                        ;; Display state of the interactive blocks, keyed by
                        ;; block identity.  It is a ref because a write must
                        ;; repaint the block that read it, not rebuild the page.
                        :block-state (etaf-ref nil :name 'etaf-md-block-state)
                        ;; The rendering environment shared by the blocks of
                        ;; one appearance.
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
                        :width (etaf-ref 92 :name 'etaf-md-width)
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

(defun etaf-md--fence-count (text from to)
  "Return how many code fence lines TEXT holds between FROM and TO."
  (let ((count 0)
        (start from))
    (while (let ((found (string-match etaf-md--fence-regexp text start)))
             (when (and found (< found to))
               (setq count (1+ count)
                     start (match-end 0))
               t)))
    count))

(defun etaf-md--splice-parse (session contents old-text old-document)
  "Return OLD-DOCUMENT updated for CONTENTS, or nil when it needs a whole parse.
The blocks before and after an edit are the same text at a shifted offset, so
only the blocks the edit could have touched are parsed again.  A whole parse
is needed when the edit reaches the front matter, and when it changes how many
code fences the region holds: a fence opens a block that can end outside the
region, and only the whole text tells where."
  (pcase-let* ((`(,old-start ,old-end ,_)
                (etaf-md--changed-span old-text contents))
               (delta (- (length contents) (length old-text)))
               (children (plist-get old-document :children))
               (count (length children)))
    (when (and children
               ;; A document parsed before blocks carried ranges, or by a
               ;; clause that forgot one, cannot be spliced: a whole parse
               ;; gives the block ranges back.
               (seq-every-p (lambda (block)
                              (and (integerp (plist-get block :begin))
                                   (integerp (plist-get block :end))))
                            children))
      (let* ((first (or (cl-position-if (lambda (block)
                                          (>= (or (plist-get block :end) 0) old-start))
                                        children)
                        count))
             (after (or (cl-position-if (lambda (block)
                                          (> (or (plist-get block :begin) 0) old-end))
                                        children)
                        count))
             (head (max 0 (- first etaf-md--reparse-neighbours)))
             (tail (min count (+ after etaf-md--reparse-neighbours)))
             (from (if (> head 0) (plist-get (nth (1- head) children) :end) 0))
             (to (if (< tail count) (plist-get (nth tail children) :begin)
                    (length old-text)))
             (to-new (+ to delta)))
        (when (and (<= from old-start)
                   (<= old-end to)
                   (> from 0)           ; front matter holds the title
                   (<= from to-new (length contents))
                   (cl-evenp (etaf-md--fence-count old-text from to))
                   (cl-evenp (etaf-md--fence-count contents from to-new)))
          (let* ((fragment (etaf-md--parse (substring contents from to-new)
                                                   (plist-get session :flavor)))
                 (middle (mapcar (lambda (block)
                                   (let ((copy (copy-sequence block)))
                                     (setq copy (plist-put copy :begin (+ from (plist-get block :begin))))
                                     (plist-put copy :end (+ from (plist-get block :end)))))
                                 (plist-get fragment :children)))
                 (suffix (mapcar (lambda (block)
                                   (let ((copy (copy-sequence block)))
                                     (setq copy (plist-put copy :begin (+ delta (plist-get block :begin))))
                                     (plist-put copy :end (+ delta (plist-get block :end)))))
                                 (nthcdr tail children)))
                 (spliced (append (seq-take children head) middle suffix)))
            (when (etaf-md--blocks-ordered-p spliced (length contents))
              (plist-put (copy-sequence old-document) :children spliced))))))))

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

(defun etaf-md--parse-changed (session contents)
  "Return the document CONTENTS describes, parsing only what changed.
A preview republishes after every keystroke and parsing is the largest part of
that cost, so the blocks the edit left alone keep the parse they already have."
  (let* ((flavor (etaf-md--flavor-for session contents))
         (cached (plist-get session :parsed))
         (document (cond ((null cached) (etaf-md--parse contents flavor))
                         ((equal (car cached) contents) (cdr cached))
                         (t (or (etaf-md--splice-parse
                                 session contents (car cached) (cdr cached))
                                (etaf-md--parse contents flavor))))))
    (plist-put session :parsed (cons contents document))
    document))

(defun etaf-md--install (session contents &optional title)
  "Parse CONTENTS and publish it as SESSION's document; return the document.
TITLE, when given, names the document instead of its own front matter or file.
The parser and the title fallback are shared by the first parse and every
refresh path: reading the file again, following a save, and following an edit
that was not saved.  Each top-level block keeps the publishing entry it had
while its source and parsed content survive, so one edited block repaints
itself and every other block keeps its instance."
  (let* ((keyed (etaf-md--keyed-document
                 session
                 (etaf-md--parse-changed session contents)
                 contents
                 (plist-get session :published)))
         (document (car keyed)))
    (etaf-batch
      (etaf-set-value (etaf-md--ref session :document) document)
      (etaf-set-value (etaf-md--ref session :title)
                      (or title
                          (plist-get document :title)
                          (and (plist-get session :file)
                               (file-name-nondirectory (plist-get session :file)))
                          "Markdown"))
      (etaf-set-value (etaf-md--ref session :error) nil))
    (plist-put session :features (plist-get document :features))
    (plist-put session :published (cdr keyed))
    (when (fboundp 'etaf-md-typeset-request)
      (etaf-md-typeset-request session))
    (when (fboundp 'etaf-md-qrcode-request)
      (etaf-md-qrcode-request session))
    document))

(defun etaf-md--publish (session contents)
  "Publish CONTENTS as SESSION's document and return SESSION."
  (etaf-md--install session contents)
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
    (plist-put session :live-text text)))

(defun etaf-md--republish (session)
  "Publish SESSION's document again for its current palette and return it.
A picture block carries the file drawn for the palette it was published with,
so a palette change has to publish the document even though its text is the
same.  The parse is cached, so this costs the block keys, not the text, and the
publish starts the pictures the new palette needs."
  (when (plist-get session :buffer)
    (etaf-md--install session (etaf-md--session-text session)))
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

(defun etaf-md-cycle-theme (session)
  "Switch SESSION to the next palette and return its name."
  (let* ((themes (mapcar #'car etaf-md-themes))
         (current (etaf-md--read session :theme))
         (tail (cdr (memq current themes))))
    (etaf-md-set-theme session (or (car tail) (car themes)))
    (etaf-md--read session :theme)))

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
column fills the window."
  (let ((width (etaf-md--clamp-width
                (+ (etaf-md--read session :width) delta))))
    (etaf-md--write session :width width)
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
display spaces the renderer uses for centering) may precede the match."
  (let ((found nil))
    (while (and (not found) (search-forward text nil t))
      (let ((line-start (line-beginning-position)))
        (when (string-blank-p
               (buffer-substring-no-properties line-start (match-beginning 0)))
          (setq found (match-beginning 0)))))
    found))

(defun etaf-md--heading-positions (session)
  "Return SESSION's heading buffer positions as a list of (INDEX . POSITION).
The scan walks the outline in document order, so repeated heading texts map to
successive occurrences."
  (let ((buffer (plist-get session :buffer))
        (outline (etaf-md-outline session)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (save-excursion
          (goto-char (point-min))
          (cl-loop for entry in outline
                   for index from 0
                   for position = (etaf-md--heading-match-forward (nth 1 entry))
                   when position collect (cons index position)))))))

(defun etaf-md-locate (session index)
  "Move point to SESSION's outline heading INDEX and recenter.
Return the position, or nil when the heading is not visible."
  (let* ((buffer (plist-get session :buffer))
         (position (cdr (assq index (etaf-md--heading-positions session)))))
    (when (and position (buffer-live-p buffer))
      (with-selected-window (or (get-buffer-window buffer t) (selected-window))
        (with-current-buffer buffer
          (goto-char position)
          (recenter 0)))
      position)))

(defun etaf-md--adjacent-heading (session direction)
  "Move point to the next outline heading in DIRECTION.
DIRECTION is 1 for forward and -1 for backward.  Return the position moved to,
or nil when there is no heading left in that direction."
  (let* ((positions (etaf-md--heading-positions session))
         (buffer (plist-get session :buffer))
         (point-now (if (buffer-live-p buffer)
                        (with-current-buffer buffer (point))
                      0))
         (target (if (> direction 0)
                     (cl-find-if (lambda (cell) (> (cdr cell) point-now)) positions)
                   (car (last (cl-remove-if-not
                               (lambda (cell) (< (cdr cell) point-now))
                               positions))))))
    (when target
      (etaf-md-locate session (car target)))))

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
An in-document anchor jumps to the matching heading, a URL with a scheme goes
to the browser, and a local path opens in Emacs: a markdown document opens as
its preview, anything else as a file.  A `#fragment' after a local path selects
that heading in the opened preview."
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
         (t (message "File not found: %s" path))))))))

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

(defun etaf-md--jump-footnote (session label)
  "Move point to footnote LABEL in SESSION's buffer."
  (let ((buffer (plist-get session :buffer)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (goto-char (point-min))
        (if (search-forward (format "[%s]" (or (plist-get
                                                (cl-find label
                                                         (plist-get
                                                          (etaf-md--read
                                                           session :document)
                                                          :footnotes)
                                                         :key (lambda (footnote)
                                                                (plist-get footnote :label))
                                                         :test #'equal)
                                                :number)
                                               label))
                             nil t)
            (progn (beginning-of-line) (recenter 0))
          (message "Footnote %s not found" label))))))

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

(defun etaf-md--env-inputs (session)
  "Return the values SESSION's rendering environment is built from.
Every value the environment prints is read here, once.  Reading them is what
makes the shared environment follow a palette, width or theme change, so a new
input belongs both in this list and in `etaf-md--build-env'.  A
face-derived palette also reads the appearance, which is what makes a block
re-render after a theme switch instead of keeping the faces it first read."
  (let* ((source (etaf-md--read session :theme-source))
         (face-derived (not (eq source 'palette)))
         (frame (etaf-md--display-frame session)))
    (list :theme (etaf-md--read session :theme)
          :source source
          :width (etaf-md--read session :width)
          :columns (cdr (etaf-md--page-widths
                            session (etaf-md--read session :width)))
          :background (etaf-md--page-background session)
          :surface (and face-derived (etaf-md--frame-surface frame))
          :appearance (and face-derived (etaf-appearance))
          :dir (plist-get session :dir)
          :features (plist-get session :features))))

(declare-function etaf-md--render-code-block "etaf-md-typeset" (block env))
(declare-function etaf-md--render-math "etaf-md-typeset" (block env))
(declare-function etaf-md-typeset-request "etaf-md-typeset" (session))
(declare-function etaf-md-typeset-attach "etaf-md-typeset" (block env))

(defun etaf-md--build-env (session)
  "Build SESSION's rendering environment from its current inputs."
  (list :theme (etaf-md--read session :theme)
        :palette (etaf-md--session-palette session)
        :width (etaf-md--read session :width)
        :figure-width (cdr (etaf-md--page-widths
                              session (etaf-md--read session :width)))
        :background (etaf-md--page-background session)
        :dir (plist-get session :dir)
        :features (plist-get session :features)
        :open-url (lambda (url) (etaf-md--open-url session url))
        :open-link (lambda (url) (etaf-md--open-url session url))
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
        ;; A picture costs a program, so only a session with a file may start
        ;; one: the finished render repaints that file's page.
        :render-code-block #'etaf-md--render-code-block
        :render-math #'etaf-md--render-math))

(defun etaf-md--env (session)
  "Return SESSION's rendering environment, reused until one of its inputs changes.
A block Component reads this plist in its own render, so its colors and
measure follow the session; a publish that changes no input hands every
retained block the same environment object, which keeps its props unchanged."
  (let ((inputs (etaf-md--env-inputs session)))
    (let ((cached (plist-get session :env-cache)))
      (if (equal (car cached) inputs)
          (cdr cached)
        (let ((env (etaf-md--build-env session)))
          (plist-put session :env-cache (cons inputs env))
          env)))))

(defun etaf-md--card-env (session env scope)
  "Return ENV with video card identities for one render pass of SCOPE.
SCOPE names the pass, so two cards of one source stay distinct while a card
keeps its key across repaints of the same block.  ENV is shared between
publishes, so the occurrence counter cannot live in it."
  (let ((occurrences (make-hash-table :test #'equal)))
    (plist-put (copy-sequence env) :video-card
               (lambda (url)
                 (etaf-md--video-card
                  session url
                  (list scope (cl-incf (gethash url occurrences 0))))))))


(provide 'etaf-md-model)
;;; etaf-md-model.el ends here
