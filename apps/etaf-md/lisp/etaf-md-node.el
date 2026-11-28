;;; etaf-md-node.el --- Node types, declarations and style rules -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; Markdown node registry, value resolution and style rules built on
;; `etaf-doc-protocol'.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'etaf-doc)

(declare-function etaf-md-env-node "etaf-md-env" (env))

(defconst etaf-md-contract 1
  "Version of the document-side attribute table this build accepts.")

(defvar etaf-md-node-definitions (make-hash-table :test #'eq)
  "Registry mapping a type symbol to its definition plist.")

(defvar etaf-md-styles nil
  "Ordered style rules, oldest first.
Each entry is (SELECTOR RULE...), where SELECTOR is a list starting with the
type symbol and RULE is a (KEY VALUE) pair.")

(defcustom etaf-md-node-directory
  (locate-user-emacs-file "etaf-md/nodes")
  "Directory holding one user definition per file.
Its files load after the shipped definitions, in file-name order."
  :type 'directory
  :group 'etaf-md)

;;; Nodes

(cl-defstruct (etaf-md-node (:constructor etaf-md-node-create)
                            (:copier etaf-md-node-copy))
  "One node of a document tree: a type, a plist of attributes, children."
  type
  attrs
  children
  source
  block)

(defun etaf-md-node (type &optional attrs children)
  "Return a node of TYPE with ATTRS and CHILDREN."
  (etaf-md-node-create :type type :attrs attrs :children children))

(defun etaf-md-node-definition (type)
  "Return TYPE's definition plist, or nil."
  (gethash type etaf-md-node-definitions))

(defun etaf-md--child-syntax (type)
  "Return how container TYPE writes its children (`blocks' or `markers')."
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

(defun etaf-md--convert (type value)
  "Return VALUE converted to TYPE, or nil when it does not fit."
  (etaf-doc-protocol-convert type value))

