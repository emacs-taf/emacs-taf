;;; etaf-md-node.el --- Node types, declarations and style rules -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; The single model of article 2: a node has a type, attributes and children,
;; and one definition per type says which attributes the document may write,
;; which the parser fills, and how the node is painted.
;;
;; This file owns the registry, the declaration checks, value resolution and
;; the style rules.  `etaf-md-env' owns what a paint may read, and
;; `etaf-md-nodes' holds the shipped definitions.
;;
;; A value resolves in one fixed order: the reader's style rule, the
;; document's own value, the declaration's default, then the value the parser
;; or the derive step wrote.  A derived attribute has only the last source and
;; may be selected on but never written.

;;; Code:

(require 'cl-lib)
(require 'subr-x)

(defconst etaf-md-contract 1
  "Version of the document-side attribute table this build accepts.")

(defvar etaf-md-node-definitions (make-hash-table :test #'eq)
  "Registry mapping a type symbol to its definition plist.
`etaf-md-define-node' is the only writer.  Shipped and user definitions live
here alike, one entry per type, and every attribute declaration lives inside
its type's entry.")

(defvar etaf-md-styles nil
  "Ordered style rules, oldest first.
Each entry is (SELECTOR RULE...), where SELECTOR is a list starting with the
type symbol and RULE is a (KEY VALUE) pair.  `etaf-md-set-attr' is the only
writer.")

(defcustom etaf-md-node-directory
  (locate-user-emacs-file "etaf-md/nodes")
  "Directory holding one user definition per file.
Its files load after the shipped definitions, in file-name order."
  :type 'directory
  :group 'etaf-md)

(defconst etaf-md--attribute-types
  '(string number boolean length surface accent align enum color)
  "Attribute types a declaration may name.")

(defconst etaf-md--domains
  '((surface none page raised sunken quote table-header table-stripe)
    (accent neutral primary success warning danger important)
    (align start center end))
  "Closed word lists of the three semantic types.")

(defconst etaf-md--length-regexp
  "\\`\\([0-9]+\\(?:\\.[0-9]+\\)?\\)\\(ch\\|lh\\|%\\)\\'"
  "Shape of a length a document or a rule may write.")

(defconst etaf-md--color-regexp
  "\\`\\(?:[a-z][a-z0-9-]*\\|#[0-9a-fA-F]\\{3,8\\}\\)\\'"
  "Shape of a colour token or literal a rule may write.")

(defconst etaf-md--token-regexp "\\`[a-z][a-z0-9-]*\\'"
  "Shape of a colour token; a document may write only this form.")

;;; Nodes

(cl-defstruct (etaf-md-node (:constructor etaf-md-node-create)
                            (:copier etaf-md-node-copy))
  "One node of a document tree: a type, a plist of attributes, children.
SOURCE is the document text the node came from, used to show a block that
fails; BLOCK is the parsed block it was built from, kept for the painter the
new model does not replace yet."
  type
  attrs
  children
  source
  block)

(defun etaf-md-node (type &optional attrs children)
  "Return a node of TYPE with ATTRS and CHILDREN.
ATTRS uses keyword names, the same names a style rule writes."
  (etaf-md-node-create :type type :attrs attrs :children children))

(defun etaf-md-node-definition (type)
  "Return TYPE's definition plist, or nil."
  (gethash type etaf-md-node-definitions))

(defun etaf-md--child-syntax (type)
  "Return how container TYPE writes its children.
`blocks' is the default: each child is a `:::name' container.  `markers' means
one child per `@name' line, which is how a tab strip stays short.  The form is
the container's own grammar, so a marker is meaningful only inside a type that
declares it."
  (or (plist-get (etaf-md-node-definition type) :child-syntax) 'blocks))

(defun etaf-md--name (key)
  "Return KEY as the attribute name a document writes: no leading colon."
  (intern (substring (symbol-name key) 1)))

(defun etaf-md-derived-attributes (type)
  "Return TYPE's derived attribute names, in declaration order."
  (mapcar (lambda (entry) (etaf-md--name (car entry)))
          (plist-get (etaf-md-node-definition type) :derived)))

(defun etaf-md--key (name)
  "Return NAME as the keyword form attributes use."
  (if (keywordp name) name (intern (format ":%s" name))))

(defun etaf-md--declarations (entries)
  "Return declaration ENTRIES keyed by the keyword form of the name."
  (mapcar (lambda (entry) (cons (etaf-md--key (car entry)) (cdr entry)))
          entries))

(defun etaf-md--declaration (decls key)
  "Return KEY's declaration among DECLS."
  (cdr (assq (etaf-md--key key) decls)))

;;; Conversion

(defun etaf-md--convert (type value)
  "Return VALUE converted to TYPE, or nil when it does not fit."
  (pcase type
    ('string (and (stringp value) value))
    ('number (cond ((numberp value) value)
                   ((and (stringp value)
                         (string-match-p "\\`-?[0-9]+\\(?:\\.[0-9]+\\)?\\'" value))
                    (string-to-number value))))
    ('boolean (cond ((memq value '(t nil)) value)
                    ((equal value "true") t)
                    ((equal value "false") nil)))
    ('length (cond ((and (stringp value) (string-match etaf-md--length-regexp value))
                    (list (intern (match-string 2 value))
                          (string-to-number (match-string 1 value))))
                   ((and (consp value) (memq (car value) '(ch lh %)))
                    value)))
    ('surface (and (or (symbolp value) (stringp value))
                   (intern (format "%s" value))))
    ('accent (and (or (symbolp value) (stringp value))
                  (intern (format "%s" value))))
    ('align (and (or (symbolp value) (stringp value))
                 (intern (format "%s" value))))
    ('enum (and (or (symbolp value) (stringp value))
                (intern (format "%s" value))))
    ('color (and (stringp value) value))
    (_ nil)))

