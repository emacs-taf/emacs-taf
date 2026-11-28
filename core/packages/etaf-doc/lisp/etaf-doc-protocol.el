;;; etaf-doc-protocol.el --- Shared document node schema, validation & registry -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; Unified document node schema protocol shared by `etaf-md' and `etaf-org':
;; canonical attribute types, closed semantic domains (`surface', `accent',
;; `align'), type conversion, document/rule value validation, declaration
;; checking, `:extends' / `:replace' / `:shipped' registration, and sorted
;; user node-directory loading.

;;; Code:

(require 'cl-lib)
(require 'subr-x)

(defconst etaf-doc-protocol--attribute-types
  '(string number boolean length surface accent align enum color)
  "Attribute types a document node declaration may name.")

(defconst etaf-doc-protocol--domains
  '((surface none page raised sunken quote table-header table-stripe)
    (accent neutral primary success warning danger important)
    (align start center end))
  "Closed word lists of the three semantic document attribute types.")

(defconst etaf-doc-protocol--length-regexp
  "\\`\\([0-9]+\\(?:\\.[0-9]+\\)?\\)\\(ch\\|lh\\|%\\)\\'"
  "Shape of a length written in a document attribute or style rule.")

(defconst etaf-doc-protocol--color-regexp
  "\\`\\(?:[a-z][a-z0-9-]*\\|#[0-9a-fA-F]\\{3,8\\}\\)\\'"
  "Shape of a color token or hex literal accepted by a style rule.")

(defconst etaf-doc-protocol--token-regexp "\\`[a-z][a-z0-9-]*\\'"
  "Shape of a semantic color token permitted in document markup.")

(defun etaf-doc-protocol--attr-key (name)
  "Normalize attribute NAME to a keyword symbol."
  (if (keywordp name) name (intern (format ":%s" name))))

(defun etaf-doc-protocol--declarations (entries)
  "Normalize declaration ENTRIES keyed by keyword symbol."
  (mapcar (lambda (entry) (cons (etaf-doc-protocol--attr-key (car entry)) (cdr entry)))
          entries))

(defun etaf-doc-protocol--declaration (decls key)
  "Return KEY's declaration plist among normalized DECLS."
  (cdr (assq (etaf-doc-protocol--attr-key key) decls)))

(defun etaf-doc-protocol--domain (type)
  "Return TYPE's closed semantic domain word list, or nil."
  (cdr (assq type etaf-doc-protocol--domains)))

