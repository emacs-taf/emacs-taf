;;; ecss-cascade.el --- Pure CSS cascade computation -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Geekinney
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; This module owns property schemas, stylesheets, cascade precedence,
;; inheritance, CSS-wide values, custom properties, and provenance.  All
;; computation is independent of buffers, text properties, and Ebox.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'ecss-selector)

(define-error 'ecss-invalid-property-schema
  "Invalid ECSS property schema" 'ecss-error)
(define-error 'ecss-invalid-declaration
  "Invalid ECSS declaration" 'ecss-error)
(define-error 'ecss-invalid-rule "Invalid ECSS rule" 'ecss-error)

(cl-defstruct (ecss-property-schema
               (:constructor ecss--make-property-schema))
  "Schema governing one namespaced cascade property."
  id owner initial inherits normalizer validator equality shorthand
  aliases impacts projections metadata)

(cl-defstruct (ecss-schema-package
               (:constructor ecss--make-schema-package)
               (:conc-name ecss--schema-package-))
  "Immutable property schema registry owned by one package."
  id table order)

(cl-defstruct (ecss-schema-set
               (:constructor ecss--make-schema-set)
               (:conc-name ecss--schema-set-))
  "Immutable composition of package-owned property schemas."
  package-ids table aliases order)

(cl-defstruct (ecss-stylesheet
               (:constructor ecss--make-stylesheet)
               (:conc-name ecss--stylesheet-))
  "Ordered rules and cascade layers with no global state."
  rules layers source-order)

(cl-defstruct (ecss-scope (:constructor ecss--make-scope))
  "A stylesheet mounted at a subject tree root."
  root stylesheet parent subjects)

(cl-defstruct (ecss-rule (:constructor ecss--make-rule))
  "One validated stylesheet rule."
  selector declarations origin layer layer-rank scope source-order)

(cl-defun ecss-scope-create (root stylesheet &key parent (subjects t))
  "Mount a snapshot of STYLESHEET at ROOT with optional PARENT scope.
SUBJECTS is t for all descendants, or a proper list of eligible subject
identities compared with `eq'.  The list is snapshotted; nil selects none.
Ordinary selector branches address strict descendants; `&' addresses ROOT.
Membership restricts declaration targets, not structural selector traversal
or inherited values.  Listed subjects must still lie within ROOT's tree.
Hosts retain ownership of subject identities and their adapter tree."
  (unless (and root (ecss-stylesheet-p stylesheet))
    (signal 'wrong-type-argument (list 'ecss-scope-create root stylesheet)))
  (when (and parent (not (ecss-scope-p parent)))
    (signal 'wrong-type-argument (list 'ecss-scope-p parent)))
  (unless (or (eq subjects t) (proper-list-p subjects))
    (signal 'wrong-type-argument (list 'listp subjects)))
  ;; A mounted scope is a value object.  Freeze the stylesheet at the mount
  ;; boundary so later mutations of the caller's builder cannot change an
  ;; already published scope.
  (let ((snapshot (ecss--make-stylesheet
                   :rules (mapcar #'copy-ecss-rule
                                  (ecss-stylesheet-rules stylesheet))
                   :layers (copy-tree (ecss-stylesheet-layers stylesheet))
                   :source-order (ecss--stylesheet-source-order stylesheet))))
    (ecss--make-scope
     :root root :stylesheet snapshot :parent parent
     :subjects (unless (eq subjects t)
                 (let ((members (make-hash-table :test #'eq)))
                   (dolist (subject subjects) (puthash subject t members))
                   members)))))

(defun ecss--scope-reference-p (selector)
  "Return whether SELECTOR contains a scope root reference."
  (and (consp selector)
       (or (eq (car selector) :scope-root)
           (and (eq (car selector) :state)
                (equal (nth 1 selector) "scope"))
           (cl-some #'ecss--scope-reference-p (cdr selector)))))

(defun ecss--subject-document-root (subject adapter)
  "Return the outermost parent of SUBJECT through ADAPTER."
  (let ((root subject) parent)
    (while (setq parent (ecss--subject-parent root adapter))
      (setq root parent))
    root))

(defun ecss--scope-selector (selector)
  "Anchor ordinary SELECTOR branches inside a mounted scope."
  (cond ((eq (car selector) :list)
         (cons :list (mapcar #'ecss--scope-selector (cdr selector))))
        ((ecss--scope-reference-p selector) selector)
        (t (list :descendant '(:scope-root) selector))))

(cl-defstruct (ecss-computed-style
               (:constructor ecss--make-computed-style)
               (:conc-name ecss--computed-style-))
  "Computed declarations, custom properties, metadata, and diagnostics."
  schemas values custom-properties active-properties specified-properties
  winners provenance diagnostics)

(cl-defstruct (ecss-computed-property-fact
               (:constructor ecss--make-computed-property-fact))
  "One detached typed value with its package-owned schema facts."
  (property nil :read-only t)
  (value nil :read-only t)
  (owner nil :read-only t)
  (impacts nil :read-only t)
  (projections nil :read-only t)
  (provenance nil :read-only t)
  (metadata nil :read-only t))

(cl-defstruct (ecss--wide (:constructor ecss--make-wide)) kind)
(cl-defstruct (ecss--important (:constructor ecss--make-important)) value)
(cl-defstruct (ecss--var-ref (:constructor ecss--make-var-ref))
  name fallback-present-p fallback)

(cl-defstruct (ecss--candidate (:constructor ecss--make-candidate))
  property value origin important inline layer layer-rank specificity
  scope-distance source-order declaration-order selector)

(defconst ecss--schema-option-keys
  '(:id :initial :inherits :normalizer :validator :equality :shorthand
    :aliases :impacts :projections :metadata)
  "Accepted keys in one package property definition.")

(defconst ecss--origins '(ua user author animation transition)
  "Supported standard CSS cascade origins.")

(defconst ecss--wide-kinds '(initial inherit unset revert revert-layer)
  "Supported CSS-wide value kinds.")

(defconst ecss--invalid (make-symbol "ecss-invalid-value"))
(defconst ecss--absent (make-symbol "ecss-absent-value"))

(defun ecss--schema-set-check (schemas)
  "Return SCHEMAS or signal when it is not a schema set."
  (unless (ecss-schema-set-p schemas)
    (signal 'wrong-type-argument (list 'ecss-schema-set-p schemas)))
  schemas)

(defun ecss--canonical-property-id-p (id)
  "Return non-nil when ID is a namespaced property symbol."
  (and (symbolp id)
       (let ((name (symbol-name id)))
         (and (string-match-p "/" name)
              (not (string-prefix-p "/" name))
              (not (string-suffix-p "/" name))))))

(defun ecss--custom-property-p (property)
  "Return non-nil when PROPERTY names a custom property."
  (and (symbolp property)
       (string-prefix-p "--" (symbol-name property))))

(defun ecss--options-valid-p (options)
  "Return non-nil when OPTIONS is an accepted property option plist."
  (and (listp options)
       (zerop (% (length options) 2))
       (cl-loop for key in options by #'cddr
                always (memq key ecss--schema-option-keys))))

(defun ecss--plist-unique-keys-p (plist)
  "Return non-nil when PLIST contains each key once."
  (let (seen valid)
    (setq valid t)
    (while (and plist valid)
      (let ((key (pop plist)))
        (pop plist)
        (setq valid (not (memq key seen)))
        (push key seen)))
    valid))

(defun ecss--unique-symbol-list-p (value &optional nonempty)
  "Return non-nil when VALUE is a unique symbol list.
When NONEMPTY is non-nil, reject an empty list."
  (and (proper-list-p value)
       (or (not nonempty) value)
       (cl-every (lambda (item)
                   (and (symbolp item) item))
                 value)
       (= (length value) (length (delete-dups (copy-sequence value))))))

(defun ecss--schema-option (options key fallback)
  "Return KEY from OPTIONS when present, otherwise FALLBACK."
  (if (plist-member options key) (plist-get options key) fallback))

(defun ecss--validate-schema-functions (options)
  "Validate callable schema fields in OPTIONS."
  (dolist (key '(:normalizer :validator :equality :shorthand))
    (let ((value (plist-get options key)))
      (unless (or (null value) (functionp value))
        (signal 'ecss-invalid-property-schema (list key value))))))

(defun ecss--normalize-schema-initial (initial normalizer validator)
  "Normalize and validate schema INITIAL with NORMALIZER and VALIDATOR."
  (let ((normalized
         (funcall normalizer (ecss--copy-boundary-data initial))))
    (unless (funcall validator normalized)
      (signal 'ecss-invalid-property-schema
              (list :invalid-initial initial)))
    (ecss--copy-boundary-data normalized)))

(defun ecss--build-property-schema (owner definition)
  "Build a validated property schema owned by OWNER from DEFINITION."
  (let ((id (plist-get definition :id)))
    (unless (and (ecss--canonical-property-id-p id)
                 (ecss--options-valid-p definition)
                 (ecss--plist-unique-keys-p definition)
                 (ecss--unique-symbol-list-p
                  (or (plist-get definition :aliases) nil))
                 (ecss--unique-symbol-list-p
                  (plist-get definition :impacts) t)
                 (ecss--unique-symbol-list-p
                  (or (plist-get definition :projections) nil)))
      (signal 'ecss-invalid-property-schema
              (list :property id definition)))
    (ecss--validate-schema-functions definition)
    (let* ((normalizer
            (ecss--schema-option definition :normalizer #'identity))
           (validator
            (ecss--schema-option
             definition :validator (lambda (_value) t)))
           (initial (ecss--normalize-schema-initial
                     (plist-get definition :initial) normalizer validator)))
      (ecss--make-property-schema
       :id id :owner owner :initial initial
       :inherits (and (plist-get definition :inherits) t)
       :normalizer normalizer :validator validator
       :equality (ecss--schema-option definition :equality #'equal)
       :shorthand (plist-get definition :shorthand)
       :aliases (ecss--copy-boundary-data (plist-get definition :aliases))
       :impacts (ecss--copy-boundary-data (plist-get definition :impacts))
       :projections (ecss--copy-boundary-data
                     (plist-get definition :projections))
      :metadata (ecss--copy-boundary-data
                  (plist-get definition :metadata))))))

(defun ecss--composition-collision (name kind existing-kind)
  "Signal NAME collision between KIND and EXISTING-KIND."
  (signal 'ecss-invalid-property-schema
          (list :collision name kind existing-kind)))

;;;###autoload
(defun ecss-schema-package-create (package-id definitions)
  "Create immutable PACKAGE-ID schema registry from DEFINITIONS."
  (unless (and (symbolp package-id) package-id (not (keywordp package-id)))
    (signal 'ecss-invalid-property-schema
            (list :package-id package-id)))
  (unless (proper-list-p definitions)
    (signal 'ecss-invalid-property-schema
            (list :definitions definitions)))
  (let ((table (make-hash-table :test #'eq))
        (aliases (make-hash-table :test #'eq))
        order)
    (dolist (definition definitions)
      (unless (proper-list-p definition)
        (signal 'ecss-invalid-property-schema
                (list :definition definition)))
      (let* ((schema (ecss--build-property-schema package-id definition))
             (id (ecss-property-schema-id schema)))
        (when (gethash id table)
          (signal 'ecss-invalid-property-schema
                  (list :duplicate-property id)))
        (when (gethash id aliases)
          (ecss--composition-collision id 'canonical 'alias))
        (puthash id schema table)
        (push id order)
        (dolist (alias (ecss-property-schema-aliases schema))
          (when (gethash alias table)
            (ecss--composition-collision alias 'alias 'canonical))
          (when (gethash alias aliases)
            (ecss--composition-collision alias 'alias 'alias))
          (puthash alias id aliases))))
    (ecss--make-schema-package
     :id package-id :table table :order (nreverse order))))

(defun ecss-schema-package-id (package)
  "Return immutable PACKAGE identity."
  (unless (ecss-schema-package-p package)
    (signal 'wrong-type-argument (list 'ecss-schema-package-p package)))
  (ecss--schema-package-id package))

(defun ecss-schema-package-property-ids (package)
  "Return canonical property identifiers owned by PACKAGE."
  (unless (ecss-schema-package-p package)
    (signal 'wrong-type-argument (list 'ecss-schema-package-p package)))
  (copy-sequence (ecss--schema-package-order package)))

;;;###autoload
(defun ecss-schema-set-compose (&rest packages)
  "Compose immutable PACKAGES into one atomic schema set."
  (let ((package-ids nil)
        (table (make-hash-table :test #'eq))
        (aliases (make-hash-table :test #'eq))
        order)
    (dolist (package packages)
      (unless (ecss-schema-package-p package)
        (signal 'wrong-type-argument (list 'ecss-schema-package-p package)))
      (let ((package-id (ecss--schema-package-id package)))
        (when (memq package-id package-ids)
          (signal 'ecss-invalid-property-schema
                  (list :duplicate-package package-id)))
        (push package-id package-ids))
      (dolist (id (ecss--schema-package-order package))
        (when (gethash id table)
          (ecss--composition-collision id 'canonical 'canonical))
        (when (gethash id aliases)
          (ecss--composition-collision id 'canonical 'alias))
        (let ((schema (gethash id (ecss--schema-package-table package))))
          (puthash id schema table)
          (push id order)
          (dolist (alias (ecss-property-schema-aliases schema))
            (when (gethash alias table)
              (ecss--composition-collision alias 'alias 'canonical))
            (when (gethash alias aliases)
              (ecss--composition-collision alias 'alias 'alias))
            (puthash alias id aliases)))))
    (ecss--make-schema-set
     :package-ids (nreverse package-ids) :table table :aliases aliases
     :order (nreverse order))))

(defun ecss--copy-property-schema (schema)
  "Return a defensive copy of SCHEMA."
  (let ((copy (copy-ecss-property-schema schema)))
    (setf (ecss-property-schema-initial copy)
          (ecss--copy-boundary-data
           (ecss-property-schema-initial schema))
          (ecss-property-schema-aliases copy)
          (ecss--copy-boundary-data (ecss-property-schema-aliases schema))
          (ecss-property-schema-impacts copy)
          (ecss--copy-boundary-data (ecss-property-schema-impacts schema))
          (ecss-property-schema-projections copy)
          (ecss--copy-boundary-data (ecss-property-schema-projections schema))
          (ecss-property-schema-metadata copy)
          (ecss--copy-boundary-data (ecss-property-schema-metadata schema)))
    copy))

(defun ecss-schema-set-package-ids (schemas)
  "Return package identities composed into SCHEMAS."
  (ecss--schema-set-check schemas)
  (copy-sequence (ecss--schema-set-package-ids schemas)))

(defun ecss-schema-set-canonical-id (schemas name)
  "Return canonical property identifier for NAME in SCHEMAS, or nil."
  (ecss--schema-set-check schemas)
  (cond ((gethash name (ecss--schema-set-table schemas)) name)
        ((gethash name (ecss--schema-set-aliases schemas)))))

(defun ecss-schema-set-property (schemas id)
  "Return a defensive property schema copy for ID or alias in SCHEMAS."
  (ecss--schema-set-check schemas)
  (when-let* ((canonical (ecss-schema-set-canonical-id schemas id))
              (schema (gethash canonical (ecss--schema-set-table schemas))))
    (ecss--copy-property-schema schema)))

(defun ecss-schema-set-property-ids (schemas)
  "Return property identifiers from SCHEMAS in registration order."
  (ecss--schema-set-check schemas)
  (copy-sequence (ecss--schema-set-order schemas)))

(defun ecss-schema-set-property-metadata (schemas id)
  "Return detached property metadata for ID in SCHEMAS."
  (ecss--schema-set-check schemas)
  (when-let* ((canonical (ecss-schema-set-canonical-id schemas id))
              (schema (gethash canonical (ecss--schema-set-table schemas))))
    (ecss--copy-boundary-data (ecss-property-schema-metadata schema))))

(defun ecss-property-equal-p (schemas property left right)
  "Return whether PROPERTY values LEFT and RIGHT are equal in SCHEMAS."
  (ecss--schema-set-check schemas)
  (let* ((canonical (ecss-schema-set-canonical-id schemas property))
         (schema (and canonical
                      (gethash canonical (ecss--schema-set-table schemas)))))
    (unless schema
      (signal 'ecss-invalid-declaration (list :unknown-property property)))
    (funcall (ecss-property-schema-equality schema) left right)))

;;;###autoload
(defun ecss-wide-value (kind)
  "Return a tagged CSS-wide value of KIND."
  (unless (memq kind ecss--wide-kinds)
    (signal 'ecss-invalid-declaration (list :wide-value kind)))
  (ecss--make-wide :kind kind))

;;;###autoload
(defun ecss-important (value)
  "Return VALUE tagged as an important declaration."
  (ecss--make-important :value value))

;;;###autoload
(defun ecss-declaration-value-tagged-p (value)
  "Return whether VALUE carries ECSS semantics requiring cascade computation.
Importance, CSS-wide values and variable references must be computed before
projection.  This inspects only the declaration value, not nested ordinary
data, and neither resolves nor mutates VALUE."
  (or (ecss--important-p value) (ecss--wide-p value) (ecss--var-ref-p value)))

;;;###autoload
(defun ecss-declaration-value-valid-p (value predicate)
  "Check concrete declaration VALUE with PREDICATE before cascade computation.
An importance tag is transparent to validation.  CSS-wide values and custom
property references are context-dependent and return t without calling
PREDICATE; their resolved values must pass the schema validator during
`ecss-compute-style'.  Other values are passed unchanged to PREDICATE.
Return a boolean.  This does not resolve variables, evaluate value sources
or change VALUE, and errors from PREDICATE propagate."
  (let ((raw (if (ecss--important-p value)
                 (ecss--important-value value) value)))
    (or (ecss--wide-p raw) (ecss--var-ref-p raw)
        (and (funcall predicate raw) t))))

;;;###autoload
(defun ecss-var (name &rest fallback)
  "Return a custom property reference to NAME with optional FALLBACK."
  (unless (ecss--custom-property-p name)
    (signal 'ecss-invalid-declaration (list :custom-property name)))
  (when (> (length fallback) 1)
    (signal 'wrong-number-of-arguments
            (list 'ecss-var (+ 1 (length fallback)))))
  (ecss--make-var-ref
   :name name :fallback-present-p (and fallback t) :fallback (car fallback)))

(defun ecss--declaration-list-p (declarations)
  "Return non-nil when DECLARATIONS is an even property/value list."
  (and (listp declarations) (zerop (% (length declarations) 2))))

(defun ecss--schema-for (schemas property)
  "Return PROPERTY schema from SCHEMAS, or nil."
  (when-let* ((canonical (ecss-schema-set-canonical-id schemas property)))
    (gethash canonical (ecss--schema-set-table schemas))))

(defun ecss--validate-declaration-property (schemas property)
  "Return PROPERTY when it is valid for SCHEMAS."
  (unless (or (ecss--custom-property-p property)
              (ecss--schema-for schemas property))
    (signal 'ecss-invalid-declaration (list :unknown-property property)))
  property)

(defun ecss--unwrap-important (value)
  "Return VALUE paired with whether it carries an important tag."
  (if (ecss--important-p value)
      (cons (ecss--important-value value) t)
    (cons value nil)))

(defun ecss--tag-important (declarations important)
  "Tag DECLARATIONS as IMPORTANT when requested."
  (if (not important)
      declarations
    (cl-loop for (property value) on declarations by #'cddr
             append (list property (ecss-important value)))))

(defun ecss--validate-expanded-longhands (schemas shorthand declarations)
  "Validate SHORTHAND expansion DECLARATIONS against SCHEMAS."
  (unless (ecss--declaration-list-p declarations)
    (signal 'ecss-invalid-declaration
            (list :shorthand shorthand declarations)))
  (cl-loop for (property _value) on declarations by #'cddr
           for schema = (progn
                          (ecss--validate-declaration-property schemas property)
                          (ecss--schema-for schemas property))
           when (and schema (ecss-property-schema-shorthand schema))
           do (signal 'ecss-invalid-declaration
                      (list :nested-shorthand shorthand property))))

(defun ecss--expand-declaration (schemas property value)
  "Expand one PROPERTY VALUE declaration using SCHEMAS."
  (ecss--validate-declaration-property schemas property)
  (let* ((canonical (or (ecss-schema-set-canonical-id schemas property)
                        property))
         (schema (ecss--schema-for schemas canonical)))
    (if-let* ((expander (and schema
                            (ecss-property-schema-shorthand schema))))
        (pcase-let* ((`(,raw . ,important) (ecss--unwrap-important value))
                     (expanded
                      (ecss--copy-boundary-data
                       (funcall expander
                                (ecss--copy-boundary-data raw)))))
          (ecss--validate-expanded-longhands schemas canonical expanded)
          (ecss--tag-important
           (cl-loop for (longhand longhand-value) on expanded by #'cddr
                    append
                    (list (or (ecss-schema-set-canonical-id schemas longhand)
                              longhand)
                          longhand-value))
           important))
      (list canonical (ecss--copy-boundary-data value)))))

;;;###autoload
(defun ecss-expand-declarations (schemas declarations)
  "Validate and expand DECLARATIONS through SCHEMAS."
  (ecss--schema-set-check schemas)
  (unless (ecss--declaration-list-p declarations)
    (signal 'ecss-invalid-declaration (list :declarations declarations)))
  (let ((seen (make-hash-table :test #'eq)) result)
    (cl-loop
     for (source-property source-value) on declarations by #'cddr
     for expanded = (ecss--expand-declaration
                     schemas source-property source-value)
     do
     (cl-loop
      for (property value) on expanded by #'cddr
      for previous = (gethash property seen)
      do
      (when previous
        (signal 'ecss-invalid-declaration
                (list :duplicate-property property
                      :first-source previous
                      :second-source source-property)))
      (puthash property source-property seen)
      (push property result)
      (push value result)))
    (nreverse result)))

;;;###autoload
(defun ecss-merge-declarations (schemas &rest declaration-groups)
  "Merge DECLARATION-GROUPS into canonical longhands using SCHEMAS.
Groups are applied from left to right.  Later values replace earlier values for
the same expanded longhand, including explicit nil declarations."
  (ecss--schema-set-check schemas)
  (let (result)
    (dolist (declarations declaration-groups result)
      (cl-loop for (property value)
               on (ecss-expand-declarations schemas declarations) by #'cddr
               do (setq result (plist-put result property value))))))

(defun ecss-stylesheet-create ()
  "Create an empty independent stylesheet."
  (ecss--make-stylesheet :rules nil :layers nil :source-order 0))

(defun ecss--stylesheet-check (stylesheet)
  "Return STYLESHEET or signal when it is invalid."
  (unless (ecss-stylesheet-p stylesheet)
    (signal 'wrong-type-argument (list 'ecss-stylesheet-p stylesheet)))
  stylesheet)

(defun ecss--copy-rule (rule)
  "Return a defensive copy of RULE."
  (let ((copy (copy-ecss-rule rule)))
    (setf (ecss-rule-selector copy)
          (ecss--copy-boundary-data (ecss-rule-selector rule))
          (ecss-rule-declarations copy)
          (ecss--copy-boundary-data (ecss-rule-declarations rule))
          (ecss-rule-layer copy)
          (ecss--copy-boundary-data (ecss-rule-layer rule))
          (ecss-rule-scope copy)
          (ecss--copy-boundary-data (ecss-rule-scope rule)))
    copy))

(defun ecss-stylesheet-rules (stylesheet)
  "Return defensive rule copies from STYLESHEET."
  (ecss--stylesheet-check stylesheet)
  (mapcar #'ecss--copy-rule (ecss--stylesheet-rules stylesheet)))

(defun ecss--origin-layers (stylesheet origin)
  "Return internal STYLESHEET layer order for ORIGIN."
  (cdr (assq origin (ecss--stylesheet-layers stylesheet))))

(defun ecss--set-origin-layers (stylesheet origin layers)
  "Set STYLESHEET ORIGIN order to LAYERS."
  (if-let* ((cell (assq origin (ecss--stylesheet-layers stylesheet))))
      (setcdr cell layers)
    (setf (ecss--stylesheet-layers stylesheet)
          (append (ecss--stylesheet-layers stylesheet)
                  (list (cons origin layers))))))

(defun ecss-stylesheet-layers (stylesheet &optional origin)
  "Return STYLESHEET layers for ORIGIN in declared order.
ORIGIN defaults to `author'."
  (ecss--stylesheet-check stylesheet)
  (ecss--copy-boundary-data
   (ecss--origin-layers
    stylesheet (ecss--validate-origin (or origin 'author)))))

(defun ecss-stylesheet-clear (stylesheet)
  "Remove all rules and layers from STYLESHEET."
  (ecss--stylesheet-check stylesheet)
  (setf (ecss--stylesheet-rules stylesheet) nil
        (ecss--stylesheet-layers stylesheet) nil
        (ecss--stylesheet-source-order stylesheet) 0)
  stylesheet)

(defun ecss-stylesheet-declare-layers (stylesheet layers &optional origin)
  "Append unseen LAYERS to STYLESHEET for ORIGIN and return their order.
ORIGIN defaults to `author'."
  (ecss--stylesheet-check stylesheet)
  (setq origin (ecss--validate-origin (or origin 'author)))
  (unless (and (listp layers) (cl-every (lambda (layer) layer) layers))
    (signal 'ecss-invalid-rule (list :layers layers)))
  (let ((result (ecss--copy-boundary-data
                 (ecss--origin-layers stylesheet origin))))
    (dolist (layer layers)
      (unless (member layer result)
        (setq result
              (append result (list (ecss--copy-boundary-data layer))))))
    (ecss--set-origin-layers stylesheet origin result)
    (ecss--copy-boundary-data result)))

(defun ecss--validate-origin (origin)
  "Return ORIGIN when it is a standard cascade origin."
  (unless (memq origin ecss--origins)
    (signal 'ecss-invalid-rule (list :origin origin)))
  origin)

(defun ecss--prospective-layer-rank (stylesheet origin layer)
  "Return ORIGIN LAYER rank in STYLESHEET without mutation."
  (when layer
    (let ((layers (ecss--origin-layers stylesheet origin)))
      (or (cl-position layer layers :test #'equal) (length layers)))))

(defun ecss--commit-rule (stylesheet rule layer)
  "Commit RULE and optional new LAYER to STYLESHEET."
  (let* ((origin (ecss-rule-origin rule))
         (layers (ecss--origin-layers stylesheet origin)))
    (when (and layer (not (member layer layers)))
      (ecss--set-origin-layers
       stylesheet origin
       (append layers (list (ecss--copy-boundary-data layer))))))
  (setf (ecss--stylesheet-source-order stylesheet)
        (ecss-rule-source-order rule)
        (ecss--stylesheet-rules stylesheet)
        (append (ecss--stylesheet-rules stylesheet) (list rule))))

;;;###autoload
(cl-defun ecss-stylesheet-add-rule
    (stylesheet schemas selector declarations
                &key (origin 'author) layer scope)
  "Add SELECTOR and DECLARATIONS to STYLESHEET using SCHEMAS.
ORIGIN defaults to `author'.  LAYER follows declaration order.  SCOPE is an
optional selector limiting the rule to a matching subject or ancestor."
  (ecss--stylesheet-check stylesheet)
  (ecss--schema-set-check schemas)
  (let* ((selector (ecss-selector-normalize selector))
         (scope (and scope (ecss-selector-normalize scope)))
         (origin (ecss--validate-origin origin))
         (expanded (ecss-expand-declarations schemas declarations))
         (source-order (1+ (ecss--stylesheet-source-order stylesheet)))
         (rule (ecss--make-rule
                :selector selector :declarations expanded
                :origin origin :layer (ecss--copy-boundary-data layer)
                :layer-rank (ecss--prospective-layer-rank
                             stylesheet origin layer)
                :scope scope :source-order source-order)))
    (ecss--commit-rule stylesheet rule layer)
    (ecss--copy-rule rule)))

(defun ecss--scope-distance (scope subject adapter)
  "Return SUBJECT distance to matching SCOPE through ADAPTER, or nil."
  (if (null scope)
      most-positive-fixnum
    (cl-loop for current = subject then (ecss--subject-parent current adapter)
             for distance from 0 while current
             when (ecss-selector-match-p scope current adapter)
             return distance)))

(defun ecss--rule-match-facts (rule subject adapter)
  "Return RULE match facts for SUBJECT through ADAPTER, or nil."
  (when-let* ((specificity
              (ecss--selector-matched-specificity
               (ecss-rule-selector rule) subject adapter)))
    (let ((distance (ecss--scope-distance
                     (ecss-rule-scope rule) subject adapter)))
      (when (numberp distance) (cons specificity distance)))))

(defun ecss--candidate-from-rule
    (rule property value specificity distance declaration-order)
  "Create a candidate from RULE, PROPERTY, and VALUE.
SPECIFICITY, DISTANCE, and DECLARATION-ORDER are the match precedence facts."
  (pcase-let ((`(,raw . ,important) (ecss--unwrap-important value)))
    (ecss--make-candidate
     :property property :value raw
     :origin (ecss-rule-origin rule)
     :important important :inline nil :layer (ecss-rule-layer rule)
     :layer-rank (ecss-rule-layer-rank rule) :specificity specificity
     :scope-distance distance :source-order (ecss-rule-source-order rule)
     :declaration-order declaration-order
     :selector (ecss-rule-selector rule))))

(defun ecss--rule-candidates (rule subject adapter &optional scope-root)
  "Return candidates from RULE for SUBJECT through ADAPTER.
SCOPE-ROOT, when supplied, bounds traversal and sets scope proximity."
  (when (or (null scope-root)
            (cl-loop for current = subject then (ecss--subject-parent current adapter)
                     while current thereis (eq current scope-root)))
    (let* ((ecss--document-root (ecss--subject-document-root subject adapter))
           (rule (if scope-root
                     (let ((copy (copy-ecss-rule rule)))
                       (setf (ecss-rule-selector copy)
                             (ecss--scope-selector
                              (ecss-rule-selector copy)))
                       copy)
                   rule))
           (ecss--scope-root scope-root)
          (adapter (if scope-root
                       (let ((copy (copy-ecss-subject-adapter adapter))
                             (parent (ecss-subject-adapter-parent adapter)))
                         (setf (ecss-subject-adapter-parent copy)
                               (lambda (node)
                                 (unless (eq node scope-root)
                                   (funcall parent node))))
                         copy)
                     adapter)))
      (when-let* ((facts (ecss--rule-match-facts rule subject adapter)))
        (when scope-root
          (let ((mount-distance
                 (cl-loop for current = subject then
                          (ecss--subject-parent current adapter)
                          for distance from 0
                          when (eq current scope-root) return distance)))
            ;; A rule may itself carry a scope selector.  Keep that
            ;; proximity and add the mounted boundary distance instead of
            ;; replacing it.
            (setcdr facts (+ mount-distance (or (cdr facts) 0)))))
       (cl-loop for (property value) on (ecss-rule-declarations rule) by #'cddr
             for declaration-order from 0
             collect (ecss--candidate-from-rule
                      rule property value (car facts) (cdr facts)
                      declaration-order))))))

(defun ecss--max-source-order (rules)
  "Return greatest source order in RULES."
  (cl-loop for rule in rules maximize (ecss-rule-source-order rule) into value
           finally return (or value 0)))

(defun ecss--inline-candidates (schemas declarations source-order)
  "Return inline candidates from DECLARATIONS using SCHEMAS and SOURCE-ORDER."
  (when declarations
    (cl-loop for (property value)
             on (ecss-expand-declarations schemas declarations) by #'cddr
             for declaration-order from 0
             collect
             (pcase-let ((`(,raw . ,important) (ecss--unwrap-important value)))
               (ecss--make-candidate
                :property property :value raw
                :origin 'author
                :important important :inline t :layer nil :layer-rank nil
                :specificity '(0 0 0)
                :scope-distance most-positive-fixnum
                :source-order source-order :declaration-order declaration-order
                :selector :inline)))))

(defun ecss--collect-candidates
    (schemas subject adapter declarations rules &optional scopes)
  "Collect candidates for SUBJECT, DECLARATIONS, and RULES.
SCHEMAS validates inline declarations and ADAPTER exposes SUBJECT."
  (append
   (cl-loop for rule in rules
            append (ecss--rule-candidates rule subject adapter))
   ;; Each sheet numbers its rules independently.  Flatten their source
   ;; order here so a later mount wins a complete tie across sheets, too.
   (let ((offset (1+ (ecss--max-source-order rules))))
     (cl-loop for scope in scopes
              ;; The mounted sheet already owns a snapshot.  Public rule
              ;; queries copy it for callers, not for internal matching.
              for scoped-rules = (ecss--stylesheet-rules
                                  (ecss-scope-stylesheet scope))
              append
              (prog1
                  (cl-loop for rule in scoped-rules
                           when (or (null (ecss-scope-subjects scope))
                                    (gethash subject (ecss-scope-subjects scope)))
                           append
                           (let ((candidates (ecss--rule-candidates
                                              rule subject adapter
                                              (ecss-scope-root scope))))
                             (dolist (candidate candidates)
                               (cl-incf (ecss--candidate-source-order candidate)
                                        offset))
                             candidates))
                (cl-incf offset (1+ (ecss--max-source-order scoped-rules))))))
   (ecss--inline-candidates
    schemas declarations (1+ (ecss--max-source-order rules)))))

(defun ecss--cascade-level-rank (candidate)
  "Return standard CSS origin and importance rank for CANDIDATE."
  (let ((origin (ecss--candidate-origin candidate))
        (important (ecss--candidate-important candidate)))
    (cond ((eq origin 'transition) 7)
          ((and important (eq origin 'ua)) 6)
          ((and important (eq origin 'user)) 5)
          ((and important (eq origin 'author)) 4)
          ((eq origin 'animation) 3)
          ((eq origin 'author) 2)
          ((eq origin 'user) 1)
          ((eq origin 'ua) 0))))

(defun ecss--candidate-cascade-layer-rank (candidate)
  "Return cascade layer rank for CANDIDATE."
  (let ((layer (ecss--candidate-layer candidate))
        (rank (ecss--candidate-layer-rank candidate))
        (important (ecss--candidate-important candidate)))
    (cond ((ecss--candidate-inline candidate) 2000000)
          ((and important (null layer)) -1000000)
          ((null layer) 1000000)
          (important (- (or rank 0)))
          (t (or rank 0)))))

(defun ecss--compare-number (left right)
  "Compare LEFT and RIGHT, returning 1, -1, or 0."
  (cond ((> left right) 1) ((< left right) -1) (t 0)))

(defun ecss--rank-list-comparison (left right)
  "Compare numeric rank lists LEFT and RIGHT."
  (catch 'comparison
    (cl-mapc (lambda (a b)
               (let ((value (ecss--compare-number a b)))
                 (unless (zerop value) (throw 'comparison value))))
             left right)
    0))

(defun ecss--candidate-primary-ranks (candidate)
  "Return primary cascade ranks for CANDIDATE."
  (list (ecss--cascade-level-rank candidate)
        (ecss--candidate-cascade-layer-rank candidate)))

(defun ecss--candidate-higher-p (left right)
  "Return non-nil when candidate LEFT outranks RIGHT."
  (let ((rank (ecss--rank-list-comparison
               (ecss--candidate-primary-ranks left)
               (ecss--candidate-primary-ranks right))))
    (cond ((not (zerop rank)) (> rank 0))
          ((not (equal (ecss--candidate-specificity left)
                       (ecss--candidate-specificity right)))
           (ecss--specificity-greater-p
            (ecss--candidate-specificity left)
            (ecss--candidate-specificity right)))
          ((/= (ecss--candidate-scope-distance left)
               (ecss--candidate-scope-distance right))
           (< (ecss--candidate-scope-distance left)
              (ecss--candidate-scope-distance right)))
          ((/= (ecss--candidate-source-order left)
               (ecss--candidate-source-order right))
           (> (ecss--candidate-source-order left)
              (ecss--candidate-source-order right)))
          (t (> (ecss--candidate-declaration-order left)
                (ecss--candidate-declaration-order right))))))

(defun ecss--group-candidates (candidates)
  "Group and sort CANDIDATES by property."
  (let ((table (make-hash-table :test #'eq)))
    (dolist (candidate candidates)
      (let ((property (ecss--candidate-property candidate)))
        (puthash property (cons candidate (gethash property table)) table)))
    (maphash (lambda (property values)
               (puthash property
                        (sort values #'ecss--candidate-higher-p) table))
             table)
    table))

(defun ecss--skip-reverted-origin (candidates winner)
  "Remove WINNER origin from CANDIDATES."
  (seq-remove
   (lambda (candidate)
     (eq (ecss--candidate-origin candidate)
         (ecss--candidate-origin winner)))
   candidates))

(defun ecss--skip-reverted-layer (candidates winner)
  "Remove WINNER origin and layer from CANDIDATES."
  (seq-remove
   (lambda (candidate)
     (and (eq (ecss--candidate-origin candidate)
              (ecss--candidate-origin winner))
          (equal (ecss--candidate-layer candidate)
                 (ecss--candidate-layer winner))))
   candidates))

(defun ecss--resolve-source (value property subject resolver)
  "Resolve VALUE for PROPERTY and SUBJECT only through explicit RESOLVER."
  (if resolver
      (ecss--copy-boundary-data
       (funcall resolver (ecss--copy-boundary-data value) property subject))
    value))

(defun ecss--parent-values (parent-style)
  "Return computed values from PARENT-STYLE."
  (cond ((ecss-computed-style-p parent-style)
         (ecss--computed-style-values parent-style))
        ((listp parent-style) parent-style)))

(defun ecss--parent-custom-properties (parent-style)
  "Return custom properties from PARENT-STYLE."
  (when (ecss-computed-style-p parent-style)
    (ecss--computed-style-custom-properties parent-style)))

(defun ecss--parent-property-active-p (parent-style property)
  "Return non-nil when PARENT-STYLE actively supplies PROPERTY."
  (cond ((ecss-computed-style-p parent-style)
         (memq property (ecss--computed-style-active-properties parent-style)))
        ((listp parent-style) (and (plist-member parent-style property) t))))

(defun ecss--property-default (schema parent-style)
  "Return default value and source for SCHEMA using PARENT-STYLE."
  (let* ((property (ecss-property-schema-id schema))
         (values (ecss--parent-values parent-style)))
    (if (and (ecss-property-schema-inherits schema)
             (plist-member values property))
        (cons (if (ecss-computed-style-p parent-style)
                  (plist-get values property)
                (ecss--copy-boundary-data (plist-get values property)))
              'inherit)
      (cons (ecss-property-schema-initial schema) 'initial))))

(defun ecss--wide-default (wide schema parent-style)
  "Resolve non-revert WIDE value for SCHEMA using PARENT-STYLE."
  (pcase (ecss--wide-kind wide)
    ('initial (cons (ecss-property-schema-initial schema) 'initial))
    ('inherit
     (let ((values (ecss--parent-values parent-style))
           (property (ecss-property-schema-id schema)))
       (if (plist-member values property)
           (cons (if (ecss-computed-style-p parent-style)
                     (plist-get values property)
                   (ecss--copy-boundary-data (plist-get values property)))
                 'inherit)
         (cons (ecss-property-schema-initial schema) 'initial))))
    ('unset (if (ecss-property-schema-inherits schema)
                (ecss--wide-default (ecss-wide-value 'inherit)
                                    schema parent-style)
              (cons (ecss-property-schema-initial schema) 'initial)))))

(defun ecss--candidate-provenance (candidate &rest extra)
  "Return public provenance for CANDIDATE followed by EXTRA facts."
  (append
   (if candidate
       (list :source 'declaration
             :selector (ecss--copy-boundary-data
                        (ecss--candidate-selector candidate))
             :origin (ecss--candidate-origin candidate)
             :important (and (ecss--candidate-important candidate) t)
             :inline (and (ecss--candidate-inline candidate) t)
             :layer (ecss--copy-boundary-data
                     (ecss--candidate-layer candidate))
             :specificity (copy-sequence
                           (ecss--candidate-specificity candidate))
             :scope-distance (ecss--candidate-scope-distance candidate)
             :source-order (ecss--candidate-source-order candidate)
             :declaration-order (ecss--candidate-declaration-order candidate))
     '(:source initial :origin ua))
   extra))

(defun ecss--select-custom-candidate
    (candidates inherited property subject resolver)
  "Select custom PROPERTY from CANDIDATES and INHERITED values."
  (let ((remaining candidates) selected winner done)
    (while (and remaining (not done))
      (setq winner (pop remaining))
      (let ((value (ecss--resolve-source
                    (ecss--candidate-value winner) property subject resolver)))
        (if (not (ecss--wide-p value))
            (setq selected value done t)
          (pcase (ecss--wide-kind value)
            ('revert (setq remaining
                           (ecss--skip-reverted-origin remaining winner)))
            ('revert-layer (setq remaining
                                 (ecss--skip-reverted-layer remaining winner)))
            ((or 'inherit 'unset)
             (setq selected (gethash property inherited ecss--absent)
                   done t))
            ('initial (setq selected ecss--absent done t))))))
    (unless done
      (setq selected (gethash property inherited ecss--absent)
            winner nil))
    (cons selected winner)))

(defun ecss--custom-candidate-properties (candidate-table)
  "Return custom property keys from CANDIDATE-TABLE in stable order."
  (let (properties)
    (maphash (lambda (property _candidates)
               (when (ecss--custom-property-p property)
                 (push property properties)))
             candidate-table)
    (sort properties
          (lambda (left right)
            (string< (symbol-name left) (symbol-name right))))))

(defun ecss--custom-raw-table
    (candidate-table parent-style subject resolver provenance-p)
  "Build raw custom properties from CANDIDATE-TABLE.
PARENT-STYLE supplies inheritance.  SUBJECT and RESOLVER handle explicit value
sources.  Retain winner facts when PROVENANCE-P is non-nil."
  (let ((table (make-hash-table :test #'eq)) provenance)
    (cl-loop for (property value) on (ecss--parent-custom-properties parent-style)
             by #'cddr
             do (puthash property (ecss--copy-boundary-data value) table)
             when provenance-p
             do (setq provenance
                      (plist-put provenance property '(:source inherit))))
    (dolist (property (ecss--custom-candidate-properties candidate-table))
      (pcase-let ((`(,value . ,winner)
                   (ecss--select-custom-candidate
                    (gethash property candidate-table) table property
                    subject resolver)))
        (if (eq value ecss--absent)
            (remhash property table)
          (puthash property value table))
        (when provenance-p
          (setq provenance
                (plist-put provenance property
                           (if winner (ecss--candidate-provenance winner)
                             '(:source inherit)))))))
    (list table provenance)))

(defun ecss--record-cycle (stack name diagnostics)
  "Record a custom property cycle from STACK through NAME in DIAGNOSTICS."
  (let ((path (reverse (cons name stack))))
    (unless (member (list :type 'variable-cycle :path path) (car diagnostics))
      (push (list :type 'variable-cycle :path path) (car diagnostics)))))

(defun ecss--resolve-var-fallback
    (reference raw resolved stack diagnostics)
  "Resolve REFERENCE fallback using RAW, RESOLVED, STACK, and DIAGNOSTICS."
  (if (ecss--var-ref-fallback-present-p reference)
      (ecss--resolve-variable-value
       (ecss--var-ref-fallback reference) raw resolved stack diagnostics)
    ecss--invalid))

(defun ecss--resolve-custom-property
    (name raw resolved stack diagnostics)
  "Resolve custom property NAME using RAW, RESOLVED, STACK, and DIAGNOSTICS."
  (let ((memo (gethash name resolved ecss--absent)))
    (cond ((not (eq memo ecss--absent)) memo)
          ((memq name stack)
           (ecss--record-cycle stack name diagnostics)
           ecss--invalid)
          (t
           (let ((value (gethash name raw ecss--absent)))
             (if (eq value ecss--absent)
                 ecss--invalid
               (let ((answer (ecss--resolve-variable-value
                              value raw resolved (cons name stack)
                              diagnostics)))
                 (puthash name answer resolved)
                 answer)))))))

(defun ecss--resolve-compound-value
    (value raw resolved stack diagnostics)
  "Resolve custom references recursively inside VALUE.
RAW and RESOLVED are custom-property tables.  STACK detects cycles and
DIAGNOSTICS records them."
  (cond ((functionp value) value)
        ((vectorp value)
         (let ((items (mapcar
                       (lambda (item)
                         (ecss--resolve-variable-value
                          item raw resolved stack diagnostics))
                       (append value nil))))
           (if (memq ecss--invalid items) ecss--invalid (vconcat items))))
        ((consp value)
         (let ((car-value (ecss--resolve-variable-value
                           (car value) raw resolved stack diagnostics))
               (cdr-value (ecss--resolve-variable-value
                           (cdr value) raw resolved stack diagnostics)))
           (if (or (eq car-value ecss--invalid)
                   (eq cdr-value ecss--invalid))
               ecss--invalid
             (cons car-value cdr-value))))
        (t value)))

(defun ecss--resolve-variable-value
    (value raw resolved stack diagnostics)
  "Resolve custom references in VALUE using RAW and RESOLVED tables.
STACK detects cycles and DIAGNOSTICS records them."
  (if (not (ecss--var-ref-p value))
      (ecss--resolve-compound-value value raw resolved stack diagnostics)
    (let ((answer (ecss--resolve-custom-property
                   (ecss--var-ref-name value) raw resolved stack diagnostics)))
      (if (eq answer ecss--invalid)
          (ecss--resolve-var-fallback
           value raw resolved stack diagnostics)
        answer))))

(defun ecss--resolved-custom-properties (raw diagnostics)
  "Return resolved custom properties from RAW with DIAGNOSTICS."
  (let ((resolved (make-hash-table :test #'eq)) names result)
    (maphash (lambda (name _value) (push name names)) raw)
    (dolist (name (sort names
                        (lambda (left right)
                          (string< (symbol-name left) (symbol-name right)))))
      (let ((value (ecss--resolve-custom-property
                    name raw resolved nil diagnostics)))
        (unless (eq value ecss--invalid)
          (setq result (plist-put result name value)))))
    result))

(defun ecss--custom-value-tables (custom)
  "Build RAW and RESOLVED tables from computed CUSTOM properties."
  (let ((raw (make-hash-table :test #'eq))
        (resolved (make-hash-table :test #'eq)))
    (cl-loop for (name value) on custom by #'cddr
             do (puthash name value raw)
             do (puthash name value resolved))
    (cons raw resolved)))

(defun ecss--resolve-property-value
    (value schema parent-style custom-tables diagnostics)
  "Resolve VALUE for SCHEMA using PARENT-STYLE, CUSTOM-TABLES, and DIAGNOSTICS."
  (cond ((and (ecss--wide-p value)
              (memq (ecss--wide-kind value) '(initial inherit unset)))
         (ecss--wide-default value schema parent-style))
        (t
         (pcase-let ((`(,raw . ,resolved)
                      custom-tables))
           (cons (ecss--resolve-variable-value
                  value raw resolved nil diagnostics)
                 'declaration)))))

(defun ecss--normalize-property-value (schema value)
  "Normalize and validate VALUE for SCHEMA, or return invalid sentinel."
  (if (eq value ecss--invalid)
      value
    (let ((normalized
           (funcall (ecss-property-schema-normalizer schema)
                    (ecss--copy-boundary-data value))))
      (if (funcall (ecss-property-schema-validator schema) normalized)
          (ecss--copy-boundary-data normalized)
        ecss--invalid))))

(defun ecss--compute-candidate-value
    (candidate schema source parent-style custom-tables diagnostics)
  "Resolve CANDIDATE for SCHEMA and computation context.
SOURCE is the already resolved candidate value.  PARENT-STYLE and CUSTOM-TABLES
supply inherited values, and DIAGNOSTICS records variable failures."
  (ignore candidate)
  (let* ((resolved (ecss--resolve-property-value
                    source schema parent-style custom-tables diagnostics)))
    (cons (if (eq (cdr resolved) 'declaration)
              (ecss--normalize-property-value schema (car resolved))
            (ecss--copy-boundary-data (car resolved)))
          (cdr resolved))))

(defun ecss--fallback-value (schema parent-style)
  "Return the computed default for SCHEMA using PARENT-STYLE."
  (pcase-let ((`(,value . ,source)
               (ecss--property-default schema parent-style)))
    (cons value source)))

(defun ecss--resolve-property-candidates
    (schema candidates parent-style custom-tables subject resolver diagnostics)
  "Resolve SCHEMA from ordered CANDIDATES.
PARENT-STYLE and CUSTOM-TABLES supply inherited values.  SUBJECT and RESOLVER
handle explicit sources, and DIAGNOSTICS records variable failures."
  (let ((remaining candidates) winner resolved)
    (while (and remaining (null winner))
      (let* ((candidate (pop remaining))
             (raw (ecss--resolve-source
                   (ecss--candidate-value candidate)
                   (ecss-property-schema-id schema) subject resolver)))
        (cond ((and (ecss--wide-p raw) (eq (ecss--wide-kind raw) 'revert))
               (setq remaining (ecss--skip-reverted-origin
                                remaining candidate)))
              ((and (ecss--wide-p raw)
                    (eq (ecss--wide-kind raw) 'revert-layer))
               (setq remaining (ecss--skip-reverted-layer
                                remaining candidate)))
              (t
               (setq winner candidate
                     resolved
                     (ecss--compute-candidate-value
                      candidate schema raw parent-style custom-tables
                      diagnostics))))))
    (let* ((invalid (and winner (eq (car resolved) ecss--invalid)))
           (final (if (or (null winner) invalid)
                      (ecss--fallback-value schema parent-style)
                    resolved)))
      (list (car final) winner invalid (cdr final)))))

(defun ecss--property-provenance (winner invalid source)
  "Return provenance from WINNER, INVALID state, and fallback SOURCE."
  (if winner
      (ecss--candidate-provenance
       winner :valid (not invalid)
       :value-source source
       :fallback (and invalid source))
    (list :source source :origin (if (eq source 'initial) 'ua 'inherit))))

(defun ecss--compute-property-values
    (schemas table parent-style custom-tables subject resolver diagnostics
             provenance-p)
  "Compute SCHEMAS property values from TABLE and context.
PARENT-STYLE and CUSTOM-TABLES supply inherited values.  SUBJECT and RESOLVER
handle explicit sources.  DIAGNOSTICS records failures; PROVENANCE-P retains
facts."
  (let (values active specified winners provenance)
    (dolist (property (ecss--schema-set-order schemas))
      (let ((schema (gethash property (ecss--schema-set-table schemas))))
        (unless (ecss-property-schema-shorthand schema)
          (pcase-let ((`(,value ,winner ,invalid ,source)
                       (ecss--resolve-property-candidates
                        schema (gethash property table) parent-style
                        custom-tables
                        subject resolver diagnostics)))
            (setq values (plist-put values property value))
            (when (or (and winner (not invalid))
                      (and (ecss-property-schema-inherits schema)
                           (ecss--parent-property-active-p parent-style property)))
              (push property active))
            (when winner
              (push property specified)
              (unless invalid
                (setq winners (plist-put winners property winner))))
            (when provenance-p
              (setq provenance
                    (plist-put provenance property
                               (ecss--property-provenance
                                winner invalid source))))))))
    (list values (nreverse active) (nreverse specified) winners provenance)))

(defun ecss--validate-rule-declarations (schemas rule)
  "Validate canonical declarations in RULE against SCHEMAS."
  (unless (ecss--declaration-list-p (ecss-rule-declarations rule))
    (signal 'ecss-invalid-rule (list :declarations rule)))
  (cl-loop for (property _value) on (ecss-rule-declarations rule) by #'cddr
           do (ecss--validate-declaration-property schemas property)
           for schema = (ecss--schema-for schemas property)
           when (and schema (ecss-property-schema-shorthand schema))
           do (signal 'ecss-invalid-rule (list :shorthand-snapshot property))))

(defun ecss--validate-rule-snapshot (schemas rule)
  "Return RULE after validating it against SCHEMAS."
  (unless (ecss-rule-p rule)
    (signal 'ecss-invalid-rule (list :rule rule)))
  (ecss--validate-selector (ecss-rule-selector rule))
  (when (ecss-rule-scope rule)
    (ecss--validate-selector (ecss-rule-scope rule)))
  (ecss--validate-origin (ecss-rule-origin rule))
  (unless (natnump (ecss-rule-source-order rule))
    (signal 'ecss-invalid-rule (list :source-order rule)))
  (ecss--validate-rule-declarations schemas rule)
  rule)

(defun ecss--active-rules (schemas stylesheet rules)
  "Return active rules for SCHEMAS from STYLESHEET or RULES."
  (when (and stylesheet rules)
    (signal 'ecss-invalid-rule (list :stylesheet-and-rules)))
  (let ((active (cond (stylesheet
                       (ecss--stylesheet-check stylesheet)
                       (ecss--stylesheet-rules stylesheet))
                      (rules rules))))
    (when rules
      (mapc (lambda (rule) (ecss--validate-rule-snapshot schemas rule)) active))
    active))

;;;###autoload
(cl-defun ecss-compute-style
    (schemas subject &key stylesheet rules declarations parent-style
             adapter provenance value-resolver scopes)
  "Compute a deterministic style for SUBJECT using SCHEMAS.
STYLESHEET or RULES supplies validated rules.  DECLARATIONS are inline.
PARENT-STYLE may be another computed style or a values plist.  ADAPTER exposes
caller-owned subjects.  PROVENANCE retains winner facts.  VALUE-RESOLVER, when
non-nil, is the only function allowed to evaluate caller-owned value sources;
it receives VALUE, PROPERTY, and SUBJECT.  Mutable VALUE data is detached
from the declaration; functions retain their identity."
  (ecss--schema-set-check schemas)
  (let ((adapter (or adapter ecss-default-subject-adapter)))
    (unless (ecss-subject-adapter-p adapter)
      (signal 'wrong-type-argument (list 'ecss-subject-adapter-p adapter)))
    (let* ((rules (ecss--active-rules schemas stylesheet rules))
           (table (ecss--group-candidates
                   (ecss--collect-candidates
                    schemas subject adapter declarations rules scopes)))
           (diagnostics (list nil))
           (raw-facts (ecss--custom-raw-table
                       table parent-style subject value-resolver provenance))
           (custom (ecss--resolved-custom-properties
                    (car raw-facts) diagnostics)))
      (let ((custom-tables (ecss--custom-value-tables custom)))
        (pcase-let ((`(,values ,active ,specified ,winners ,property-facts)
                   (ecss--compute-property-values
                    schemas table parent-style custom-tables subject value-resolver
                    diagnostics provenance)))
          (ecss--make-computed-style
           :schemas schemas :values values :custom-properties custom
           :active-properties active
           :specified-properties specified
           :winners winners
           :provenance (and provenance
                            (append (cadr raw-facts) property-facts))
           :diagnostics (nreverse (car diagnostics))))))))

;;;###autoload
(cl-defun ecss-computed-style-copy-with-values
    (style values &key active-properties specified-properties)
  "Return STYLE copied with replacement VALUES and optional metadata.

This is a narrow immutable-style transformation for consumers that have
already proved selector/cascade facts unchanged and only need to propagate a
safe computed-value delta.  Omitted ACTIVE-PROPERTIES and
SPECIFIED-PROPERTIES retain STYLE's metadata; all mutable values are copied at
the public boundary."
  (unless (ecss-computed-style-p style)
    (signal 'wrong-type-argument (list 'ecss-computed-style-p style)))
  (let ((copy (copy-ecss-computed-style style)))
    (setf (ecss--computed-style-values copy)
          (ecss--copy-boundary-data values))
    (when active-properties
      (setf (ecss--computed-style-active-properties copy)
            (ecss--copy-boundary-data active-properties)))
    (when specified-properties
      (setf (ecss--computed-style-specified-properties copy)
            (ecss--copy-boundary-data specified-properties)))
    copy))

(defun ecss--computed-style-check (style)
  "Return STYLE or signal when it is not a computed style."
  (unless (ecss-computed-style-p style)
    (signal 'wrong-type-argument (list 'ecss-computed-style-p style)))
  style)

(defun ecss-computed-style-values (style)
  "Return a defensive values plist from computed STYLE."
  (ecss--computed-style-check style)
  (ecss--copy-boundary-data (ecss--computed-style-values style)))

(defun ecss-computed-style-custom-properties (style)
  "Return a defensive custom property plist from computed STYLE."
  (ecss--computed-style-check style)
  (ecss--copy-boundary-data
   (ecss--computed-style-custom-properties style)))

(defun ecss-computed-style-active-properties (style)
  "Return actively supplied property identifiers from computed STYLE."
  (ecss--computed-style-check style)
  (ecss--copy-boundary-data
   (ecss--computed-style-active-properties style)))

(defun ecss-computed-style-specified-properties (style)
  "Return property identifiers with cascade winners from computed STYLE."
  (ecss--computed-style-check style)
  (ecss--copy-boundary-data
   (ecss--computed-style-specified-properties style)))

(defun ecss-computed-style-precedence-winner (style properties)
  "Return the highest-precedence declared property in PROPERTIES for STYLE.
PROPERTIES may use canonical IDs or aliases from STYLE's schema set.  Nil is
returned when none has a cascade winner.  The comparison reuses ECSS's exact
cascade ordering and does not require public provenance materialization."
  (setq style (ecss--computed-style-check style))
  (let ((schemas (ecss--computed-style-schemas style))
        (winners (ecss--computed-style-winners style))
        winner-property winner)
    (dolist (property properties winner-property)
      (let* ((canonical
              (or (ecss-schema-set-canonical-id schemas property)
                  (signal 'ecss-invalid-declaration
                          (list :unknown-property property))))
             (candidate (plist-get winners canonical)))
        (when (and candidate
                   (or (null winner)
                       (ecss--candidate-higher-p candidate winner)))
          (setq winner-property canonical
                winner candidate))))))

(defun ecss-computed-style-provenance (style)
  "Return defensive winner provenance from computed STYLE."
  (ecss--computed-style-check style)
  (ecss--copy-boundary-data (ecss--computed-style-provenance style)))

(defun ecss-computed-style-diagnostics (style)
  "Return defensive diagnostics from computed STYLE."
  (ecss--computed-style-check style)
  (ecss--copy-boundary-data (ecss--computed-style-diagnostics style)))

(defun ecss-computed-style-value (style property &optional fallback)
  "Return PROPERTY from computed STYLE, or FALLBACK when absent."
  (setq style (ecss--computed-style-check style))
  (let* ((schemas (ecss--computed-style-schemas style))
         (canonical (or (ecss-schema-set-canonical-id schemas property)
                        property))
         (values (ecss--computed-style-values style)))
    (if (plist-member values canonical)
        (ecss--copy-boundary-data (plist-get values canonical))
      fallback)))

(defun ecss-computed-style-property-fact (style property)
  "Return one immutable computed fact for PROPERTY in STYLE, or nil."
  (setq style (ecss--computed-style-check style))
  (let* ((schemas (ecss--computed-style-schemas style))
         (canonical (ecss-schema-set-canonical-id schemas property))
         (schema (and canonical
                      (gethash canonical (ecss--schema-set-table schemas))))
         (values (ecss--computed-style-values style)))
    (when (and schema (plist-member values canonical))
      (ecss--make-computed-property-fact
       :property canonical
       :value (ecss--copy-boundary-data (plist-get values canonical))
       :owner (ecss-property-schema-owner schema)
       :impacts (ecss--copy-boundary-data
                 (ecss-property-schema-impacts schema))
       :projections (ecss--copy-boundary-data
                     (ecss-property-schema-projections schema))
       :provenance
       (ecss--copy-boundary-data
        (plist-get (ecss--computed-style-provenance style) canonical))
       :metadata (ecss--copy-boundary-data
                  (ecss-property-schema-metadata schema))))))

(defun ecss-computed-style-present-p (style property)
  "Return non-nil when PROPERTY is actively supplied in computed STYLE."
  (setq style (ecss--computed-style-check style))
  (memq (or (ecss-schema-set-canonical-id
             (ecss--computed-style-schemas style) property)
            property)
        (ecss--computed-style-active-properties style)))

(defun ecss-computed-style-specified-p (style property)
  "Return non-nil when PROPERTY has a cascade winner in computed STYLE."
  (setq style (ecss--computed-style-check style))
  (memq (or (ecss-schema-set-canonical-id
             (ecss--computed-style-schemas style) property)
            property)
        (ecss--computed-style-specified-properties style)))

(provide 'ecss-cascade)
;;; ecss-cascade.el ends here
