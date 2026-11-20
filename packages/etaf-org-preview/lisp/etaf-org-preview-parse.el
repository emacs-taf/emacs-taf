;;; etaf-org-preview-parse.el --- Org document parsing -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; Pure Org parsing for the previewer: text in, document tree out.  Nothing
;; here reads a file, opens a buffer, looks at a frame or depends on Org being
;; loaded.  The tree carries no presentation facts; the views decide every
;; color, size and spacing.
;;
;; A document is a plist.  `:sections' holds the headline tree as
;; `etaf-org-preview-section' structs, `:preamble' the blocks before the first
;; headline, and the remaining keys are the document settings the parser
;; understands.  A block is a plist whose `:type' names the element; an inline
;; is a plist whose `:type' names the run.
;;
;; The parser never signals on malformed input.  An unclosed block ends at the
;; end of its container, an unknown construct keeps its source text, and every
;; degradation is counted with `:degraded' so the reader can be told.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'etaf-org-preview-entities)

(define-error 'etaf-org-preview-parse-error "Org document parse error")

;;; ---------------------------------------------------------------------------
;;; Context and records
;;; ---------------------------------------------------------------------------

(cl-defstruct (etaf-org-preview-footnotes
               (:constructor etaf-org-preview--make-footnotes))
  "Footnote registry shared by every context derived from one document.
Copies of a parsing context share this object, so a reference inside a list
item and a definition in another section still count in one sequence."
  (counter 0)
  (order nil)
  (entries (make-hash-table :test #'equal)))

(cl-defstruct (etaf-org-preview-ctx (:constructor etaf-org-preview--make-ctx))
  (lines [])
  (end 0)
  (source-file nil)
  (title nil)
  (subtitle nil)
  (author nil)
  (date nil)
  (email nil)
  (language nil)
  (keywords nil)
  (description nil)
  (filetags nil)
  (options nil)
  (startup 'content)
  (todo-keywords nil)
  (priorities nil)
  (macros nil)
  (link-abbrevs nil)
  (degraded (make-hash-table :test #'equal))
  (footnotes (etaf-org-preview--make-footnotes))
  (targets (make-hash-table :test #'equal))
  (current-section nil))

(cl-defstruct (etaf-org-preview-section
               (:constructor etaf-org-preview--section-create))
  (id nil)
  (level 1)
  (todo nil)
  (priority nil)
  (title nil)
  (title-plain "")
  (title-inlines nil)
  (cookie nil)
  (tags nil)
  (planning nil)
  (properties nil)
  (logbook nil)
  (logbook-text nil)
  (archived nil)
  (commented nil)
  (children nil)
  (body nil))

(defconst etaf-org-preview--image-extensions
  '("png" "jpg" "jpeg" "gif" "svg" "webp" "bmp" "tif" "tiff")
  "Image file extensions the previewer renders as pictures.")

(defconst etaf-org-preview--video-extensions
  '("mp4" "mov" "m4v" "webm" "mkv" "avi")
  "Video file extensions the previewer renders as media cards.")

(defconst etaf-org-preview--default-todo-keywords
  '(("TODO" . active) ("DONE" . done))
  "Keyword set used when neither the file nor Org defines one.")

;;; ---------------------------------------------------------------------------
;;; Line helpers
;;; ---------------------------------------------------------------------------

(defun etaf-org-preview--split-lines (text)
  "Return TEXT as a vector of lines, with CRLF normalized."
  (let ((text (if (string-prefix-p "\uFEFF" text) (substring text 3) text)))
    (setq text (replace-regexp-in-string "\r\n?" "\n" text))
    (vconcat (split-string text "\n"))))

(defun etaf-org-preview--indent-columns (string)
  "Return the column width of STRING's leading whitespace."
  (let ((column 0)
        (index 0)
        (length (length string)))
    (while (and (< index length) (memq (aref string index) '(?\s ?\t)))
      (setq column (if (eq (aref string index) ?\t)
                       (* 8 (1+ (/ column 8)))
                     (1+ column)))
      (cl-incf index))
    column))

(defun etaf-org-preview--strip-columns (string columns)
  "Return STRING without its first COLUMNS columns of whitespace."
  (let ((column 0)
        (index 0)
        (length (length string)))
    (while (and (< index length) (< column columns)
                (memq (aref string index) '(?\s ?\t)))
      (setq column (if (eq (aref string index) ?\t)
                       (* 8 (1+ (/ column 8)))
                     (1+ column)))
      (cl-incf index))
    (substring string index)))

(defun etaf-org-preview--blank-line-p (line)
  "Return non-nil when LINE holds only whitespace."
  (string-blank-p line))

(defun etaf-org-preview--degrade (ctx type)
  "Count one degradation of TYPE in CTX."
  (puthash type (1+ (gethash type (etaf-org-preview-ctx-degraded ctx) 0))
           (etaf-org-preview-ctx-degraded ctx)))

(defun etaf-org-preview--cjk-char-p (char)
  "Return non-nil when CHAR belongs to a CJK script."
  (and (integerp char)
       (or (and (>= char #x2E80) (<= char #x9FFF))
           (and (>= char #xF900) (<= char #xFAFF))
           (and (>= char #xFF00) (<= char #xFFEF))
           (and (>= char #x20000) (<= char #x3FFFF)))))

(defun etaf-org-preview--join-lines (lines)
  "Join paragraph LINES the way Org exports them.
A line ending in a hard break keeps a newline; adjacent CJK characters join
without a space, so a Chinese paragraph does not gain gaps between its words."
  (let ((result nil)
        (first t))
    (dolist (line lines)
      (unless first
        (let* ((previous (car result))
               (last-char (and (> (length previous) 0)
                               (aref previous (1- (length previous)))))
               (first-char (and (> (length line) 0) (aref line 0))))
          (cond
           ((and last-char (= last-char ?\\))
            (setcar result (concat (substring previous 0 -2) "\n")))
           ((and (etaf-org-preview--cjk-char-p last-char)
                 (etaf-org-preview--cjk-char-p first-char))
            nil)
           (t (setcar result (concat previous " "))))))
      (if first
          (progn (push line result) (setq first nil))
        (setcar result (concat (car result) line))))
    (nreverse result)))

(defun etaf-org-preview--paragraph-text (lines)
  "Return the joined text of paragraph LINES."
  (car (etaf-org-preview--join-lines lines)))

;;; ---------------------------------------------------------------------------
;;; Settings
;;; ---------------------------------------------------------------------------

(defconst etaf-org-preview--keyword-line-regexp
  "^[ \t]*#\\+\\([A-Za-z_][A-Za-z0-9_-]*\\):[ \t]*\\(.*\\)$"
  "A `#+KEY: value' line.")

(defun etaf-org-preview--parse-value-list (value)
  "Return VALUE split on whitespace and commas."
  (split-string value "[ \t,]+" t))

(defun etaf-org-preview--parse-todo-keywords (value)
  "Return the keyword alist described by the TODO VALUE.
Keywords before `|' are active, those after it are done.  A shortcut in
parentheses is discarded."
  (let ((words (etaf-org-preview--parse-value-list value))
        (done nil)
        (result nil))
    (dolist (word words)
      (cond
       ((equal word "|") (setq done t))
       (t (let ((name (if (string-match "\\`\\([^()]+\\)(" word)
                          (match-string 1 word)
                        word)))
            (push (cons name (if done 'done 'active)) result)))))
    (nreverse result)))

(defun etaf-org-preview--parse-priorities (value)
  "Return (HIGHEST LOWEST DEFAULT) from the PRIORITIES VALUE."
  (let ((words (etaf-org-preview--parse-value-list value)))
    (list (and (nth 0 words) (aref (nth 0 words) 0))
          (and (nth 1 words) (aref (nth 1 words) 0))
          (and (nth 2 words) (aref (nth 2 words) 0)))))

(defun etaf-org-preview--parse-options (value)
  "Return the option plist described by VALUE.
Unknown keys are ignored; the returned plist always carries the defaults."
  (let ((options (list :toc 2 :todo t :tags t :priority t :subsup t
                       :entities t :drawers nil :headline-levels 8)))
    (dolist (word (etaf-org-preview--parse-value-list value))
      (when (string-match "\\`\\([^:]+\\):\\(.*\\)\\'" word)
        (let ((key (downcase (match-string 1 word)))
              (raw (match-string 2 word)))
          (pcase key
            ("toc" (setq options (plist-put options :toc
                                             (if (equal raw "nil") nil
                                               (string-to-number raw)))))
            ("todo" (setq options (plist-put options :todo (not (equal raw "nil")))))
            ("tags" (setq options (plist-put options :tags (not (equal raw "nil")))))
            ("pri" (setq options (plist-put options :priority (not (equal raw "nil")))))
            ("^" (setq options (plist-put options :subsup (not (equal raw "nil")))))
            ("_" (setq options (plist-put options :subsup (not (equal raw "nil")))))
            ("-" (setq options (plist-put options :entities (not (equal raw "nil")))))
            ("h" (setq options (plist-put options :headline-levels
                                           (if (equal raw "nil") 8
                                             (string-to-number raw)))))
            ("d" (setq options (plist-put options :drawers (not (equal raw "nil")))))
            (_ nil)))))
    options))