(defun etaf-md--domain (type)
  "Return TYPE's closed word list, or nil."
  (cdr (assq type etaf-md--domains)))

(defun etaf-md--converts-p (type value)
  "Return non-nil when VALUE converts to TYPE.
A boolean false converts to nil, which is a value and not a failure."
  (pcase type
    ('boolean (or (memq value '(t nil))
                  (and (stringp value) (member value '("true" "false")))))
    (_ (and (etaf-md--convert type value) t))))

(defun etaf-md--value-problem (key decl value source)
  "Return a message when VALUE breaks DECL of KEY from SOURCE, else nil.
SOURCE is `document' or `rule'."
  (let* ((type (plist-get decl :type))
         (converted (etaf-md--convert type value))
         (name (substring (symbol-name key) 1)))
    (cond
     ((not (etaf-md--converts-p type value))
      (format "%s: %S is not a %s" name value type))
     ((and (eq type 'string) (plist-get decl :pattern)
           (not (string-match-p (plist-get decl :pattern) converted)))
      (format "%s: %S does not match %s" name value (plist-get decl :pattern)))
     ((and (eq type 'number) (plist-get decl :integer)
           (not (integerp converted)))
      (format "%s: %S is not an integer" name value))
     ((and (eq type 'number) (plist-get decl :min)
           (< converted (plist-get decl :min)))
      (format "%s: %S is below %s" name value (plist-get decl :min)))
     ((and (eq type 'number) (plist-get decl :max)
           (> converted (plist-get decl :max)))
      (format "%s: %S is above %s" name value (plist-get decl :max)))
     ((and (plist-get decl :one-of)
           (not (memq converted (plist-get decl :one-of))))
      (format "%s: %S is not one of %S" name value (plist-get decl :one-of)))
     ((and (eq type 'color) (eq source 'document)
           (not (string-match-p etaf-md--token-regexp converted)))
      (format "%s: a document writes a token, not %S" name value)))))

(defun etaf-md--shipped-declaration (type key)
  "Return KEY's declaration in TYPE's shipped definition."
  (or (etaf-md--declaration
       (plist-get (plist-get (etaf-md-node-definition type) :shipped) :attrs) key)
      (etaf-md--declaration
       (plist-get (etaf-md-node-definition type) :attrs) key)))

;;; Definition

(defun etaf-md--check (type decls derived)
  "Signal a declaration error for DECLS of TYPE; DERIVED marks that table."
  (let ((seen nil))
    (dolist (entry decls)
      (unless (and (consp entry) (symbolp (car entry)) (listp (cdr entry)))
        (signal 'etaf-md-error
                (list (format "%s: %S is not an attribute declaration" type entry))))
      (let ((key (etaf-md--key (car entry)))
            (decl (cdr entry)))
        (when (memq key seen)
          (signal 'etaf-md-error
                  (list (format "%s: %s is declared twice" type key))))
        (push key seen)
        (let ((type-name (plist-get decl :type)))
          (cond
           ((not (memq type-name etaf-md--attribute-types))
            (signal 'etaf-md-error
                    (list (format "%s.%s: unknown type %S" type key type-name))))
           ((and (eq type-name 'enum) (null (plist-get decl :one-of)))
            (signal 'etaf-md-error
                    (list (format "%s.%s: enum needs :one-of" type key))))
           ((and derived (plist-member decl :default))
            (signal 'etaf-md-error
                    (list (format "%s.%s: a derived attribute has no :default"
                                  type key))))
           ((and derived (plist-member decl :required))
            (signal 'etaf-md-error
                    (list (format "%s.%s: a derived attribute is never required"
                                  type key))))
           ((and (plist-get decl :required) (plist-member decl :default))
            (signal 'etaf-md-error
                    (list (format "%s.%s: :required and :default exclude each other"
                                  type key))))
           ((and (plist-member decl :pattern) (not (eq type-name 'string)))
            (signal 'etaf-md-error
                    (list (format "%s.%s: :pattern belongs to string" type key))))
           ((and (or (plist-member decl :min) (plist-member decl :max)
                     (plist-member decl :integer))
                 (not (eq type-name 'number)))
            (signal 'etaf-md-error
                    (list (format "%s.%s: :min, :max and :integer belong to number"
                                  type key))))
           ((and (plist-member decl :default)
                 (etaf-md--value-problem key decl (plist-get decl :default) 'rule))
            (signal 'etaf-md-error
                    (list (format "%s.%s: default %S does not fit"
                                  type key (plist-get decl :default)))))))))))

(defun etaf-md--shipped (definition)
  "Return the built-in snapshot of DEFINITION, or nil.
A snapshot is taken once, on the first definition of TYPE, so `:default' keeps
meaning the shipped value however many times a reader overrides it."
  (when definition
    (list :summary (plist-get definition :summary)
          :name (plist-get definition :name)
          :attrs (copy-tree (plist-get definition :attrs))
          :derived (copy-tree (plist-get definition :derived))
          :accepts (copy-tree (plist-get definition :accepts))
          :child-syntax (plist-get definition :child-syntax)
          :view (plist-get definition :view)
          :contract (plist-get definition :contract))))

(defun etaf-md-define-node (type &rest args)
  "Register or update the definition of TYPE.
ARGS follow article 10: :name, :summary, :attrs, :derived, :accepts,
:child-syntax, :contract, :view, :extends and :replace.  A second definition
of an existing type must say :extends or :replace; without either it is an
error.  `:child-syntax' is `blocks' (the default, one `:::name' per child) or
`markers' (one `@name' line per child)."
  (unless (symbolp type)
    (signal 'etaf-md-error (list (format "A type name is a symbol: %S" type))))
  (let* ((old (etaf-md-node-definition type))
         (extends (plist-get args :extends))
         (replace (plist-get args :replace))
         (added (etaf-md--declarations (plist-get args :attrs)))
         (derived (etaf-md--declarations (plist-get args :derived)))
         (old-attrs (plist-get old :attrs))
         (old-derived (plist-get old :derived)))
    (when (and old (not extends) (not replace))
      (signal 'etaf-md-error
              (list (format "%s is already defined; say :extends or :replace"
                            type))))
    (when (and (null old) (or extends replace))
      (signal 'etaf-md-error
              (list (format "%s has no definition to %s" type
                            (if extends "extend" "replace")))))
    (unless (memq (plist-get args :child-syntax) '(nil blocks markers))
      (signal 'etaf-md-error
              (list (format "%s: :child-syntax is blocks or markers" type))))
    (etaf-md--check type added nil)
    (etaf-md--check type derived t)
    (let* ((attrs (cond (replace added)
                        (extends (append (copy-tree old-attrs) added))
                        (t added)))
           (all-derived (cond (replace derived)
                              (extends (append (copy-tree old-derived) derived))
                              (t derived))))
      (unless replace
        (dolist (entry added)
          (when (and old (etaf-md--declaration old-attrs (car entry)))
            (signal 'etaf-md-error
                    (list (format "%s.%s is already declared" type (car entry)))))))
      (let ((definition
             (list :summary (or (plist-get args :summary)
                                (plist-get old :summary))
                   :name (or (plist-get args :name)
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
                   :default-view (and extends (plist-get old :view))
                   :contract (or (plist-get args :contract)
                                 (plist-get old :contract)
                                 etaf-md-contract)
                   :shipped (plist-get old :shipped)
                   :overridden (and old t))))
        (puthash type definition etaf-md-node-definitions)
        definition))))

(defun etaf-md--define-shipped (type &rest args)
  "Register TYPE as a shipped definition and keep it as the :default target.
Shipped definitions are the only ones with a snapshot, because `:default' means
the built-in value and a user type has none."
  (let ((definition (apply #'etaf-md-define-node type args)))
    (setq definition (plist-put definition :shipped (etaf-md--shipped definition)))
    (puthash type definition etaf-md-node-definitions)
    definition))

(defun etaf-md-undefine-node (type)
  "Remove TYPE's user definition.
A shipped type returns to its shipped declaration and paint; a user type
disappears from the registry."
  (let ((old (etaf-md-node-definition type)))
    (when old
      (if-let* ((shipped (plist-get old :shipped)))
          (puthash type shipped etaf-md-node-definitions)
        (remhash type etaf-md-node-definitions))
      (setq etaf-md-styles
            (cl-remove-if (lambda (entry) (eq (caar entry) type))
                          etaf-md-styles))))
  t)

(defun etaf-md-set-attr (selector rules)
  "Install RULES for SELECTOR, or remove them when RULES is nil.
SELECTOR is a list such as (heading) or (heading :level 2); RULES is a list of
(KEY VALUE) pairs.  A second call for the same selector replaces it, keeping
its place in the order."
  (unless (and (listp selector) (symbolp (car selector)))
    (signal 'etaf-md-error
            (list (format "A selector is a list starting with a type: %S"
                          selector))))
  (setq etaf-md-styles
        (cl-remove-if (lambda (entry) (equal (car entry) selector))
                      etaf-md-styles))
  (when rules
    (unless (cl-every (lambda (rule)
                        (and (consp rule) (keywordp (car rule))))
                      rules)
      (signal 'etaf-md-error
              (list (format "Rules are (KEY VALUE) pairs: %S" rules))))
    (setq etaf-md-styles (append etaf-md-styles (list (cons selector rules)))))
  etaf-md-styles)

(defun etaf-md-set-view (type function &rest args)
  "Give TYPE the paint FUNCTION.
ARGS accept :extends, :replace and :style-keys.  A nil FUNCTION puts the
previous paint back.  Without :replace the previous paint stays reachable as
`etaf-md-default-view'."
  (let ((definition (etaf-md-node-definition type)))
    (unless definition
      (signal 'etaf-md-error (list (format "No definition for %s" type))))
    (if (null function)
        (setq definition (plist-put definition :view
                                    (plist-get definition :default-view))
              definition (plist-put definition :default-view nil))
      (when-let* ((keys (plist-get args :style-keys)))
        (etaf-md--check type (etaf-md--declarations keys) nil)
        (dolist (entry (etaf-md--declarations keys))
          (when (etaf-md--declaration (plist-get definition :attrs) (car entry))
            (signal 'etaf-md-error
                    (list (format "%s.%s is already declared" type (car entry)))))
          (setq definition (plist-put definition :attrs
                                      (append (plist-get definition :attrs)
                                              (list entry))))))
      (unless (plist-get args :replace)
        (setq definition (plist-put definition :default-view
                                    (plist-get definition :view))))
      (setq definition (plist-put definition :view function)))
    (puthash type definition etaf-md-node-definitions)
    (etaf-md-node-definition type)))

;;; Resolution

(defun etaf-md--selector-value (node key)
  "Return KEY's value on NODE as a selector reads it.
A selector compares the document value, a derived value or the shipped
default; style rules take no part, so matching never depends on its own
result."
  (let* ((type (etaf-md-node-type node))
         (definition (etaf-md-node-definition type))
         (derived (etaf-md--declaration (plist-get definition :derived) key))
         (decl (or derived
                   (etaf-md--declaration (plist-get definition :attrs) key)))
         (raw (cond (derived (plist-get (etaf-md-node-attrs node) key))
                    ((plist-member (etaf-md-node-attrs node) key)
                     (plist-get (etaf-md-node-attrs node) key))
                    (t (plist-get decl :default)))))
    (if (null raw) nil (etaf-md--convert (plist-get decl :type) raw))))

(defun etaf-md--declaration-of (type key)
  "Return KEY's declaration in TYPE, derived or ordinary."
  (let ((definition (etaf-md-node-definition type)))
    (or (etaf-md--declaration (plist-get definition :derived) key)
        (etaf-md--declaration (plist-get definition :attrs) key))))

(defun etaf-md--selector-match-p (node selector)
  "Return non-nil when NODE matches SELECTOR.
A selector compares values as the document and the derive step leave them, so
a derived attribute may be selected on and a rule never matches itself."
  (and (eq (car selector) (etaf-md-node-type node))
       (cl-every (lambda (pair)
                   (let* ((key (etaf-md--key (car pair)))
                          (decl (etaf-md--declaration-of
                                 (etaf-md-node-type node) key)))
                     (and decl
                          (equal (etaf-md--selector-value node key)
                                 (etaf-md--convert (plist-get decl :type)
                                                   (cdr pair))))))
                 (cdr selector))))

(defun etaf-md--rule-value (node key)
  "Return (VALUE) when a rule sets KEY on NODE, or nil.
Later rules win, as the table is kept in order."
  (let (result)
    (dolist (entry etaf-md-styles)
      (when (etaf-md--selector-match-p node (car entry))
        (when-let* ((rule (assq (etaf-md--key key) (cdr entry))))
          (setq result (list (cadr rule))))))
    result))

(defun etaf-md--derived-p (type key)
  "Return non-nil when KEY is a derived attribute of TYPE."
  (and (etaf-md--declaration
        (plist-get (etaf-md-node-definition type) :derived) key)
       t))

(defun etaf-md--parent-declaration (parent node key)
  "Return KEY's declaration for NODE among PARENT's accepted children.
A child block is declared by the container that accepts it; the child's own
type has no definition to read from."
  (let* ((definition (etaf-md-node-definition
                      (etaf-md-node-type (etaf-md-env-node parent))))
         (accepts (plist-get definition :accepts))
         (entry (and accepts (assq (etaf-md-node-type node) accepts)))
         (decls (and (consp (cdr-safe entry))
                     (etaf-md--declarations (plist-get (cdr entry) :attrs)))))
    (and decls (etaf-md--declaration decls key))))

(defun etaf-md--value (node key &optional parent)
  "Return KEY's final value on NODE, following article 10.3.
PARENT, when given, is the environment node whose `:accepts' declares NODE's
attributes; a child block is declared by its container, so its type has no
definition of its own to read the declaration from."
  (let* ((type (etaf-md-node-type node))
         (definition (etaf-md-node-definition type))
         (derived (etaf-md--declaration (plist-get definition :derived) key))
         (child-decl
          (when (and parent (not (eq node (etaf-md-env-node parent))))
            (etaf-md--parent-declaration parent node key)))
         (decl (or derived
                   child-decl
                   (etaf-md--declaration (plist-get definition :attrs) key)))
         (rule (etaf-md--rule-value node key))
         (raw (cond
               (rule
                (let ((value (car rule)))
                  (cond ((null value) nil)
                        ((eq value :default)
                         (plist-get (etaf-md--shipped-declaration type key)
                                    :default))
                        (t value))))
               (derived (plist-get (etaf-md-node-attrs node) key))
               ((plist-member (etaf-md-node-attrs node) key)
                (plist-get (etaf-md-node-attrs node) key))
               (t (plist-get decl :default)))))
    (when raw
      (let ((converted (etaf-md--convert (plist-get decl :type) raw)))
        (cond ((not (null converted)) converted)
              ;; A boolean's false converts to nil, which is the value it
              ;; means.  Falling back to the raw string made every
              ;; `x=false' a truthy setting.
              ((eq (plist-get decl :type) 'boolean) nil)
              (t raw))))))

(defun etaf-md--problems (node)
  "Return (KEY MESSAGE) for every attribute of NODE that breaks its declaration.
A document value is checked against the ordinary table; a written derived
attribute is a problem.  The renderer shows one line per problem and keeps the
source, and a style rule with a bad key or value is ignored with its own line."
  (let* ((type (etaf-md-node-type node))
         (definition (etaf-md-node-definition type))
         (attrs (plist-get definition :attrs))
         (derived (plist-get definition :derived))
         (problems nil))
    (unless definition
      (push (list nil (format "%s has no definition" type)) problems))
    (when definition
      (let ((plist (etaf-md-node-attrs node)))
        (while plist
          (let* ((key (car plist))
                 (value (cadr plist))
                 (decl (etaf-md--declaration attrs key)))
            (cond
             ((etaf-md--declaration derived key)
              (push (list key (format "%s is derived; the parser writes it"
                                      (substring (symbol-name key) 1)))
                    problems))
             ((null decl)
              (push (list key (format "%s is not an attribute of %s"
                                      (substring (symbol-name key) 1) type))
                    problems))
             ((etaf-md--value-problem key decl value 'document)
              (push (list key (etaf-md--value-problem key decl value 'document))
                    problems))))
          (setq plist (cddr plist))))
      (dolist (decl attrs)
        (when (and (plist-get (cdr decl) :required)
                   (null (plist-get (etaf-md-node-attrs node) (car decl))))
          (push (list (car decl)
                      (format "%s is required" (substring (symbol-name (car decl)) 1)))
                problems))))
    (nreverse problems)))


(defun etaf-md--rule-problems (node)
  "Return (KEY MESSAGE) for every rule that names something NODE's type lacks.
A rule key must be an ordinary attribute of the type; a derived key may only be
a selector; a value must fit its declaration.  The bad rule is ignored and the
page reports one line, never aborting."
  (let* ((type (etaf-md-node-type node))
         (definition (etaf-md-node-definition type))
         (attrs (plist-get definition :attrs))
         (derived (plist-get definition :derived))
         (problems nil))
    (dolist (entry etaf-md-styles)
      (when (etaf-md--selector-match-p node (car entry))
        (dolist (rule (cdr entry))
          (let ((key (car rule)))
            (cond
             ((etaf-md--declaration derived key)
              (push (list key (format "%s is derived; it can only be a selector"
                                      (substring (symbol-name key) 1)))
                    problems))
             ((null (etaf-md--declaration attrs key))
              (push (list key (format "%s is not an attribute of %s"
                                      (substring (symbol-name key) 1) type))
                    problems))
             ((let ((value (cadr rule)))
                (and (not (eq value :default))
                     (etaf-md--value-problem
                      key (etaf-md--declaration attrs key) value 'rule)))
              (push (list key (etaf-md--value-problem
                               key (etaf-md--declaration attrs key)
                               (cadr rule) 'rule))
                    problems)))))))
    (nreverse problems)))

(defun etaf-md--all-problems (node)
  "Return NODE's declaration and rule problems, in that order."
  (append (etaf-md--problems node) (etaf-md--rule-problems node)))

;;; Derive

(defun etaf-md--roman (number)
  "Return NUMBER as an upper-case Roman numeral."
  (let ((specs '((1000 . "M") (900 . "CM") (500 . "D") (400 . "CD")
                 (100 . "C") (90 . "XC") (50 . "L") (40 . "XL")
                 (10 . "X") (9 . "IX") (5 . "V") (4 . "IV") (1 . "I")))
        (out ""))
    (dolist (spec specs out)
      (while (>= number (car spec))
        (setq out (concat out (cdr spec)))
        (setq number (- number (car spec)))))))

(defun etaf-md--outline-number (counters level numbering)
  "Return LEVEL's section number from COUNTERS under NUMBERING."
  (unless (eq numbering 'none)
    (let ((nums (cl-subseq counters 1 (1+ level))))
      (mapconcat
       (lambda (n)
         (pcase numbering
           ('lower-roman (downcase (etaf-md--roman n)))
           ('upper-alpha (format "%c" (+ 64 n)))
           (_ (number-to-string n))))
       nums "."))))

(defun etaf-md-derive-numbers (nodes)
  "Write a `number' on each heading in NODES, in document order.
The number is nil when that heading's resolved `numbering' is none.  Returns
NODES."
  (let ((counters (make-vector 7 0)))
    (dolist (node nodes nodes)
      (when (eq (etaf-md-node-type node) 'heading)
        (let* ((level (or (etaf-md--value node :level) 1))
               (numbering (or (etaf-md--value node :numbering) 'decimal)))
          (aset counters level (1+ (aref counters level)))
          (cl-loop for index from (1+ level) below (length counters)
                   do (aset counters index 0))
          (setf (etaf-md-node-attrs node)
                (plist-put (etaf-md-node-attrs node) :number
                           (etaf-md--outline-number counters level numbering))))))))

;;; Inspection

(defun etaf-md-describe-nodes (&optional type)
  "Return the registry as text, one type after another.
With TYPE, describe only that one."
  (let* ((types (if type
                    (list type)
                  (sort (hash-table-keys etaf-md-node-definitions) #'string<)))
         (lines nil))
    (dolist (name types)
      (let ((definition (etaf-md-node-definition name)))
        (push (format "%-19s%s"
                      name
                      (if (plist-get definition :name)
                          (format "文档写法 :::%s" (plist-get definition :name))
                        "内置语法，文档写不出名字"))
              lines)
        (push (format "  derived   %s"
                      (mapconcat (lambda (entry)
                                   (symbol-name (etaf-md--name (car entry))))
                                 (plist-get definition :derived)
                                 "  "))
              lines)
        (push (format "  ordinary  %s"
                      (mapconcat (lambda (entry)
                                   (symbol-name (etaf-md--name (car entry))))
                                 (plist-get definition :attrs)
                                 "  "))
              lines)
        (push (format "  rules     %s"
                      (mapconcat (lambda (entry) (format "%S" (car entry)))
                                 (cl-remove-if-not
                                  (lambda (entry) (eq (caar entry) name))
                                  etaf-md-styles)
                                 "  "))
              lines)))
    (mapconcat #'identity (nreverse lines) "\n")))


(defun etaf-md-load-node-directory ()
  "Load every `.el' file in `etaf-md-node-directory', in file-name order.
A missing directory is not an error: most readers keep their definitions in
their init file."
  (interactive)
  (when (file-directory-p etaf-md-node-directory)
    (dolist (file (sort (directory-files etaf-md-node-directory t "\\.el\\'")
                        #'string<))
      (load file nil t))))

(provide 'etaf-md-node)
;;; etaf-md-node.el ends here
