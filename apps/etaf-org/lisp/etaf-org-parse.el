;;; etaf-org-parse.el --- Pure Org parser with native extension syntax -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; Pure Org parsing for `etaf-org': text in, document tree out.  Nothing here
;; reads a file, opens a buffer, looks at a frame or depends on Org being
;; loaded.  The tree carries source line spans (`:line-start' / `:line-end')
;; and no presentation facts.
;;
;; Features beyond basic Org:
;; - Dialect control (`standard', `etaf' default, or feature plist) via call
;;   argument, `#+ETAF_FLAVOR:', or `#+OPTIONS: etaf:nil'.
;; - Accumulating multiple `#+TODO:' / `#+SEQ_TODO:' / `#+TYP_TODO:' sequences.
;; - Complete `#+OPTIONS:' (`num:', `toc:', `todo:', `tags:', `pri:',
;;   `^:t|{}|nil', `-:', `f:', `stat:', `d:').
;; - Depth-counting nested `#+begin_<name> :key val' containers (up to 8
;;   levels), `#+attr_etaf:' attribute merging, `#+<marker>:' child markers,
;;   and `#+BEGIN: name :args' dynamic blocks with parsed inner Org blocks.
;; - Strict Org `$...$' math boundaries (never misparses `$100 and $200').
;; - Multi-paragraph footnote definitions, full `org-cite', date/time ranges,
;;   all `#+RESULTS:' shapes paired to preceding `#+begin_src', `VERSE' with
;;   inline markup, `LOGBOOK' clock + state-change notes, `#+TOC:',
;;   `#+BIBLIOGRAPHY:', `#+PRINT_BIBLIOGRAPHY:', `#+SETUPFILE:', and
;;   custom inline link micro-widgets (`kbd:', `badge:', `sym:', `color:',
;;   `spoiler:', `icon:', `abbr:', `denote:', `roam:') plus `etaf' flavor
;;   `==highlight==' and `!!spoiler!!'.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'etaf-org-entities)
(require 'etaf-org-node)

(define-error 'etaf-org-parse-error "Org document parse error")

;;; ---------------------------------------------------------------------------
;;; Flavors & feature flags
;;; ---------------------------------------------------------------------------

(defcustom etaf-org-flavor 'etaf
  "Default Org dialect of `etaf-org-create' when no `:flavor' is passed.
`etaf' enables Org-native containers, `#+attr_etaf:' attributes, custom inline
link widgets, and `==mark==' / `!!spoiler!!' sugars.  `standard' parses pure
Org syntax only.  A feature plist toggles individual flags."
  :type '(choice (const :tag "ETAF extended Org" etaf)
                 (const :tag "Standard Org only" standard)
                 (plist :tag "Custom feature plist"))
  :group 'etaf-org)

(defconst etaf-org--flavor-presets
  '((standard . (:containers nil
                 :custom-links nil
                 :inline-marks nil
                 :spoilers nil
                 :dynamic-widgets nil))
    (etaf . (:containers t
             :custom-links t
             :inline-marks t
             :spoilers t
             :dynamic-widgets t)))
  "Named Org dialect presets.")