(defun etaf-org-preview--parse-startup (value)
  "Return the startup fold state named by VALUE, or nil."
  (let ((words (mapcar #'downcase (etaf-org-preview--parse-value-list value))))
    (cond
     ((member "overview" words) 'overview)
     ((cl-intersection words '("content" "showall" "showeverything") :test #'equal)
      'content)
     ((member "folded" words) 'folded)
     ((member "nofold" words) 'content)
     (t nil))))

(defun etaf-org-preview--scan-settings (ctx)
  "Read the file-level keywords of CTX into the context."
  (let ((lines (etaf-org-preview-ctx-lines ctx))
        (end (etaf-org-preview-ctx-end ctx)))
    (dotimes (index end)
      (let ((line (aref lines index)))
        (when (string-match etaf-org-preview--keyword-line-regexp line)
          (let* ((key (upcase (match-string 1 line)))
                 (value (string-trim (match-string 2 line))))
            (pcase key
              ("TITLE" (setf (etaf-org-preview-ctx-title ctx) value))
              ("SUBTITLE" (setf (etaf-org-preview-ctx-subtitle ctx) value))
              ("AUTHOR" (setf (etaf-org-preview-ctx-author ctx) value))
              ("DATE" (setf (etaf-org-preview-ctx-date ctx) value))
              ("EMAIL" (setf (etaf-org-preview-ctx-email ctx) value))
              ("LANGUAGE" (setf (etaf-org-preview-ctx-language ctx) value))
              ("KEYWORDS" (setf (etaf-org-preview-ctx-keywords ctx)
                                (etaf-org-preview--parse-value-list value)))
              ("DESCRIPTION" (setf (etaf-org-preview-ctx-description ctx) value))
              ("FILETAGS" (setf (etaf-org-preview-ctx-filetags ctx)
                                (etaf-org-preview--parse-tag-string value)))
              ("TODO" "SEQ_TODO" "TYP_TODO"
               (setf (etaf-org-preview-ctx-todo-keywords ctx)
                     (etaf-org-preview--parse-todo-keywords value)))
              ("PRIORITIES" (setf (etaf-org-preview-ctx-priorities ctx)
                                  (etaf-org-preview--parse-priorities value)))
              ("OPTIONS" (setf (etaf-org-preview-ctx-options ctx)
                               (etaf-org-preview--parse-options value)))
              ("STARTUP" (let ((startup (etaf-org-preview--parse-startup value)))
                           (when startup
                             (setf (etaf-org-preview-ctx-startup ctx) startup))))
              ("MACRO" (when (string-match "\\`\\([^ \t]+\\)[ \t]+\\(.*\\)\\'" value)
                         (push (cons (match-string 1 value) (match-string 2 value))
                               (etaf-org-preview-ctx-macros ctx))))
              ("LINK" (when (string-match "\\`\\([^ \t]+\\)[ \t]+\\(.*\\)\\'" value)
                        (push (cons (match-string 1 value) (match-string 2 value))
                              (etaf-org-preview-ctx-link-abbrevs ctx))))
              (_ nil))))))))

(defun etaf-org-preview--parse-tag-string (value)
  "Return the tag list in VALUE, which may be `:a:b:' or a bare list."
  (let ((trimmed (string-trim value)))
    (if (string-match-p ":" trimmed)
        (split-string trimmed ":" t)
      (etaf-org-preview--parse-value-list trimmed))))

;;; ---------------------------------------------------------------------------
;;; Inline parsing
;;; ---------------------------------------------------------------------------

(defconst etaf-org-preview--inline-candidate
  (concat "\\[\\[\\|\\[fn:\\|\\[cite\\|\\[@\\|<[0-9]\\|\\[[0-9]"
          "\\|<\\{2,3\\}\\|{{{\\|@@"
          "\\|\\(?:src\\|call\\)_[A-Za-z0-9_+-]+"
          "\\|\\(?:https?\\|mailto\\):[^ \t\n]+"
          "\\|\\\\"
          "\\|[*_/+=~^$]")
  "Regexp matching the first character of any inline construct.")

(defconst etaf-org-preview--alnum-regexp "[[:alnum:]]"
  "Characters that may not bound an emphasis run.")

(defun etaf-org-preview--boundary-ok-p (string position)
  "Return non-nil when an emphasis may start or end at POSITION in STRING.
The neighbouring character, if any, must not be alphanumeric, and an emphasis
may not end on whitespace."
  (let ((char (and (>= position 0) (< position (length string))
                   (aref string position))))
    (not (and char (string-match-p etaf-org-preview--alnum-regexp
                                   (char-to-string char))))))

(defun etaf-org-preview--text-node (text)
  "Return a text inline node for TEXT."
  (list :type 'text :text text))

(defun etaf-org-preview--inline-at-emphasis (ctx string start)
  "Parse an emphasis construct of STRING at START.
Return (NODE . NEXT) or nil.  CTX supplies the entity and macro tables."
  (let* ((marker (aref string start))
         (verbatim (memq marker '(?= ?~)))
         (end (length string))
         (search (1+ start))
         (found nil))
    (when (and (etaf-org-preview--boundary-ok-p string (1- start))
               (< search end))
      (while (and (not found) (string-match
                               (regexp-quote (char-to-string marker))
                               string search))
        (let ((close (match-beginning 0)))
          (if (and (> close (1+ start))
                   (not (memq (aref string (1- close)) '(?\s ?\t ?\n)))
                   (etaf-org-preview--boundary-ok-p string (1+ close)))
              (setq found close)
            (setq search (1+ close)))))
      (when found
        (let ((content (substring string (1+ start) found)))
          (cons
           (if verbatim
               (list :type 'code :verbatim (eq marker ?=) :text content)
             (list :type 'emphasis
                   :marker (char-to-string marker)
                   :children (etaf-org-preview--parse-inlines ctx content)))
           (1+ found)))))))

(defun etaf-org-preview--substitute-map (string table)
  "Return STRING with every character translated through TABLE, or nil.
A character without an entry makes the whole translation fail, so the caller
keeps the literal marker instead of showing half a subscript."
  (let ((result nil)
        (ok t)
        (index 0)
        (length (length string)))
    (while (and ok (< index length))
      (let ((mapped (cdr (assq (aref string index) table))))
        (if mapped
            (push mapped result)
          (setq ok nil)))
      (cl-incf index))
    (when (and ok (not (string-empty-p string)))
      (apply #'concat (nreverse result)))))

(defun etaf-org-preview--inline-at-subsup (_ctx string start)
  "Parse a subscript or superscript of STRING at START.
Return (NODE . NEXT) or nil."
  (let* ((marker (aref string start))
         (table (if (eq marker ?_) etaf-org-preview-subscripts
                  etaf-org-preview-superscripts))
         (end (length string)))
    (cond
     ((and (< (1+ start) end) (eq (aref string (1+ start)) ?{))
      (let ((close (string-match "}" string (+ start 2))))
        (when close
          (let ((mapped (etaf-org-preview--substitute-map
                         (substring string (+ start 2) close) table)))
            (when mapped
              (cons (list :type 'subsup :kind (if (eq marker ?_) 'sub 'sup)
                          :text mapped)
                    (1+ close)))))))
     ((and (< (1+ start) end))
      (let* ((tail (substring string (1+ start)))
             (index 0))
        (while (and (< index (length tail))
                    (cdr (assq (aref tail index) table)))
          (cl-incf index))
        (when (> index 0)
          (let ((mapped (etaf-org-preview--substitute-map
                         (substring tail 0 index) table)))
            (when mapped
              (cons (list :type 'subsup :kind (if (eq marker ?_) 'sub 'sup)
                          :text mapped)
                    (+ start 1 index)))))))
     (t nil))))

(defun etaf-org-preview--inline-at-entity (_ctx string start)
  "Parse an entity or LaTeX escape of STRING at START.
Return (NODE . NEXT) or nil."
  (let ((end (length string)))
    (cond
     ;; Hard line break.
     ((and (< (1+ start) end))
      (cond
       ((and (eq (aref string (1+ start)) ?\\)
             (or (= (+ start 2) end)
                 (memq (aref string (+ start 2)) '(?\s ?\t ?\n))))
        (cons (list :type 'break :hard t) (+ start 2)))
       ((eq (aref string (1+ start)) ?\()
        (let ((close (string-match "\\\\)" string (+ start 2))))
          (when close
            (cons (list :type 'latex-fragment :display nil
                        :text (etaf-org-preview--tex-to-unicode
                               (substring string (+ start 2) close)))
                  (+ close 2)))))
       ((eq (aref string (1+ start)) ?\[)
        (let ((close (string-match "\\\\]" string (+ start 2))))
          (when close
            (cons (list :type 'latex-fragment :display t
                        :text (etaf-org-preview--tex-to-unicode
                               (substring string (+ start 2) close)))
                  (+ close 2)))))
       (t
        (let ((rest (substring string (1+ start))))
          (cond
           ((string-match "\\`\\([A-Za-z][A-Za-z0-9]*\\)\\(?:{}\\)?" rest)
            (let* ((name (match-string 1 rest))
                   (utf8 (cdr (assoc name etaf-org-preview-entities))))
              (when utf8
                (cons (list :type 'entity :name name :text utf8)
                      (+ start 1 (match-end 0))))))
           ;; Escaped character: `\*' renders the character itself.
           ((string-match "\\`\\([][{}()*+/_=~^$<>&#%!-]\\)" rest)
            (cons (etaf-org-preview--text-node (match-string 1 rest))
                  (+ start 1 (match-end 0))))
           (t nil))))))
     (t nil))))

(defun etaf-org-preview--tex-to-unicode (text)
  "Replace known TeX command names in TEXT with their Unicode spelling."
  (let ((case-fold-search nil))
    (replace-regexp-in-string
     "\\\\\\([A-Za-z]+\\)"
     (lambda (match)
       (save-match-data
         (let ((name (match-string 1 match)))
           (or (cdr (assoc name etaf-org-preview-entities)) match))))
     text t t)))

(defun etaf-org-preview--link-kind (target)
  "Return the semantic kind of link TARGET."
  (cond
   ((string-prefix-p "http://" target) 'url)
   ((string-prefix-p "https://" target) 'url)
   ((string-prefix-p "mailto:" target) 'mail)
   ((string-prefix-p "file:" target) 'file)
   ((string-prefix-p "id:" target) 'id)
   ((string-prefix-p "attachment:" target) 'attachment)
   ((string-prefix-p "elisp:" target) 'elisp)
   ((string-prefix-p "shell:" target) 'shell)
   ((string-prefix-p "doi:" target) 'url)
   ((string-prefix-p "*" target) 'headline)
   ((string-prefix-p "#" target) 'custom-id)
   ((string-match-p "\\`[A-Za-z][A-Za-z0-9+.-]*:" target) 'other)
   (t 'file)))

(defun etaf-org-preview--link-target (target ctx)
  "Expand link abbreviation TARGET through CTX, or return it unchanged."
  (if (string-match "\\`\\([A-Za-z][A-Za-z0-9+.-]*\\)::?\\(.*\\)\\'" target)
      (let* ((scheme (match-string 1 target))
             (abbrev (cdr (assoc scheme (etaf-org-preview-ctx-link-abbrevs ctx)))))
        (if abbrev
            (replace-regexp-in-string "%s" (match-string 2 target) abbrev t t)
          target))
    target))

(defun etaf-org-preview--inline-at-link (ctx string start)
  "Parse an Org link of STRING at START.
Return (NODE . NEXT) or nil."
  (when (and (< (+ start 1) (length string))
             (eq (aref string (+ start 1)) ?\[))
    (let ((close (string-match "\\]\\]" string (+ start 2))))
      (when close
        (let* ((inner (substring string (+ start 2) close))
               (split (string-match "\\]\\[" inner))
               (target (if split (substring inner 0 split) inner))
               (desc (if split (substring inner (+ split 2)) nil))
               (target (etaf-org-preview--link-target target ctx)))
          (cons (list :type 'link
                      :target target
                      :kind (etaf-org-preview--link-kind target)
                      :desc (if desc
                                (etaf-org-preview--parse-inlines ctx desc)
                              nil))
                (+ close 2)))))))

(defun etaf-org-preview--footnote-register (ctx label inlines)
  "Register footnote LABEL with INLINES in CTX and return its number."
  (let* ((registry (etaf-org-preview-ctx-footnotes ctx))
         (entries (etaf-org-preview-footnotes-entries registry))
         (existing (gethash label entries)))
    (if existing
        (progn
          (when inlines
            (plist-put existing :inlines inlines))
          (plist-get existing :number))
      (let ((number (cl-incf (etaf-org-preview-footnotes-counter registry))))
        (puthash label (list :label label :number number :inlines inlines)
                 entries)
        (push label (etaf-org-preview-footnotes-order registry))
        number))))

(defun etaf-org-preview--inline-at-footnote (ctx string start)
  "Parse a footnote reference or definition of STRING at START.
Return (NODE . NEXT) or nil."
  (when (string-prefix-p "[fn:" (substring string start (min (length string)
                                                             (+ start 4))))
    (let* ((close (string-match "\\]" string (+ start 4)))
           (body (and close (substring string (+ start 4) close))))
      (when body
        (let* ((colon (string-match ":" body))
               (label (if colon (substring body 0 colon) body))
               (definition (and colon (substring body (1+ colon))))
               (label (if (string-empty-p label)
                          (format "anon-%d"
                                  (1+ (etaf-org-preview-footnotes-counter
                                       (etaf-org-preview-ctx-footnotes ctx))))
                        label))
               (number (etaf-org-preview--footnote-register
                        ctx label
                        (and definition
                             (etaf-org-preview--parse-inlines ctx definition)))))
          (cons (list :type 'footnote-ref :label label :number number)
                (1+ close)))))))

(defun etaf-org-preview--inline-at-citation (_ctx string start)
  "Parse a citation of STRING at START.
Return (NODE . NEXT) or nil."
  (when (eq (aref string start) ?\[)
    (let ((close (string-match "\\]" string (1+ start))))
      (when close
        (let ((body (substring string (1+ start) close)))
          (when (and (string-match "@" body)
                     (or (string-prefix-p "@" body)
                         (string-prefix-p "cite" body)))
            (let (keys)
              (with-temp-buffer
                (insert body)
                (goto-char (point-min))
                (while (re-search-forward "@\\([A-Za-z0-9_:.#$-]+\\)" nil t)
                  (push (match-string 1) keys)))
              (cons (list :type 'citation
                          :keys (nreverse keys)
                          :raw (concat "[" body "]"))
                    (1+ close)))))))))

(defun etaf-org-preview--parse-timestamp (string start)
  "Parse the timestamp text of STRING at START.
Return (PLIST . NEXT) or nil."
  (let* ((active (eq (aref string start) ?<))
         (close (and (< (1+ start) (length string))
                     (string-match (if active ">" "\\]") string (1+ start)))))
    (when close
      (let ((body (substring string (1+ start) close)))
        (when (string-match
               "\\`\\([0-9]\\{4\\}\\)-\\([0-9]\\{2\\}\\)-\\([0-9]\\{2\\}\\)\\(?:[ \t]+\\([^ \t0-9+-]+\\)\\)?\\(?:[ \t]+\\([0-9]\\{2\\}\\):\\([0-9]\\{2\\}\\)\\(?:-\\([0-9]\\{2\\}\\):\\([0-9]\\{2\\}\\)\\)?[ \t]*\\([+-][0-9]+[hdwmy]\\)?\\)?"
               body)
          (cons (list :type 'timestamp
                      :active active
                      :raw (concat (if active "<" "[") body (if active ">" "]"))
                      :start (list :y (string-to-number (match-string 1 body))
                                   :m (string-to-number (match-string 2 body))
                                   :d (string-to-number (match-string 3 body))
                                   :day (match-string 4 body)
                                   :hh (and (match-string 5 body)
                                            (string-to-number (match-string 5 body)))
                                   :mm (and (match-string 6 body)
                                            (string-to-number (match-string 6 body)))
                                   :end-hh (and (match-string 7 body)
                                                (string-to-number (match-string 7 body)))
                                   :end-mm (and (match-string 8 body)
                                                (string-to-number (match-string 8 body))))
                      :repeater (match-string 9 body))
                (1+ close)))))))

(defun etaf-org-preview--inline-at-timestamp (_ctx string start)
  "Parse a timestamp of STRING at START.
Return (NODE . NEXT) or nil."
  (and (memq (aref string start) '(?< ?\[))
       (< (1+ start) (length string))
       (>= (aref string (1+ start)) ?0)
       (<= (aref string (1+ start)) ?9)
       (etaf-org-preview--parse-timestamp string start)))

(defun etaf-org-preview--inline-at-target (ctx string start)
  "Parse a target of STRING at START.
Return (NODE . NEXT) or nil."
  (cond
   ((and (string-prefix-p "<<<" (substring string start (min (length string)
                                                             (+ start 3))))
         (string-match ">>>" string (+ start 3)))
    (let* ((close (match-beginning 0))
           (name (substring string (+ start 3) close)))
      (puthash name (etaf-org-preview-ctx-current-section ctx)
               (etaf-org-preview-ctx-targets ctx))
      (cons (list :type 'target :name name :radio t) (+ close 3))))
   ((and (string-prefix-p "<<" (substring string start (min (length string)
                                                            (+ start 2))))
         (string-match ">>" string (+ start 2)))
    (let* ((close (match-beginning 0))
           (name (substring string (+ start 2) close)))
      (puthash name (etaf-org-preview-ctx-current-section ctx)
               (etaf-org-preview-ctx-targets ctx))
      (cons (list :type 'target :name name) (+ close 2))))
   (t nil)))

(defun etaf-org-preview--inline-at-macro (ctx string start)
  "Parse a macro call of STRING at START.
Return (NODE . NEXT) or nil."
  (when (string-prefix-p "{{{" (substring string start (min (length string)
                                                            (+ start 3))))
    (when (string-match "}}}" string (+ start 3))
      (let* ((close (match-beginning 0))
             (body (substring string (+ start 3) close))
             (name (if (string-match "\\`\\([^()]+\\)" body)
                       (match-string 1 body)
                     body))
             (args (if (string-match "(\\(.*\\))\\'" body)
                       (split-string (match-string 1 body) "," t)
                     nil))
             (template (cdr (assoc name (etaf-org-preview-ctx-macros ctx)))))
        (cond
         (template
          (let ((expanded (etaf-org-preview--expand-macro ctx template args)))
            (cons (etaf-org-preview--text-node expanded) (+ close 3))))
         ((member name '("title" "author" "date" "email" "input-file"))
          (cons (etaf-org-preview--text-node
                 (or (pcase name
                       ("title" (etaf-org-preview-ctx-title ctx))
                       ("author" (etaf-org-preview-ctx-author ctx))
                       ("date" (etaf-org-preview-ctx-date ctx))
                       ("email" (etaf-org-preview-ctx-email ctx))
                       ("input-file" (etaf-org-preview-ctx-source-file ctx)))
                     ""))
                (+ close 3)))
         (t
          (etaf-org-preview--degrade ctx 'macro)
          (cons (etaf-org-preview--text-node (concat "{{{" body "}}}"))
                (+ close 3))))))))

(defun etaf-org-preview--expand-macro (_ctx template args)
  "Expand TEMPLATE in CTX with ARGS, following Org's `$1' convention."
  (let ((expanded template)
        (index 1))
    (dolist (arg args)
      (setq expanded (replace-regexp-in-string (format "\\$%d" index) arg
                                               expanded t t))
      (cl-incf index))
    (setq expanded (replace-regexp-in-string "\\$0" template expanded t t))
    expanded))

(defun etaf-org-preview--inline-at-inline-src (_ctx string start)
  "Parse an inline source block of STRING at START.
Return (NODE . NEXT) or nil."
  (let ((rest (substring string start)))
    (when (string-match "\\`\\(src\\|call\\)_\\([A-Za-z0-9_+-]+\\)\\(?:\\[[^]]*\\]\\)?{" rest)
      (let* ((source-p (equal (match-string 1 rest) "src"))
             (language (downcase (match-string 2 rest)))
             (name-end (+ start (match-end 0)))
             ;; Reading the close brace overwrites the match data, so the
             ;; prefix and language are captured before this search.
             (close (string-match "}" string name-end)))
        (when close
          (cons (if source-p
                    (list :type 'inline-src
                          :lang language
                          :text (substring string name-end close))
                  (list :type 'inline-src
                        :lang nil
                        :text (substring string start close)))
                (1+ close)))))))

(defun etaf-org-preview--inline-at-snippet (_ctx string start)
  "Parse an export snippet of STRING at START.
The snippet keeps its BACKEND and its payload TEXT separately: a preview shows
the payload and never interprets it."
  (when (string-prefix-p "@@" (substring string start (min (length string)
                                                           (+ start 2))))
    (when (string-match "@@" string (+ start 2))
      (let* ((close (match-beginning 0))
             (body (substring string (+ start 2) close))
             (colon (string-match ":" body)))
        (cons (list :type 'export-snippet
                    :backend (and colon (substring body 0 colon))
                    :text (if colon (substring body (1+ colon)) body))
              (+ close 2))))))

(defun etaf-org-preview--inline-at-url (_ctx string start)
  "Parse a bare URL of STRING at START.
Return (NODE . NEXT) or nil."
  (let ((rest (substring string start)))
    (when (string-match "\\`\\(?:https?\\|mailto\\):[^ \t\n<>]+" rest)
      (let* ((raw (match-string 0 rest))
             (url (replace-regexp-in-string "[.,;:!?)\"']+\\'" "" raw)))
        (cons (list :type 'link :target url
                    :kind (if (string-prefix-p "mailto:" url) 'mail 'url)
                    :desc (list (etaf-org-preview--text-node
                                 (if (string-prefix-p "mailto:" url)
                                     (substring url 7)
                                   url))))
              (+ start (length url)))))))

(defun etaf-org-preview--inline-at-cookie (_ctx string start)
  "Parse a statistics cookie or priority of STRING at START.
Return (NODE . NEXT) or nil."
  (when (eq (aref string start) ?\[)
    (let ((close (string-match "\\]" string (1+ start))))
      (when close
        (let ((body (substring string (1+ start) close)))
          (when (string-match "\\`\\(?:[0-9]*/[0-9]*\\|[0-9]+%\\)\\'" body)
            (cons (list :type 'statistics-cookie :text (concat "[" body "]"))
                  (1+ close))))))))

(defun etaf-org-preview--inline-at-math (_ctx string start)
  "Parse an inline `$...$' fragment of STRING at START.
Return (NODE . NEXT) or nil."
  (when (and (eq (aref string start) ?$)
             (< (+ start 1) (length string))
             (not (eq (aref string (+ start 1)) ?$)))
    (let ((close (string-match "[^\\]\\$" string (1+ start))))
      (when close
        (cons (list :type 'latex-fragment :display nil
                    :text (etaf-org-preview--tex-to-unicode
                           (substring string (1+ start) (1+ close))))
              (+ close 2))))))

(defun etaf-org-preview--parse-inline-at (ctx string start)
  "Parse the inline construct of STRING at START.
Return (NODE . NEXT) or nil when START begins no construct."
  (or (etaf-org-preview--inline-at-link ctx string start)
      (etaf-org-preview--inline-at-footnote ctx string start)
      (etaf-org-preview--inline-at-citation ctx string start)
      (etaf-org-preview--inline-at-timestamp ctx string start)
      (etaf-org-preview--inline-at-target ctx string start)
      (etaf-org-preview--inline-at-cookie ctx string start)
      (etaf-org-preview--inline-at-macro ctx string start)
      (etaf-org-preview--inline-at-snippet ctx string start)
      (etaf-org-preview--inline-at-inline-src ctx string start)
      (and (eq (aref string start) ?\\)
           (etaf-org-preview--inline-at-entity ctx string start))
      (and (eq (aref string start) ?$)
           (etaf-org-preview--inline-at-math ctx string start))
      (and (memq (aref string start) '(?* ?/ ?_ ?+ ?= ?~))
           (etaf-org-preview--inline-at-emphasis ctx string start))
      (and (memq (aref string start) '(?_ ?^))
           (etaf-org-preview--inline-at-subsup ctx string start))
      (etaf-org-preview--inline-at-url ctx string start)))

(defun etaf-org-preview--parse-inlines (ctx string)
  "Parse STRING into inline nodes for CTX."
  (let ((position 0)
        (length (length string))
        (nodes nil))
    (while (< position length)
      (if (string-match etaf-org-preview--inline-candidate string position)
          (let ((start (match-beginning 0)))
            (when (> start position)
              (push (etaf-org-preview--text-node (substring string position start))
                    nodes))
            (let ((result (etaf-org-preview--parse-inline-at ctx string start)))
              (if result
                  (progn
                    (push (car result) nodes)
                    (setq position (cdr result)))
                (push (etaf-org-preview--text-node
                       (substring string start (1+ start)))
                      nodes)
                (setq position (1+ start)))))
        (push (etaf-org-preview--text-node (substring string position))
              nodes)
        (setq position length)))
    (nreverse nodes)))

(defun etaf-org-preview-inline-plain-text (inlines)
  "Return INLINES as plain text, dropping markers and handlers."
  (let ((parts nil))
    (dolist (node inlines)
      (let ((type (plist-get node :type)))
        (push
         (pcase type
           ((or 'text 'code 'inline-src 'entity 'subsup 'statistics-cookie)
            (or (plist-get node :text) ""))
           ('emphasis (etaf-org-preview-inline-plain-text
                       (plist-get node :children)))
           ('link (if (plist-get node :desc)
                      (etaf-org-preview-inline-plain-text
                       (plist-get node :desc))
                    (or (plist-get node :target) "")))
           ('timestamp (or (plist-get node :raw) ""))
           ('footnote-ref (format "[fn:%s]" (plist-get node :label)))
           ('citation (or (plist-get node :raw) ""))
           ('latex-fragment (or (plist-get node :text) ""))
           ('break " ")
           (_ ""))
         parts)))
    (apply #'concat (nreverse parts))))

;;; ---------------------------------------------------------------------------
;;; Headlines and planning
;;; ---------------------------------------------------------------------------

(defconst etaf-org-preview--headline-regexp
  "\\`\\(\\*+\\)\\(?:[ \t]+\\|\\'\\)\\(.*\\)\\'"
  "A headline line, with its stars and the rest of the line.")

(defun etaf-org-preview--headline-line-p (line)
  "Return non-nil when LINE starts a headline."
  (string-match-p "\\`\\*+[ \t]" line))

(defun etaf-org-preview--headline-level (line)
  "Return LINE's headline level."
  (if (string-match "\\`\\(\\*+\\)" line) (length (match-string 1 line)) 0))

(defun etaf-org-preview--parse-headline-title (ctx rest)
  "Split REST into the headline fields for CTX.
Return a plist with `:todo', `:priority', `:title', `:tags', `:cookie',
`:commented' and `:title-inlines'."
  (let ((commented nil)
        (todo nil)
        (priority nil)
        (tags nil)
        (cookie nil)
        (case-fold-search t))
    (setq rest (string-trim rest))
    (when (string-match "\\`COMMENT[ \t]+\\(.*\\)\\'" rest)
      (setq commented t
            rest (match-string 1 rest)))
    (let ((keywords (or (etaf-org-preview-ctx-todo-keywords ctx)
                        etaf-org-preview--default-todo-keywords)))
      (dolist (keyword keywords)
        (when (and (not todo)
                   (string-match (format "\\`%s[ \t]+\\(.*\\)\\'"
                                         (regexp-quote (car keyword)))
                                 rest))
          (setq todo (car keyword)
                rest (match-string 1 rest)))))
    (when (string-match "\\`\\[#\\([A-Za-z]\\)\\][ \t]*\\(.*\\)\\'" rest)
      (setq priority (upcase (match-string 1 rest))
            rest (match-string 2 rest)))
    (when (string-match "\\(?:[ \t]\\|\\`\\)\\(:[A-Za-z0-9_@#%:]+:\\)[ \t]*\\'" rest)
      (let ((tag-text (match-string 1 rest))
            (tag-start (match-beginning 0)))
        (setq tags (etaf-org-preview--parse-tag-string tag-text)
              rest (string-trim (substring rest 0 tag-start)))))
    (when (string-match "\\(\\[[0-9]*/[0-9]*\\]\\|\\[[0-9]+%\\]\\)[ \t]*\\'" rest)
      (setq cookie (match-string 1 rest)
            rest (string-trim (substring rest 0 (match-beginning 0)))))
    (list :todo todo
          :priority priority
          :tags tags
          :cookie cookie
          :commented commented
          :title rest
          :title-inlines (etaf-org-preview--parse-inlines ctx rest))))

(defun etaf-org-preview--planning-line-p (line)
  "Return non-nil when LINE carries one or more planning keywords."
  (string-match-p "\\`[ \t]*\\(?:SCHEDULED\\|DEADLINE\\|CLOSED\\):" line))

(defun etaf-org-preview--parse-planning (_ctx line)
  "Return the planning plist of LINE for CTX."
  (let ((planning nil))
    (with-temp-buffer
      (insert line)
      (goto-char (point-min))
      (while (re-search-forward
              "\\(SCHEDULED\\|DEADLINE\\|CLOSED\\):[ \t]*\\(<[^>]+>\\|\\[[^]]+\\]\\)"
              nil t)
        (let* ((key (downcase (match-string 1)))
               (stamp (etaf-org-preview--parse-timestamp
                       (match-string 2) 0)))
          (when stamp
            (setq planning (plist-put planning (intern (concat ":" key))
                                      (car stamp)))))))
    planning))

(defun etaf-org-preview--parse-headline (ctx index)
  "Return a section for the headline at INDEX in CTX."
  (let* ((line (aref (etaf-org-preview-ctx-lines ctx) index))
         (level (etaf-org-preview--headline-level line))
         (rest (if (string-match etaf-org-preview--headline-regexp line)
                   (match-string 2 line)
                 ""))
         (fields (etaf-org-preview--parse-headline-title ctx rest))
         (section (etaf-org-preview--section-create
                   :level level
                   :todo (plist-get fields :todo)
                   :priority (plist-get fields :priority)
                   :title (plist-get fields :title)
                   :title-plain (etaf-org-preview-inline-plain-text
                                 (plist-get fields :title-inlines))
                   :title-inlines (plist-get fields :title-inlines)
                   :cookie (plist-get fields :cookie)
                   :tags (plist-get fields :tags)
                   :commented (plist-get fields :commented))))
    section))

;;; ---------------------------------------------------------------------------
;;; Blocks
;;; ---------------------------------------------------------------------------

(defun etaf-org-preview--block-stop-p (_ctx line)
  "Return non-nil when LINE cannot continue a paragraph in CTX."
  (or (etaf-org-preview--blank-line-p line)
      (etaf-org-preview--headline-line-p line)
      (string-match-p "\\`[ \t]*#\\+" line)
      (string-match-p "\\`[ \t]*|" line)
      (string-match-p "\\`[ \t]*:[ \t]" line)
      (string-match-p "\\`[ \t]*:\\'" line)
      (string-match-p "\\`[ \t]*:[A-Za-z0-9_-]+:[ \t]*\\'" line)
      (string-match-p "\\`[ \t]*\\(?:[-+*]\\|[0-9]+[.)]\\|[A-Za-z][.)]\\)[ \t]+" line)
      (string-match-p "\\`[ \t]*-\\{5,\\}[ \t]*\\'" line)
      (string-match-p "\\`[ \t]*\\\\begin{" line)
      (string-match-p "\\`[ \t]*\\(?:\\\\\\[\\|\\$\\$\\)" line)
      (string-match-p "\\`[ \t]*#[ \t]" line)))

(defun etaf-org-preview--parse-blocks (ctx)
  "Parse CTX's lines into a list of block plists."
  (let ((index 0)
        (end (etaf-org-preview-ctx-end ctx))
        (blocks nil))
    (while (< index end)
      (let ((line (aref (etaf-org-preview-ctx-lines ctx) index)))
        (cond
         ((etaf-org-preview--blank-line-p line)
          (cl-incf index))
         (t
          (let ((result (etaf-org-preview--read-block ctx index)))
            (when (car result)
              (push (car result) blocks))
            (setq index (max (cdr result) (1+ index))))))))
    (nreverse blocks)))

(defun etaf-org-preview--read-block (ctx index)
  "Read the block at INDEX in CTX.
Return (BLOCK . NEXT-INDEX)."
  (let ((line (aref (etaf-org-preview-ctx-lines ctx) index)))
    (cond
     ((string-match-p "\\`[ \t]*#\\+" line)
      (etaf-org-preview--read-directive ctx index))
     ((string-match-p "\\`[ \t]*#[ \t]" line)
      (etaf-org-preview--read-comment ctx index))
     ((string-match-p "\\`[ \t]*:[A-Za-z0-9_-]+:[ \t]*\\'" line)
      (etaf-org-preview--read-drawer ctx index))
     ((string-match-p "\\`[ \t]*|" line)
      (etaf-org-preview--read-table ctx index))
     ((string-match-p "\\`[ \t]*:\\(?:[ \t]\\|\\'\\)" line)
      (etaf-org-preview--read-fixed-width ctx index))
     ((etaf-org-preview--list-item-p line)
      (etaf-org-preview--read-list ctx index))
     ((string-match-p "\\`[ \t]*-\\{5,\\}[ \t]*\\'" line)
      (cons (list :type 'horizontal-rule) (1+ index)))
     ((string-match-p "\\`[ \t]*\\\\begin{" line)
      (etaf-org-preview--read-latex-environment ctx index))
     ((string-match-p "\\`[ \t]*\\(?:\\\\\\[\\|\\$\\$\\)" line)
      (etaf-org-preview--read-display-math ctx index))
     (t
      (etaf-org-preview--read-paragraph ctx index)))))

(defun etaf-org-preview--read-paragraph (ctx index)
  "Read a paragraph at INDEX in CTX.
A paragraph that is only a footnote definition becomes that definition."
  (let* ((lines (etaf-org-preview-ctx-lines ctx))
         (end (etaf-org-preview-ctx-end ctx))
         (cursor index)
         (collected nil)
         (first-line (aref lines index)))
    (if (string-match "\\`[ \t]*\\[fn:\\([^]]+\\)\\][ \t]*\\(.*\\)\\'" first-line)
        (let ((label (match-string 1 first-line))
              (rest (match-string 2 first-line)))
          (setq cursor (1+ cursor))
          (while (and (< cursor end)
                      (not (etaf-org-preview--block-stop-p
                            ctx (aref lines cursor))))
            (push (aref lines cursor) collected)
            (cl-incf cursor))
          (let ((text (etaf-org-preview--paragraph-text
                       (cons rest (nreverse collected)))))
            (etaf-org-preview--footnote-register
             ctx label (etaf-org-preview--parse-inlines ctx text))
            (cons (list :type 'footnote-def :label label) cursor)))
      (while (and (< cursor end)
                  (not (etaf-org-preview--block-stop-p
                        ctx (aref lines cursor))))
        (push (aref lines cursor) collected)
        (cl-incf cursor))
      (let ((text (etaf-org-preview--paragraph-text (nreverse collected))))
        (cons (list :type 'paragraph
                    :text text
                    :inlines (etaf-org-preview--parse-inlines ctx text))
              cursor)))))

(defun etaf-org-preview--read-comment (ctx index)
  "Read consecutive comment lines starting at INDEX in CTX."
  (let* ((lines (etaf-org-preview-ctx-lines ctx))
         (end (etaf-org-preview-ctx-end ctx))
         (cursor index)
         (text nil))
    (while (and (< cursor end)
                (string-match-p "\\`[ \t]*#[ \t]" (aref lines cursor)))
      (push (string-trim-left (aref lines cursor) "[ \t]*#[ \t]?") text)
      (cl-incf cursor))
    (cons (list :type 'comment :text (string-join (nreverse text) "\n"))
          cursor)))

(defun etaf-org-preview--read-fixed-width (ctx index)
  "Read fixed-width lines starting at INDEX in CTX."
  (let* ((lines (etaf-org-preview-ctx-lines ctx))
         (end (etaf-org-preview-ctx-end ctx))
         (cursor index)
         (text nil))
    (while (and (< cursor end)
                (string-match "\\`[ \t]*:\\([ \t]\\(.*\\)\\|\\'\\)"
                              (aref lines cursor)))
      (push (or (match-string 2 (aref lines cursor)) "") text)
      (cl-incf cursor))
    (cons (list :type 'fixed-width :text (string-join (nreverse text) "\n"))
          cursor)))

(defun etaf-org-preview--read-drawer (ctx index)
  "Read a drawer starting at INDEX in CTX."
  (let* ((lines (etaf-org-preview-ctx-lines ctx))
         (end (etaf-org-preview-ctx-end ctx))
         (line (aref lines index))
         (name (progn (string-match "\\`[ \t]*:\\([A-Za-z0-9_-]+\\):" line)
                      (upcase (match-string 1 line))))
         (cursor (1+ index))
         (content nil)
         (closed nil))
    (while (and (< cursor end) (not closed))
      (let ((current (aref lines cursor)))
        (if (string-match-p "\\`[ \t]*:END:[ \t]*\\'" current)
            (setq closed t)
          (push current content)))
      (cl-incf cursor))
    (setq content (nreverse content))
    (when (and (not closed) content)
      (etaf-org-preview--degrade ctx 'drawer))
    (cond
     ((equal name "PROPERTIES")
      (cons (list :type 'property-drawer :properties
                  (etaf-org-preview--parse-properties content))
            cursor))
     ((equal name "LOGBOOK")
      (cons (list :type 'drawer :name name
                  :text (string-join content "\n")
                  :clock (etaf-org-preview--parse-clock-lines content))
            cursor))
     (t
      (cons (list :type 'drawer :name name
                  :text (string-join content "\n"))
            cursor)))))

(defun etaf-org-preview--parse-properties (lines)
  "Return property pairs parsed from drawer LINES."
  (let ((properties nil)
        (last-key nil))
    (dolist (line lines)
      (cond
       ((string-match "\\`[ \t]*:\\([^: \t]+\\):[ \t]*\\(.*\\)\\'" line)
        (let ((key (match-string 1 line))
              (value (match-string 2 line)))
          (if (string-suffix-p "+" key)
              (let ((base (substring key 0 -1)))
                (setcdr (assoc base properties) (concat (cdr (assoc base properties))
                                                        (concat "\n" value))))
            (push (cons key value) properties)
            (setq last-key key))))
       ((and last-key (string-match "\\`[ \t]+\\(.*\\)\\'" line))
        (setcdr (assoc last-key properties)
                (concat (cdr (assoc last-key properties)) " " (match-string 1 line))))
       (t nil)))
    (nreverse properties)))

(defun etaf-org-preview--parse-clock-lines (lines)
  "Return CLOCK entries parsed from LOGBOOK LINES."
  (let ((entries nil))
    (dolist (line lines)
      (when (string-match
             "\\`[ \t]*CLOCK:[ \t]*\\(\\[[^]]+\\]\\)--\\(\\[[^]]+\\]\\)[ \t]*\\(?:=>[ \t]*\\([0-9]+\\):\\([0-9]+\\)\\)?"
             line)
        (push (list :start (match-string 1 line)
                    :end (match-string 2 line)
                    :minutes (and (match-string 3 line)
                                  (+ (* 60 (string-to-number (match-string 3 line)))
                                     (string-to-number (match-string 4 line)))))
              entries)))
    (nreverse entries)))

(defun etaf-org-preview--list-item-p (line)
  "Return non-nil when LINE starts a plain-list item."
  (or (string-match-p "\\`[ \t]+[-+*][ \t]+" line)
      (string-match-p "\\`[-+]?[ \t]*\\(?:[0-9]+[.)]\\|[A-Za-z][.)]\\)[ \t]+" line)
      (string-match-p "\\`[-+][ \t]+" line)))

(defun etaf-org-preview--item-match (line)
  "Return (INDENT MARKER CONTENT COLUMN) for a list item LINE, or nil.
A `*' at column zero is a headline, not a bullet."
  (when (string-match
         "\\`\\([ \t]*\\)\\([-+*]\\|[0-9]+[.)]\\|[A-Za-z][.)]\\)[ \t]+\\(.*\\)\\'"
         line)
    (let* ((indent (etaf-org-preview--indent-columns line))
           (marker (match-string 2 line))
           (content (match-string 3 line))
           (column (etaf-org-preview--indent-columns
                    (concat (match-string 1 line) marker))))
      (unless (and (equal marker "*") (zerop indent))
        (list indent marker content column)))))

(defun etaf-org-preview--read-list (ctx index)
  "Read a plain list starting at INDEX in CTX."
  (let* ((lines (etaf-org-preview-ctx-lines ctx))
         (end (etaf-org-preview-ctx-end ctx))
         (first (etaf-org-preview--item-match (aref lines index)))
         (base (nth 0 first))
         (ordered (string-match-p "[0-9A-Za-z][.)]\\'" (nth 1 first)))
         (style (and ordered
                     (aref (nth 1 first) (1- (length (nth 1 first))))))
         (items nil)
         (cursor index))
    (while (and (< cursor end)
                (let* ((line (aref lines cursor))
                       (match (etaf-org-preview--item-match line)))
                  (cond
                   ;; A same-level item continues this list; a deeper item is
                   ;; part of the current item and is consumed by the item's
                   ;; own continuation lines.
                   ((and match (= (nth 0 match) base))
                    (and (equal (and (string-match-p "[0-9A-Za-z][.)]\\'"
                                                     (nth 1 match))
                                     t)
                                (and ordered t))
                         (or (not ordered)
                             (eq (aref (nth 1 match)
                                       (1- (length (nth 1 match))))
                                 style))))
                   (match t)
                   ((etaf-org-preview--blank-line-p line)
                    (let ((next cursor))
                      (while (and (< next end)
                                  (etaf-org-preview--blank-line-p (aref lines next)))
                        (cl-incf next))
                      (and (< next end)
                           (let ((next-line (aref lines next)))
                             (or (etaf-org-preview--item-match next-line)
                                 (> (etaf-org-preview--indent-columns next-line) base))))))
                   (t nil))))
      (let* ((match (etaf-org-preview--item-match (aref lines cursor)))
             (marker (nth 1 match))
             (content (nth 2 match))
             (column (nth 3 match))
             (item-lines (list content)))
        (cl-incf cursor)
        (while (and (< cursor end)
                    (let ((line (aref lines cursor)))
                      (or (etaf-org-preview--blank-line-p line)
                          (> (etaf-org-preview--indent-columns line) base)))
                    (not (and (etaf-org-preview--item-match (aref lines cursor))
                              (= (nth 0 (etaf-org-preview--item-match
                                         (aref lines cursor)))
                                 base))))
          (let ((line (aref lines cursor)))
            (push (if (etaf-org-preview--blank-line-p line)
                      ""
                    (etaf-org-preview--strip-columns line column))
                  item-lines))
          (cl-incf cursor))
        (setq item-lines (nreverse item-lines))
        (push (etaf-org-preview--list-item
               ctx marker item-lines ordered
               (and ordered
                    (string-match "[0-9]+" marker)
                    (string-to-number (match-string 0 marker))))
              items)))
    (cons (list :type 'list
                :ordered ordered
                :items (nreverse items))
          cursor)))

(defun etaf-org-preview--list-item (ctx marker lines ordered number)
  "Return a list item for MARKER, LINES and NUMBER in CTX.
The first line may carry a counter, a checkbox, or a description separator."
  (let* ((first (car lines))
         (rest (cdr lines))
         (counter nil)
         (checkbox nil)
         (term nil))
    (when (string-match "\\`\\[@\\([0-9]+\\)\\][ \t]*" first)
      (setq counter (match-string 1 first)
            first (substring first (match-end 0))))
    (cond
     ((string-match "\\`\\[\\([ xX-]\\)\\][ \t]*" first)
      (setq checkbox (pcase (match-string 1 first)
                       (" " 'off)
                       ("-" 'partial)
                       (_ 'on))
            first (substring first (match-end 0))))
     (t nil))
    (when (string-match "\\`\\(.*?\\)[ \t]+::[ \t]*\\(.*\\)\\'" first)
      (setq term (etaf-org-preview--parse-inlines ctx (match-string 1 first))
            first (match-string 2 first)))
    (let* ((sub-lines (cons first rest))
           (sub-ctx (copy-etaf-org-preview-ctx ctx)))
      (setf (etaf-org-preview-ctx-lines sub-ctx) (vconcat sub-lines)
            (etaf-org-preview-ctx-end sub-ctx) (length sub-lines))
      (list :type 'list-item
            :marker marker
            :ordered ordered
            :number number
            :counter counter
            :checkbox checkbox
            :term term
            :blocks (etaf-org-preview--parse-blocks sub-ctx)))))

(defun etaf-org-preview--table-separator-p (line)
  "Return non-nil when LINE is an Org table rule."
  (and (string-match-p "\\`[ \t]*|" line)
       (let ((rest (string-trim-left (substring line (1+ (string-match "|" line))))))
         (and (string-prefix-p "-" rest)
              (string-match-p "\\`[-+:| \t]+\\'" rest)))))

(defun etaf-org-preview--table-cells (line)
  "Return the raw cells of a table LINE."
  (let* ((trimmed (string-trim line))
         (body (if (string-prefix-p "|" trimmed) (substring trimmed 1) trimmed))
         (body (if (string-suffix-p "|" body) (substring body 0 -1) body)))
    (mapcar #'string-trim (split-string body "|"))))

(defun etaf-org-preview--table-cookie (cell)
  "Return (ALIGN . WIDTH) described by table CELL."
  (let ((align nil)
        (width nil))
    (when (string-match "<\\([lcr]\\)?\\([0-9]*\\)>" cell)
      (setq align (pcase (match-string 1 cell)
                    ("l" 'left) ("c" 'center) ("r" 'right) (_ nil))
            width (and (not (string-empty-p (match-string 2 cell)))
                       (string-to-number (match-string 2 cell)))))
    (cons align width)))

(defun etaf-org-preview--read-table (ctx index)
  "Read an Org table starting at INDEX in CTX."
  (let* ((lines (etaf-org-preview-ctx-lines ctx))
         (end (etaf-org-preview-ctx-end ctx))
         (cursor index)
         (rows nil)
         (rules nil)
         (aligns nil)
         (widths nil)
         (header-count 0)
         (seen-rule nil)
         (tblfm nil))
    (while (and (< cursor end)
                (string-match-p "\\`[ \t]*|" (aref lines cursor)))
      (let* ((line (aref lines cursor))
             (separator (etaf-org-preview--table-separator-p line))
             (cells (etaf-org-preview--table-cells line))
             (special (and (not separator)
                           (cl-every (lambda (cell)
                                       (string-match-p "\\`<\\(?:[lcr]?[0-9]*\\)>\\'"
                                                       cell))
                                     cells))))
        (cond
         (special
          (setq aligns (mapcar (lambda (cell)
                                 (car (etaf-org-preview--table-cookie cell)))
                               cells)
                widths (mapcar (lambda (cell)
                                 (cdr (etaf-org-preview--table-cookie cell)))
                               cells)))
         (separator
          (unless aligns
            (setq aligns (mapcar (lambda (cell)
                                   (car (etaf-org-preview--table-cookie cell)))
                                 cells)
                  widths (mapcar (lambda (cell)
                                   (cdr (etaf-org-preview--table-cookie cell)))
                                 cells)))
          (unless seen-rule
            (setq header-count (length rows)))
          (setq seen-rule t)
          (push (length rows) rules))
         (t
          (push (list :type 'table-row
                      :cells (mapcar
                              (lambda (cell)
                                (list :raw cell
                                      :inlines (etaf-org-preview--parse-inlines ctx cell)))
                              cells))
                rows)))
        (cl-incf cursor)))
    (when (and (< cursor end)
               (string-match "\\`[ \t]*#\\+TBLFM:[ \t]*\\(.*\\)\\'"
                             (aref lines cursor)))
      (setq tblfm (match-string 1 (aref lines cursor)))
      (cl-incf cursor))
    (let* ((rows (nreverse rows))
           (columns (apply #'max 1 (mapcar (lambda (row)
                                             (length (plist-get row :cells)))
                                           rows)))
           (rows (mapcar (lambda (row) (plist-put row :columns columns)) rows)))
      (cons (list :type 'table
                  :rows rows
                  :columns columns
                  :rules (nreverse rules)
                  :aligns aligns
                  :widths widths
                  :header-count header-count
                  :tblfm tblfm)
            cursor))))

(defun etaf-org-preview--read-latex-environment (ctx index)
  "Read a LaTeX environment starting at INDEX in CTX."
  (let* ((lines (etaf-org-preview-ctx-lines ctx))
         (end (etaf-org-preview-ctx-end ctx))
         (line (aref lines index))
         (name (progn (string-match "\\\\begin{\\([^}]+\\)}" line)
                      (match-string 1 line)))
         (cursor index)
         (text nil)
         (closed nil))
    (while (and (< cursor end) (not closed))
      (let ((current (aref lines cursor)))
        (push current text)
        (when (string-match-p (format "\\\\end{%s}" (regexp-quote name)) current)
          (setq closed t)))
      (cl-incf cursor))
    (cons (list :type 'latex-environment :name name
                :text (string-join (nreverse text) "\n"))
          cursor)))

(defun etaf-org-preview--read-display-math (ctx index)
  "Read display math starting at INDEX in CTX.
The opening and closing delimiters are dropped from the text.  A formula that
closes on its opening line is read as one line."
  (let* ((lines (etaf-org-preview-ctx-lines ctx))
         (end (etaf-org-preview-ctx-end ctx))
         (trimmed (string-trim (aref lines index)))
         (double (string-prefix-p "$$" trimmed))
         (opener (if double "$$" "\\["))
         (closer (if double "$$" "\\]"))
         (first-body (string-trim (substring trimmed (length opener))))
         (cursor (1+ index))
         (text nil)
         (closed nil))
    (cond
     ((string-match (concat (regexp-quote closer) "[ \t]*\\'") first-body)
      (push (string-trim (substring first-body 0 (match-beginning 0))) text)
      (setq closed t))
     (t
      (unless (string-empty-p first-body)
        (push first-body text))
      (while (and (< cursor end) (not closed))
        (let ((current (aref lines cursor)))
          (if (string-match-p (concat "\\`[ \t]*" (regexp-quote closer))
                              current)
              (setq closed t)
            (push current text)))
        (cl-incf cursor))))
    (cons (list :type 'display-math
                :text (etaf-org-preview--tex-to-unicode
                       (string-join (nreverse text) "\n")))
          cursor)))

;;; ---------------------------------------------------------------------------
;;; Directives and blocks
;;; ---------------------------------------------------------------------------

(defconst etaf-org-preview--begin-regexp
  "\\`[ \t]*#\\+\\(BEGIN\\|begin\\)_\\([A-Za-z0-9_]+\\)\\(?:[ \t]+\\(.*\\)\\)?[ \t]*\\'"
  "A `#+BEGIN_NAME' line.")

(defun etaf-org-preview--find-block-end (ctx index name)
  "Return the index of the END line of block NAME after INDEX in CTX."
  (let ((lines (etaf-org-preview-ctx-lines ctx))
        (end (etaf-org-preview-ctx-end ctx))
        (cursor (1+ index))
        (regexp (format "\\`[ \t]*#\\+END_%s[ \t]*\\'" (regexp-quote name)))
        (found nil))
    (while (and (< cursor end) (not found))
      (when (string-match-p regexp (aref lines cursor))
        (setq found cursor))
      (cl-incf cursor))
    found))

(defun etaf-org-preview--block-content (ctx index end-index begin-indent)
  "Return block content lines between INDEX and END-INDEX in CTX.
Each line loses up to BEGIN-INDENT columns, so an indented block keeps its
relative shape without its list indentation."
  (let* ((lines (etaf-org-preview-ctx-lines ctx))
         (result nil))
    (cl-loop for cursor from (1+ index) below end-index
             do (push (etaf-org-preview--strip-columns (aref lines cursor)
                                                       begin-indent)
                      result))
    (nreverse result)))

(defun etaf-org-preview--read-directive (ctx index)
  "Read a `#+` directive at INDEX in CTX."
  (let* ((lines (etaf-org-preview-ctx-lines ctx))
         (end (etaf-org-preview-ctx-end ctx))
         (line (aref lines index)))
    (cond
     ;; Container blocks: #+BEGIN_NAME ... #+END_NAME.
     ((string-match etaf-org-preview--begin-regexp line)
      (etaf-org-preview--read-container ctx index
                                        (upcase (match-string 2 line))
                                        (match-string 3 line)))
     ;; Dynamic block: #+BEGIN: name args ... #+END:
     ((string-match "\\`[ \t]*#\\+BEGIN:[ \t]*\\(.*\\)\\'" line)
      (etaf-org-preview--degrade ctx 'dynamic-block)
      (let* ((args (match-string 1 line))
             (cursor (1+ index))
             (closed nil)
             (content nil))
        (while (and (< cursor end) (not closed))
          (if (string-match-p "\\`[ \t]*#\\+END:[ \t]*\\'" (aref lines cursor))
              (setq closed t)
            (push (aref lines cursor) content))
          (cl-incf cursor))
        (cons (list :type 'dynamic-block
                    :name (car (split-string args))
                    :args args
                    :text (string-join (nreverse content) "\n"))
              cursor)))
     ((string-match "\\`[ \t]*#\\+\\(TBLFM\\|tblfm\\):" line)
      (cons (list :type 'keyword :key "TBLFM" :value (match-string 1 line)
                  :hidden t)
            (1+ index)))
     ((string-match (concat "\\`[ \t]*#\\+\\(?:\\(CAPTION\\|caption\\|NAME\\|name\\|"
                            "ATTR_[A-Za-z_]+\\)\\):[ \t]*\\(.*\\)\\'")
                    line)
      (cons (list :type 'keyword
                  :key (upcase (match-string 1 line))
                  :value (match-string 2 line))
            (1+ index)))
     ((string-match (concat "\\`[ \t]*#\\+\\(RESULTS\\|results\\):[ \t]*\\(.*\\)\\'")
                    line)
      (let* ((value (match-string 2 line))
             (cursor (1+ index))
             (content nil))
        (while (and (< cursor end)
                    (not (string-match-p "\\`[ \t]*#\\+" (aref lines cursor)))
                    (not (etaf-org-preview--blank-line-p (aref lines cursor)))
                    (or (string-match-p "\\`[ \t]*:" (aref lines cursor))
                        (string-match-p "\\`[ \t]*#" (aref lines cursor))))
          (push (string-trim-left (aref lines cursor) "[ \t]*[:#]?[ \t]?")
                content)
          (cl-incf cursor))
        (cons (list :type 'results
                    :name value
                    :text (string-join (nreverse content) "\n"))
              cursor)))
     ((string-match (concat "\\`[ \t]*#\\+\\(CALL\\|call\\):[ \t]*"
                            "\\([^ \t(]+\\)\\(.*\\)\\'") line)
      (cons (list :type 'babel-call
                  :name (match-string 2 line)
                  :args (string-trim (match-string 3 line)))
            (1+ index)))
     ((string-match (concat "\\`[ \t]*#\\+\\(INCLUDE\\|include\\):[ \t]*"
                            "\\([^ \t]+\\)\\(.*\\)\\'") line)
      (cons (list :type 'include-card
                  :target (match-string 2 line)
                  :args (string-trim (match-string 3 line)))
            (1+ index)))
     ((string-match etaf-org-preview--keyword-line-regexp line)
      (cons (list :type 'keyword
                  :key (upcase (match-string 1 line))
                  :value (string-trim (match-string 2 line))
                  :hidden t)
            (1+ index)))
     (t
      (etaf-org-preview--degrade ctx 'directive)
      (cons (list :type 'paragraph :text line
                  :inlines (list (etaf-org-preview--text-node line)))
            (1+ index))))))

(defun etaf-org-preview--read-container (ctx index name argument)
  "Read the block NAME starting at INDEX in CTX, with ARGUMENT.
Blocks whose content is Org markup parse recursively; code-like blocks keep
their text."
  (let* ((lines (etaf-org-preview-ctx-lines ctx))
         (end (etaf-org-preview-ctx-end ctx))
         (found (etaf-org-preview--find-block-end ctx index name))
         (end-index (or found end))
         (begin-indent (etaf-org-preview--indent-columns (aref lines index)))
         (content (etaf-org-preview--block-content ctx index end-index
                                                   begin-indent))
         (next (if found (1+ found) end))
         (text (string-join content "\n")))
    (unless found
      (etaf-org-preview--degrade ctx 'unclosed-block))
    (cons
     (pcase name
       ("SRC"
        (let* ((words (split-string (or argument "") "[ \t]+" t))
               (lang (downcase (or (car words) "")))
               (switches (string-join (cdr words) " ")))
          (list :type 'src-block :lang (unless (string-empty-p lang) lang)
                :switches switches :text text)))
       ("EXAMPLE" (list :type 'example-block :text text))
       ("QUOTE" (etaf-org-preview--container-node ctx 'quote-block content))
       ((or "VERSE") (list :type 'verse-block :text text))
       ("CENTER" (etaf-org-preview--container-node ctx 'center-block content))
       ("COMMENT" (list :type 'comment-block :text text))
       ("EXPORT" (list :type 'export-block
                       :backend (string-trim (or argument ""))
                       :text text))
       (_ (etaf-org-preview--container-node ctx 'special-block content
                                            (downcase name))))
     next)))

(defun etaf-org-preview--container-node (ctx type lines &optional name)
  "Return a container block of TYPE parsing LINES in CTX, named NAME.
QUOTE blocks keep a trailing `-- author' line as their attribution."
  (let ((attribution nil)
        (last (car (last lines))))
    (when (and (eq type 'quote-block) last
               (string-match "\\`[ \t]*--[ \t]+\\(.+\\)\\'" last))
      (setq attribution (string-trim (match-string 1 last)))
      (setq lines (butlast lines)))
    (let* ((sub-ctx (copy-etaf-org-preview-ctx ctx))
           (vector (vconcat lines)))
      (setf (etaf-org-preview-ctx-lines sub-ctx) vector
            (etaf-org-preview-ctx-end sub-ctx) (length vector))
      (list :type type
            :name name
            :attribution attribution
            :blocks (etaf-org-preview--parse-blocks sub-ctx)))))

;;; ---------------------------------------------------------------------------
;;; Document assembly
;;; ---------------------------------------------------------------------------

(defun etaf-org-preview--parse-attributes (value)
  "Return the keyword pairs of an `#+ATTR_*' VALUE as a plist."
  (let ((tokens (split-string value "[ \t]+" t))
        (plist nil))
    (while tokens
      (let ((token (pop tokens)))
        (when (string-prefix-p ":" token)
          (setq plist (plist-put plist (intern token) (pop tokens))))))
    plist))

(defun etaf-org-preview--apply-nested-attachments (ctx block)
  "Apply attachment keywords inside BLOCK and return it."
  (when-let* ((children (plist-get block :blocks)))
    (setq block (plist-put block :blocks
                           (etaf-org-preview--apply-attachments ctx children))))
  (when-let* ((items (plist-get block :items)))
    (setq block (plist-put block :items
                           (mapcar
                            (lambda (item)
                              (plist-put item :blocks
                                         (etaf-org-preview--apply-attachments
                                          ctx (plist-get item :blocks))))
                            items))))
  block)

(defun etaf-org-preview--apply-attachments (ctx blocks)
  "Attach CAPTION, NAME and ATTR keywords in BLOCKS to the next element.
An attached keyword stays in the list with `:attached' set, so showing hidden
content can still reveal it, while the renderer skips it.  BLOCKS is a list of
block plists and the return value is a new list of the same order."
  (let ((pending nil)
        (result nil))
    (dolist (block blocks)
      (if (eq (plist-get block :type) 'keyword)
          (let ((key (plist-get block :key))
                (value (plist-get block :value)))
            (cond
             ((string-prefix-p "ATTR_" key)
              (push (cons :attrs (etaf-org-preview--parse-attributes value))
                    pending)
              (push (plist-put block :attached t) result))
             ((equal key "CAPTION")
              (push (cons :caption value) pending)
              (push (plist-put block :attached t) result))
             ((equal key "NAME")
              (push (cons :name value) pending)
              (push (plist-put block :attached t) result))
             (t (push block result))))
        (let ((block block))
          (dolist (entry (nreverse pending))
            (setq block (plist-put block (car entry) (cdr entry))))
          (when-let* ((name (plist-get block :name)))
            (puthash name (etaf-org-preview-ctx-current-section ctx)
                     (etaf-org-preview-ctx-targets ctx)))
          (setq pending nil)
          (push (etaf-org-preview--apply-nested-attachments ctx block) result))))
    (nreverse result)))

(defun etaf-org-preview--apply-section-attachments (ctx sections)
  "Apply attachment keywords to every body in SECTIONS."
  (dolist (section sections)
    (setf (etaf-org-preview-ctx-current-section ctx) section)
    (setf (etaf-org-preview-section-body section)
          (etaf-org-preview--apply-attachments
           ctx (etaf-org-preview-section-body section)))
    (etaf-org-preview--apply-section-attachments
     ctx (etaf-org-preview-section-children section))))

(defun etaf-org-preview--org-todo-keywords ()
  "Return the keyword alist from Org's own settings, or nil.
The preview keeps rendering deterministic: the file wins, then the user's
`org-todo-keywords' when Org happens to be loaded, then the built-in pair."
  (when (and (boundp 'org-todo-keywords) (consp org-todo-keywords))
    (let ((sequence (car org-todo-keywords))
          (done nil)
          (result nil))
      (dolist (word sequence)
        (cond
         ((equal word "|") (setq done t))
         ((stringp word)
          (let ((name (if (string-match "\\`\\([^()]+\\)(" word)
                          (match-string 1 word)
                        word)))
            (push (cons name (if done 'done 'active)) result)))))
      (nreverse result))))

(defun etaf-org-preview--finalize-section-ids (sections)
  "Assign stable ids to SECTIONS in document order and return the outline."
  (let ((outline nil))
    (cl-labels ((walk (section path)
                  (let* ((properties (etaf-org-preview-section-properties section))
                         (custom (or (cdr (assoc "CUSTOM_ID" properties))
                                     (cdr (assoc "ID" properties))))
                         (id (or custom path)))
                    (setf (etaf-org-preview-section-id section) id)
                    (push (list (etaf-org-preview-section-level section)
                                (etaf-org-preview-section-title-plain section)
                                id
                                (etaf-org-preview-section-todo section)
                                (etaf-org-preview-section-tags section))
                          outline)
                    (let ((number 0))
                      (dolist (child (etaf-org-preview-section-children section))
                        (cl-incf number)
                        (walk child (format "%s.%d" path number)))))))
      (let ((number 0))
        (dolist (section sections)
          (cl-incf number)
          (walk section (format "s%d" number)))))
    (nreverse outline)))

(defun etaf-org-preview--lift-section-metadata (sections)
  "Move property drawers and logbooks of SECTIONS into their sections.
A logbook may follow a property drawer or open the body on its own; both forms
belong to the section summary rather than to the reading blocks."
  (cl-labels ((walk (section)
                (let ((body (etaf-org-preview-section-body section)))
                  (when (and body (eq (plist-get (car body) :type) 'property-drawer))
                    (setf (etaf-org-preview-section-properties section)
                          (plist-get (car body) :properties))
                    (setf (etaf-org-preview-section-body section) (cdr body))
                    (setq body (cdr body)))
                  (when (and body (eq (plist-get (car body) :type) 'drawer)
                             (equal (plist-get (car body) :name) "LOGBOOK"))
                    (setf (etaf-org-preview-section-logbook section)
                          (plist-get (car body) :clock))
                    (setf (etaf-org-preview-section-logbook-text section)
                          (plist-get (car body) :text))
                    (setf (etaf-org-preview-section-body section) (cdr body))))
                (when (or (member "ARCHIVE" (etaf-org-preview-section-tags section))
                          (equal (cdr (assoc "ARCHIVE" (etaf-org-preview-section-properties
                                                        section)))
                                 "true"))
                  (setf (etaf-org-preview-section-archived section) t))
                (dolist (child (etaf-org-preview-section-children section))
                  (walk child))))
    (dolist (section sections) (walk section))))

(cl-defun etaf-org-preview--parse (text &key file startup)
  "Parse TEXT into a document plist.
FILE names the source for `input-file' and link resolution; STARTUP is the
fold state used when the document names none."
  (let* ((lines (etaf-org-preview--split-lines text))
         (ctx (etaf-org-preview--make-ctx
               :lines lines :end (length lines) :source-file file))
         (sections nil)
         (preamble nil)
         (stack nil))
    (etaf-org-preview--scan-settings ctx)
    (unless (etaf-org-preview-ctx-todo-keywords ctx)
      (setf (etaf-org-preview-ctx-todo-keywords ctx)
            (or (etaf-org-preview--org-todo-keywords)
                etaf-org-preview--default-todo-keywords)))
    (let ((index 0)
          (end (etaf-org-preview-ctx-end ctx)))
      (while (< index end)
        (let ((line (aref lines index)))
          (cond
           ((etaf-org-preview--blank-line-p line)
            (cl-incf index))
           ((etaf-org-preview--headline-line-p line)
            (let* ((level (etaf-org-preview--headline-level line))
                   (section (etaf-org-preview--parse-headline ctx index)))
              (cl-incf index)
              ;; A planning line may wrap over several lines; every keyword
              ;; found there belongs to the section that follows it.
              (while (and (< index end)
                          (etaf-org-preview--planning-line-p (aref lines index)))
                (setf (etaf-org-preview-section-planning section)
                      (append (etaf-org-preview--parse-planning
                               ctx (aref lines index))
                              (etaf-org-preview-section-planning section)))
                (cl-incf index))
              (setf (etaf-org-preview-ctx-current-section ctx) section)
              (while (and stack (>= (etaf-org-preview-section-level (car stack))
                                    level))
                (pop stack))
              (if stack
                  (push section (etaf-org-preview-section-children (car stack)))
                (push section sections))
              (push section stack)))
           (t
            (let* ((result (etaf-org-preview--read-block ctx index))
                   (block (car result)))
              (if stack
                  (push block (etaf-org-preview-section-body (car stack)))
                (push block preamble))
              (setq index (max (cdr result) (1+ index)))))))))
    (setq sections (nreverse sections))
    (dolist (section sections)
      (cl-labels ((reverse-body (node)
                    (setf (etaf-org-preview-section-body node)
                          (nreverse (etaf-org-preview-section-body node)))
                    (setf (etaf-org-preview-section-children node)
                          (nreverse (etaf-org-preview-section-children node)))
                    (dolist (child (etaf-org-preview-section-children node))
                      (reverse-body child))))
        (reverse-body section)))
    (etaf-org-preview--lift-section-metadata sections)
    (etaf-org-preview--apply-section-attachments ctx sections)
    (setq preamble (etaf-org-preview--apply-attachments ctx preamble))
    (let* ((outline (etaf-org-preview--finalize-section-ids sections))
           (footnotes (etaf-org-preview--footnote-list ctx))
           (degraded (etaf-org-preview--degraded-total ctx))
           (options (or (etaf-org-preview-ctx-options ctx)
                        (etaf-org-preview--parse-options "")))
           (blocks (etaf-org-preview--count-blocks sections preamble)))
      (list :type 'document
            :title (etaf-org-preview-ctx-title ctx)
            :subtitle (etaf-org-preview-ctx-subtitle ctx)
            :author (etaf-org-preview-ctx-author ctx)
            :date (etaf-org-preview-ctx-date ctx)
            :email (etaf-org-preview-ctx-email ctx)
            :language (etaf-org-preview-ctx-language ctx)
            :keywords (etaf-org-preview-ctx-keywords ctx)
            :description (etaf-org-preview-ctx-description ctx)
            :filetags (etaf-org-preview-ctx-filetags ctx)
            :options options
            :startup (or (and (not (eq (etaf-org-preview-ctx-startup ctx) 'content))
                              (etaf-org-preview-ctx-startup ctx))
                         startup
                         'content)
            :todo-keywords (etaf-org-preview-ctx-todo-keywords ctx)
            :priorities (etaf-org-preview-ctx-priorities ctx)
            :sections sections
            :preamble (nreverse preamble)
            :outline outline
            :targets (etaf-org-preview-ctx-targets ctx)
            :footnotes footnotes
            :degraded degraded
            :degraded-types (etaf-org-preview--degraded-types ctx)
            :blocks blocks
            :chars (length text)
            :file file))))

(defun etaf-org-preview--count-blocks (sections preamble)
  "Count PREAMBLE blocks and every block below SECTIONS."
  (let ((count (length preamble)))
    (cl-labels ((walk (blocks)
                  (dolist (block blocks)
                    (cl-incf count)
                    (when-let* ((children (plist-get block :blocks)))
                      (walk children))
                    (dolist (item (plist-get block :items))
                      (walk (plist-get item :blocks)))))
                (walk-section (section)
                  (walk (etaf-org-preview-section-body section))
                  (dolist (child (etaf-org-preview-section-children section))
                    (walk-section child))))
      (dolist (section sections) (walk-section section)))
    count))

(defun etaf-org-preview--degraded-total (ctx)
  "Return the number of degraded constructs in CTX."
  (let ((total 0))
    (maphash (lambda (_type count) (cl-incf total count))
             (etaf-org-preview-ctx-degraded ctx))
    total))

(defun etaf-org-preview--degraded-types (ctx)
  "Return the degradation counts of CTX as a list of (TYPE . COUNT)."
  (let (result)
    (maphash (lambda (type count) (push (cons type count) result))
             (etaf-org-preview-ctx-degraded ctx))
    (sort result (lambda (a b) (string< (symbol-name (car a))
                                        (symbol-name (car b)))))))

(defun etaf-org-preview--footnote-list (ctx)
  "Return CTX's footnotes as a list of plists in numbering order."
  (let* ((registry (etaf-org-preview-ctx-footnotes ctx))
         (order (reverse (etaf-org-preview-footnotes-order registry)))
         (entries (etaf-org-preview-footnotes-entries registry))
         (result nil))
    (dolist (label order)
      (when-let* ((entry (gethash label entries)))
        (unless (plist-get entry :inlines)
          (plist-put entry :inlines (list (etaf-org-preview--text-node
                                           (format "（脚注 %s 没有定义）" label)))))
        (push entry result)))
    (nreverse result)))

(provide 'etaf-org-preview-parse)
;;; etaf-org-preview-parse.el ends here
