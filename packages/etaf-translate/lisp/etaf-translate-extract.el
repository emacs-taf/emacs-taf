;;; etaf-translate-extract.el --- Host tree extraction and inline run codec -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Walks the read-only committed Host tree returned by `etaf-runtime-host-tree'
;; and produces logical Translation Units.  Adjacent inline text runs inside a
;; paragraph `box' are grouped into a single unit with lightweight markup tags
;; (`<1>...</1>') for styled/interactive runs and atomic placeholders (`⟦c0⟧')
;; for inline code, keyboard shortcuts and footnotes.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'etaf-translate-core)

;;;; Data structures

(cl-defstruct (etaf-translate-run (:constructor etaf-translate-run--make))
  "One inline run captured from a paragraph Host."
  id          ; integer tag index (1, 2, ...) or nil for plain/base run
  host-id     ; original Host ID (for press forwarding on links)
  text        ; original text string
  props       ; original sanitized style/semantic props
  atomic-p    ; non-nil when preserved verbatim via ⟦cN⟧ placeholder
  token)      ; placeholder string \"⟦cN⟧\" when atomic

(cl-defstruct (etaf-translate-unit (:constructor etaf-translate-unit--make))
  "One logical translatable unit extracted from a committed ETAF Host tree."
  host-id       ; target Host ID for presentation attachment
  host-tag      ; 'box | 'text | ...
  parent-tag    ; enclosing Host tag ('column | 'grid | 'flex | 'box | nil)
  kind          ; 'paragraph | 'heading | 'cell | 'text
  source-text   ; joined plain text (used for language/meaningfulness filters)
  markup-text   ; text sent to the translation engine (with <N> and ⟦cN⟧)
  source-hash   ; stable hash over markup-text + inline structure
  base-props    ; common style props shared by every run in this unit
  runs          ; alist of (TAG-ID . etaf-translate-run)
  atoms         ; alist of (TOKEN . etaf-translate-run)
  props         ; sanitized props of the target Host
  geometry      ; (:x X :y Y :width W :height H) or nil
  constrained-p ; non-nil when fixed single-line height + overflow hidden
  has-chrome-p) ; non-nil when target box carries borders, fill or padding

(defun etaf-translate-make-unit (&rest args)
  "Create a public translation unit from keyword ARGS for custom providers.
Required keys: `:id' (integer or stable key) and `:text' (string).
Optional keys: `:markup' (string, defaults to `:text'), `:kind' (default
`paragraph'), `:geometry' and `:constrained'."
  (let* ((id (plist-get args :id))
         (text (plist-get args :text))
         (markup (or (plist-get args :markup) text))
         (kind (or (plist-get args :kind) 'paragraph)))
    (unless (and id (stringp text))
      (signal 'etaf-translate-error
              (list "Translation unit requires :id and string :text" args)))
    (etaf-translate-unit--make
     :host-id id
     :host-tag 'box
     :kind kind
     :source-text text
     :markup-text markup
     :source-hash (etaf-translate-text-hash markup)
     :geometry (plist-get args :geometry)
     :constrained-p (plist-get args :constrained))))

;;;; Heuristics

(defconst etaf-translate--chrome-roles
  '(button tab menuitem switch checkbox radio slider textbox searchbox
    toolbar navigation menubar tablist statusbar progressbar separator
    scrollbar spinbutton combobox listbox option)
  "Host `:role' symbols excluded by default in `content' scope.")

(defconst etaf-translate--chrome-classes
  '("etaf-tag" "etaf-badge" "etaf-kbd" "etaf-breadcrumb" "etaf-toolbar"
    "etaf-status-bar")
  "Host `:class' names excluded by default in `content' scope.")

(defconst etaf-translate--mono-family-re
  "\\(?:mono\\|courier\\|consolas\\|menlo\\|monaco\\|fira code\\|jetbrains\\|iosevka\\|pragmata\\|hack\\|source code\\|fixed\\)"
  "Regexp matching monospace font family names.")

(defconst etaf-translate--inline-style-keys
  '(:font-weight :font-style :text-decoration-line :color :background-color
    :font-family :font-size :role :tab-index :pointer :help-echo :has-on-press)
  "Inline text properties preserved when reconstructing translated runs.")

(defun etaf-translate--role-symbol (role)
  "Normalize Host `:role' value ROLE into a symbol, or nil."
  (cond ((symbolp role) role)
        ((stringp role) (intern (downcase role)))
        (t nil)))

(defun etaf-translate--node-classes (props)
  "Return the list of class name strings declared in PROPS."
  (let ((cls (plist-get props :class)))
    (cond
     ((null cls) nil)
     ((stringp cls) (split-string cls "[ \t]+" t))
     ((symbolp cls) (list (symbol-name cls)))
     ((listp cls)
      (mapcar (lambda (c) (if (symbolp c) (symbol-name c) (format "%s" c))) cls))
     (t nil))))

(defun etaf-translate--monospace-p (props)
  "Return non-nil when PROPS explicitly specify a monospace font family."
  (let ((family (plist-get props :font-family)))
    (and (stringp family)
         (let ((case-fold-search t))
           (string-match-p etaf-translate--mono-family-re family)))))

(defun etaf-translate--single-line-constrained-p (props)
  "Return non-nil when PROPS pin height to 1 line with hidden overflow."
  (let ((h (plist-get props :height))
        (ov (plist-get props :overflow)))
    (and (eq ov 'hidden)
         (consp h)
         (eq (car h) 'lh)
         (numberp (cadr h))
         (<= (cadr h) 1.2))))

(defun etaf-translate--box-has-chrome-p (props)
  "Return non-nil when box PROPS paint borders, background fill or padding."
  (cl-some (lambda (k) (plist-get props k))
           '(:border :border-top :border-right :border-bottom :border-left
             :background-color :padding :padding-left :padding-right
             :padding-top :padding-bottom)))

(defun etaf-translate--inline-only-box-p (node)
  "Return non-nil when NODE is a `box' whose non-empty children are all `text'."
  (and (eq (plist-get node :tag) 'box)
       (let ((kids (plist-get node :children)))
         (and kids
              (cl-every (lambda (kid) (eq (plist-get kid :tag) 'text)) kids)))))

(defun etaf-translate--code-block-p (node)
  "Return non-nil when container NODE appears to be a code or raw-HTML block."
  (let* ((props (plist-get node :props))
         (wrap (plist-get props :wrap-mode))
         (kids (plist-get node :children)))
    (or (eq wrap 'char)
        (etaf-translate--monospace-p props)
        (and kids
             (cl-every (lambda (kid)
                         (and (eq (plist-get kid :tag) 'text)
                              (etaf-translate--monospace-p (plist-get kid :props))))
                       kids)))))

(defun etaf-translate--atomic-run-p (text-node)
  "Return non-nil when inline TEXT-NODE should be kept verbatim as `⟦cN⟧'."
  (let* ((props (plist-get text-node :props))
         (text (or (plist-get text-node :text) ""))
         (trimmed (string-trim text))
         (role (etaf-translate--role-symbol (plist-get props :role))))
    (or (eq (plist-get props :translate) 'no)
        ;; Inline code span (monospace or tinted fill without being a link).
        (etaf-translate--monospace-p props)
        (and (plist-get props :background-color)
             (not (eq role 'link))
             (<= (length trimmed) 64))
        ;; Footnote markers like "[1]".
        (and (eq role 'link)
             (string-match-p "\\`\\[[0-9A-Za-z_-]+\\]\\'" trimmed))
        ;; Pure technical symbol or URL link where label == URL.
        (and (not (string-empty-p trimmed))
             (string-match-p etaf-translate--url-or-path-re trimmed)))))

(defun etaf-translate--run-style-subset (props)
  "Extract the relevant inline style/interaction subset from PROPS."
  (let (out)
    (dolist (key etaf-translate--inline-style-keys)
      (when (plist-member props key)
        (let ((val (plist-get props key)))
          (when val
            (push key out)
            (push val out)))))
    (nreverse out)))

(defun etaf-translate--common-run-props (run-prop-lists)
  "Return the key/value pairs identical across every plist in RUN-PROP-LISTS.
Excludes `:has-on-press' and `:role' `link' so links always stay tagged."
  (when run-prop-lists
    (let ((first (car run-prop-lists))
          (rest (cdr run-prop-lists))
          common)
      (cl-loop for (k v) on first by #'cddr
               unless (or (eq k :has-on-press)
                          (and (eq k :role)
                               (eq (etaf-translate--role-symbol v) 'link)))
               when (cl-every (lambda (pl) (equal (plist-get pl k) v)) rest)
               do (push k common) (push v common))
      (nreverse common))))

(defun etaf-translate--diff-props (props base)
  "Return entries of PROPS that differ from BASE."
  (let (diff)
    (cl-loop for (k v) on props by #'cddr
             unless (equal (plist-get base k) v)
             do (push k diff) (push v diff))
    (nreverse diff)))

(defconst etaf-translate--latex-math-re
  (concat
   "\\$\\$\\(?:[^$]\\|\\\\.\\)+?\\$\\$"
   "\\|\\\\\\[\\(?:.\\|\n\\)+?\\\\\\]"
   "\\|\\\\(\\(?:.\\|\n\\)+?\\\\)"
   "\\|\\$\\([^ \t\n$]\\(?:[^$\n]*[^ \t\n$]\\)?\\)\\$")
  "Regexp matching LaTeX display (`$$...$$', `\\[...\\]') and inline math.")

(defconst etaf-translate--math-symbol-re
  "[\\\\^_={}+*/<>|~±×÷≤≥≠≈∑∫∞α-ωΑ-Ω]"
  "Regexp matching mathematical operators or Greek letters inside `$...$'.")

(defun etaf-translate--valid-inline-dollar-math-p (text start inner)
  "Return non-nil when `$INNER$' at START in TEXT looks like LaTeX math.
Rejects currency phrases such as \"costs $100 and $200\" while preserving
single-variable formulas (`$x$', `$n$') and equations (`$E = mc^2$')."
  (let ((prev (and (> start 0) (aref text (1- start)))))
    (and (not (and prev (or (eq prev ?\\) (<= ?0 prev ?9)
                            (<= ?a prev ?z) (<= ?A prev ?Z))))
         (not (string-match-p "\\`[0-9][0-9,.]*\\'" inner))
         (or (not (string-match-p "[ \t]" inner))
             (string-match-p etaf-translate--math-symbol-re inner)))))

(defun etaf-translate--split-math-chunks (text)
  "Split TEXT into `(IS-MATH . SUBSTRING)' chunks preserving LaTeX formulas."
  (if (or (not (stringp text))
          (not (or (string-search "$" text) (string-search "\\(" text)
                   (string-search "\\[" text))))
      (list (cons nil text))
    (let ((chunks nil)
          (pos 0)
          (len (length text)))
      (save-match-data
        (while (< pos len)
          (if (string-match etaf-translate--latex-math-re text pos)
              (let ((m0 (match-beginning 0))
                    (m1 (match-end 0))
                    (full (match-string 0 text))
                    (dollar-inner (match-string 1 text)))
                (if (and dollar-inner
                         (not (etaf-translate--valid-inline-dollar-math-p
                               text m0 dollar-inner)))
                    (progn
                      (push (cons nil (substring text pos (1+ m0))) chunks)
                      (setq pos (1+ m0)))
                  (when (> m0 pos)
                    (push (cons nil (substring text pos m0)) chunks))
                  (push (cons t full) chunks)
                  (setq pos m1)))
            (push (cons nil (substring text pos)) chunks)
            (setq pos len))))
      ;; Merge adjacent plain chunks produced after skipped `$'.
      (let ((merged nil))
        (dolist (c (nreverse chunks))
          (if (and merged (null (car c)) (null (caar merged)))
              (setcdr (car merged) (concat (cdar merged) (cdr c)))
            (push c merged)))
        (nreverse merged)))))

(defun etaf-translate--heading-p (node kids)
  "Return non-nil when NODE with inline KIDS looks like a heading."
  (let ((props (plist-get node :props)))
    (or (eq (etaf-translate--role-symbol (plist-get props :role)) 'heading)
        (and kids
             (cl-every (lambda (kid)
                         (let ((kp (plist-get kid :props)))
                           (or (eq (plist-get kp :font-weight) 'bold)
                               (and (numberp (plist-get kp :font-size))
                                    (> (plist-get kp :font-size) 1.0)))))
                       kids)))))

;;;; Paragraph serialization

(defun etaf-translate--build-box-unit (node parent-tag policy)
  "Construct an `etaf-translate-unit' for inline-only `box' NODE, or nil."
  (let* ((kids (plist-get node :children))
         (props (plist-get node :props))
         (non-atomic-styles
          (cl-loop for kid in kids
                   for ktext = (or (plist-get kid :text) "")
                   unless (or (string-blank-p ktext)
                              (etaf-translate--atomic-run-p kid))
                   collect (etaf-translate--run-style-subset
                            (plist-get kid :props))))
         (base (etaf-translate--common-run-props non-atomic-styles))
         (plain-parts nil)
         (markup-parts nil)
         (runs-alist nil)
         (atoms-alist nil)
         (next-tag 0)
         (next-atom 0)
         (translatable-chars 0))
    (dolist (kid kids)
      (let* ((text (or (plist-get kid :text) ""))
             (kprops (etaf-translate--run-style-subset (plist-get kid :props)))
             (kid-id (plist-get kid :id)))
        (push text plain-parts)
        (cond
         ((string-empty-p text) nil)
         ((string-blank-p text)
          (push text markup-parts))
         ((etaf-translate--atomic-run-p kid)
          (let* ((token (format "⟦c%d⟧" next-atom))
                 (run (etaf-translate-run--make
                       :host-id kid-id :text text :props kprops
                       :atomic-p t :token token)))
            (cl-incf next-atom)
            (push (cons token run) atoms-alist)
            (push token markup-parts)))
         (t
          (let* ((diff (etaf-translate--diff-props kprops base))
                 (chunks (etaf-translate--split-math-chunks text))
                 (has-math (cl-some #'car chunks)))
            (cond
             ((and (not has-math) diff)
              (cl-incf translatable-chars (length (string-trim text)))
              (let* ((tag-id (cl-incf next-tag))
                     (run (etaf-translate-run--make
                           :id tag-id :host-id kid-id :text text :props kprops)))
                (push (cons tag-id run) runs-alist)
                (push (format "<%d>%s</%d>" tag-id text tag-id) markup-parts)))
             ((not has-math)
              (cl-incf translatable-chars (length (string-trim text)))
              (push text markup-parts))
             (t
              (let ((inner-parts nil))
                (dolist (ch chunks)
                  (if (car ch)
                      (let* ((token (format "⟦c%d⟧" next-atom))
                             (run (etaf-translate-run--make
                                   :host-id kid-id :text (cdr ch) :props kprops
                                   :atomic-p t :token token)))
                        (cl-incf next-atom)
                        (push (cons token run) atoms-alist)
                        (push token inner-parts))
                    (cl-incf translatable-chars (length (string-trim (cdr ch))))
                    (push (cdr ch) inner-parts)))
                (let ((joined (apply #'concat (nreverse inner-parts))))
                  (if diff
                      (let* ((tag-id (cl-incf next-tag))
                             (run (etaf-translate-run--make
                                   :id tag-id :host-id kid-id :text text :props kprops)))
                        (push (cons tag-id run) runs-alist)
                        (push (format "<%d>%s</%d>" tag-id joined tag-id) markup-parts))
                    (push joined markup-parts)))))))))))
    (let* ((plain (apply #'concat (nreverse plain-parts)))
           (markup (apply #'concat (nreverse markup-parts)))
           (target-lang (plist-get policy :target-lang)))
      (when (and (> translatable-chars 0)
                 (etaf-translate-text-meaningful-p plain)
                 (not (etaf-translate-text-matches-target-p plain target-lang)))
        (let ((kind (cond
                     ((eq parent-tag 'grid) 'cell)
                     ((etaf-translate--heading-p node kids) 'heading)
                     (t 'paragraph))))
          (etaf-translate-unit--make
           :host-id (plist-get node :id)
           :host-tag 'box
           :parent-tag parent-tag
           :kind kind
           :source-text plain
           :markup-text markup
           :source-hash (etaf-translate-text-hash markup)
           :base-props base
           :runs (nreverse runs-alist)
           :atoms (nreverse atoms-alist)
           :props props
           :geometry (plist-get node :geometry)
           :constrained-p (etaf-translate--single-line-constrained-p props)
           :has-chrome-p (etaf-translate--box-has-chrome-p props)))))))

(defun etaf-translate--build-text-unit (node parent-tag parent-props policy)
  "Construct an `etaf-translate-unit' for standalone `text' NODE, or nil."
  (let* ((text (or (plist-get node :text) ""))
         (props (plist-get node :props))
         (target-lang (plist-get policy :target-lang)))
    (when (and (not (etaf-translate--atomic-run-p node))
               (etaf-translate-text-meaningful-p text)
               (not (etaf-translate-text-matches-target-p text target-lang)))
      (let* ((style (etaf-translate--run-style-subset props))
             (constrained (or (etaf-translate--single-line-constrained-p props)
                              (etaf-translate--single-line-constrained-p parent-props)))
             (chunks (etaf-translate--split-math-chunks text))
             (atoms-alist nil)
             (next-atom 0)
             (markup-parts nil))
        (dolist (ch chunks)
          (if (car ch)
              (let* ((token (format "⟦c%d⟧" next-atom))
                     (run (etaf-translate-run--make
                           :host-id (plist-get node :id) :text (cdr ch)
                           :props style :atomic-p t :token token)))
                (cl-incf next-atom)
                (push (cons token run) atoms-alist)
                (push token markup-parts))
            (push (cdr ch) markup-parts)))
        (let ((markup (apply #'concat (nreverse markup-parts))))
          (etaf-translate-unit--make
           :host-id (plist-get node :id)
           :host-tag 'text
           :parent-tag parent-tag
           :kind 'text
           :source-text text
           :markup-text markup
           :source-hash (etaf-translate-text-hash markup)
           :base-props style
           :runs nil
           :atoms (nreverse atoms-alist)
           :props props
           :geometry (plist-get node :geometry)
           :constrained-p constrained
           :has-chrome-p nil))))))

(defun etaf-translate-extract-title (host-tree)
  "Return the first heading's text from HOST-TREE for LLM context, or nil."
  (cl-labels
      ((collect-text (node)
         (if (eq (plist-get node :tag) 'text)
             (or (plist-get node :text) "")
           (mapconcat #'collect-text (plist-get node :children) "")))
       (find-heading (nodes)
         (cl-loop for node in nodes
                  for props = (plist-get node :props)
                  for kids = (plist-get node :children)
                  for hit = (cond
                             ((eq (plist-get props :translate) 'no) nil)
                             ((and (etaf-translate--inline-only-box-p node)
                                   (etaf-translate--heading-p node kids))
                              (let ((txt (string-trim (collect-text node))))
                                (when (and (> (length txt) 1) (<= (length txt) 160))
                                  txt)))
                             (t (find-heading kids)))
                  when hit return hit)))
    (find-heading host-tree)))

;;;; Tree extraction entry point

(defun etaf-translate--excluded-node-p (node scope exclude-roles exclude-classes)
  "Return non-nil when NODE and its subtree should be skipped under SCOPE."
  (let* ((props (plist-get node :props))
         (hint (plist-get props :translate))
         (role (etaf-translate--role-symbol (plist-get props :role)))
         (classes (etaf-translate--node-classes props)))
    (or (eq hint 'no)
        (and role (memq role exclude-roles))
        (and (eq scope 'content)
             role
             (memq role etaf-translate--chrome-roles))
        (and (eq scope 'content)
             (cl-some (lambda (c) (member c etaf-translate--chrome-classes)) classes))
        (and exclude-classes
             (cl-some (lambda (c) (member c exclude-classes)) classes))
        (and (eq scope 'content)
             (eq (plist-get node :tag) 'box)
             (etaf-translate--code-block-p node)))))

(defun etaf-translate-extract-units (host-tree policy)
  "Extract an ordered list of `etaf-translate-unit' structs from HOST-TREE.
POLICY is the resolved plist from `etaf-translate-resolve-policy'."
  (let* ((scope (or (plist-get policy :scope) 'content))
         (exclude-roles (plist-get policy :exclude-roles))
         (exclude-classes (plist-get policy :exclude-classes))
         (units nil))
    (cl-labels
        ((walk (nodes parent-tag parent-props inherited-hint)
           (dolist (node nodes)
             (let* ((props (plist-get node :props))
                    (hint (or (plist-get props :translate) inherited-hint))
                    (tag (plist-get node :tag)))
               (unless (or (eq hint 'no)
                           (and (not (memq hint '(t yes content)))
                                (etaf-translate--excluded-node-p
                                 node scope exclude-roles exclude-classes)))
                 (cond
                  ((eq tag 'image) nil)
                  ((etaf-translate--inline-only-box-p node)
                   ;; Respect constrained single-line chrome in `content' scope
                   ;; unless explicitly opted in with `:translate'.
                   (unless (and (eq scope 'content)
                                (not (memq hint '(t yes content)))
                                (etaf-translate--single-line-constrained-p props)
                                (< (length (string-trim
                                            (mapconcat
                                             (lambda (k) (or (plist-get k :text) ""))
                                             (plist-get node :children) "")))
                                   24))
                     (when-let* ((unit (etaf-translate--build-box-unit
                                        node parent-tag policy)))
                       (push unit units))))
                  ((eq tag 'text)
                   (when-let* ((unit (etaf-translate--build-text-unit
                                      node parent-tag parent-props policy)))
                     (push unit units)))
                  (t
                   (walk (plist-get node :children) tag props hint))))))))
      (walk host-tree nil nil nil))
    (nreverse units)))

;;;; Deserializing translated markup back into styled segments

(defconst etaf-translate--markup-token-re
  "<\\([0-9]+\\)>\\(\\(?:.\\|\n\\)*?\\)</\\1>\\|⟦c\\([0-9]+\\)⟧"
  "Regexp matching `<N>...</N>' inline runs or `⟦cM⟧' atomic placeholders.")

(defun etaf-translate--strip-stray-tags (text)
  "Remove any unmatched `<N>' or `</N>' markers left behind by a translator."
  (replace-regexp-in-string "</?[0-9]+>" "" (or text "")))

(defun etaf-translate--cjk-char-p (ch)
  "Return non-nil when character CH is a CJK Unified Ideograph."
  (and ch
       (or (<= #x4E00 ch #x9FFF)
           (<= #x3400 ch #x4DBF)
           (<= #xF900 ch #xFAFF))))

(defun etaf-translate--ascii-alnum-p (ch)
  "Return non-nil when character CH is an ASCII letter or digit."
  (and ch
       (or (<= ?a ch ?z) (<= ?A ch ?Z) (<= ?0 ch ?9))))

(defun etaf-translate--normalize-segment-boundaries (segments base-props)
  "Insert plain ASCII spaces across CJK/Latin boundaries between SEGMENTS.
Keeps separating spaces outside atomic code fills and link underlines."
  (if (or (not etaf-translate-spacing-normalize) (null (cdr segments)))
      segments
    (let ((out (list (car segments)))
          (prev (car segments)))
      (dolist (cur (cdr segments))
        (let* ((pt (or (plist-get prev :text) ""))
               (ct (or (plist-get cur :text) ""))
               (last-ch (and (> (length pt) 0) (aref pt (1- (length pt)))))
               (first-ch (and (> (length ct) 0) (aref ct 0))))
          (when (or (and (etaf-translate--cjk-char-p last-ch)
                         (etaf-translate--ascii-alnum-p first-ch))
                    (and (etaf-translate--ascii-alnum-p last-ch)
                         (etaf-translate--cjk-char-p first-ch)))
            (push (list :text " " :props base-props) out)))
        (push cur out)
        (setq prev cur))
      (nreverse out))))

(defun etaf-translate-decode-runs (translated unit)
  "Decode TRANSLATED string for UNIT into a list of segment plists.
Each segment is `(:text STRING :props PLIST :host-id ID-OR-NIL :atomic BOOL)'.
Original inline links, emphasis and atomic code spans are restored; malformed
tags degrade cleanly to plain text without signaling."
  (let* ((raw (or translated ""))
         (runs-alist (etaf-translate-unit-runs unit))
         (atoms-alist (etaf-translate-unit-atoms unit))
         (base (etaf-translate-unit-base-props unit))
         (segments nil)
         (pos 0)
         (len (length raw)))
    (while (< pos len)
      (if (string-match etaf-translate--markup-token-re raw pos)
          (let ((mstart (match-beginning 0))
                (mend (match-end 0))
                (tag-str (match-string 1 raw))
                (tag-body (match-string 2 raw))
                (atom-str (match-string 3 raw)))
            (when (> mstart pos)
              (let ((plain (etaf-translate-normalize-spacing
                            (etaf-translate--strip-stray-tags
                             (substring raw pos mstart)))))
                (unless (string-empty-p plain)
                  (push (list :text plain :props base) segments))))
            (cond
             (atom-str
              (let* ((token (format "⟦c%s⟧" atom-str))
                     (atom (cdr (assoc token atoms-alist))))
                (if atom
                    (push (list :text (etaf-translate-run-text atom)
                                :props (etaf-translate-run-props atom)
                                :host-id (etaf-translate-run-host-id atom)
                                :atomic t)
                          segments)
                  (push (list :text token :props base) segments))))
             (tag-str
              (let* ((tag-id (string-to-number tag-str))
                     (run (cdr (assq tag-id runs-alist)))
                     (rprops (if run (etaf-translate-run-props run) base))
                     (rhost (and run (etaf-translate-run-host-id run))))
                ;; Allow atomic placeholders nested inside a tagged run.
                (let ((sub-pos 0)
                      (sub-len (length tag-body)))
                  (while (< sub-pos sub-len)
                    (if (string-match "⟦c\\([0-9]+\\)⟧" tag-body sub-pos)
                        (let ((s0 (match-beginning 0))
                              (s1 (match-end 0))
                              (aid (match-string 1 tag-body)))
                          (when (> s0 sub-pos)
                            (let ((part (etaf-translate-normalize-spacing
                                         (etaf-translate--strip-stray-tags
                                          (substring tag-body sub-pos s0)))))
                              (unless (string-empty-p part)
                                (push (list :text part :props rprops :host-id rhost)
                                      segments))))
                          (let* ((tok (format "⟦c%s⟧" aid))
                                 (atom (cdr (assoc tok atoms-alist))))
                            (if atom
                                (push (list :text (etaf-translate-run-text atom)
                                            :props (etaf-translate-run-props atom)
                                            :host-id (etaf-translate-run-host-id atom)
                                            :atomic t)
                                      segments)
                              (push (list :text tok :props rprops :host-id rhost)
                                    segments)))
                          (setq sub-pos s1))
                      (let ((part (etaf-translate-normalize-spacing
                                   (etaf-translate--strip-stray-tags
                                    (substring tag-body sub-pos)))))
                        (unless (string-empty-p part)
                          (push (list :text part :props rprops :host-id rhost)
                                segments)))
                      (setq sub-pos sub-len)))))))
            (setq pos mend))
        (let ((tail (etaf-translate-normalize-spacing
                     (etaf-translate--strip-stray-tags
                      (substring raw pos)))))
          (unless (string-empty-p tail)
            (push (list :text tail :props base) segments)))
        (setq pos len)))
    (etaf-translate--normalize-segment-boundaries
     (or (nreverse segments)
         (list (list :text (etaf-translate-normalize-spacing
                            (etaf-translate--strip-stray-tags raw))
                     :props base)))
     base)))

(provide 'etaf-translate-extract)
;;; etaf-translate-extract.el ends here