(defun etaf-doc-protocol-convert (type value)
  "Convert VALUE to document attribute TYPE, or return nil when incompatible.
TYPE is one of `string', `number', `boolean', `length', `surface', `accent',
`align', `enum' or `color'."
  (pcase type
    ('string (and (stringp value) value))
    ('number (cond ((numberp value) value)
                   ((and (stringp value)
                         (string-match-p "\\`-?[0-9]+\\(?:\\.[0-9]+\\)?\\'" value))
                    (string-to-number value))))
    ('boolean (cond ((eq value t) t)
                    ((null value) nil)
                    ((eq value 'true) t)
                    ((eq value 'false) nil)
                    ((and (stringp value)
                          (member (downcase value) '("t" "true" "yes")))
                     t)
                    ((and (stringp value)
                          (member (downcase value) '("nil" "false" "no")))
                     nil)))
    ('length (cond ((and (stringp value)
                         (string-match etaf-doc-protocol--length-regexp value))
                    (list (intern (match-string 2 value))
                          (string-to-number (match-string 1 value))))
                   ((and (consp value) (memq (car value) '(ch lh %)))
                    value)))
    ((or 'surface 'accent 'align 'enum)
     (and (or (symbolp value) (stringp value))
          (intern (downcase (format "%s" value)))))
    ('color (cond ((stringp value) value)
                  ((symbolp value) (symbol-name value))))
    (_ nil)))

(defun etaf-doc-protocol--converts-p (type value &optional strict-color)
  "Return non-nil when VALUE converts cleanly to TYPE.
When STRICT-COLOR is non-nil, colors must match the color regexp."
  (pcase type
    ('boolean (or (memq value '(t nil true false))
                  (and (stringp value)
                       (member (downcase value)
                               '("t" "nil" "true" "false" "yes" "no")))))
    ('string (stringp value))
    ('color (if strict-color
                (and (or (stringp value) (symbolp value))
                     (string-match-p etaf-doc-protocol--color-regexp
                                     (if (symbolp value) (symbol-name value) value)))
              (stringp value)))
    (_ (and (etaf-doc-protocol-convert type value) t))))

(defun etaf-doc-protocol-validate-value (key decl value source &optional style)
  "Return a diagnostic message when VALUE violates DECL for KEY from SOURCE.
SOURCE is `document' or `rule'.  STYLE may be `en' (default) or `zh' to select
English or Chinese diagnostic wording."
  (let* ((type (plist-get decl :type))
         (name (substring (symbol-name (etaf-doc-protocol--attr-key key)) 1))
         (zh (eq style 'zh))
         (strict-color zh))
    (if (not (etaf-doc-protocol--converts-p type value strict-color))
        (if zh
            (format "%s 的值 %S 不是合法的 %s" name value type)
          (format "%s: %S is not a %s" name value type))
      (let* ((converted (etaf-doc-protocol-convert type value))
             (domain (or (plist-get decl :one-of)
                         (when zh (etaf-doc-protocol--domain type)))))
        (cond
         ((and (eq type 'string) (plist-get decl :pattern)
               (not (string-match-p (plist-get decl :pattern) converted)))
          (if zh
              (format "%s 的值 %S 不符合格式 %s" name value (plist-get decl :pattern))
            (format "%s: %S does not match %s" name value (plist-get decl :pattern))))
         ((and (eq type 'number) (plist-get decl :integer)
               (not (integerp converted)))
          (if zh
              (format "%s 的值 %S 必须是整数" name value)
            (format "%s: %S is not an integer" name value)))
         ((and (eq type 'number) (plist-get decl :min)
               (< converted (plist-get decl :min)))
          (if zh
              (format "%s 的值 %S 小于下限 %s" name value (plist-get decl :min))
            (format "%s: %S is below %s" name value (plist-get decl :min))))
         ((and (eq type 'number) (plist-get decl :max)
               (> converted (plist-get decl :max)))
          (if zh
              (format "%s 的值 %S 超过上限 %s" name value (plist-get decl :max))
            (format "%s: %S is above %s" name value (plist-get decl :max))))
         ((and domain (not (memq converted domain)))
          (if zh
              (format "%s 的值是 %S，只允许 %s"
                      name value (mapconcat #'symbol-name domain "、"))
            (format "%s: %S is not one of %S" name value domain)))
         ((and (eq type 'color) (eq source 'document)
               (not (string-match-p etaf-doc-protocol--token-regexp converted)))
          (if zh
              (format "%s 在文档里只允许写令牌名，不能写 %S" name value)
            (format "%s: a document writes a token, not %S" name value))))))))

(defun etaf-doc-protocol-check-declarations (type decls derived error-symbol &optional allow-nil-default)
  "Validate attribute DECLS of TYPE; signal ERROR-SYMBOL on invalid shape.
DERIVED marks `:derived' tables.  When ALLOW-NIL-DEFAULT is non-nil, explicit
`:default nil' skips value checks."
  (let ((seen nil))
    (dolist (entry decls)
      (unless (and (consp entry) (symbolp (car entry)) (listp (cdr entry)))
        (signal error-symbol
                (list (format "%s: %S is not an attribute declaration" type entry))))
      (let ((key (etaf-doc-protocol--attr-key (car entry)))
            (decl (cdr entry)))
        (when (memq key seen)
          (signal error-symbol
                  (list (format "%s: %s is declared twice" type key))))
        (push key seen)
        (let ((type-name (plist-get decl :type)))
          (cond
           ((not (memq type-name etaf-doc-protocol--attribute-types))
            (signal error-symbol
                    (list (format "%s.%s: unknown type %S" type key type-name))))
           ((and (eq type-name 'enum) (null (plist-get decl :one-of)))
            (signal error-symbol
                    (list (format "%s.%s: enum needs :one-of" type key))))
           ((and derived (plist-member decl :default))
            (signal error-symbol
                    (list (format "%s.%s: a derived attribute has no :default"
                                  type key))))
           ((and derived (plist-member decl :required))
            (signal error-symbol
                    (list (format "%s.%s: a derived attribute is never required"
                                  type key))))
           ((and (plist-get decl :required) (plist-member decl :default))
            (signal error-symbol
                    (list (format "%s.%s: :required and :default exclude each other"
                                  type key))))
           ((and (plist-member decl :pattern) (not (eq type-name 'string)))
            (signal error-symbol
                    (list (format "%s.%s: :pattern belongs to string" type key))))
           ((and (or (plist-member decl :min) (plist-member decl :max)
                     (plist-member decl :integer))
                 (not (eq type-name 'number)))
            (signal error-symbol
                    (list (format "%s.%s: :min, :max and :integer belong to number"
                                  type key))))
           ((and (plist-member decl :default)
                 (not (and allow-nil-default (null (plist-get decl :default))))
                 (etaf-doc-protocol-validate-value key decl (plist-get decl :default) 'rule))
            (signal error-symbol
                    (list (format "%s.%s: default %S does not fit"
                                  type key (plist-get decl :default)))))))))))

(defun etaf-doc-protocol--shipped-snapshot (definition)
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

(defun etaf-doc-protocol-define-node (registry type args contract error-symbol &optional shipped-p allow-nil-default)
  "Register or update node TYPE in hash table REGISTRY using plist ARGS.
Supports `:name', `:summary', `:attrs', `:derived', `:accepts', `:child-syntax',
`:contract', `:view', `:extends' and `:replace'.  When SHIPPED-P is non-nil,
replaces any prior record and captures a `:shipped' snapshot."
  (unless (symbolp type)
    (signal error-symbol (list (format "A type name is a symbol: %S" type))))
  (when shipped-p
    (remhash type registry))
  (let* ((old (gethash type registry))
         (extends (plist-get args :extends))
         (replace (plist-get args :replace))
         (added (etaf-doc-protocol--declarations (plist-get args :attrs)))
         (derived (etaf-doc-protocol--declarations (plist-get args :derived)))
         (old-attrs (plist-get old :attrs))
         (old-derived (plist-get old :derived)))
    (when (and old (not extends) (not replace))
      (signal error-symbol
              (list (format "%s is already defined; say :extends or :replace" type))))
    (when (and (null old) (or extends replace))
      (signal error-symbol
              (list (format "%s has no definition to %s"
                            type (if extends "extend" "replace")))))
    (unless (memq (plist-get args :child-syntax) '(nil blocks markers))
      (signal error-symbol
              (list (format "%s: :child-syntax is blocks or markers" type))))
    (etaf-doc-protocol-check-declarations type added nil error-symbol allow-nil-default)
    (etaf-doc-protocol-check-declarations type derived t error-symbol allow-nil-default)
    (let* ((attrs (cond (replace added)
                        (extends (append (copy-tree old-attrs) added))
                        (t added)))
           (all-derived (cond (replace derived)
                              (extends (append (copy-tree old-derived) derived))
                              (t derived))))
      (unless replace
        (dolist (entry added)
          (when (and old (etaf-doc-protocol--declaration old-attrs (car entry)))
            (signal error-symbol
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
                                 contract)
                   :shipped (plist-get old :shipped)
                   :overridden (and old t))))
        (when shipped-p
          (setq definition
                (plist-put definition :shipped
                           (etaf-doc-protocol--shipped-snapshot definition))))
        (puthash type definition registry)
        definition))))

(defun etaf-doc-protocol-undefine-node (registry styles type)
  "Restore shipped TYPE or remove user TYPE from REGISTRY and STYLES.
Returns the updated STYLES list."
  (when-let* ((old (gethash type registry)))
    (if-let* ((shipped (plist-get old :shipped)))
        (let ((restored (copy-tree shipped)))
          (setq restored (plist-put restored :shipped (copy-tree shipped)))
          (puthash type restored registry))
      (remhash type registry)
      (setq styles
            (cl-remove-if (lambda (entry) (eq (caar entry) type))
                          styles))))
  styles)

(defun etaf-doc-protocol-load-directory (directory &optional label)
  "Load every `.el' file in DIRECTORY in sorted filename order.
Skips missing directories without error.  When LABEL is non-nil, catches load
errors per file and logs a warning prefixed with LABEL."
  (when (and (stringp directory) (file-directory-p directory))
    (dolist (file (sort (directory-files directory t "\\.el\\'") #'string<))
      (if label
          (condition-case err
              (load file nil t)
            (error
             (message "%s skipped user node %s: %s"
                      label (file-name-nondirectory file)
                      (error-message-string err))))
        (load file nil t)))))

(provide 'etaf-doc-protocol)
;;; etaf-doc-protocol.el ends here
