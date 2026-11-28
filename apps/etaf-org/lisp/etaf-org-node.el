;;; etaf-org-node.el --- Unified node types, declarations and style rules -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; Org node registry, value resolution and style rules built on
;; `etaf-doc-protocol'.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'etaf-doc)

(define-error 'etaf-org-error "Org document error")

(defconst etaf-org-contract 1
  "Version of the document-side attribute table this build accepts.")

(defvar etaf-org-node-definitions (make-hash-table :test #'eq)
  "Registry mapping a type symbol to its definition plist.")

(defvar etaf-org-styles nil
  "Ordered style rules, oldest first.")

(defcustom etaf-org-node-directory
  (locate-user-emacs-file "etaf-org/nodes")
  "Directory holding one user node definition per `.el' file."
  :type 'directory
  :group 'etaf-org)

(defconst etaf-org--max-nesting-depth 8
  "Maximum allowed nesting depth for container blocks.")

;;; Node record & lookup

(cl-defstruct (etaf-org-node (:constructor etaf-org-node-create)
                             (:copier etaf-org-node-copy))
  "One node of a document tree: TYPE, ATTRS plist, DERIVED plist, CHILDREN."
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
  (if (keywordp key) (intern (substring (symbol-name key) 1)) key))

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

(defun etaf-org--convert (type value)
  "Convert VALUE to attribute TYPE, or return nil when incompatible."
  (or (etaf-doc-protocol-convert type value)
      (when (eq type 'string)
        (cond ((symbolp value) (symbol-name value))
              ((numberp value) (number-to-string value))))))

(defun etaf-org--value-problem (key decl value source)
  "Return a diagnostic message when VALUE violates DECL for KEY from SOURCE."
  (etaf-doc-protocol-validate-value key decl value source 'zh))

;;; Registration API

(defun etaf-org-define-node (type &rest args)
  "Register a node TYPE, or extend or replace one."
  (etaf-doc-protocol-define-node
   etaf-org-node-definitions type args etaf-org-contract 'etaf-org-error nil t))

(defun etaf-org--define-shipped (type &rest args)
  "Register TYPE as a shipped node definition, safe on reload."
  (etaf-doc-protocol-define-node
   etaf-org-node-definitions type args etaf-org-contract 'etaf-org-error t t))

(defun etaf-org-undefine-node (type)
  "Remove TYPE's user definition."
  (setq etaf-org-styles
        (etaf-doc-protocol-undefine-node etaf-org-node-definitions etaf-org-styles type))
  nil)

(defun etaf-org-set-view (type function &rest args)
  "Give node TYPE the paint FUNCTION."
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

;;; Style rules & resolution

(defun etaf-org--validate-selector (selector)
  "Validate style SELECTOR `(TYPE :ATTR VAL ...)' and signal on bad shape."
  (unless (and (consp selector) (symbolp (car selector)))
    (signal 'etaf-org-error
            (list (format "Style selector must be a list starting with type: %S" selector))))
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
                  (list (format "Selector %S references undeclared attribute %s" selector k))))))))

(defun etaf-org-set-attr (selector rules)
  "Install style RULES for SELECTOR, or remove them when RULES is nil."
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
              (append etaf-org-styles (list (cons selector (nreverse normalized)))))))
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
                   ((and (listp actual) (not (listp want))) (member want actual))
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
  "Return final resolved value of KEY on NODE."
  (let* ((type (etaf-org-node-type node))
         (def (etaf-org-node-definition type))
         (k (etaf-org--attr-key key))
         (derived-decl (etaf-org--declaration (plist-get def :derived) k)))
    (if derived-decl
        (plist-get (etaf-org-node-derived node) k)
      (let* ((decl (etaf-org--declaration (plist-get def :attrs) k))
             (found nil)
             (value nil))
        (dolist (entry etaf-org-styles)
          (when (etaf-org--selector-matches-p (car entry) node)
            (dolist (pair (cdr entry))
              (when (eq (etaf-org--attr-key (car pair)) k)
                (setq found t value (cadr pair))))))
        (cond
         ((and found (eq value :default)) (etaf-org--shipped-default type k))
         (found
          (if (null value) nil
            (if decl (etaf-org--convert (plist-get decl :type) value) value)))
         ((plist-member (etaf-org-node-attrs node) k)
          (let ((doc-val (plist-get (etaf-org-node-attrs node) k)))
            (if (null doc-val) nil
              (if decl (etaf-org--convert (plist-get decl :type) doc-val) doc-val))))
         ((and decl (plist-member decl :default))
          (let ((def-val (plist-get decl :default)))
            (if (null def-val) nil
              (etaf-org--convert (plist-get decl :type) def-val))))
         (t nil))))))

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
             (allowed-names (mapcar (lambda (d) (substring (symbol-name (car d)) 1))
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
                            (if allowed-names (mapconcat #'identity allowed-names "、") "无"))
                    problems))
             (t
              (let ((decl (etaf-org--declaration attrs-decls k)))
                (when-let* ((p (etaf-org--value-problem k decl v 'document)))
                  (push (format "line %d: %s 的 %s" line type p) problems)))))))
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

;;; Introspection & user directory loader

(defun etaf-org-describe-nodes (&optional type)
  "Return the node registry as readable text, one type per stanza."
  (let ((types (if type
                   (list type)
                 (sort (let (keys)
                         (maphash (lambda (k _v) (push k keys)) etaf-org-node-definitions)
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
                                    (if doc-name (format "#+begin_%s" doc-name) "内置语法")
                                    (if (string-empty-p summary) "" (concat " — " summary))))))
          (when derived (push (format "  derived   %s" (string-join derived "  ")) lines))
          (when ordinary (push (format "  ordinary  %s" (string-join ordinary "  ")) lines))
          (when accepts
            (push (format "  accepts   %s (%s)"
                          (mapconcat (lambda (a) (format "%s" (car a))) accepts ", ")
                          syntax)
                  lines))
          (when rules (push (format "  rules     %s" (string-join rules "  ")) lines))
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
    (etaf-doc-protocol-load-directory etaf-org-node-directory "etaf-org")))

(provide 'etaf-org-node)
;;; etaf-org-node.el ends here