(defun etaf-org--resolve-flavor (flavor)
  "Resolve FLAVOR (nil, symbol or plist) into a normalized feature plist."
  (let ((spec (or flavor etaf-org-flavor 'etaf)))
    (cond
     ((symbolp spec)
      (or (copy-sequence (cdr (assq spec etaf-org--flavor-presets)))
          (signal 'etaf-org-error (list (format "Unknown Org flavor: %S" spec)))))
     ((listp spec)
      (let ((base (copy-sequence (cdr (assq 'etaf etaf-org--flavor-presets))))
            (rest spec))
        (while rest
          (let ((k (pop rest)) (v (pop rest)))
            (setq base (plist-put base k (and v t)))))
        base))
     (t (signal 'etaf-org-error (list (format "Invalid Org flavor: %S" spec)))))))

(defun etaf-org--feature-p (ctx flag)
  "Return non-nil when dialect FLAG is enabled in CTX."
  (plist-get (etaf-org-ctx-features ctx) flag))

;;; ---------------------------------------------------------------------------
;;; Context and records
;;; ---------------------------------------------------------------------------

(cl-defstruct (etaf-org-footnotes
               (:constructor etaf-org--make-footnotes))
  "Footnote registry shared across all sub-contexts of one document."
  (counter 0)
  (order nil)
  (entries (make-hash-table :test #'equal)))

(cl-defstruct (etaf-org-ctx (:constructor etaf-org--make-ctx))
  (lines [])
  (end 0)
  (line-offset 1)
  (source-file nil)
  (flavor 'etaf)
  (features nil)
  (live-p nil)
  (nesting-depth 0)
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
  (abbreviations nil)
  (bibliographies nil)
  (setupfiles nil)
  (contract nil)
  (degraded (make-hash-table :test #'equal))
  (footnotes (etaf-org--make-footnotes))
  (targets (make-hash-table :test #'equal))
  (citations (cons nil nil))
  (current-section nil))

(cl-defstruct (etaf-org-section
               (:constructor etaf-org--section-create))
  (id nil)
  (level 1)
  (number nil)
  (todo nil)
  (todo-state nil)
  (priority nil)
  (title nil)
  (title-plain "")
  (title-inlines nil)
  (cookie nil)
  (tags nil)
  (effective-tags nil)
  (planning nil)
  (properties nil)
  (logbook nil)
  (logbook-notes nil)
  (logbook-text nil)
  (archived nil)
  (commented nil)
  (line-start 1)
  (line-end 1)
  (children nil)
  (body nil))

(defconst etaf-org--image-extensions
  '("png" "jpg" "jpeg" "gif" "svg" "webp" "bmp" "tif" "tiff")
  "Image file extensions rendered as pictures.")

(defconst etaf-org--video-extensions
  '("mp4" "mov" "m4v" "webm" "mkv" "avi")
  "Video file extensions rendered as media cards.")

(defconst etaf-org--default-todo-keywords
  '(("TODO" . active) ("DONE" . done))
  "Default TODO keyword set when neither the document nor Org defines one.")

(defconst etaf-org--custom-inline-schemes
  '("kbd" "badge" "sym" "color" "spoiler" "icon" "abbr" "roam" "denote")
  "Org custom link schemes rendered as inline micro-widgets in `etaf' flavor.")

;;; ---------------------------------------------------------------------------
;;; Line helpers
;;; ---------------------------------------------------------------------------

(defun etaf-org--split-lines (text)
  "Return TEXT as a vector of lines with CRLF and BOM normalized."
  (let ((text (if (and (>= (length text) 1) (eq (aref text 0) #xFEFF))
                  (substring text 1)
                text)))
    (setq text (replace-regexp-in-string "\r\n?" "\n" text))
    (vconcat (split-string text "\n"))))

(defun etaf-org--indent-columns (string)
  "Return column width of STRING's leading whitespace."
  (let ((column 0) (index 0) (length (length string)))
    (while (and (< index length) (memq (aref string index) '(?\s ?\t)))
      (setq column (if (eq (aref string index) ?\t)
                       (* 8 (1+ (/ column 8)))
                     (1+ column)))
      (cl-incf index))
    column))

(defun etaf-org--strip-columns (string columns)
  "Return STRING without its first COLUMNS columns of whitespace."
  (let ((column 0) (index 0) (length (length string)))
    (while (and (< index length) (< column columns)
                (memq (aref string index) '(?\s ?\t)))
      (setq column (if (eq (aref string index) ?\t)
                       (* 8 (1+ (/ column 8)))
                     (1+ column)))
      (cl-incf index))
    (substring string index)))

(defun etaf-org--blank-line-p (line)
  "Return non-nil when LINE holds only whitespace."
  (string-blank-p line))

(defun etaf-org--degrade (ctx type)
  "Count one degradation of TYPE in CTX."
  (puthash type (1+ (gethash type (etaf-org-ctx-degraded ctx) 0))
           (etaf-org-ctx-degraded ctx)))

(defun etaf-org--cjk-char-p (char)
  "Return non-nil when CHAR belongs to a CJK script."
  (and (integerp char)
       (or (and (>= char #x2E80) (<= char #x9FFF))
           (and (>= char #xF900) (<= char #xFAFF))
           (and (>= char #xFF00) (<= char #xFFEF))
           (and (>= char #x20000) (<= char #x3FFFF)))))

(defun etaf-org--join-lines (lines)
  "Join paragraph LINES the way Org exports them."
  (let ((result nil) (first t))
    (dolist (line lines)
      (unless first
        (let* ((previous (car result))
               (len (length previous))
               (last-char (and (> len 0) (aref previous (1- len))))
               (prev2 (and (> len 1) (aref previous (- len 2))))
               (first-char (and (> (length line) 0) (aref line 0))))
          (cond
           ((and last-char (= last-char ?\\) prev2 (= prev2 ?\\))
            (setcar result (concat (substring previous 0 -2) "\n")))
           ((and (etaf-org--cjk-char-p last-char)
                 (etaf-org--cjk-char-p first-char))
            nil)
           (t (setcar result (concat previous " "))))))
      (if first
          (progn (push line result) (setq first nil))
        (setcar result (concat (car result) line))))
    (nreverse result)))

(defun etaf-org--paragraph-text (lines)
  "Return the joined text of paragraph LINES."
  (or (car (etaf-org--join-lines lines)) ""))

;;; ---------------------------------------------------------------------------
;;; Org plist attribute parser (`:key val :key2 "quoted string"')
;;; ---------------------------------------------------------------------------

(defun etaf-org--parse-plist-string (text)
  "Parse Org `:key value' pairs in TEXT.
Return `(PLIST DUPLICATES)' where PLIST maps keyword keys to string values
and DUPLICATES lists any attribute key written more than once."
  (let ((str (string-trim (or text "")))
        (pos 0)
        (len (length (string-trim (or text ""))))
        (plist nil)
        (seen nil)
        (dups nil))
    (while (< pos len)
      ;; Skip whitespace.
      (while (and (< pos len) (memq (aref str pos) '(?\s ?\t)))
        (cl-incf pos))
      (when (< pos len)
        (if (eq (aref str pos) ?:)
            (let ((kstart (1+ pos)))
              (cl-incf pos)
              (while (and (< pos len)
                          (not (memq (aref str pos) '(?\s ?\t ?=))))
                (cl-incf pos))
              (let* ((kname (downcase (substring str kstart pos)))
                     (key (and (not (string-empty-p kname))
                               (intern (concat ":" kname)))))
                (while (and (< pos len) (memq (aref str pos) '(?\s ?\t)))
                  (cl-incf pos))
                (let ((val
                       (cond
                        ((>= pos len) "t")
                        ;; Next token starts a new `:key': bare flag -> "t".
                        ((and (eq (aref str pos) ?:)
                              (< (1+ pos) len)
                              (string-match-p "[A-Za-z]"
                                              (char-to-string (aref str (1+ pos)))))
                         "t")
                        ((eq (aref str pos) ?\")
                         (cl-incf pos)
                         (let ((chars nil) (done nil))
                           (while (and (< pos len) (not done))
                             (let ((ch (aref str pos)))
                               (cond
                                ((and (eq ch ?\\) (< (1+ pos) len))
                                 (cl-incf pos)
                                 (push (aref str pos) chars))
                                ((eq ch ?\")
                                 (setq done t))
                                (t (push ch chars)))
                               (cl-incf pos)))
                           (apply #'string (nreverse chars))))
                        (t
                         (let ((vstart pos))
                           (while (and (< pos len)
                                       (not (memq (aref str pos) '(?\s ?\t))))
                             (cl-incf pos))
                           (substring str vstart pos))))))
                  (when key
                    (if (memq key seen)
                        (push key dups)
                      (push key seen)
                      (setq plist (plist-put plist key val)))))))
          ;; Bare token outside `:key' (skip to next whitespace).
          (while (and (< pos len) (not (memq (aref str pos) '(?\s ?\t))))
            (cl-incf pos)))))
    (list plist (nreverse dups))))

(defun etaf-org--parse-attributes (value)
  "Return the keyword pairs of an `#+ATTR_*' VALUE as a plist."
  (car (etaf-org--parse-plist-string value)))

;;; ---------------------------------------------------------------------------
;;; Settings pass
;;; ---------------------------------------------------------------------------

(defconst etaf-org--keyword-line-regexp
  "^[ \t]*#\\+\\([A-Za-z_][A-Za-z0-9_-]*\\):[ \t]*\\(.*\\)$"
  "A `#+KEY: value' line.")

(defun etaf-org--parse-value-list (value)
  "Return VALUE split on whitespace and commas."
  (split-string value "[ \t,]+" t))

(defun etaf-org--parse-todo-keywords (value)
  "Return the keyword alist described by TODO VALUE."
  (let ((words (etaf-org--parse-value-list value))
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

(defun etaf-org--merge-todo-keywords (existing added)
  "Append ADDED TODO keywords onto EXISTING without losing earlier sequences."
  (let ((result (copy-sequence existing)))
    (dolist (pair added)
      (unless (assoc (car pair) result)
        (setq result (append result (list pair)))))
    result))

(defun etaf-org--parse-priorities (value)
  "Return (HIGHEST LOWEST DEFAULT) from PRIORITIES VALUE."
  (let ((words (etaf-org--parse-value-list value)))
    (list (and (nth 0 words) (aref (nth 0 words) 0))
          (and (nth 1 words) (aref (nth 1 words) 0))
          (and (nth 2 words) (aref (nth 2 words) 0)))))

(defun etaf-org--default-options ()
  "Return default `#+OPTIONS:' plist."
  (list :toc 2 :num nil :todo t :tags t :priority t :subsup t
        :entities t :footnotes t :stat t :drawers nil
        :headline-levels 8 :etaf t))

(defun etaf-org--parse-options (value &optional base)
  "Merge `#+OPTIONS:' VALUE into BASE option plist."
  (let ((options (copy-sequence (or base (etaf-org--default-options)))))
    (dolist (word (etaf-org--parse-value-list value))
      (when (string-match "\\`\\([^:]+\\):\\(.*\\)\\'" word)
        (let ((key (downcase (match-string 1 word)))
              (raw (match-string 2 word)))
          (pcase key
            ("toc" (setq options
                         (plist-put options :toc
                                    (cond ((equal raw "nil") nil)
                                          ((equal raw "t") 3)
                                          (t (string-to-number raw))))))
            ("num" (setq options
                         (plist-put options :num
                                    (cond ((equal raw "nil") nil)
                                          ((equal raw "t") t)
                                          (t (string-to-number raw))))))
            ("todo" (setq options (plist-put options :todo (not (equal raw "nil")))))
            ("tags" (setq options (plist-put options :tags (not (equal raw "nil")))))
            ("pri" (setq options (plist-put options :priority (not (equal raw "nil")))))
            ((or "^" "_")
             (setq options (plist-put options :subsup
                                      (cond ((equal raw "nil") nil)
                                            ((equal raw "{}") 'brace)
                                            (t t)))))
            ("-" (setq options (plist-put options :entities (not (equal raw "nil")))))
            ("f" (setq options (plist-put options :footnotes (not (equal raw "nil")))))
            ("stat" (setq options (plist-put options :stat (not (equal raw "nil")))))
            ("h" (setq options (plist-put options :headline-levels
                                          (if (equal raw "nil") 8
                                            (string-to-number raw)))))
            ("d" (setq options (plist-put options :drawers (not (equal raw "nil")))))
            ("etaf" (setq options (plist-put options :etaf (not (equal raw "nil")))))
            (_ nil)))))
    options))

(defun etaf-org--parse-startup (value)
  "Return the startup fold state named by VALUE, or nil."
  (let ((words (mapcar #'downcase (etaf-org--parse-value-list value))))
    (cond
     ((member "overview" words) 'overview)
     ((member "folded" words) 'folded)
     ((member "show2levels" words) 'show2levels)
     ((member "show3levels" words) 'show3levels)
     ((cl-intersection words '("content" "showall" "showeverything" "nofold")
                       :test #'equal)
      'content)
     (t nil))))

(defun etaf-org--parse-tag-string (value)
  "Return tag list from `:a:b:' or whitespace-separated VALUE."
  (let ((trimmed (string-trim value)))
    (if (string-match-p ":" trimmed)
        (split-string trimmed ":" t)
      (etaf-org--parse-value-list trimmed))))

(defun etaf-org--apply-setting-line (ctx line)
  "Apply a single `#+KEY: VALUE' LINE to CTX."
  (when (string-match etaf-org--keyword-line-regexp line)
    (let* ((key (upcase (match-string 1 line)))
           (value (string-trim (match-string 2 line))))
      (pcase key
        ("TITLE" (setf (etaf-org-ctx-title ctx) value))
        ("SUBTITLE" (setf (etaf-org-ctx-subtitle ctx) value))
        ("AUTHOR" (setf (etaf-org-ctx-author ctx) value))
        ("DATE" (setf (etaf-org-ctx-date ctx) value))
        ("EMAIL" (setf (etaf-org-ctx-email ctx) value))
        ("LANGUAGE" (setf (etaf-org-ctx-language ctx) value))
        ("KEYWORDS" (setf (etaf-org-ctx-keywords ctx)
                          (append (etaf-org-ctx-keywords ctx)
                                  (etaf-org--parse-value-list value))))
        ("DESCRIPTION" (setf (etaf-org-ctx-description ctx) value))
        ("FILETAGS" (setf (etaf-org-ctx-filetags ctx)
                          (delete-dups
                           (append (etaf-org-ctx-filetags ctx)
                                   (etaf-org--parse-tag-string value)))))
        ((or "TODO" "SEQ_TODO" "TYP_TODO")
         (setf (etaf-org-ctx-todo-keywords ctx)
               (etaf-org--merge-todo-keywords
                (etaf-org-ctx-todo-keywords ctx)
                (etaf-org--parse-todo-keywords value))))
        ("PRIORITIES" (setf (etaf-org-ctx-priorities ctx)
                            (etaf-org--parse-priorities value)))
        ("OPTIONS" (setf (etaf-org-ctx-options ctx)
                         (etaf-org--parse-options value (etaf-org-ctx-options ctx))))
        ("STARTUP" (when-let* ((startup (etaf-org--parse-startup value)))
                     (setf (etaf-org-ctx-startup ctx) startup)))
        ("MACRO" (when (string-match "\\`\\([^ \t]+\\)[ \t]+\\(.*\\)\\'" value)
                   (push (cons (match-string 1 value) (match-string 2 value))
                         (etaf-org-ctx-macros ctx))))
        ("LINK" (when (string-match "\\`\\([^ \t]+\\)[ \t]+\\(.*\\)\\'" value)
                  (push (cons (match-string 1 value) (match-string 2 value))
                        (etaf-org-ctx-link-abbrevs ctx))))
        ("ABBR" (when (string-match "\\`\\([^ \t:]+\\)[ \t:]+\\(.*\\)\\'" value)
                  (push (cons (match-string 1 value) (match-string 2 value))
                        (etaf-org-ctx-abbreviations ctx))))
        ("BIBLIOGRAPHY"
         (unless (string-empty-p value)
           (push (string-trim value "\"" "\"") (etaf-org-ctx-bibliographies ctx))))
        ("SETUPFILE"
         (unless (string-empty-p value)
           (push (string-trim value "\"" "\"") (etaf-org-ctx-setupfiles ctx))))
        ("ETAF_FLAVOR"
         (let ((sym (intern (downcase value))))
           (when (assq sym etaf-org--flavor-presets)
             (setf (etaf-org-ctx-flavor ctx) sym))))
        ("ETAF_CONTRACT"
         (when (string-match-p "\\`[0-9]+\\'" value)
           (setf (etaf-org-ctx-contract ctx) (string-to-number value))))
        (_ nil)))))

(defun etaf-org--scan-settings (ctx &optional setup-lines)
  "Read file-level keywords of CTX (preceded by optional SETUP-LINES)."
  (dolist (line setup-lines)
    (etaf-org--apply-setting-line ctx line))
  (let ((lines (etaf-org-ctx-lines ctx))
        (end (etaf-org-ctx-end ctx)))
    (dotimes (index end)
      (etaf-org--apply-setting-line ctx (aref lines index)))))

;;; ---------------------------------------------------------------------------
;;; Inline parsing
;;; ---------------------------------------------------------------------------

(defconst etaf-org--inline-candidate
  (concat "\\[\\[\\|\\[fn:\\|\\[cite\\|\\[@\\|<[0-9]\\|\\[[0-9]"
          "\\|<\\{2,3\\}\\|{{{\\|@@\\|==\\|!!"
          "\\|\\(?:src\\|call\\)_[A-Za-z0-9_+-]+"
          "\\|\\(?:https?\\|mailto\\):[^ \t\n]+"
          "\\|\\\\"
          "\\|[*_/+=~^$]")
  "Regexp matching the first character of any inline Org construct.")

(defconst etaf-org--alnum-regexp "[[:alnum:]]"
  "Characters that may not bound an Org emphasis run.")

(defun etaf-org--boundary-ok-p (string position)
  "Return non-nil when emphasis may start or end at POSITION in STRING."
  (let ((char (and (>= position 0) (< position (length string))
                   (aref string position))))
    (not (and char (string-match-p etaf-org--alnum-regexp
                                   (char-to-string char))))))

(defun etaf-org--text-node (text)
  "Return a text inline node for TEXT."
  (list :type 'text :text text))

(defun etaf-org--inline-at-emphasis (ctx string start)
  "Parse an Org emphasis or code construct of STRING at START."
  (let* ((marker (aref string start))
         (verbatim (memq marker '(?= ?~)))
         (end (length string))
         (search (1+ start))
         (found nil))
    (when (and (etaf-org--boundary-ok-p string (1- start))
               (< search end)
               (not (memq (aref string search) '(?\s ?\t ?\n))))
      (while (and (not found)
                  (string-match (regexp-quote (char-to-string marker))
                                string search))
        (let ((close (match-beginning 0)))
          (if (and (> close (1+ start))
                   (not (memq (aref string (1- close)) '(?\s ?\t ?\n)))
                   (etaf-org--boundary-ok-p string (1+ close)))
              (setq found close)
            (setq search (1+ close)))))
      (when found
        (let ((content (substring string (1+ start) found)))
          (cons
           (if verbatim
               (list :type 'code :verbatim (eq marker ?=) :text content)
             (list :type 'emphasis
                   :marker (char-to-string marker)
                   :children (etaf-org--parse-inlines ctx content)))
           (1+ found)))))))

(defun etaf-org--inline-at-mark (ctx string start)
  "Parse `==highlight==' in `etaf' flavor at START in STRING."
  (when (and (etaf-org--feature-p ctx :inline-marks)
             (< (+ start 3) (length string))
             (eq (aref string start) ?=)
             (eq (aref string (1+ start)) ?=)
             (not (memq (aref string (+ start 2)) '(?\s ?\t ?=))))
    (when (string-match "==" string (+ start 2))
      (let* ((close (match-beginning 0))
             (content (substring string (+ start 2) close)))
        (unless (or (string-empty-p content)
                    (memq (aref content (1- (length content))) '(?\s ?\t)))
          (cons (list :type 'mark
                      :children (etaf-org--parse-inlines ctx content))
                (+ close 2)))))))

(defun etaf-org--inline-at-spoiler (ctx string start)
  "Parse `!!spoiler!!' in `etaf' flavor at START in STRING."
  (when (and (etaf-org--feature-p ctx :spoilers)
             (< (+ start 3) (length string))
             (eq (aref string start) ?!)
             (eq (aref string (1+ start)) ?!)
             (not (memq (aref string (+ start 2)) '(?\s ?\t ?!))))
    (when (string-match "!!" string (+ start 2))
      (let* ((close (match-beginning 0))
             (content (substring string (+ start 2) close)))
        (unless (or (string-empty-p content)
                    (memq (aref content (1- (length content))) '(?\s ?\t)))
          (cons (list :type 'spoiler
                      :text content
                      :children (etaf-org--parse-inlines ctx content))
                (+ close 2)))))))

(defun etaf-org--substitute-map (string table)
  "Translate every char of STRING via TABLE, or return nil if any is unmapped."
  (let ((result nil) (ok t) (index 0) (length (length string)))
    (while (and ok (< index length))
      (let ((mapped (cdr (assq (aref string index) table))))
        (if mapped (push mapped result) (setq ok nil)))
      (cl-incf index))
    (when (and ok (not (string-empty-p string)))
      (apply #'concat (nreverse result)))))

(defun etaf-org--inline-at-subsup (ctx string start)
  "Parse subscript or superscript at START in STRING, respecting `^:' option."
  (let* ((opt (plist-get (or (etaf-org-ctx-options ctx)
                             (etaf-org--default-options))
                         :subsup)))
    (when opt
      (let* ((marker (aref string start))
             (table (if (eq marker ?_) etaf-org-subscripts etaf-org-superscripts))
             (end (length string)))
        (cond
         ((and (< (1+ start) end) (eq (aref string (1+ start)) ?{))
          (let ((close (string-match "}" string (+ start 2))))
            (when close
              (let ((mapped (etaf-org--substitute-map
                             (substring string (+ start 2) close) table)))
                (when mapped
                  (cons (list :type 'subsup :kind (if (eq marker ?_) 'sub 'sup)
                              :text mapped)
                        (1+ close)))))))
         ((and (not (eq opt 'brace)) (< (1+ start) end))
          (let* ((tail (substring string (1+ start)))
                 (index 0))
            (while (and (< index (length tail))
                        (cdr (assq (aref tail index) table)))
              (cl-incf index))
            (when (> index 0)
              (let ((mapped (etaf-org--substitute-map
                             (substring tail 0 index) table)))
                (when mapped
                  (cons (list :type 'subsup :kind (if (eq marker ?_) 'sub 'sup)
                              :text mapped)
                        (+ start 1 index)))))))
         (t nil))))))

(defun etaf-org--tex-to-unicode (text)
  "Replace known TeX command names in TEXT with their Unicode spelling."
  (let ((case-fold-search nil))
    (replace-regexp-in-string
     "\\\\\\([A-Za-z]+\\)"
     (lambda (match)
       (save-match-data
         (let ((name (match-string 1 match)))
           (or (cdr (assoc name etaf-org-entities)) match))))
     text t t)))

(defun etaf-org--inline-at-entity (ctx string start)
  "Parse an entity, inline LaTeX fragment, or hard break at START."
  (let ((end (length string)))
    (when (< (1+ start) end)
      (cond
       ((and (eq (aref string (1+ start)) ?\\)
             (or (= (+ start 2) end)
                 (memq (aref string (+ start 2)) '(?\s ?\t ?\n))))
        (cons (list :type 'break :hard t) (+ start 2)))
       ((eq (aref string (1+ start)) ?\()
        (let ((close (string-match "\\\\)" string (+ start 2))))
          (when close
            (let ((raw (substring string (+ start 2) close)))
              (cons (list :type 'latex-fragment :display nil
                          :raw raw
                          :text (etaf-org--tex-to-unicode raw))
                    (+ close 2))))))
       ((eq (aref string (1+ start)) ?\[)
        (let ((close (string-match "\\\\]" string (+ start 2))))
          (when close
            (let ((raw (substring string (+ start 2) close)))
              (cons (list :type 'latex-fragment :display t
                          :raw raw
                          :text (etaf-org--tex-to-unicode raw))
                    (+ close 2))))))
       (t
        (let ((rest (substring string (1+ start)))
              (entities-on (plist-get (or (etaf-org-ctx-options ctx)
                                          (etaf-org--default-options))
                                      :entities)))
          (cond
           ((and entities-on
                 (string-match "\\`\\([A-Za-z][A-Za-z0-9]*\\)\\(?:{}\\)?" rest))
            (let* ((name (match-string 1 rest))
                   (utf8 (cdr (assoc name etaf-org-entities))))
              (when utf8
                (cons (list :type 'entity :name name :text utf8)
                      (+ start 1 (match-end 0))))))
           ((string-match "\\`\\([][{}()*+/_=~^$<>&#%!-]\\)" rest)
            (cons (etaf-org--text-node (match-string 1 rest))
                  (+ start 1 (match-end 0))))
           (t nil))))))))

(defun etaf-org--link-kind (target)
  "Return the semantic kind of Org link TARGET."
  (cond
   ((string-prefix-p "http://" target) 'url)
   ((string-prefix-p "https://" target) 'url)
   ((string-prefix-p "mailto:" target) 'mail)
   ((string-prefix-p "file:" target) 'file)
   ((string-prefix-p "id:" target) 'id)
   ((string-prefix-p "attachment:" target) 'attachment)
   ((string-prefix-p "elisp:" target) 'elisp)
   ((string-prefix-p "shell:" target) 'shell)
   ((string-prefix-p "info:" target) 'info)
   ((string-prefix-p "help:" target) 'help)
   ((string-prefix-p "doi:" target) 'url)
   ((string-prefix-p "*" target) 'headline)
   ((string-prefix-p "#" target) 'custom-id)
   ((string-match "\\`\\([a-z][a-z0-9-]*\\):" target)
    (let ((scheme (match-string 1 target)))
      (if (member scheme etaf-org--custom-inline-schemes)
          'custom-widget
        'other)))
   (t 'fuzzy)))

(defun etaf-org--link-target (target ctx)
  "Expand link abbreviation TARGET through CTX, or return it unchanged."
  (if (string-match "\\`\\([A-Za-z][A-Za-z0-9+.-]*\\)::?\\(.*\\)\\'" target)
      (let* ((scheme (match-string 1 target))
             (abbrev (cdr (assoc scheme (etaf-org-ctx-link-abbrevs ctx)))))
        (if abbrev
            (if (string-match-p "%s" abbrev)
                (replace-regexp-in-string "%s" (match-string 2 target) abbrev t t)
              (concat abbrev (match-string 2 target)))
          target))
    target))

(defun etaf-org--inline-at-link (ctx string start)
  "Parse an Org `[[target][desc]]' link or custom micro-widget at START."
  (when (and (< (+ start 1) (length string))
             (eq (aref string (+ start 1)) ?\[))
    (let ((close (string-match "\\]\\]" string (+ start 2))))
      (when close
        (let* ((inner (substring string (+ start 2) close))
               (split (string-match "\\]\\[" inner))
               (raw-target (if split (substring inner 0 split) inner))
               (raw-desc (if split (substring inner (+ split 2)) nil))
               (target (etaf-org--link-target raw-target ctx))
               (kind (etaf-org--link-kind target)))
          (if (and (eq kind 'custom-widget)
                   (etaf-org--feature-p ctx :custom-links)
                   (string-match "\\`\\([a-z][a-z0-9-]*\\):\\(.*\\)\\'" target))
              (cons (list :type 'inline-widget
                          :scheme (intern (match-string 1 target))
                          :payload (match-string 2 target)
                          :label raw-desc
                          :target target)
                    (+ close 2))
            (cons (list :type 'link
                        :target target
                        :kind (if (eq kind 'custom-widget) 'other kind)
                        :desc (when raw-desc
                                (etaf-org--parse-inlines ctx raw-desc)))
                  (+ close 2))))))))

(defun etaf-org--footnote-register (ctx label inlines &optional blocks)
  "Register footnote LABEL with INLINES or BLOCKS in CTX and return number."
  (let* ((registry (etaf-org-ctx-footnotes ctx))
         (entries (etaf-org-footnotes-entries registry))
         (existing (gethash label entries)))
    (if existing
        (progn
          (when inlines (plist-put existing :inlines inlines))
          (when blocks (plist-put existing :blocks blocks))
          (plist-get existing :number))
      (let ((number (cl-incf (etaf-org-footnotes-counter registry))))
        (puthash label (list :label label :number number
                             :inlines inlines :blocks blocks)
                 entries)
        (push label (etaf-org-footnotes-order registry))
        number))))

(defun etaf-org--inline-at-footnote (ctx string start)
  "Parse a footnote reference `[fn:label]' or `[fn::inline def]' at START."
  (when (and (<= (+ start 4) (length string))
             (string-prefix-p "[fn:" (substring string start (+ start 4))))
    (let* ((close (string-match "\\]" string (+ start 4)))
           (body (and close (substring string (+ start 4) close))))
      (when body
        (let* ((colon (string-match ":" body))
               (label (if colon (substring body 0 colon) body))
               (definition (and colon (substring body (1+ colon))))
               (label (if (string-empty-p label)
                          (format "anon-%d"
                                  (1+ (etaf-org-footnotes-counter
                                       (etaf-org-ctx-footnotes ctx))))
                        label))
               (number (etaf-org--footnote-register
                        ctx label
                        (and definition
                             (etaf-org--parse-inlines ctx definition)))))
          (cons (list :type 'footnote-ref :label label :number number)
                (1+ close)))))))

(defun etaf-org--inline-at-citation (ctx string start)
  "Parse Org-cite `[cite/style:prefix @key suffix; @key2]' or `[@key]'."
  (when (eq (aref string start) ?\[)
    (let ((close (string-match "\\]" string (1+ start))))
      (when close
        (let ((body (substring string (1+ start) close)))
          (when (and (string-match "@" body)
                     (or (string-prefix-p "@" body)
                         (string-prefix-p "cite" body)))
            (let ((style nil)
                  (keys nil)
                  (refs nil))
              (when (string-match "\\`cite\\(?:/\\([^:]+\\)\\)?:" body)
                (setq style (match-string 1 body)))
              (with-temp-buffer
                (insert body)
                (goto-char (point-min))
                (while (re-search-forward "@\\([A-Za-z0-9_:.#$-]+\\)" nil t)
                  (let ((k (match-string 1)))
                    (push k keys)
                    (push k refs)
                    (cl-pushnew k (car (etaf-org-ctx-citations ctx)) :test #'equal))))
              (cons (list :type 'citation
                          :style style
                          :keys (nreverse keys)
                          :raw (concat "[" body "]"))
                    (1+ close)))))))))

(defun etaf-org--parse-single-timestamp (string start)
  "Parse one `<...>' or `[...]' Org timestamp at START in STRING."
  (let* ((active (eq (aref string start) ?<))
         (close (and (< (1+ start) (length string))
                     (string-match (if active ">" "\\]") string (1+ start)))))
    (when close
      (let ((body (substring string (1+ start) close)))
        (when (string-match
               "\\`\\([0-9]\\{4\\}\\)-\\([0-9]\\{2\\}\\)-\\([0-9]\\{2\\}\\)\\(?:[ \t]+\\([^ \t0-9+-]+\\)\\)?\\(?:[ \t]+\\([0-9]\\{2\\}\\):\\([0-9]\\{2\\}\\)\\(?:-\\([0-9]\\{2\\}\\):\\([0-9]\\{2\\}\\)\\)?\\)?\\(?:[ \t]+\\(\\.[+]\\|[+][+]\\|[+]\\)[0-9]+[hdwmy]\\)?\\(?:[ \t]+\\(--\\|-\\)[0-9]+[hdwmy]\\)?"
               body)
          (let* ((y (string-to-number (match-string 1 body)))
                 (m (string-to-number (match-string 2 body)))
                 (d (string-to-number (match-string 3 body)))
                 (day (match-string 4 body))
                 (hh (and (match-string 5 body)
                          (string-to-number (match-string 5 body))))
                 (mm (and (match-string 6 body)
                          (string-to-number (match-string 6 body))))
                 (end-hh (and (match-string 7 body)
                              (string-to-number (match-string 7 body))))
                 (end-mm (and (match-string 8 body)
                              (string-to-number (match-string 8 body))))
                 (repeater (when (string-match "\\(\\(?:\\.\\+\\|\\+\\+\\|\\+\\)[0-9]+[hdwmy]\\)" body)
                             (match-string 1 body)))
                 (warning (when (string-match "[ \t]+\\(--?[0-9]+[hdwmy]\\)" body)
                            (match-string 1 body))))
            (cons (list :type 'timestamp
                        :active active
                        :raw (concat (if active "<" "[") body (if active ">" "]"))
                        :start (list :y y :m m :d d :day day
                                     :hh hh :mm mm
                                     :end-hh end-hh :end-mm end-mm)
                        :repeater repeater
                        :warning warning)
                  (1+ close))))))))

(defun etaf-org--parse-timestamp (string start)
  "Parse an Org timestamp or timestamp range `<d1>--<d2>' at START."
  (when-let* ((first (etaf-org--parse-single-timestamp string start)))
    (let* ((node (car first))
           (next (cdr first)))
      (if (and (< (+ next 2) (length string))
               (string-prefix-p "--" (substring string next (+ next 2)))
               (memq (aref string (+ next 2)) '(?< ?\[)))
          (if-let* ((second (etaf-org--parse-single-timestamp string (+ next 2))))
              (let ((merged (copy-sequence node)))
                (setq merged (plist-put merged :end (car second)))
                (setq merged (plist-put merged :range-end (car second)))
                (setq merged (plist-put merged :raw
                                        (concat (plist-get node :raw)
                                                "--"
                                                (plist-get (car second) :raw))))
                (cons merged (cdr second)))
            first)
        first))))

(defun etaf-org--inline-at-timestamp (_ctx string start)
  "Parse an inline timestamp at START in STRING."
  (and (memq (aref string start) '(?< ?\[))
       (< (1+ start) (length string))
       (>= (aref string (1+ start)) ?0)
       (<= (aref string (1+ start)) ?9)
       (etaf-org--parse-timestamp string start)))

(defun etaf-org--inline-at-target (ctx string start)
  "Parse a `<<target>>' or `<<<radio>>>' target at START in STRING."
  (cond
   ((and (<= (+ start 3) (length string))
         (string-prefix-p "<<<" (substring string start (+ start 3)))
         (string-match ">>>" string (+ start 3)))
    (let* ((close (match-beginning 0))
           (name (substring string (+ start 3) close)))
      (puthash name (etaf-org-ctx-current-section ctx)
               (etaf-org-ctx-targets ctx))
      (cons (list :type 'target :name name :radio t) (+ close 3))))
   ((and (<= (+ start 2) (length string))
         (string-prefix-p "<<" (substring string start (+ start 2)))
         (string-match ">>" string (+ start 2)))
    (let* ((close (match-beginning 0))
           (name (substring string (+ start 2) close)))
      (puthash name (etaf-org-ctx-current-section ctx)
               (etaf-org-ctx-targets ctx))
      (cons (list :type 'target :name name) (+ close 2))))
   (t nil)))

(defun etaf-org--expand-macro (_ctx template args)
  "Expand macro TEMPLATE with ARGS using Org's `$1' convention."
  (let ((expanded template) (index 1))
    (dolist (arg args)
      (setq expanded (replace-regexp-in-string (format "\\$%d" index) arg
                                               expanded t t))
      (cl-incf index))
    (setq expanded (replace-regexp-in-string "\\$0" template expanded t t))
    expanded))

(defun etaf-org--inline-at-macro (ctx string start)
  "Parse a `{{{macro}}}' call at START in STRING."
  (when (and (<= (+ start 3) (length string))
             (string-prefix-p "{{{" (substring string start (+ start 3)))
             (string-match "}}}" string (+ start 3)))
    (let* ((close (match-beginning 0))
           (body (substring string (+ start 3) close))
           (name (if (string-match "\\`\\([^()]+\\)" body)
                     (match-string 1 body)
                   body))
           (args (if (string-match "(\\(.*\\))\\'" body)
                     (split-string (match-string 1 body) "," t)
                   nil))
           (template (cdr (assoc name (etaf-org-ctx-macros ctx)))))
      (cond
       (template
        (cons (etaf-org--text-node (etaf-org--expand-macro ctx template args))
              (+ close 3)))
       ((member name '("title" "author" "date" "email" "input-file"))
        (cons (etaf-org--text-node
               (or (pcase name
                     ("title" (etaf-org-ctx-title ctx))
                     ("author" (etaf-org-ctx-author ctx))
                     ("date" (etaf-org-ctx-date ctx))
                     ("email" (etaf-org-ctx-email ctx))
                     ("input-file" (etaf-org-ctx-source-file ctx)))
                   ""))
              (+ close 3)))
       (t
        (etaf-org--degrade ctx 'macro)
        (cons (etaf-org--text-node (concat "{{{" body "}}}"))
              (+ close 3)))))))

(defun etaf-org--inline-at-inline-src (_ctx string start)
  "Parse inline `src_lang{...}' or `call_name(...)' at START."
  (let ((rest (substring string start)))
    (when (string-match "\\`\\(src\\|call\\)_\\([A-Za-z0-9_+-]+\\)\\(?:\\[[^]]*\\]\\)?{" rest)
      (let* ((source-p (equal (match-string 1 rest) "src"))
             (language (downcase (match-string 2 rest)))
             (name-end (+ start (match-end 0)))
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

(defun etaf-org--inline-at-snippet (_ctx string start)
  "Parse an export snippet `@@backend:payload@@' at START."
  (when (and (<= (+ start 2) (length string))
             (string-prefix-p "@@" (substring string start (+ start 2)))
             (string-match "@@" string (+ start 2)))
    (let* ((close (match-beginning 0))
           (body (substring string (+ start 2) close))
           (colon (string-match ":" body)))
      (cons (list :type 'export-snippet
                  :backend (and colon (substring body 0 colon))
                  :text (if colon (substring body (1+ colon)) body))
            (+ close 2)))))

(defun etaf-org--inline-at-url (_ctx string start)
  "Parse a bare URL at START in STRING."
  (let ((rest (substring string start)))
    (when (string-match "\\`\\(?:https?\\|mailto\\):[^ \t\n<>]+" rest)
      (let* ((raw (match-string 0 rest))
             (url (replace-regexp-in-string "[.,;:!?)\"']+\\'" "" raw)))
        (cons (list :type 'link :target url
                    :kind (if (string-prefix-p "mailto:" url) 'mail 'url)
                    :desc (list (etaf-org--text-node
                                 (if (string-prefix-p "mailto:" url)
                                     (substring url 7)
                                   url))))
              (+ start (length url)))))))

(defun etaf-org--inline-at-cookie (_ctx string start)
  "Parse a statistics cookie `[2/5]' or `[50%]' at START."
  (when (eq (aref string start) ?\[)
    (let ((close (string-match "\\]" string (1+ start))))
      (when close
        (let ((body (substring string (1+ start) close)))
          (when (string-match "\\`\\(?:[0-9]*/[0-9]*\\|[0-9]+%\\)\\'" body)
            (cons (list :type 'statistics-cookie :text (concat "[" body "]"))
                  (1+ close))))))))

(defun etaf-org--inline-at-math (_ctx string start)
  "Parse an inline `$...$' LaTeX fragment obeying strict Org boundaries.
Rejects currency forms like `$100 and $200' where `$' is preceded by a word
character, followed by whitespace, or closed before a digit/word."
  (let ((len (length string)))
    (when (and (eq (aref string start) ?$)
               (< (+ start 2) len)
               (not (eq (aref string (1+ start)) ?$))
               ;; Left border: start of string or non-alnum / non-$.
               (or (= start 0)
                   (not (string-match-p "[[:alnum:]$]"
                                        (char-to-string (aref string (1- start))))))
               ;; Inner start: must not be whitespace or punctuation like ,.;?
               (not (memq (aref string (1+ start)) '(?\s ?\t ?\n ?, ?\; ?\. ?\?))))
      (let ((search (1+ start))
            (found nil)
            (stop nil))
        (while (and (not found) (not stop) (string-match "\\$" string search))
          (let ((close (match-beginning 0)))
            (cond
             ;; Escaped \$ inside math: keep scanning.
             ((and (> close start) (eq (aref string (1- close)) ?\\))
              (setq search (1+ close)))
             ;; Newline inside single-$ not allowed across multiple lines.
             ((string-match-p "\n" (substring string (1+ start) close))
              (setq stop t))
             ;; First unescaped `$' is the only legal closing delimiter.
             (t
              (let ((inner (substring string (1+ start) close)))
                (when (and (> close (1+ start))
                           (not (memq (aref string (1- close)) '(?\s ?\t ?\n ?, ?\.)))
                           (or (= (1+ close) len)
                               (not (string-match-p "[[:alnum:]$]"
                                                    (char-to-string (aref string (1+ close))))))
                           (not (string-match-p "\\`[0-9]+\\(?:[.,][0-9]+\\)*[ \t]" inner))
                           (not (string-match-p "\\cc" inner)))
                  (setq found close)))
              (setq stop t)))))
        (when found
          (let ((raw (substring string (1+ start) found)))
            (cons (list :type 'latex-fragment :display nil
                        :raw raw
                        :text (etaf-org--tex-to-unicode raw))
                  (1+ found))))))))

(defun etaf-org--parse-inline-at (ctx string start)
  "Parse the inline Org construct at START in STRING."
  (or (etaf-org--inline-at-link ctx string start)
      (etaf-org--inline-at-footnote ctx string start)
      (etaf-org--inline-at-citation ctx string start)
      (etaf-org--inline-at-timestamp ctx string start)
      (etaf-org--inline-at-target ctx string start)
      (etaf-org--inline-at-cookie ctx string start)
      (etaf-org--inline-at-macro ctx string start)
      (etaf-org--inline-at-snippet ctx string start)
      (etaf-org--inline-at-inline-src ctx string start)
      (etaf-org--inline-at-mark ctx string start)
      (etaf-org--inline-at-spoiler ctx string start)
      (and (eq (aref string start) ?\\)
           (etaf-org--inline-at-entity ctx string start))
      (and (eq (aref string start) ?$)
           (etaf-org--inline-at-math ctx string start))
      (and (memq (aref string start) '(?* ?/ ?_ ?+ ?= ?~))
           (etaf-org--inline-at-emphasis ctx string start))
      (and (memq (aref string start) '(?_ ?^))
           (etaf-org--inline-at-subsup ctx string start))
      (etaf-org--inline-at-url ctx string start)))

(defun etaf-org--parse-inlines (ctx string)
  "Parse STRING into inline nodes for CTX."
  (let ((position 0)
        (length (length string))
        (nodes nil))
    (while (< position length)
      (if (string-match etaf-org--inline-candidate string position)
          (let ((start (match-beginning 0)))
            (when (> start position)
              (push (etaf-org--text-node (substring string position start))
                    nodes))
            (let ((result (etaf-org--parse-inline-at ctx string start)))
              (if result
                  (progn
                    (push (car result) nodes)
                    (setq position (cdr result)))
                (push (etaf-org--text-node (substring string start (1+ start)))
                      nodes)
                (setq position (1+ start)))))
        (push (etaf-org--text-node (substring string position)) nodes)
        (setq position length)))
    (nreverse nodes)))

(defun etaf-org-inline-plain-text (inlines)
  "Return INLINES as plain text, stripping markers and handlers."
  (let ((parts nil))
    (dolist (node inlines)
      (let ((type (plist-get node :type)))
        (push
         (pcase type
           ((or 'text 'code 'inline-src 'entity 'subsup 'statistics-cookie)
            (or (plist-get node :text) ""))
           ((or 'emphasis 'mark)
            (etaf-org-inline-plain-text (plist-get node :children)))
           ('spoiler (or (plist-get node :text) ""))
           ('inline-widget
            (or (plist-get node :label) (plist-get node :payload) ""))
           ('link (if (plist-get node :desc)
                      (etaf-org-inline-plain-text (plist-get node :desc))
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

(defconst etaf-org--headline-regexp
  "\\`\\(\\*+\\)\\(?:[ \t]+\\|\\'\\)\\(.*\\)\\'"
  "An Org headline line.")

(defun etaf-org--headline-line-p (line)
  "Return non-nil when LINE starts an Org headline."
  (string-match-p "\\`\\*+[ \t]" line))

(defun etaf-org--headline-level (line)
  "Return LINE's headline star level."
  (if (string-match "\\`\\(\\*+\\)" line) (length (match-string 1 line)) 0))

(defun etaf-org--parse-headline-title (ctx rest)
  "Split headline REST into TODO, priority, tags, cookie, comment and title."
  (let ((commented nil)
        (todo nil)
        (todo-state nil)
        (priority nil)
        (tags nil)
        (cookie nil)
        (case-fold-search t))
    (setq rest (string-trim rest))
    (when (string-match "\\`COMMENT[ \t]+\\(.*\\)\\'" rest)
      (setq commented t
            rest (match-string 1 rest)))
    (let ((keywords (or (etaf-org-ctx-todo-keywords ctx)
                        etaf-org--default-todo-keywords)))
      (dolist (keyword keywords)
        (when (and (not todo)
                   (string-match (format "\\`%s[ \t]+\\(.*\\)\\'"
                                         (regexp-quote (car keyword)))
                                 rest))
          (setq todo (car keyword)
                todo-state (cdr keyword)
                rest (match-string 1 rest)))))
    (when (string-match "\\`\\[#\\([A-Za-z]\\)\\][ \t]*\\(.*\\)\\'" rest)
      (setq priority (upcase (match-string 1 rest))
            rest (match-string 2 rest)))
    (when (string-match "\\(?:[ \t]\\|\\`\\)\\(:[A-Za-z0-9_@#%:]+:\\)[ \t]*\\'" rest)
      (let ((tag-text (match-string 1 rest))
            (tag-start (match-beginning 0)))
        (setq tags (etaf-org--parse-tag-string tag-text)
              rest (string-trim (substring rest 0 tag-start)))))
    (when (string-match "\\(\\[[0-9]*/[0-9]*\\]\\|\\[[0-9]+%\\]\\)[ \t]*\\'" rest)
      (setq cookie (match-string 1 rest)
            rest (string-trim (substring rest 0 (match-beginning 0)))))
    (list :todo todo
          :todo-state todo-state
          :priority priority
          :tags tags
          :cookie cookie
          :commented commented
          :title rest
          :title-inlines (etaf-org--parse-inlines ctx rest))))

(defun etaf-org--planning-line-p (line)
  "Return non-nil when LINE carries SCHEDULED/DEADLINE/CLOSED keywords."
  (string-match-p "\\`[ \t]*\\(?:SCHEDULED\\|DEADLINE\\|CLOSED\\):" line))

(defun etaf-org--parse-planning (_ctx line)
  "Return the planning plist parsed from LINE."
  (let ((planning nil))
    (with-temp-buffer
      (insert line)
      (goto-char (point-min))
      (while (re-search-forward
              "\\(SCHEDULED\\|DEADLINE\\|CLOSED\\):[ \t]*\\(<[^>]+>\\(?:--<[^>]+>\\)?\\|\\[[^]]+\\]\\(?:--\\[[^]]+\\]\\)?\\)"
              nil t)
        (let* ((key (downcase (match-string 1)))
               (stamp (etaf-org--parse-timestamp (match-string 2) 0)))
          (when stamp
            (setq planning (plist-put planning (intern (concat ":" key))
                                      (car stamp)))))))
    planning))

(defun etaf-org--parse-headline (ctx index)
  "Return an `etaf-org-section' for the headline at INDEX in CTX."
  (let* ((line (aref (etaf-org-ctx-lines ctx) index))
         (level (etaf-org--headline-level line))
         (rest (if (string-match etaf-org--headline-regexp line)
                   (match-string 2 line)
                 ""))
         (fields (etaf-org--parse-headline-title ctx rest))
         (lno (+ (etaf-org-ctx-line-offset ctx) index)))
    (etaf-org--section-create
     :level level
     :todo (plist-get fields :todo)
     :todo-state (plist-get fields :todo-state)
     :priority (plist-get fields :priority)
     :title (plist-get fields :title)
     :title-plain (etaf-org-inline-plain-text (plist-get fields :title-inlines))
     :title-inlines (plist-get fields :title-inlines)
     :cookie (plist-get fields :cookie)
     :tags (plist-get fields :tags)
     :commented (plist-get fields :commented)
     :line-start lno
     :line-end lno)))

;;; ---------------------------------------------------------------------------
;;; Blocks
;;; ---------------------------------------------------------------------------

(defun etaf-org--block-stop-p (_ctx line)
  "Return non-nil when LINE starts a new block and cannot continue a paragraph."
  (or (etaf-org--blank-line-p line)
      (etaf-org--headline-line-p line)
      (string-match-p "\\`[ \t]*#\\+" line)
      (string-match-p "\\`[ \t]*|" line)
      (string-match-p "\\`[ \t]*:[ \t]" line)
      (string-match-p "\\`[ \t]*:\\'" line)
      (string-match-p "\\`[ \t]*:[A-Za-z0-9_-]+:[ \t]*\\'" line)
      (string-match-p "\\`[ \t]*\\(?:[-+*]\\|[0-9]+[.)]\\|[A-Za-z][.)]\\)[ \t]+" line)
      (string-match-p "\\`[ \t]*-\\{5,\\}[ \t]*\\'" line)
      (string-match-p "\\`[ \t]*\\\\begin{" line)
      (string-match-p "\\`[ \t]*\\(?:\\\\\\[\\|\\$\\$\\)" line)
      (string-match-p "\\`[ \t]*\\[fn:[^]]+\\]" line)
      (string-match-p "\\`[ \t]*#[ \t]" line)))

(defun etaf-org--parse-blocks (ctx)
  "Parse all blocks of CTX into a list of block plists."
  (let ((index 0)
        (end (etaf-org-ctx-end ctx))
        (blocks nil))
    (while (< index end)
      (let ((line (aref (etaf-org-ctx-lines ctx) index)))
        (if (etaf-org--blank-line-p line)
            (cl-incf index)
          (let* ((result (etaf-org--read-block ctx index))
                 (block (car result))
                 (next (max (cdr result) (1+ index))))
            (when block
              (let ((ls (+ (etaf-org-ctx-line-offset ctx) index))
                    (le (+ (etaf-org-ctx-line-offset ctx) (1- next))))
                (setq block (plist-put (plist-put block :line-start ls)
                                       :line-end le)))
              (push block blocks))
            (setq index next)))))
    (nreverse blocks)))

(defun etaf-org--read-block (ctx index)
  "Read one block starting at INDEX in CTX; return `(BLOCK . NEXT-INDEX)'."
  (let ((line (aref (etaf-org-ctx-lines ctx) index)))
    (cond
     ((string-match-p "\\`[ \t]*#\\+" line)
      (etaf-org--read-directive ctx index))
     ((string-match-p "\\`[ \t]*#[ \t]" line)
      (etaf-org--read-comment ctx index))
     ((string-match-p "\\`[ \t]*:[A-Za-z0-9_-]+:[ \t]*\\'" line)
      (etaf-org--read-drawer ctx index))
     ((string-match-p "\\`[ \t]*|" line)
      (etaf-org--read-table ctx index))
     ((string-match-p "\\`[ \t]*:\\(?:[ \t]\\|\\'\\)" line)
      (etaf-org--read-fixed-width ctx index))
     ((etaf-org--list-item-p line)
      (etaf-org--read-list ctx index))
     ((string-match-p "\\`[ \t]*-\\{5,\\}[ \t]*\\'" line)
      (cons (list :type 'horizontal-rule) (1+ index)))
     ((string-match-p "\\`[ \t]*\\\\begin{" line)
      (etaf-org--read-latex-environment ctx index))
     ((string-match-p "\\`[ \t]*\\(?:\\\\\\[\\|\\$\\$\\)" line)
      (etaf-org--read-display-math ctx index))
     (t
      (etaf-org--read-paragraph ctx index)))))

(defun etaf-org--read-paragraph (ctx index)
  "Read a paragraph or multi-paragraph footnote definition at INDEX in CTX."
  (let* ((lines (etaf-org-ctx-lines ctx))
         (end (etaf-org-ctx-end ctx))
         (cursor index)
         (collected nil)
         (first-line (aref lines index)))
    (if (string-match "\\`[ \t]*\\[fn:\\([^]]+\\)\\][ \t]*\\(.*\\)\\'" first-line)
        ;; Multi-paragraph footnote definition: continues until next headline,
        ;; next [fn:...] definition, or two consecutive blank lines.
        (let ((label (match-string 1 first-line))
              (rest (match-string 2 first-line))
              (blank-run 0)
              (def-lines nil)
              (stop nil))
          (push rest def-lines)
          (setq cursor (1+ cursor))
          (while (and (< cursor end) (not stop))
            (let ((cur (aref lines cursor)))
              (cond
               ((etaf-org--headline-line-p cur) (setq stop t))
               ((string-match-p "\\`[ \t]*\\[fn:[^]]+\\]" cur) (setq stop t))
               ((etaf-org--blank-line-p cur)
                (cl-incf blank-run)
                (if (>= blank-run 2)
                    (setq stop t)
                  (push "" def-lines)
                  (cl-incf cursor)))
               (t
                (setq blank-run 0)
                (push cur def-lines)
                (cl-incf cursor)))))
          ;; Trim trailing blank line consumed before stop.
          (while (and def-lines (string-blank-p (car def-lines)))
            (pop def-lines))
          (setq def-lines (nreverse def-lines))
          (let* ((sub-ctx (copy-etaf-org-ctx ctx))
                 (vec (vconcat def-lines)))
            (setf (etaf-org-ctx-lines sub-ctx) vec
                  (etaf-org-ctx-end sub-ctx) (length vec)
                  (etaf-org-ctx-line-offset sub-ctx)
                  (+ (etaf-org-ctx-line-offset ctx) index))
            (let* ((blocks (etaf-org--parse-blocks sub-ctx))
                   (inlines (if (and (= (length blocks) 1)
                                     (eq (plist-get (car blocks) :type) 'paragraph))
                                (plist-get (car blocks) :inlines)
                              (etaf-org--parse-inlines
                               ctx (etaf-org--paragraph-text def-lines)))))
              (etaf-org--footnote-register ctx label inlines blocks)
              (cons (list :type 'footnote-def :label label) cursor))))
      (while (and (< cursor end)
                  (not (etaf-org--block-stop-p ctx (aref lines cursor))))
        (push (aref lines cursor) collected)
        (cl-incf cursor))
      (let ((text (etaf-org--paragraph-text (nreverse collected))))
        (cons (list :type 'paragraph
                    :text text
                    :inlines (etaf-org--parse-inlines ctx text))
              cursor)))))

(defun etaf-org--read-comment (ctx index)
  "Read consecutive `# ' comment lines starting at INDEX."
  (let* ((lines (etaf-org-ctx-lines ctx))
         (end (etaf-org-ctx-end ctx))
         (cursor index)
         (text nil))
    (while (and (< cursor end)
                (string-match-p "\\`[ \t]*#[ \t]" (aref lines cursor)))
      (push (string-trim-left (aref lines cursor) "[ \t]*#[ \t]?") text)
      (cl-incf cursor))
    (cons (list :type 'comment :text (string-join (nreverse text) "\n"))
          cursor)))

(defun etaf-org--read-fixed-width (ctx index)
  "Read consecutive `: ' fixed-width lines starting at INDEX."
  (let* ((lines (etaf-org-ctx-lines ctx))
         (end (etaf-org-ctx-end ctx))
         (cursor index)
         (text nil))
    (while (and (< cursor end)
                (string-match "\\`[ \t]*:\\([ \t]\\(.*\\)\\|\\'\\)"
                              (aref lines cursor)))
      (push (or (match-string 2 (aref lines cursor)) "") text)
      (cl-incf cursor))
    (cons (list :type 'fixed-width :text (string-join (nreverse text) "\n"))
          cursor)))

(defun etaf-org--read-drawer (ctx index)
  "Read a `:NAME: ... :END:' drawer starting at INDEX."
  (let* ((lines (etaf-org-ctx-lines ctx))
         (end (etaf-org-ctx-end ctx))
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
      (etaf-org--degrade ctx 'drawer))
    (cond
     ((equal name "PROPERTIES")
      (cons (list :type 'property-drawer
                  :properties (etaf-org--parse-properties content))
            cursor))
     ((equal name "LOGBOOK")
      (let ((parsed (etaf-org--parse-logbook content)))
        (cons (list :type 'drawer :name name
                    :text (string-join content "\n")
                    :clock (plist-get parsed :clock)
                    :notes (plist-get parsed :notes))
              cursor)))
     (t
      (cons (list :type 'drawer :name name
                  :text (string-join content "\n"))
            cursor)))))

(defun etaf-org--parse-properties (lines)
  "Return property `(KEY . VALUE)' pairs parsed from drawer LINES."
  (let ((properties nil) (last-key nil))
    (dolist (line lines)
      (cond
       ((string-match "\\`[ \t]*:\\([^: \t]+\\):[ \t]*\\(.*\\)\\'" line)
        (let ((key (match-string 1 line))
              (value (match-string 2 line)))
          (if (string-suffix-p "+" key)
              (let* ((base (substring key 0 -1))
                     (cell (assoc base properties)))
                (if cell
                    (setcdr cell (concat (cdr cell) "\n" value))
                  (push (cons base value) properties)))
            (push (cons key value) properties)
            (setq last-key key))))
       ((and last-key (string-match "\\`[ \t]+\\(.*\\)\\'" line))
        (when-let* ((cell (assoc last-key properties)))
          (setcdr cell (concat (cdr cell) " " (match-string 1 line)))))
       (t nil)))
    (nreverse properties)))

(defun etaf-org--parse-logbook (lines)
  "Parse CLOCK entries (including running clocks) and state notes from LINES."
  (let ((entries nil) (notes nil))
    (dolist (line lines)
      (cond
       ((string-match
         "\\`[ \t]*CLOCK:[ \t]*\\(\\[[^]]+\\]\\)--\\(\\[[^]]+\\]\\)[ \t]*\\(?:=>[ \t]*\\([0-9]+\\):\\([0-9]+\\)\\)?"
         line)
        (push (list :start (match-string 1 line)
                    :end (match-string 2 line)
                    :minutes (and (match-string 3 line)
                                  (+ (* 60 (string-to-number (match-string 3 line)))
                                     (string-to-number (match-string 4 line)))))
              entries))
       ((string-match "\\`[ \t]*CLOCK:[ \t]*\\(\\[[^]]+\\]\\)[ \t]*\\'" line)
        (push (list :start (match-string 1 line) :end nil :running t :minutes 0)
              entries))
       ((string-match
         "\\`[ \t]*-[ \t]+State[ \t]+\"\\([^\"]+\\)\"[ \t]+from[ \t]+\"\\([^\"]*\\)\"[ \t]+\\(\\[[^]]+\\]\\)"
         line)
        (push (list :kind 'state
                    :to (match-string 1 line)
                    :from (match-string 2 line)
                    :timestamp (match-string 3 line))
              notes))
       ((string-match
         "\\`[ \t]*-[ \t]+Note taken on[ \t]+\\(\\[[^]]+\\]\\)[ \t]*\\\\\\\\[ \t]*\\(.*\\)\\'"
         line)
        (push (list :kind 'note
                    :timestamp (match-string 1 line)
                    :text (string-trim (match-string 2 line)))
              notes))))
    (list :clock (nreverse entries) :notes (nreverse notes))))

;;; ---------------------------------------------------------------------------
;;; Lists
;;; ---------------------------------------------------------------------------

(defun etaf-org--list-item-p (line)
  "Return non-nil when LINE starts a plain-list item."
  (or (string-match-p "\\`[ \t]+[-+*][ \t]+" line)
      (string-match-p "\\`[ \t]*\\(?:[0-9]+[.)]\\|[A-Za-z][.)]\\)[ \t]+" line)
      (string-match-p "\\`[-+][ \t]+" line)))

(defun etaf-org--item-match (line)
  "Return `(INDENT MARKER CONTENT COLUMN)' for list item LINE, or nil."
  (when (string-match
         "\\`\\([ \t]*\\)\\([-+*]\\|[0-9]+[.)]\\|[A-Za-z][.)]\\)[ \t]+\\(.*\\)\\'"
         line)
    (let* ((indent (etaf-org--indent-columns line))
           (marker (match-string 2 line))
           (content (match-string 3 line))
           (column (etaf-org--indent-columns
                    (concat (match-string 1 line) marker))))
      (unless (and (equal marker "*") (zerop indent))
        (list indent marker content column)))))

(defun etaf-org--read-list (ctx index)
  "Read a plain list starting at INDEX in CTX."
  (let* ((lines (etaf-org-ctx-lines ctx))
         (end (etaf-org-ctx-end ctx))
         (first (etaf-org--item-match (aref lines index)))
         (base (nth 0 first))
         (ordered (string-match-p "[0-9A-Za-z][.)]\\'" (nth 1 first)))
         (style (and ordered (aref (nth 1 first) (1- (length (nth 1 first))))))
         (items nil)
         (cursor index))
    (while (and (< cursor end)
                (let* ((line (aref lines cursor))
                       (match (etaf-org--item-match line)))
                  (cond
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
                   ((etaf-org--blank-line-p line)
                    (let ((next cursor))
                      (while (and (< next end)
                                  (etaf-org--blank-line-p (aref lines next)))
                        (cl-incf next))
                      (and (< next end)
                           (let ((next-line (aref lines next)))
                             (or (etaf-org--item-match next-line)
                                 (> (etaf-org--indent-columns next-line) base))))))
                   (t nil))))
      (let* ((item-start cursor)
             (match (etaf-org--item-match (aref lines cursor)))
             (marker (nth 1 match))
             (content (nth 2 match))
             (column (nth 3 match))
             (item-lines (list content)))
        (cl-incf cursor)
        (while (and (< cursor end)
                    (let ((line (aref lines cursor)))
                      (or (etaf-org--blank-line-p line)
                          (> (etaf-org--indent-columns line) base)))
                    (not (and (etaf-org--item-match (aref lines cursor))
                              (= (nth 0 (etaf-org--item-match
                                         (aref lines cursor)))
                                 base))))
          (let ((line (aref lines cursor)))
            (push (if (etaf-org--blank-line-p line)
                      ""
                    (etaf-org--strip-columns line column))
                  item-lines))
          (cl-incf cursor))
        (setq item-lines (nreverse item-lines))
        (push (etaf-org--list-item
               ctx marker item-lines ordered
               (and ordered (string-match "[0-9]+" marker)
                    (string-to-number (match-string 0 marker)))
               (+ (etaf-org-ctx-line-offset ctx) item-start))
              items)))
    (cons (list :type 'list
                :ordered ordered
                :items (nreverse items))
          cursor)))

(defun etaf-org--list-item (ctx marker lines ordered number source-line)
  "Return a list item plist with SOURCE-LINE recorded for checkbox toggling."
  (let* ((first (car lines))
         (rest (cdr lines))
         (counter nil)
         (checkbox nil)
         (term nil))
    (when (string-match "\\`\\[@\\([0-9]+\\)\\][ \t]*" first)
      (setq counter (match-string 1 first)
            first (substring first (match-end 0))))
    (when (string-match "\\`\\[\\([ xX-]\\)\\][ \t]*" first)
      (setq checkbox (pcase (match-string 1 first)
                       (" " 'off)
                       ("-" 'partial)
                       (_ 'on))
            first (substring first (match-end 0))))
    (when (string-match "\\`\\(.*?\\)[ \t]+::[ \t]*\\(.*\\)\\'" first)
      (setq term (etaf-org--parse-inlines ctx (match-string 1 first))
            first (match-string 2 first)))
    (let* ((sub-lines (cons first rest))
           (sub-ctx (copy-etaf-org-ctx ctx)))
      (setf (etaf-org-ctx-lines sub-ctx) (vconcat sub-lines)
            (etaf-org-ctx-end sub-ctx) (length sub-lines)
            (etaf-org-ctx-line-offset sub-ctx) source-line)
      (list :type 'list-item
            :marker marker
            :ordered ordered
            :number number
            :counter counter
            :checkbox checkbox
            :term term
            :line-start source-line
            :blocks (etaf-org--parse-blocks sub-ctx)))))

;;; ---------------------------------------------------------------------------
;;; Tables
;;; ---------------------------------------------------------------------------

(defun etaf-org--table-separator-p (line)
  "Return non-nil when LINE is an Org table rule (`|---+---|')."
  (and (string-match-p "\\`[ \t]*|" line)
       (let ((rest (string-trim-left (substring line (1+ (string-match "|" line))))))
         (and (string-prefix-p "-" rest)
              (string-match-p "\\`[-+:| \t]+\\'" rest)))))

(defun etaf-org--table-cells (line)
  "Return the raw cell strings of a table LINE."
  (let* ((trimmed (string-trim line))
         (body (if (string-prefix-p "|" trimmed) (substring trimmed 1) trimmed))
         (body (if (string-suffix-p "|" body) (substring body 0 -1) body)))
    (mapcar #'string-trim (split-string body "|"))))

(defun etaf-org--table-cookie (cell)
  "Return `(ALIGN . WIDTH)' described by table cookie CELL."
  (let ((align nil) (width nil))
    (when (string-match "<\\([lcr]\\)?\\([0-9]*\\)>" cell)
      (setq align (pcase (match-string 1 cell)
                    ("l" 'left) ("c" 'center) ("r" 'right) (_ nil))
            width (and (not (string-empty-p (match-string 2 cell)))
                       (string-to-number (match-string 2 cell)))))
    (cons align width)))

(defun etaf-org--read-table (ctx index)
  "Read an Org table starting at INDEX in CTX, including multi-line `#+TBLFM:'."
  (let* ((lines (etaf-org-ctx-lines ctx))
         (end (etaf-org-ctx-end ctx))
         (cursor index)
         (rows nil)
         (rules nil)
         (aligns nil)
         (widths nil)
         (col-groups nil)
         (header-count 0)
         (seen-rule nil)
         (tblfms nil))
    (while (and (< cursor end)
                (string-match-p "\\`[ \t]*|" (aref lines cursor)))
      (let* ((line (aref lines cursor))
             (separator (etaf-org--table-separator-p line))
             (cells (etaf-org--table-cells line))
             (cookie-row (and (not separator)
                              (cl-every (lambda (cell)
                                          (or (string-empty-p cell)
                                              (string-match-p "\\`<\\(?:[lcr]?[0-9]*\\)>\\'"
                                                              cell)))
                                        cells)
                              (cl-some (lambda (cell) (not (string-empty-p cell))) cells)))
             (group-row (and (not separator)
                             (equal (car cells) "/")
                             (cl-every (lambda (cell)
                                         (member cell '("" "<" ">" "<>")))
                                       (cdr cells)))))
        (cond
         (group-row
          (setq col-groups (cdr cells)))
         (cookie-row
          (setq aligns (mapcar (lambda (c) (car (etaf-org--table-cookie c))) cells)
                widths (mapcar (lambda (c) (cdr (etaf-org--table-cookie c))) cells)))
         (separator
          (unless aligns
            (setq aligns (mapcar (lambda (c) (car (etaf-org--table-cookie c))) cells)
                  widths (mapcar (lambda (c) (cdr (etaf-org--table-cookie c))) cells)))
          (unless seen-rule
            (setq header-count (length rows)))
          (setq seen-rule t)
          (push (length rows) rules))
         (t
          (push (list :type 'table-row
                      :cells (mapcar
                              (lambda (cell)
                                (list :raw cell
                                      :inlines (etaf-org--parse-inlines ctx cell)))
                              cells))
                rows)))
        (cl-incf cursor)))
    (while (and (< cursor end)
                (string-match "\\`[ \t]*#\\+\\(?:TBLFM\\|tblfm\\):[ \t]*\\(.*\\)\\'"
                              (aref lines cursor)))
      (push (string-trim (match-string 1 (aref lines cursor))) tblfms)
      (cl-incf cursor))
    (let* ((rows (nreverse rows))
           (columns (apply #'max 1 (mapcar (lambda (row)
                                             (length (plist-get row :cells)))
                                           rows)))
           (rows (mapcar (lambda (row) (plist-put row :columns columns)) rows))
           (tblfm (when tblfms (string-join (nreverse tblfms) "\n"))))
      (cons (list :type 'table
                  :rows rows
                  :columns columns
                  :rules (nreverse rules)
                  :aligns aligns
                  :widths widths
                  :col-groups col-groups
                  :header-count header-count
                  :tblfm tblfm)
            cursor))))

;;; ---------------------------------------------------------------------------
;;; Math & LaTeX environments
;;; ---------------------------------------------------------------------------

(defun etaf-org--read-latex-environment (ctx index)
  "Read a `\\begin{env} ... \\end{env}' block starting at INDEX."
  (let* ((lines (etaf-org-ctx-lines ctx))
         (end (etaf-org-ctx-end ctx))
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

(defun etaf-org--read-display-math (ctx index)
  "Read `$$...$$' or `\\[...\\]' display math starting at INDEX."
  (let* ((lines (etaf-org-ctx-lines ctx))
         (end (etaf-org-ctx-end ctx))
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
      (unless (string-empty-p first-body) (push first-body text))
      (while (and (< cursor end) (not closed))
        (let ((current (aref lines cursor)))
          (if (string-match-p (concat "\\`[ \t]*" (regexp-quote closer)) current)
              (setq closed t)
            (push current text)))
        (cl-incf cursor))))
    (let ((raw (string-join (nreverse text) "\n")))
      (cons (list :type 'display-math
                  :raw raw
                  :text (etaf-org--tex-to-unicode raw))
            cursor))))

;;; ---------------------------------------------------------------------------
;;; Directives, depth-counting containers, markers & dynamic blocks
;;; ---------------------------------------------------------------------------

(defconst etaf-org--begin-regexp
  "\\`[ \t]*#\\+\\(BEGIN\\|begin\\)_\\([A-Za-z0-9_-]+\\)\\(?:[ \t]+\\(.*\\)\\)?[ \t]*\\'"
  "A `#+BEGIN_NAME [ARGS]' line.")

(defun etaf-org--find-block-end (ctx index name &optional verbatim)
  "Return the index of the matching `#+END_NAME' after INDEX in CTX.
For non-VERBATIM blocks, counts nested `#+BEGIN_NAME'/`#+END_NAME' depth so
same-name containers like nested `#+begin_card' match accurately."
  (let ((lines (etaf-org-ctx-lines ctx))
        (end (etaf-org-ctx-end ctx))
        (cursor (1+ index))
        (open-re (format "\\`[ \t]*#\\+BEGIN_%s\\(?:[ \t]\\|\\'\\)"
                         (regexp-quote name)))
        (close-re (format "\\`[ \t]*#\\+END_%s[ \t]*\\'"
                          (regexp-quote name)))
        (case-fold-search t)
        (depth 1)
        (found nil))
    (while (and (< cursor end) (not found))
      (let ((cur (aref lines cursor)))
        (cond
         ((and (not verbatim) (string-match-p open-re cur))
          (cl-incf depth))
         ((string-match-p close-re cur)
          (cl-decf depth)
          (when (zerop depth)
            (setq found cursor)))))
      (cl-incf cursor))
    found))

(defun etaf-org--block-content (ctx index end-index begin-indent)
  "Return block content lines between INDEX and END-INDEX stripped by BEGIN-INDENT."
  (let* ((lines (etaf-org-ctx-lines ctx))
         (result nil))
    (cl-loop for cursor from (1+ index) below end-index
             do (push (etaf-org--strip-columns (aref lines cursor) begin-indent)
                      result))
    (nreverse result)))

(defun etaf-org--parse-src-header (argument)
  "Parse `#+begin_src LANG SWITCHES :key val ...' ARGUMENT.
Return plist `(:lang :switches :header-args)'."
  (let* ((str (string-trim (or argument "")))
         (pos 0)
         (len (length str))
         (lang nil)
         (switches nil)
         (header-text ""))
    (when (string-match "\\`\\([^ \t]+\\)" str)
      (setq lang (downcase (match-string 1 str))
            pos (match-end 0)))
    (while (and (< pos len) (memq (aref str pos) '(?\s ?\t)))
      (cl-incf pos))
    ;; Consume switches (`-n', `+n', `-n 20', `-r', `-i', `-k') before `:key'.
    (while (and (< pos len)
                (memq (aref str pos) '(?- ?+)))
      (let ((start pos))
        (while (and (< pos len) (not (memq (aref str pos) '(?\s ?\t))))
          (cl-incf pos))
        (let ((tok (substring str start pos)))
          (push tok switches)
          (while (and (< pos len) (memq (aref str pos) '(?\s ?\t)))
            (cl-incf pos))
          (when (and (member tok '("-n" "+n"))
                     (< pos len)
                     (string-match "\\`\\([0-9]+\\)" (substring str pos)))
            (push (match-string 1 (substring str pos)) switches)
            (setq pos (+ pos (match-end 0)))
            (while (and (< pos len) (memq (aref str pos) '(?\s ?\t)))
              (cl-incf pos))))))
    (when (< pos len)
      (setq header-text (substring str pos)))
    (list :lang (unless (or (null lang) (string-empty-p lang)) lang)
          :switches (string-join (nreverse switches) " ")
          :header-args (car (etaf-org--parse-plist-string header-text)))))

(defun etaf-org--read-results-block (ctx index name)
  "Read `#+RESULTS:' at INDEX with NAME in CTX.
Supports fixed-width, table, list, src/example, drawer and paragraph bodies."
  (let* ((lines (etaf-org-ctx-lines ctx))
         (end (etaf-org-ctx-end ctx))
         (cursor (1+ index)))
    (while (and (< cursor end) (etaf-org--blank-line-p (aref lines cursor)))
      (cl-incf cursor))
    (if (>= cursor end)
        (cons (list :type 'results :name name :text "") cursor)
      (let ((next-line (aref lines cursor)))
        (cond
         ;; Drawer :RESULTS: ... :END:
         ((string-match-p "\\`[ \t]*:RESULTS:[ \t]*\\'" next-line)
          (let* ((res (etaf-org--read-drawer ctx cursor))
                 (drawer (car res)))
            (cons (list :type 'results :name name
                        :text (or (plist-get drawer :text) ""))
                  (cdr res))))
         ;; Table result
         ((string-match-p "\\`[ \t]*|" next-line)
          (let ((res (etaf-org--read-table ctx cursor)))
            (cons (list :type 'results :name name :body-block (car res))
                  (cdr res))))
         ;; Block result (#+begin_example / #+begin_src / etc.)
         ((string-match-p etaf-org--begin-regexp next-line)
          (let ((res (etaf-org--read-directive ctx cursor)))
            (cons (list :type 'results :name name :body-block (car res))
                  (cdr res))))
         ;; Fixed-width `: ' lines
         ((string-match-p "\\`[ \t]*:" next-line)
          (let ((res (etaf-org--read-fixed-width ctx cursor)))
            (cons (list :type 'results :name name
                        :text (or (plist-get (car res) :text) ""))
                  (cdr res))))
         ;; Lone image/file link result `[[file:...]]'
         ((string-match-p "\\`[ \t]*\\[\\[" next-line)
          (let ((res (etaf-org--read-paragraph ctx cursor)))
            (cons (list :type 'results :name name :body-block (car res))
                  (cdr res))))
         (t
          (cons (list :type 'results :name name :text "") (1+ index))))))))

(defun etaf-org--read-directive (ctx index)
  "Read a `#+` directive or block starting at INDEX in CTX."
  (let* ((lines (etaf-org-ctx-lines ctx))
         (end (etaf-org-ctx-end ctx))
         (line (aref lines index))
         (case-fold-search t))
    (cond
     ;; Container blocks: #+BEGIN_NAME ... #+END_NAME.
     ((string-match etaf-org--begin-regexp line)
      (etaf-org--read-container ctx index
                                (upcase (match-string 2 line))
                                (match-string 3 line)))
     ;; Dynamic block: #+BEGIN: name :args ... #+END:
     ((string-match "\\`[ \t]*#\\+BEGIN:[ \t]*\\([^ \t]+\\)\\(?:[ \t]+\\(.*\\)\\)?\\'" line)
      (let* ((name (downcase (match-string 1 line)))
             (raw-args (string-trim (or (match-string 2 line) "")))
             (parsed-args (etaf-org--parse-plist-string raw-args))
             (cursor (1+ index))
             (closed nil)
             (content nil))
        (while (and (< cursor end) (not closed))
          (if (string-match-p "\\`[ \t]*#\\+END:[ \t]*\\'" (aref lines cursor))
              (setq closed t)
            (push (aref lines cursor) content))
          (cl-incf cursor))
        (setq content (nreverse content))
        (let* ((sub-ctx (copy-etaf-org-ctx ctx))
               (vec (vconcat content))
               (inner-blocks (when content
                               (setf (etaf-org-ctx-lines sub-ctx) vec
                                     (etaf-org-ctx-end sub-ctx) (length vec)
                                     (etaf-org-ctx-line-offset sub-ctx)
                                     (+ (etaf-org-ctx-line-offset ctx) index 1))
                               (etaf-org--parse-blocks sub-ctx)))
               (known-dblock (or (member name '("clocktable" "columnview"))
                                 (and (etaf-org--feature-p ctx :dynamic-widgets)
                                      (etaf-org--definition-by-name name)))))
          (unless known-dblock
            (etaf-org--degrade ctx 'dynamic-block))
          (cons (list :type 'dynamic-block
                      :name name
                      :args raw-args
                      :attrs (car parsed-args)
                      :dup-attrs (cadr parsed-args)
                      :blocks inner-blocks
                      :text (string-join content "\n")
                      :source (string-join (cl-subseq (append lines nil)
                                                      index (min end cursor))
                                           "\n"))
                cursor))))
     ;; Inline TOC directive: #+TOC: headlines 2 | tables | listings
     ((string-match "\\`[ \t]*#\\+TOC:[ \t]*\\(.*\\)\\'" line)
      (let* ((raw (string-trim (match-string 1 line)))
             (parts (split-string raw "[ \t]+" t))
             (kind (downcase (or (car parts) "headlines")))
             (depth (and (nth 1 parts)
                         (string-match-p "\\`[0-9]+\\'" (nth 1 parts))
                         (string-to-number (nth 1 parts)))))
        (cons (list :type 'toc-directive :kind kind :depth depth :raw raw)
              (1+ index))))
     ;; #+PRINT_BIBLIOGRAPHY:
     ((string-match "\\`[ \t]*#\\+PRINT_BIBLIOGRAPHY:[ \t]*\\(.*\\)\\'" line)
      (cons (list :type 'print-bibliography
                  :args (string-trim (match-string 1 line)))
            (1+ index)))
     ((string-match "\\`[ \t]*#\\+TBLFM:[ \t]*\\(.*\\)\\'" line)
      (cons (list :type 'keyword :key "TBLFM" :value (match-string 1 line) :hidden t)
            (1+ index)))
     ((string-match "\\`[ \t]*#\\+\\(CAPTION\\|NAME\\|ATTR_[A-Za-z0-9_]+\\):[ \t]*\\(.*\\)\\'"
                    line)
      (cons (list :type 'keyword
                  :key (upcase (match-string 1 line))
                  :value (match-string 2 line))
            (1+ index)))
     ((string-match "\\`[ \t]*#\\+RESULTS\\(?:\\[[^]]*\\]\\)?:[ \t]*\\(.*\\)\\'" line)
      (etaf-org--read-results-block ctx index (string-trim (match-string 1 line))))
     ((string-match "\\`[ \t]*#\\+CALL:[ \t]*\\([^ \t(]+\\)\\(.*\\)\\'" line)
      (let ((cname (match-string 1 line))
            (cargs (match-string 2 line)))
        (cons (list :type 'babel-call
                    :name cname
                    :args (string-trim (or cargs "")))
              (1+ index))))
     ((string-match "\\`[ \t]*#\\+INCLUDE:[ \t]*\\(\"[^\"]+\"\\|[^ \t]+\\)\\(.*\\)\\'" line)
      (let* ((raw-target (match-string 1 line))
             (raw-args (match-string 2 line))
             (target (string-trim (or raw-target "") "\"" "\""))
             (args (string-trim (or raw-args ""))))
        (cons (list :type 'include-card :target target :args args)
              (1+ index))))
     ((string-match etaf-org--keyword-line-regexp line)
      (let ((kname (match-string 1 line))
            (kval (match-string 2 line)))
        (cons (list :type 'keyword
                    :key (upcase kname)
                    :value (string-trim (or kval ""))
                    :hidden t)
              (1+ index))))
     (t
      (etaf-org--degrade ctx 'directive)
      (cons (list :type 'paragraph :text line
                  :inlines (list (etaf-org--text-node line)))
            (1+ index))))))

(defun etaf-org--split-marker-children (ctx lines allowed-markers base-line)
  "Split LINES of a `:child-syntax markers' container by `#+<marker>:' lines.
Returns `(CHILDREN . ERRORS)'."
  (let ((allowed-names (mapcar (lambda (entry) (downcase (symbol-name (car entry))))
                               allowed-markers))
        (children nil)
        (errors nil)
        (cur-marker nil)
        (cur-attrs nil)
        (cur-line base-line)
        (cur-body nil)
        (line-idx 0)
        (in-code nil))
    (cl-labels
        ((flush-child ()
           (when cur-marker
             (let* ((body-lines (nreverse cur-body))
                    (sub-ctx (copy-etaf-org-ctx ctx))
                    (vec (vconcat body-lines)))
               (setf (etaf-org-ctx-lines sub-ctx) vec
                     (etaf-org-ctx-end sub-ctx) (length vec)
                     (etaf-org-ctx-line-offset sub-ctx) (1+ cur-line))
               (push (etaf-org-node-create
                      :type (intern cur-marker)
                      :attrs cur-attrs
                      :children (etaf-org--parse-blocks sub-ctx)
                      :line cur-line
                      :source (string-join body-lines "\n"))
                     children))
             (setq cur-marker nil cur-attrs nil cur-body nil))))
      (dolist (line lines)
        (let ((case-fold-search t))
          (cond
           ((string-match-p "\\`[ \t]*#\\+BEGIN_\\(SRC\\|EXAMPLE\\|EXPORT\\|COMMENT\\)" line)
            (setq in-code t)
            (if cur-marker (push line cur-body)
              (push (format "line %d: 第一个子块标记之前不能有正文"
                            (+ base-line line-idx))
                    errors)))
           ((and in-code
                 (string-match-p "\\`[ \t]*#\\+END_\\(SRC\\|EXAMPLE\\|EXPORT\\|COMMENT\\)" line))
            (setq in-code nil)
            (when cur-marker (push line cur-body)))
           ((and (not in-code)
                 (string-match "\\`[ \t]*#\\+\\([A-Za-z][A-Za-z0-9_-]*\\):[ \t]*\\(.*\\)\\'" line)
                 (member (downcase (match-string 1 line)) allowed-names))
            (let* ((mname (downcase (match-string 1 line)))
                   (raw-rest (or (match-string 2 line) "")))
              (flush-child)
              (let* ((rest (string-trim raw-rest))
                     (attrs (cond
                             ((string-empty-p rest) nil)
                             ((string-prefix-p ":" rest)
                              (car (etaf-org--parse-plist-string rest)))
                             (t (list :title rest)))))
                (setq cur-marker mname
                      cur-attrs attrs
                      cur-line (+ base-line line-idx)
                      cur-body nil))))
           ;; Also accept `@marker' as a gentle shorthand when inside markers container
           ((and (not in-code)
                 (string-match "\\`[ \t]*@\\([A-Za-z][A-Za-z0-9_-]*\\)\\(?:[ \t]+\\(.*\\)\\)?\\'" line)
                 (member (downcase (match-string 1 line)) allowed-names))
            (let* ((mname (downcase (match-string 1 line)))
                   (raw-rest (or (match-string 2 line) "")))
              (flush-child)
              (let* ((rest (string-trim raw-rest))
                     (attrs (cond
                             ((string-empty-p rest) nil)
                             ((string-prefix-p ":" rest)
                              (car (etaf-org--parse-plist-string rest)))
                             (t (list :title rest)))))
                (setq cur-marker mname
                      cur-attrs attrs
                      cur-line (+ base-line line-idx)
                      cur-body nil))))
           (t
            (if cur-marker
                (push line cur-body)
              (unless (string-blank-p line)
                (push (format "line %d: 第一个子块标记之前不能有正文"
                              (+ base-line line-idx))
                      errors))))))
        (cl-incf line-idx))
      (flush-child))
    (cons (nreverse children) (nreverse errors))))

(defun etaf-org--read-container (ctx index name argument)
  "Read `#+BEGIN_NAME ARGUMENT ... #+END_NAME' at INDEX in CTX."
  (let* ((lines (etaf-org-ctx-lines ctx))
         (end (etaf-org-ctx-end ctx))
         (verbatim (member name '("SRC" "EXAMPLE" "VERSE" "COMMENT" "EXPORT")))
         (found (etaf-org--find-block-end ctx index name verbatim))
         (end-index (or found end))
         (begin-indent (etaf-org--indent-columns (aref lines index)))
         (content (etaf-org--block-content ctx index end-index begin-indent))
         (next (if found (1+ found) end))
         (text (string-join content "\n"))
         (lno (+ (etaf-org-ctx-line-offset ctx) index))
         (raw-source (string-join (cl-subseq (append lines nil)
                                             index (min end next))
                                  "\n")))
    (unless (or found (etaf-org-ctx-live-p ctx))
      (etaf-org--degrade ctx 'unclosed-block))
    (cons
     (pcase name
       ("SRC"
        (let ((hdr (etaf-org--parse-src-header argument)))
          (list :type 'src-block
                :lang (plist-get hdr :lang)
                :switches (plist-get hdr :switches)
                :header-args (plist-get hdr :header-args)
                :text text
                :unclosed (not found))))
       ("EXAMPLE" (list :type 'example-block :text text :unclosed (not found)))
       ("QUOTE" (etaf-org--container-node ctx 'quote-block content nil lno))
       ("VERSE"
        (list :type 'verse-block
              :text text
              :lines (mapcar (lambda (ln)
                               (list :indent (etaf-org--indent-columns ln)
                                     :inlines (etaf-org--parse-inlines
                                               ctx (string-trim-left ln))))
                             content)))
       ("CENTER" (etaf-org--container-node ctx 'center-block content nil lno))
       ("COMMENT" (list :type 'comment-block :text text))
       ("EXPORT" (list :type 'export-block
                       :backend (string-trim (or argument ""))
                       :text text))
       (_
        (let* ((lname (downcase name))
               (parsed-args (etaf-org--parse-plist-string argument))
               (inline-attrs (car parsed-args))
               (dup-attrs (cadr parsed-args))
               (depth (1+ (etaf-org-ctx-nesting-depth ctx)))
               (def-entry (and (etaf-org--feature-p ctx :containers)
                               (etaf-org--definition-by-name lname)))
               (def (cdr def-entry))
               (errors nil))
          (when (> depth etaf-org--max-nesting-depth)
            (etaf-org--degrade ctx 'nesting-depth)
            (push (format "line %d: 第 %d 层嵌套超过上限 %d 层"
                          lno depth etaf-org--max-nesting-depth)
                  errors))
          (dolist (dup dup-attrs)
            (push (format "line %d: %s 的属性 %s 重复声明"
                          lno lname (substring (symbol-name dup) 1))
                  errors))
          (unless (or found (etaf-org-ctx-live-p ctx))
            (push (format "line %d: #+begin_%s 缺少闭合行 #+end_%s"
                          lno lname lname)
                  errors))
          (if (and def (eq (plist-get def :child-syntax) 'markers))
              (let* ((sub-ctx (copy-etaf-org-ctx ctx))
                     (_ (setf (etaf-org-ctx-nesting-depth sub-ctx) depth))
                     (split (etaf-org--split-marker-children
                             sub-ctx content (plist-get def :accepts) (1+ lno)))
                     (all-errs (append (nreverse errors) (cdr split))))
                (list :type 'special-block
                      :name lname
                      :node-type (car def-entry)
                      :inline-attrs inline-attrs
                      :children (car split)
                      :raw-content text
                      :source raw-source
                      :errors all-errs))
            (let* ((sub-ctx (copy-etaf-org-ctx ctx))
                   (_ (setf (etaf-org-ctx-nesting-depth sub-ctx) depth))
                   (node (etaf-org--container-node sub-ctx 'special-block
                                                   content lname lno)))
              (plist-put node :node-type (car def-entry))
              (plist-put node :inline-attrs inline-attrs)
              (plist-put node :raw-content text)
              (plist-put node :source raw-source)
              (plist-put node :errors (nreverse errors))
              node)))))
     next)))

(defun etaf-org--container-node (ctx type lines &optional name base-line)
  "Return a container block of TYPE parsing LINES in CTX."
  (let ((attribution nil)
        (attribution-inlines nil)
        (last (car (last lines))))
    (when (and (eq type 'quote-block) last
               (string-match "\\`[ \t]*--[ \t]+\\(.+\\)\\'" last))
      (setq attribution (string-trim (match-string 1 last))
            attribution-inlines (etaf-org--parse-inlines ctx attribution)
            lines (butlast lines)))
    (let* ((sub-ctx (copy-etaf-org-ctx ctx))
           (vector (vconcat lines)))
      (setf (etaf-org-ctx-lines sub-ctx) vector
            (etaf-org-ctx-end sub-ctx) (length vector)
            (etaf-org-ctx-line-offset sub-ctx) (1+ (or base-line 0)))
      (list :type type
            :name name
            :attribution attribution
            :attribution-inlines attribution-inlines
            :blocks (etaf-org--parse-blocks sub-ctx)))))

;;; ---------------------------------------------------------------------------
;;; Attachments, RESULTS pairing & Document assembly
;;; ---------------------------------------------------------------------------

(defun etaf-org--merge-plists (base override)
  "Return a new plist with OVERRIDE entries applied on top of BASE."
  (let ((out (copy-sequence base))
        (rest override))
    (while rest
      (let ((k (pop rest)) (v (pop rest)))
        (setq out (plist-put out k v))))
    out))

(defun etaf-org--apply-nested-attachments (ctx block)
  "Recursively apply attachments inside nested blocks of BLOCK."
  (when-let* ((children (plist-get block :blocks)))
    (setq block (plist-put block :blocks
                           (etaf-org--apply-attachments ctx children))))
  (when-let* ((items (plist-get block :items)))
    (setq block (plist-put block :items
                           (mapcar
                            (lambda (item)
                              (plist-put item :blocks
                                         (etaf-org--apply-attachments
                                          ctx (plist-get item :blocks))))
                            items))))
  block)

(defun etaf-org--apply-attachments (ctx blocks)
  "Attach CAPTION, NAME, ATTR_* keywords to next block and pair RESULTS to SRC."
  (let ((pending nil)
        (result nil))
    (dolist (block blocks)
      (if (eq (plist-get block :type) 'keyword)
          (let ((key (plist-get block :key))
                (value (plist-get block :value)))
            (cond
             ((equal key "ATTR_ETAF")
              (push (cons :etaf-attrs (etaf-org--parse-attributes value)) pending)
              (push (plist-put block :attached t) result))
             ((string-prefix-p "ATTR_" key)
              (push (cons :attrs (etaf-org--parse-attributes value)) pending)
              (push (plist-put block :attached t) result))
             ((equal key "CAPTION")
              (push (cons :caption value) pending)
              (push (plist-put block :attached t) result))
             ((equal key "NAME")
              (push (cons :block-name value) pending)
              (push (plist-put block :attached t) result))
             (t (push block result))))
        (let ((block (copy-sequence block))
              (etaf-attrs nil)
              (other-attrs nil))
          (dolist (entry (nreverse pending))
            (pcase (car entry)
              (:etaf-attrs (setq etaf-attrs (etaf-org--merge-plists etaf-attrs (cdr entry))))
              (:attrs (setq other-attrs (etaf-org--merge-plists other-attrs (cdr entry))))
              (:block-name (setq block (plist-put block :block-name (cdr entry))))
              (k (setq block (plist-put block k (cdr entry))))))
          ;; Merge affiliated attributes: inline-attrs > attr_etaf > other attr_*
          (let* ((merged (etaf-org--merge-plists
                          (etaf-org--merge-plists other-attrs etaf-attrs)
                          (plist-get block :inline-attrs))))
            (when merged
              (setq block (plist-put block :attrs merged)))
            (when etaf-attrs
              (setq block (plist-put block :etaf-attrs etaf-attrs))))
          (when-let* ((bname (or (plist-get block :block-name)
                                 (and (not (eq (plist-get block :type) 'special-block))
                                      (plist-get block :name)))))
            (puthash bname (etaf-org-ctx-current-section ctx)
                     (etaf-org-ctx-targets ctx)))
          (setq pending nil)
          (setq block (etaf-org--apply-nested-attachments ctx block))
          ;; Pair #+RESULTS: directly onto the preceding src-block when adjacent.
          (if (and (eq (plist-get block :type) 'results)
                   result
                   (eq (plist-get (car result) :type) 'src-block)
                   (or (string-empty-p (or (plist-get block :name) ""))
                       (equal (plist-get block :name)
                              (plist-get (car result) :block-name))))
              (setcar result (plist-put (copy-sequence (car result)) :results block))
            (push block result)))))
    (nreverse result)))

(defun etaf-org--apply-section-attachments (ctx sections)
  "Apply attachment keywords across every body in SECTIONS."
  (dolist (section sections)
    (setf (etaf-org-ctx-current-section ctx) section)
    (setf (etaf-org-section-body section)
          (etaf-org--apply-attachments ctx (etaf-org-section-body section)))
    (etaf-org--apply-section-attachments ctx (etaf-org-section-children section))))

(defun etaf-org--org-todo-keywords ()
  "Return keyword alist from Org's `org-todo-keywords' when Org is loaded.
In Org, a sequence without `|' treats its last string entry as a done state."
  (when (and (boundp 'org-todo-keywords) (consp org-todo-keywords))
    (let ((result nil))
      (dolist (sequence org-todo-keywords)
        (when (listp sequence)
          (let* ((strings (cl-remove-if-not #'stringp sequence))
                 (has-bar (member "|" strings))
                 (last-word (car (last strings)))
                 (done nil))
            (dolist (word strings)
              (if (equal word "|")
                  (setq done t)
                (let* ((name (if (string-match "\\`\\([^()]+\\)(" word)
                                 (match-string 1 word)
                               word))
                       (is-done (or done (and (not has-bar) (equal word last-word)))))
                  (unless (assoc name result)
                    (push (cons name (if is-done 'done 'active)) result))))))))
      (nreverse result))))

(defun etaf-org--lift-section-metadata (sections)
  "Lift leading `:PROPERTIES:' and `:LOGBOOK:' drawers into SECTIONS."
  (cl-labels ((walk (section)
                (let ((body (etaf-org-section-body section)))
                  (when (and body (eq (plist-get (car body) :type) 'property-drawer))
                    (setf (etaf-org-section-properties section)
                          (plist-get (car body) :properties))
                    (setf (etaf-org-section-body section) (cdr body))
                    (setq body (cdr body)))
                  (when (and body (eq (plist-get (car body) :type) 'drawer)
                             (equal (plist-get (car body) :name) "LOGBOOK"))
                    (setf (etaf-org-section-logbook section)
                          (plist-get (car body) :clock))
                    (setf (etaf-org-section-logbook-notes section)
                          (plist-get (car body) :notes))
                    (setf (etaf-org-section-logbook-text section)
                          (plist-get (car body) :text))
                    (setf (etaf-org-section-body section) (cdr body))))
                (when (or (member "ARCHIVE" (etaf-org-section-tags section))
                          (equal (cdr (assoc "ARCHIVE" (etaf-org-section-properties
                                                        section)))
                                 "true"))
                  (setf (etaf-org-section-archived section) t))
                (dolist (child (etaf-org-section-children section))
                  (walk child))))
    (dolist (section sections) (walk section))))

(defun etaf-org--count-blocks (sections preamble)
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
                  (walk (etaf-org-section-body section))
                  (dolist (child (etaf-org-section-children section))
                    (walk-section child))))
      (dolist (section sections) (walk-section section)))
    count))

(defun etaf-org--degraded-total (ctx)
  "Return the total degraded construct count in CTX."
  (let ((total 0))
    (maphash (lambda (_type count) (cl-incf total count))
             (etaf-org-ctx-degraded ctx))
    total))

(defun etaf-org--degraded-types (ctx)
  "Return degradation counts of CTX as a sorted list of `(TYPE . COUNT)'."
  (let (result)
    (maphash (lambda (type count) (push (cons type count) result))
             (etaf-org-ctx-degraded ctx))
    (sort result (lambda (a b) (string< (symbol-name (car a))
                                        (symbol-name (car b)))))))

(defun etaf-org--footnote-list (ctx)
  "Return CTX's footnotes as a list of plists in numbering order."
  (let* ((registry (etaf-org-ctx-footnotes ctx))
         (order (reverse (etaf-org-footnotes-order registry)))
         (entries (etaf-org-footnotes-entries registry))
         (result nil))
    (dolist (label order)
      (when-let* ((entry (gethash label entries)))
        (unless (or (plist-get entry :inlines) (plist-get entry :blocks))
          (plist-put entry :inlines (list (etaf-org--text-node
                                           (format "（脚注 %s 没有定义）" label)))))
        (push entry result)))
    (nreverse result)))

(cl-defun etaf-org--parse-body-slice (text &key file flavor todo-keywords options macros
                                           link-abbrevs line-offset live-p)
  "Parse an isolated Org body slice TEXT (no headlines) for O(Δ) live edits."
  (let* ((lines (etaf-org--split-lines text))
         (features (etaf-org--resolve-flavor flavor))
         (ctx (etaf-org--make-ctx
               :lines lines
               :end (length lines)
               :line-offset (or line-offset 1)
               :source-file file
               :flavor (or flavor etaf-org-flavor 'etaf)
               :features features
               :live-p live-p
               :todo-keywords (or todo-keywords etaf-org--default-todo-keywords)
               :options (or options (etaf-org--default-options))
               :macros macros
               :link-abbrevs link-abbrevs)))
    (etaf-org--apply-attachments ctx (etaf-org--parse-blocks ctx))))

(cl-defun etaf-org--parse (text &key file startup flavor setup-lines live-p)
  "Parse Org TEXT into a pure document plist.
FILE names the source path; STARTUP sets fallback startup fold; FLAVOR
overrides `#+ETAF_FLAVOR:' and `etaf-org-flavor'; SETUP-LINES injects
pre-loaded `#+SETUPFILE:' lines (read outside `:render'); LIVE-P enables
provisional closing of unclosed blocks while typing."
  (let* ((lines (etaf-org--split-lines text))
         (ctx (etaf-org--make-ctx
               :lines lines :end (length lines) :source-file file
               :live-p live-p))
         (sections nil)
         (preamble nil)
         (stack nil))
    (etaf-org--scan-settings ctx setup-lines)
    (let* ((opts (or (etaf-org-ctx-options ctx) (etaf-org--default-options)))
           (effective-flavor
            (cond
             (flavor flavor)
             ((not (plist-get opts :etaf)) 'standard)
             (t (or (etaf-org-ctx-flavor ctx) etaf-org-flavor 'etaf)))))
      (setf (etaf-org-ctx-options ctx) opts
            (etaf-org-ctx-flavor ctx) effective-flavor
            (etaf-org-ctx-features ctx) (etaf-org--resolve-flavor effective-flavor)))
    (unless (etaf-org-ctx-todo-keywords ctx)
      (setf (etaf-org-ctx-todo-keywords ctx)
            (or (etaf-org--org-todo-keywords)
                etaf-org--default-todo-keywords)))
    (let ((index 0)
          (end (etaf-org-ctx-end ctx)))
      (while (< index end)
        (let ((line (aref lines index)))
          (cond
           ((etaf-org--blank-line-p line)
            (cl-incf index))
           ((etaf-org--headline-line-p line)
            (let* ((level (etaf-org--headline-level line))
                   (section (etaf-org--parse-headline ctx index)))
              (cl-incf index)
              (while (and (< index end)
                          (etaf-org--planning-line-p (aref lines index)))
                (setf (etaf-org-section-planning section)
                      (append (etaf-org--parse-planning ctx (aref lines index))
                              (etaf-org-section-planning section)))
                (cl-incf index))
              (setf (etaf-org-ctx-current-section ctx) section)
              (while (and stack (>= (etaf-org-section-level (car stack)) level))
                (let ((popped (pop stack)))
                  (setf (etaf-org-section-line-end popped) index)))
              (if stack
                  (push section (etaf-org-section-children (car stack)))
                (push section sections))
              (push section stack)))
           (t
            (let* ((result (etaf-org--read-block ctx index))
                   (block (car result))
                   (next (max (cdr result) (1+ index))))
              (when block
                (setq block (plist-put (plist-put block :line-start (1+ index))
                                       :line-end next))
                (if stack
                    (push block (etaf-org-section-body (car stack)))
                  (push block preamble)))
              (setq index next))))))
      (while stack
        (setf (etaf-org-section-line-end (pop stack)) end)))
    (setq sections (nreverse sections))
    (dolist (section sections)
      (cl-labels ((reverse-body (node)
                    (setf (etaf-org-section-body node)
                          (nreverse (etaf-org-section-body node)))
                    (setf (etaf-org-section-children node)
                          (nreverse (etaf-org-section-children node)))
                    (dolist (child (etaf-org-section-children node))
                      (reverse-body child))))
        (reverse-body section)))
    (etaf-org--lift-section-metadata sections)
    (etaf-org--apply-section-attachments ctx sections)
    (setq preamble (etaf-org--apply-attachments ctx (nreverse preamble)))
    (let* ((footnotes (etaf-org--footnote-list ctx))
           (degraded (etaf-org--degraded-total ctx))
           (options (or (etaf-org-ctx-options ctx) (etaf-org--default-options)))
           (blocks (etaf-org--count-blocks sections preamble)))
      (list :type 'document
            :title (etaf-org-ctx-title ctx)
            :subtitle (etaf-org-ctx-subtitle ctx)
            :author (etaf-org-ctx-author ctx)
            :date (etaf-org-ctx-date ctx)
            :email (etaf-org-ctx-email ctx)
            :language (etaf-org-ctx-language ctx)
            :keywords (etaf-org-ctx-keywords ctx)
            :description (etaf-org-ctx-description ctx)
            :filetags (etaf-org-ctx-filetags ctx)
            :options options
            :flavor (etaf-org-ctx-flavor ctx)
            :features (etaf-org-ctx-features ctx)
            :contract (etaf-org-ctx-contract ctx)
            :startup (or (and (not (eq (etaf-org-ctx-startup ctx) 'content))
                              (etaf-org-ctx-startup ctx))
                         startup
                         'content)
            :todo-keywords (etaf-org-ctx-todo-keywords ctx)
            :priorities (etaf-org-ctx-priorities ctx)
            :macros (etaf-org-ctx-macros ctx)
            :link-abbrevs (etaf-org-ctx-link-abbrevs ctx)
            :abbreviations (etaf-org-ctx-abbreviations ctx)
            :bibliographies (nreverse (etaf-org-ctx-bibliographies ctx))
            :setupfiles (nreverse (etaf-org-ctx-setupfiles ctx))
            :citations (nreverse (copy-sequence (car (etaf-org-ctx-citations ctx))))
            :sections sections
            :preamble preamble
            :targets (etaf-org-ctx-targets ctx)
            :footnotes footnotes
            :degraded degraded
            :degraded-types (etaf-org--degraded-types ctx)
            :blocks blocks
            :line-count (length lines)
            :chars (length text)
            :file file))))

(provide 'etaf-org-parse)
;;; etaf-org-parse.el ends here