(defun etaf-md--value-problem (key decl value source)
  "Return a message when VALUE breaks DECL of KEY from SOURCE, else nil."
  (etaf-doc-protocol-validate-value key decl value source 'en))

(defun etaf-md--shipped-declaration (type key)
  "Return KEY's declaration in TYPE's shipped definition."
  (or (etaf-md--declaration
       (plist-get (plist-get (etaf-md-node-definition type) :shipped) :attrs) key)
      (etaf-md--declaration
       (plist-get (etaf-md-node-definition type) :attrs) key)))

;;; Definition

(defun etaf-md--check (type decls derived)
  "Signal a declaration error for DECLS of TYPE; DERIVED marks that table."
  (etaf-doc-protocol-check-declarations type decls derived 'etaf-md-error nil))

(defun etaf-md-define-node (type &rest args)
  "Register or update the definition of TYPE."
  (etaf-doc-protocol-define-node
   etaf-md-node-definitions type args etaf-md-contract 'etaf-md-error nil nil))

(defun etaf-md--define-shipped (type &rest args)
  "Register TYPE as a shipped definition and keep it as the :default target."
  (etaf-doc-protocol-define-node
   etaf-md-node-definitions type args etaf-md-contract 'etaf-md-error t nil))

(defun etaf-md-undefine-node (type)
  "Remove TYPE's user definition."
  (setq etaf-md-styles
        (etaf-doc-protocol-undefine-node etaf-md-node-definitions etaf-md-styles type))
  t)

(defun etaf-md-set-attr (selector rules)
  "Install RULES for SELECTOR, or remove them when RULES is nil."
  (unless (and (listp selector) (symbolp (car selector)))
    (signal 'etaf-md-error
            (list (format "A selector is a list starting with a type: %S" selector))))
  (setq etaf-md-styles
        (cl-remove-if (lambda (entry) (equal (car entry) selector))
                      etaf-md-styles))
  (when rules
    (unless (cl-every (lambda (rule) (and (consp rule) (keywordp (car rule)))) rules)
      (signal 'etaf-md-error
              (list (format "Rules are (KEY VALUE) pairs: %S" rules))))
    (setq etaf-md-styles (append etaf-md-styles (list (cons selector rules)))))
  etaf-md-styles)

(defun etaf-md-set-view (type function &rest args)
  "Give TYPE the paint FUNCTION."
  (let ((definition (etaf-md-node-definition type)))
    (unless definition
      (signal 'etaf-md-error (list (format "No definition for %s" type))))
    (if (null function)
        (setq definition (plist-put definition :view (plist-get definition :default-view))
              definition (plist-put definition :default-view nil))
      (when-let* ((keys (plist-get args :style-keys)))
        (etaf-md--check type (etaf-md--declarations keys) nil)
        (dolist (entry (etaf-md--declarations keys))
          (when (etaf-md--declaration (plist-get definition :attrs) (car entry))
            (signal 'etaf-md-error
                    (list (format "%s.%s is already declared" type (car entry)))))
          (setq definition (plist-put definition :attrs
                                      (append (plist-get definition :attrs) (list entry))))))
      (unless (plist-get args :replace)
        (setq definition (plist-put definition :default-view (plist-get definition :view))))
      (setq definition (plist-put definition :view function)))
    (puthash type definition etaf-md-node-definitions)
    (etaf-md-node-definition type)))

;;; Resolution

(defun etaf-md--selector-value (node key)
  "Return KEY's value on NODE as a selector reads it."
  (let* ((type (etaf-md-node-type node))
         (definition (etaf-md-node-definition type))
         (derived (etaf-md--declaration (plist-get definition :derived) key))
         (decl (or derived (etaf-md--declaration (plist-get definition :attrs) key)))
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
  "Return non-nil when NODE matches SELECTOR."
  (and (eq (car selector) (etaf-md-node-type node))
       (cl-every (lambda (pair)
                   (let* ((key (etaf-md--key (car pair)))
                          (decl (etaf-md--declaration-of (etaf-md-node-type node) key)))
                     (and decl
                          (equal (etaf-md--selector-value node key)
                                 (etaf-md--convert (plist-get decl :type) (cdr pair))))))
                 (cdr selector))))

(defun etaf-md--rule-value (node key)
  "Return (VALUE) when a rule sets KEY on NODE, or nil."
  (let (result)
    (dolist (entry etaf-md-styles)
      (when (etaf-md--selector-match-p node (car entry))
        (when-let* ((rule (assq (etaf-md--key key) (cdr entry))))
          (setq result (list (cadr rule))))))
    result))

(defun etaf-md--derived-p (type key)
  "Return non-nil when KEY is a derived attribute of TYPE."
  (and (etaf-md--declaration (plist-get (etaf-md-node-definition type) :derived) key) t))

(defun etaf-md--parent-declaration (parent node key)
  "Return KEY's declaration for NODE among PARENT's accepted children."
  (let* ((definition (etaf-md-node-definition
                      (etaf-md-node-type (etaf-md-env-node parent))))
         (accepts (plist-get definition :accepts))
         (entry (and accepts (assq (etaf-md-node-type node) accepts)))
         (decls (and (consp (cdr-safe entry))
                     (etaf-md--declarations (plist-get (cdr entry) :attrs)))))
    (and decls (etaf-md--declaration decls key))))

(defun etaf-md--value (node key &optional parent)
  "Return KEY's final value on NODE."
  (let* ((type (etaf-md-node-type node))
         (definition (etaf-md-node-definition type))
         (derived (etaf-md--declaration (plist-get definition :derived) key))
         (child-decl
          (when (and parent (not (eq node (etaf-md-env-node parent))))
            (etaf-md--parent-declaration parent node key)))
         (decl (or derived child-decl
                   (etaf-md--declaration (plist-get definition :attrs) key)))
         (rule (etaf-md--rule-value node key))
         (raw (cond
               (rule
                (let ((value (car rule)))
                  (cond ((null value) nil)
                        ((eq value :default)
                         (plist-get (etaf-md--shipped-declaration type key) :default))
                        (t value))))
               (derived (plist-get (etaf-md-node-attrs node) key))
               ((plist-member (etaf-md-node-attrs node) key)
                (plist-get (etaf-md-node-attrs node) key))
               (t (plist-get decl :default)))))
    (when raw
      (let ((converted (etaf-md--convert (plist-get decl :type) raw)))
        (cond ((not (null converted)) converted)
              ((eq (plist-get decl :type) 'boolean) nil)
              (t raw))))))

(defun etaf-md--problems (node)
  "Return (KEY MESSAGE) for every attribute of NODE that breaks its declaration."
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
  "Return (KEY MESSAGE) for every rule that names something NODE's type lacks."
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

;;; Inspection

(defun etaf-md-describe-nodes (&optional type)
  "Return the registry as text, one type after another."
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
                      (mapconcat (lambda (entry) (symbol-name (etaf-md--name (car entry))))
                                 (plist-get definition :derived) "  "))
              lines)
        (push (format "  ordinary  %s"
                      (mapconcat (lambda (entry) (symbol-name (etaf-md--name (car entry))))
                                 (plist-get definition :attrs) "  "))
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
  "Load every `.el' file in `etaf-md-node-directory', in file-name order."
  (etaf-doc-protocol-load-directory etaf-md-node-directory))

(provide 'etaf-md-node)
;;; etaf-md-node.el ends here
