;;; etaf-org-node.el --- Unified node types, declarations and style rules -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; The single unified node model of `etaf-org': every built-in Org construct
;; (`headline', `src', `table', `quote', `callout', `drawer', `planning',
;; `math') and every Org special-block container (`card', `columns', `tabs',
;; `org-query', `kanban', ...) lives in `etaf-org-node-definitions'.
;;
;; Value resolution follows one fixed order:
;;   1. Reader style rules (`etaf-org-styles' / `etaf-org-set-attr')
;;   2. Document values (inline `#+begin_<name> :key val' over `#+attr_etaf:')
;;   3. Declaration `:default'
;;   4. Derived attributes (`:derived'), filled by parse/derive and read-only.

;;; Code:

(require 'cl-lib)
(require 'subr-x)

(define-error 'etaf-org-error "Org document error")

(defconst etaf-org-contract 1
  "Version of the document-side attribute table this build accepts.")

(defvar etaf-org-node-definitions (make-hash-table :test #'eq)
  "Registry mapping a type symbol to its definition plist.
`etaf-org-define-node' is the only writer.  Shipped and user definitions live
here alike, one entry per type.")

(defvar etaf-org-styles nil
  "Ordered style rules, oldest first.
Each entry is (SELECTOR RULE...), where SELECTOR is a list starting with the
type symbol and RULE is a (KEY VALUE) pair.  `etaf-org-set-attr' is the
recommended writer.")

(defcustom etaf-org-node-directory
  (locate-user-emacs-file "etaf-org/nodes")
  "Directory holding one user node definition per `.el' file.
Its files load after the shipped definitions, in file-name order."
  :type 'directory
  :group 'etaf-org)

(defconst etaf-org--attribute-types
  '(string number boolean length surface accent align enum color)
  "Attribute types a declaration may name.")

(defconst etaf-org--domains
  '((surface none page raised sunken quote table-header table-stripe)
    (accent neutral primary success warning danger important)
    (align start center end))
  "Closed word lists of the three semantic types.")

(defconst etaf-org--length-regexp
  "\\`\\([0-9]+\\(?:\\.[0-9]+\\)?\\)\\(ch\\|lh\\|%\\)\\'"
  "Shape of a length a document or a rule may write.")

(defconst etaf-org--color-regexp
  "\\`\\(?:[a-z][a-z0-9-]*\\|#[0-9a-fA-F]\\{3,8\\}\\)\\'"
  "Shape of a color token or literal a rule may write.")

(defconst etaf-org--token-regexp "\\`[a-z][a-z0-9-]*\\'"
  "Shape of a color token; a document may write only this form.")

(defconst etaf-org--max-nesting-depth 8
  "Maximum allowed nesting depth for container blocks.")

;;; ---------------------------------------------------------------------------
;;; Node record & lookup
;;; ---------------------------------------------------------------------------

(cl-defstruct (etaf-org-node (:constructor etaf-org-node-create)
                             (:copier etaf-org-node-copy))
  "One node of a document tree: TYPE, ATTRS plist, DERIVED plist, CHILDREN.
SOURCE keeps the raw source text for inline error fallback; BLOCK keeps the
parsed block plist; ERRORS records parse/validation problems on this block."
  type
  attrs
  derived
  children
  source
  block
  line
  errors)

(defun etaf-org-node (type &optional attrs children)
  "Return a node of TYPE with ATTRS and CHILDREN."
  (etaf-org-node-create :type type :attrs attrs :children children))

(defun etaf-org-node-definition (type)
  "Return TYPE's definition plist, or nil."
  (gethash type etaf-org-node-definitions))

(defun etaf-org--definition-by-name (name)
  "Return (TYPE . DEFINITION) for container document NAME, or nil."
  (let ((target (downcase (or name "")))
        (found nil))
    (maphash (lambda (type def)
               (when (and (not found)
                          (stringp (plist-get def :name))
                          (equal (downcase (plist-get def :name)) target))
                 (setq found (cons type def))))
             etaf-org-node-definitions)
    found))

(defun etaf-org--child-syntax (type)
  "Return how container TYPE writes its children (`blocks' or `markers')."
  (or (plist-get (etaf-org-node-definition type) :child-syntax) 'blocks))

(defun etaf-org--attr-name (key)
  "Return KEY as a non-keyword attribute name symbol."
  (if (keywordp key)
      (intern (substring (symbol-name key) 1))
    key))

(defun etaf-org--attr-key (name)
  "Return NAME as a keyword attribute symbol."
  (if (keywordp name) name (intern (format ":%s" name))))

(defun etaf-org-derived-attributes (type)
  "Return TYPE's derived attribute names in declaration order."
  (mapcar (lambda (entry) (etaf-org--attr-name (car entry)))
          (plist-get (etaf-org-node-definition type) :derived)))

(defun etaf-org--declarations (entries)
  "Normalize declaration ENTRIES keyed by keyword symbol."
  (mapcar (lambda (entry) (cons (etaf-org--attr-key (car entry)) (cdr entry)))
          entries))

(defun etaf-org--declaration (decls key)
  "Return KEY's declaration plist among DECLS."
  (cdr (assq (etaf-org--attr-key key) decls)))

(defun etaf-org--domain (type)
  "Return TYPE's closed semantic domain word list, or nil."
  (cdr (assq type etaf-org--domains)))

;;; ---------------------------------------------------------------------------
;;; Type conversion and validation
;;; ---------------------------------------------------------------------------

(defun etaf-org--convert (type value)
  "Convert VALUE to attribute TYPE, or return nil when incompatible."
  (pcase type
    ('string (cond ((stringp value) value)
                   ((symbolp value) (symbol-name value))
                   ((numberp value) (number-to-string value))))
    ('number (cond ((numberp value) value)
                   ((and (stringp value)
                         (string-match-p "\\`-?[0-9]+\\(?:\\.[0-9]+\\)?\\'" value))
                    (string-to-number value))))
    ('boolean (cond ((eq value t) t)
                    ((null value) nil)
                    ((and (stringp value)
                          (member (downcase value) '("t" "true" "yes")))
                     t)
                    ((and (stringp value)
                          (member (downcase value) '("nil" "false" "no")))
                     nil)
                    ((eq value 'true) t)
                    ((eq value 'false) nil)))
    ('length (cond ((and (stringp value) (string-match etaf-org--length-regexp value))
                    (list (intern (match-string 2 value))
                          (string-to-number (match-string 1 value))))
                   ((and (consp value) (memq (car value) '(ch lh %)))
                    value)))
    ('surface (and (or (symbolp value) (stringp value))
                   (intern (downcase (format "%s" value)))))
    ('accent (and (or (symbolp value) (stringp value))
                  (intern (downcase (format "%s" value)))))
    ('align (and (or (symbolp value) (stringp value))
                 (intern (downcase (format "%s" value)))))
    ('enum (and (or (symbolp value) (stringp value))
                (intern (downcase (format "%s" value)))))
    ('color (cond ((stringp value) value)
                  ((symbolp value) (symbol-name value))))
    (_ nil)))

(defun etaf-org--converts-p (type value)
  "Return non-nil when VALUE converts cleanly to TYPE."
  (pcase type
    ('boolean (or (memq value '(t nil true false))
                  (and (stringp value)
                       (member (downcase value)
                               '("t" "nil" "true" "false")))))
    ('string (stringp value))
    ('color (and (or (stringp value) (symbolp value))
                 (string-match-p etaf-org--color-regexp
                                 (if (symbolp value) (symbol-name value) value))))
    (_ (and (etaf-org--convert type value) t))))

(defun etaf-org--value-problem (key decl value source)
  "Return a diagnostic message when VALUE violates DECL for KEY from SOURCE.
SOURCE is `document' or `rule'."
  (let* ((type (plist-get decl :type))
         (name (substring (symbol-name (etaf-org--attr-key key)) 1)))
    (if (not (etaf-org--converts-p type value))
        (format "%s 的值 %S 不是合法的 %s" name value type)
      (let* ((converted (etaf-org--convert type value))
             (domain (or (plist-get decl :one-of) (etaf-org--domain type))))
        (cond
         ((and (eq type 'string) (plist-get decl :pattern)
               (not (string-match-p (plist-get decl :pattern) converted)))
          (format "%s 的值 %S 不符合格式 %s" name value (plist-get decl :pattern)))
         ((and (eq type 'number) (plist-get decl :integer)
               (not (integerp converted)))
          (format "%s 的值 %S 必须是整数" name value))
         ((and (eq type 'number) (plist-get decl :min)
               (< converted (plist-get decl :min)))
          (format "%s 的值 %S 小于下限 %s" name value (plist-get decl :min)))
         ((and (eq type 'number) (plist-get decl :max)
               (> converted (plist-get decl :max)))
          (format "%s 的值 %S 超过上限 %s" name value (plist-get decl :max)))
         ((and domain (not (memq converted domain)))
          (format "%s 的值是 %S，只允许 %s"
                  name value
                  (mapconcat #'symbol-name domain "、")))
         ((and (eq type 'color) (eq source 'document)
               (not (string-match-p etaf-org--token-regexp converted)))
          (format "%s 在文档里只允许写令牌名，不能写 %S" name value)))))))

;;; ---------------------------------------------------------------------------
;;; Registration API
;;; ---------------------------------------------------------------------------

(defun etaf-org--check-declarations (type decls derived)
  "Validate attribute declarations DECLS of TYPE; DERIVED marks `:derived'."
  (let ((seen nil))
    (dolist (entry decls)
      (unless (and (consp entry) (symbolp (car entry)) (listp (cdr entry)))
        (signal 'etaf-org-error
                (list (format "%s: %S is not an attribute declaration" type entry))))
      (let ((key (etaf-org--attr-key (car entry)))
            (decl (cdr entry)))
        (when (memq key seen)
          (signal 'etaf-org-error
                  (list (format "%s: %s is declared twice" type key))))
        (push key seen)
        (let ((type-name (plist-get decl :type)))
          (cond
           ((not (memq type-name etaf-org--attribute-types))
            (signal 'etaf-org-error
                    (list (format "%s.%s: unknown type %S" type key type-name))))
           ((and (eq type-name 'enum) (null (plist-get decl :one-of)))
            (signal 'etaf-org-error
                    (list (format "%s.%s: enum needs :one-of" type key))))
           ((and derived (plist-member decl :default))
            (signal 'etaf-org-error
                    (list (format "%s.%s: a derived attribute has no :default"
                                  type key))))
           ((and derived (plist-member decl :required))
            (signal 'etaf-org-error
                    (list (format "%s.%s: a derived attribute is never required"
                                  type key))))
           ((and (plist-get decl :required) (plist-member decl :default))
            (signal 'etaf-org-error
                    (list (format "%s.%s: :required and :default exclude each other"
                                  type key))))
           ((and (plist-member decl :pattern) (not (eq type-name 'string)))
            (signal 'etaf-org-error
                    (list (format "%s.%s: :pattern belongs to string" type key))))
           ((and (or (plist-member decl :min) (plist-member decl :max)
                     (plist-member decl :integer))
                 (not (eq type-name 'number)))
            (signal 'etaf-org-error
                    (list (format "%s.%s: :min, :max and :integer belong to number"
                                  type key))))
           ((and (plist-member decl :default)
                 (not (null (plist-get decl :default)))
                 (etaf-org--value-problem key decl (plist-get decl :default) 'rule))
            (signal 'etaf-org-error
                    (list (format "%s.%s: default %S does not fit"
                                  type key (plist-get decl :default)))))))))))

(defun etaf-org--shipped-snapshot (definition)
  "Return a clean snapshot of DEFINITION for `:default' and undo."
  (when definition
    (list :summary (plist-get definition :summary)
          :name (plist-get definition :name)
          :attrs (copy-tree (plist-get definition :attrs))
          :derived (copy-tree (plist-get definition :derived))
          :accepts (copy-tree (plist-get definition :accepts))
          :child-syntax (plist-get definition :child-syntax)
          :view (plist-get definition :view)
          :contract (plist-get definition :contract))))

(defun etaf-org-define-node (type &rest args)
  "Register a node TYPE, or extend or replace one.
ARGS accepts :name, :summary, :attrs, :derived, :accepts, :child-syntax,
:contract, :view, :extends and :replace.  A second definition of an existing
type must pass :extends or :replace, and a declared attribute name cannot be
redeclared without :replace.  `:child-syntax' is `blocks' (default) or
`markers'."
  (unless (symbolp type)
    (signal 'etaf-org-error (list (format "A type name is a symbol: %S" type))))
  (let* ((old (etaf-org-node-definition type))
         (extends (plist-get args :extends))
         (replace (plist-get args :replace))
         (added (etaf-org--declarations (plist-get args :attrs)))
         (derived (etaf-org--declarations (plist-get args :derived)))
         (old-attrs (plist-get old :attrs))
         (old-derived (plist-get old :derived)))
    (when (and old (not extends) (not replace))
      (signal 'etaf-org-error
              (list (format "%s is already defined; pass :extends or :replace"
                            type))))
    (when (and (null old) (or extends replace))
      (signal 'etaf-org-error
              (list (format "%s has no definition to %s"
                            type (if extends "extend" "replace")))))
    (unless (memq (plist-get args :child-syntax) '(nil blocks markers))
      (signal 'etaf-org-error
              (list (format "%s: :child-syntax must be blocks or markers" type))))
    (etaf-org--check-declarations type added nil)
    (etaf-org--check-declarations type derived t)
    (let* ((attrs (cond (replace added)
                        (extends (append (copy-tree old-attrs) added))
                        (t added)))
           (all-derived (cond (replace derived)
                              (extends (append (copy-tree old-derived) derived))
                              (t derived))))
      (unless replace
        (dolist (entry added)
          (when (and old (etaf-org--declaration old-attrs (car entry)))
            (signal 'etaf-org-error
                    (list (format "%s.%s is already declared" type (car entry)))))))
      (let ((definition
             (list :summary (or (plist-get args :summary)
                                (plist-get old :summary))
                   :name (if (plist-member args :name)
                             (plist-get args :name)
                           (plist-get old :name))
                   :attrs attrs
                   :derived all-derived
                   :accepts (or (plist-get args :accepts)
                                (and extends (copy-tree (plist-get old :accepts))))
                   :child-syntax (or (plist-get args :child-syntax)
                                     (and (not replace)
                                          (plist-get old :child-syntax)))
                   :view (or (plist-get args :view)
                             (and (not replace) (plist-get old :view)))
                   :default-view (cond
                                  ((and extends (plist-get args :view))
                                   (plist-get old :view))
                                  (extends (plist-get old :default-view))
                                  (t nil))
                   :contract (or (plist-get args :contract)
                                 (plist-get old :contract)
                                 etaf-org-contract)
                   :shipped (plist-get old :shipped)
                   :overridden (and old t))))
        (puthash type definition etaf-org-node-definitions)
        definition))))

(defun etaf-org--define-shipped (type &rest args)
  "Register TYPE as a shipped node definition, safe on reload."
  (remhash type etaf-org-node-definitions)
  (let ((definition (apply #'etaf-org-define-node type args)))
    (setq definition (plist-put definition :shipped
                                (etaf-org--shipped-snapshot definition)))
    (puthash type definition etaf-org-node-definitions)
    definition))

(defun etaf-org-undefine-node (type)
  "Remove TYPE's user definition.
A shipped type returns to its built-in declaration and paint; a user type
disappears from `etaf-org-node-definitions'."
  (when-let* ((old (etaf-org-node-definition type)))
    (if-let* ((shipped (plist-get old :shipped)))
        (let ((restored (copy-tree shipped)))
          (setq restored (plist-put restored :shipped (copy-tree shipped)))
          (puthash type restored etaf-org-node-definitions))
      (remhash type etaf-org-node-definitions)
      (setq etaf-org-styles
            (cl-remove-if (lambda (entry) (eq (car (car entry)) type))
                          etaf-org-styles))))
  nil)

(defun etaf-org-set-view (type function &rest args)
  "Give node TYPE the paint FUNCTION.
ARGS accepts :extends, :replace and :style-keys.  Passing nil for FUNCTION
restores the previous shipped view."
  (let ((def (etaf-org-node-definition type)))
    (unless def
      (signal 'etaf-org-error (list (format "Unknown node type: %S" type))))
    (if (null function)
        (if-let* ((shipped (plist-get def :shipped)))
            (let ((restored (copy-tree shipped)))
              (setq restored (plist-put restored :shipped (copy-tree shipped)))
              (puthash type restored etaf-org-node-definitions))
          (plist-put def :view nil))
      (let ((style-keys (plist-get args :style-keys))
            (extends (plist-get args :extends))
            (replace (plist-get args :replace)))
        (apply #'etaf-org-define-node
               type
               (append (list :view function)
                       (when style-keys (list :attrs style-keys))
                       (if replace '(:replace t)
                         (list :extends (or extends t)))))))))

;;; ---------------------------------------------------------------------------
;;; Style rules
;;; ---------------------------------------------------------------------------

(defun etaf-org--validate-selector (selector)
  "Validate style SELECTOR `(TYPE :ATTR VAL ...)' and signal on bad shape."
  (unless (and (consp selector) (symbolp (car selector)))
    (signal 'etaf-org-error
            (list (format "Style selector must be a list starting with type: %S"
                          selector))))
  (let* ((type (car selector))
         (def (etaf-org-node-definition type))
         (attrs (plist-get def :attrs))
         (derived (plist-get def :derived))
         (rest (cdr selector)))
    (unless def
      (signal 'etaf-org-error (list (format "Unknown node type in selector: %S" type))))
    (unless (cl-evenp (length rest))
      (signal 'etaf-org-error
              (list (format "Selector %S must have :key value pairs" selector))))
    (while rest
      (let* ((k (etaf-org--attr-key (pop rest)))
             (_v (pop rest)))
        (unless (or (etaf-org--declaration attrs k)
                    (etaf-org--declaration derived k))
          (signal 'etaf-org-error
                  (list (format "Selector %S references undeclared attribute %s"
                                selector k))))))))

(defun etaf-org-set-attr (selector rules)
  "Install style RULES for SELECTOR, or remove them when RULES is nil.
RULES is a list of `(KEY VALUE)' pairs.  A derived attribute cannot be written
as a key in RULES."
  (etaf-org--validate-selector selector)
  (let* ((type (car selector))
         (def (etaf-org-node-definition type))
         (attrs (plist-get def :attrs))
         (derived (plist-get def :derived)))
    (setq etaf-org-styles
          (cl-remove-if (lambda (entry) (equal (car entry) selector))
                        etaf-org-styles))
    (when rules
      (let ((normalized nil))
        (dolist (pair rules)
          (unless (and (consp pair) (= (length pair) 2))
            (signal 'etaf-org-error
                    (list (format "Style rule entry must be (KEY VALUE): %S" pair))))
          (let* ((key (etaf-org--attr-key (car pair)))
                 (val (cadr pair)))
            (when (etaf-org--declaration derived key)
              (signal 'etaf-org-error
                      (list (format "%s.%s is a derived attribute and cannot be written by style rules"
                                    type key))))
            (let ((decl (etaf-org--declaration attrs key)))
              (unless decl
                (signal 'etaf-org-error
                        (list (format "%s does not declare attribute %s" type key))))
              (unless (memq val '(nil :default))
                (when-let* ((prob (etaf-org--value-problem key decl val 'rule)))
                  (signal 'etaf-org-error (list prob)))))
            (push (list key val) normalized)))
        (setq etaf-org-styles
              (append etaf-org-styles
                      (list (cons selector (nreverse normalized)))))))
    etaf-org-styles))

(defun etaf-org--selector-matches-p (selector node)
  "Return non-nil when style SELECTOR matches NODE."
  (when (eq (car selector) (etaf-org-node-type node))
    (let ((rest (cdr selector))
          (matched t))
      (while (and matched rest)
        (let* ((key (etaf-org--attr-key (pop rest)))
               (want (pop rest))
               (actual (if (plist-member (etaf-org-node-derived node) key)
                           (plist-get (etaf-org-node-derived node) key)
                         (plist-get (etaf-org-node-attrs node) key))))
          (unless (cond
                   ((and (listp actual) (not (listp want)))
                    (member want actual))
                   (t (equal actual want)))
            (setq matched nil))))
      matched)))

(defun etaf-org--shipped-default (type key)
  "Return the shipped `:default' value for TYPE's KEY."
  (let* ((def (etaf-org-node-definition type))
         (shipped (plist-get def :shipped))
         (decl (or (etaf-org--declaration (plist-get shipped :attrs) key)
                   (etaf-org--declaration (plist-get def :attrs) key))))
    (when decl
      (let ((raw (plist-get decl :default)))
        (if (null raw) nil (etaf-org--convert (plist-get decl :type) raw))))))

(defun etaf-org--resolve-attr (node key)
  "Return final resolved value of KEY on NODE.
Precedence: matching `etaf-org-styles' > document attrs > default > derived."
  (let* ((type (etaf-org-node-type node))
         (def (etaf-org-node-definition type))
         (k (etaf-org--attr-key key))
         (derived-decl (etaf-org--declaration (plist-get def :derived) k)))
    (if derived-decl
        (plist-get (etaf-org-node-derived node) k)
      (let* ((decl (etaf-org--declaration (plist-get def :attrs) k))
             (found nil)
             (value nil))
        ;; 1. Reader style rules (later wins).
        (dolist (entry etaf-org-styles)
          (when (etaf-org--selector-matches-p (car entry) node)
            (dolist (pair (cdr entry))
              (when (eq (etaf-org--attr-key (car pair)) k)
                (setq found t
                      value (cadr pair))))))
        (cond
         ((and found (eq value :default))
          (etaf-org--shipped-default type k))
         (found
          (if (null value)
              nil
            (if decl (etaf-org--convert (plist-get decl :type) value) value)))
         ;; 2. Document attributes.
         ((plist-member (etaf-org-node-attrs node) k)
          (let ((doc-val (plist-get (etaf-org-node-attrs node) k)))
            (if (null doc-val)
                nil
              (if decl (etaf-org--convert (plist-get decl :type) doc-val) doc-val))))
         ;; 3. Declaration default.
         ((and decl (plist-member decl :default))
          (let ((def-val (plist-get decl :default)))
            (if (null def-val)
                nil
              (etaf-org--convert (plist-get decl :type) def-val))))
         (t nil))))))

;;; ---------------------------------------------------------------------------
;;; Node validation (21-case failure catalog)
;;; ---------------------------------------------------------------------------

(defun etaf-org--validate-node (node)
  "Return a list of diagnostic strings for NODE, or nil when valid."
  (let* ((type (etaf-org-node-type node))
         (def (etaf-org-node-definition type))
         (line (or (etaf-org-node-line node) 1))
         (problems (copy-sequence (etaf-org-node-errors node))))
    (cond
     ((null def)
      (push (format "line %d: 没有 %s 的定义" line type) problems))
     (t
      (let* ((attrs-decls (plist-get def :attrs))
             (derived-decls (plist-get def :derived))
             (doc-attrs (etaf-org-node-attrs node))
             (allowed-names (mapcar (lambda (d)
                                      (substring (symbol-name (car d)) 1))
                                    attrs-decls))
             (rest doc-attrs))
        (when (and (plist-get def :contract)
                   (/= (plist-get def :contract) etaf-org-contract))
          (push (format "line %d: %s 需要契约版本 %d，当前构建支持 %d"
                        line type (plist-get def :contract) etaf-org-contract)
                problems))
        (while rest
          (let* ((k (etaf-org--attr-key (pop rest)))
                 (v (pop rest))
                 (kname (substring (symbol-name k) 1)))
            (cond
             ((etaf-org--declaration derived-decls k)
              (push (format "line %d: %s 是派生属性，没有文档写法，由解析或派生阶段填入"
                            line kname)
                    problems))
             ((not (etaf-org--declaration attrs-decls k))
              (push (format "line %d: %s 不收 %S，它收 %s"
                            line type kname
                            (if allowed-names
                                (mapconcat #'identity allowed-names "、")
                              "无"))
                    problems))
             (t
              (let ((decl (etaf-org--declaration attrs-decls k)))
                (when-let* ((p (etaf-org--value-problem k decl v 'document)))
                  (push (format "line %d: %s 的 %s" line type p) problems)))))))
        ;; Check required attributes in declaration order.
        (dolist (entry attrs-decls)
          (let ((k (car entry))
                (decl (cdr entry)))
            (when (and (plist-get decl :required)
                       (not (plist-member doc-attrs k))
                       (null (etaf-org--resolve-attr node k)))
              (push (format "line %d: %s 缺少必填属性 %s"
                            line type (substring (symbol-name k) 1))
                    problems)))))))
    (nreverse problems)))

;;; ---------------------------------------------------------------------------
;;; Introspection & user directory loader
;;; ---------------------------------------------------------------------------

(defun etaf-org-describe-nodes (&optional type)
  "Return the node registry as readable text, one type per stanza.
When TYPE is non-nil, limit output to that type."
  (let ((types (if type
                   (list type)
                 (sort (let (keys)
                         (maphash (lambda (k _v) (push k keys))
                                  etaf-org-node-definitions)
                         keys)
                       (lambda (a b) (string< (symbol-name a) (symbol-name b))))))
        (stanzas nil))
    (dolist (ty types)
      (when-let* ((def (etaf-org-node-definition ty)))
        (let* ((doc-name (plist-get def :name))
               (summary (or (plist-get def :summary) ""))
               (derived (mapcar (lambda (d) (substring (symbol-name (car d)) 1))
                                (plist-get def :derived)))
               (ordinary (mapcar (lambda (d) (substring (symbol-name (car d)) 1))
                                 (plist-get def :attrs)))
               (accepts (plist-get def :accepts))
               (syntax (or (plist-get def :child-syntax) 'blocks))
               (rules (cl-loop for entry in etaf-org-styles
                               when (eq (car (car entry)) ty)
                               collect (format "%S" (car entry))))
               (lines (list (format "%-18s %s%s"
                                    ty
                                    (if doc-name
                                        (format "#+begin_%s" doc-name)
                                      "内置语法")
                                    (if (string-empty-p summary) ""
                                      (concat " — " summary))))))
          (when derived
            (push (format "  derived   %s" (string-join derived "  ")) lines))
          (when ordinary
            (push (format "  ordinary  %s" (string-join ordinary "  ")) lines))
          (when accepts
            (push (format "  accepts   %s (%s)"
                          (mapconcat (lambda (a) (format "%s" (car a))) accepts ", ")
                          syntax)
                  lines))
          (when rules
            (push (format "  rules     %s" (string-join rules "  ")) lines))
          (push (string-join (nreverse lines) "\n") stanzas))))
    (string-join (nreverse stanzas) "\n\n")))

(defvar etaf-org--user-nodes-loaded nil
  "Non-nil once `etaf-org-node-directory' files have been loaded.")

(defun etaf-org--load-user-nodes ()
  "Load user `.el' node definitions from `etaf-org-node-directory' once."
  (when (and (not etaf-org--user-nodes-loaded)
             (stringp etaf-org-node-directory)
             (file-directory-p etaf-org-node-directory))
    (setq etaf-org--user-nodes-loaded t)
    (dolist (file (sort (directory-files etaf-org-node-directory t "\\.el\\'")
                        #'string<))
      (condition-case err
          (load file nil t)
        (error
         (message "etaf-org skipped user node %s: %s"
                  (file-name-nondirectory file)
                  (error-message-string err)))))))

(provide 'etaf-org-node)
;;; etaf-org-node.el ends here
