;;; ecss.el --- Pure extensible CSS cascade engine -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Geekinney

;; Author: Geekinney <vhkdzszh@gmail.com>
;; URL: https://github.com/geekinney/ecss
;; Version: 0.1.0
;; Package-Requires: ((emacs "28.1"))
;; Keywords: lisp, extensions
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Assisted-by: Codex

;;; Commentary:

;; A CSS engine for Emacs Lisp: parse stylesheets, match selectors,
;; cascade declarations by origin, importance and layer, and resolve
;; computed values for a subject tree.
;;
;; Public API
;;
;; Load this package with (require 'ecss) after adding the repository
;; root to load-path.
;; Only the interfaces listed below are supported for use by other packages.
;; All unlisted symbols and implementation features are internal, including
;; names without a double hyphen.  Do not require files below lisp/ from consumers.
;; This Commentary is the authoritative export list; implementations and precise
;; docstrings remain beside their definitions.  The ETAF Reference Manual contains workflows.
;;
;; Function: ecss-compute-style (schemas subject &key stylesheet rules declarations parent-style adapter provenance value-resolver scopes)
;;;###autoload (autoload 'ecss-compute-style "ecss" nil nil)
;; Compute a deterministic style for SUBJECT using SCHEMAS.
;; STYLESHEET or RULES supplies validated rules.  DECLARATIONS are inline.
;; PARENT-STYLE may be another computed style or a values plist.  ADAPTER exposes
;; caller-owned subjects.  PROVENANCE retains winner facts.  VALUE-RESOLVER, when
;; non-nil, is the only function allowed to evaluate caller-owned value sources;
;; it receives VALUE, PROPERTY, and SUBJECT. Mutable VALUE data is detached
;; from the declaration; functions retain their identity.
;;
;; Function: ecss-computed-style-active-properties (style)
;;;###autoload (autoload 'ecss-computed-style-active-properties "ecss" nil nil)
;; Return actively supplied property identifiers from computed STYLE.
;;
;; Function: ecss-computed-style-copy-with-values (style values &key active-properties specified-properties)
;;;###autoload (autoload 'ecss-computed-style-copy-with-values "ecss" nil nil)
;; Return STYLE copied with replacement VALUES and optional metadata.
;;
;; This is a narrow immutable-style transformation for consumers that have
;; already proved selector/cascade facts unchanged and only need to propagate a
;; safe computed-value delta.  Omitted ACTIVE-PROPERTIES and
;; SPECIFIED-PROPERTIES retain STYLE's metadata; all mutable values are copied at
;; the public boundary.
;;
;; Function: ecss-computed-style-custom-properties (style)
;;;###autoload (autoload 'ecss-computed-style-custom-properties "ecss" nil nil)
;; Return a defensive custom property plist from computed STYLE.
;;
;; Function: ecss-computed-style-diagnostics (style)
;;;###autoload (autoload 'ecss-computed-style-diagnostics "ecss" nil nil)
;; Return defensive diagnostics from computed STYLE.
;;
;; Function: ecss-computed-style-p (x)
;;;###autoload (autoload 'ecss-computed-style-p "ecss" nil nil)
;;
;;
;; Function: ecss-computed-style-precedence-winner (style properties)
;;;###autoload (autoload 'ecss-computed-style-precedence-winner "ecss" nil nil)
;; Return the highest-precedence declared property in PROPERTIES for STYLE.
;; PROPERTIES may use canonical IDs or aliases from STYLE's schema set.  Nil is
;; returned when none has a cascade winner.  The comparison reuses ECSS's exact
;; cascade ordering and does not require public provenance materialization.
;;
;; Function: ecss-computed-style-present-p (style property)
;;;###autoload (autoload 'ecss-computed-style-present-p "ecss" nil nil)
;; Return non-nil when PROPERTY is actively supplied in computed STYLE.
;;
;; Function: ecss-computed-style-property-fact (style property)
;;;###autoload (autoload 'ecss-computed-style-property-fact "ecss" nil nil)
;; Return one immutable computed fact for PROPERTY in STYLE, or nil.
;;
;; Function: ecss-computed-style-provenance (style)
;;;###autoload (autoload 'ecss-computed-style-provenance "ecss" nil nil)
;; Return defensive winner provenance from computed STYLE.
;;
;; Function: ecss-computed-style-specified-p (style property)
;;;###autoload (autoload 'ecss-computed-style-specified-p "ecss" nil nil)
;; Return non-nil when PROPERTY has a cascade winner in computed STYLE.
;;
;; Function: ecss-computed-style-specified-properties (style)
;;;###autoload (autoload 'ecss-computed-style-specified-properties "ecss" nil nil)
;; Return property identifiers with cascade winners from computed STYLE.
;;
;; Function: ecss-computed-style-value (style property &optional fallback)
;;;###autoload (autoload 'ecss-computed-style-value "ecss" nil nil)
;; Return PROPERTY from computed STYLE, or FALLBACK when absent.
;;
;; Function: ecss-computed-style-values (style)
;;;###autoload (autoload 'ecss-computed-style-values "ecss" nil nil)
;; Return a defensive values plist from computed STYLE.
;;
;; Error: ecss-error
;; ECSS error
;; Catch this condition with condition-case; failed calls do not return a value.
;;
;; Function: ecss-declaration-value-tagged-p (value)
;;;###autoload (autoload 'ecss-declaration-value-tagged-p "ecss" nil nil)
;; Return whether VALUE carries ECSS importance, CSS-wide or variable semantics
;; and must be computed before projection. Ordinary nested data is not scanned;
;; this neither resolves nor mutates VALUE.
;;
;; Function: ecss-declaration-value-valid-p (value predicate)
;;;###autoload (autoload 'ecss-declaration-value-valid-p "ecss" nil nil)
;; Validate concrete VALUE through PREDICATE before cascade. Importance tags
;; are transparent; CSS-wide values and variable references defer validation
;; and return t. Their resolved values still require the schema validator in
;; `ecss-compute-style`. Other values pass unchanged to PREDICATE. Return a
;; boolean without mutation or source evaluation; predicate errors propagate.
;;
;; Function: ecss-expand-declarations (schemas declarations)
;;;###autoload (autoload 'ecss-expand-declarations "ecss" nil nil)
;; Validate and expand DECLARATIONS through SCHEMAS.
;;
;; Function: ecss-file-read (file)
;;;###autoload (autoload 'ecss-file-read "ecss" nil nil)
;; Read FILE as one inert ordered rule list via `ecss-read-rules`.
;; FILE must be readable. No outer quote or styles wrapper is accepted.
;;
;; Function: ecss-read-rules (source)
;;;###autoload (autoload 'ecss-read-rules "ecss" nil nil)
;; Read exactly one inert rule list from string SOURCE, allowing surrounding
;; comments and whitespace. Empty input, wrappers, trailing expressions and
;; malformed rules signal an error. Values are never evaluated or called.
;; Property semantics require the consumer's schema after reading.
;;
;; Function: ecss-validate-rules (rules)
;;;###autoload (autoload 'ecss-validate-rules "ecss" nil nil)
;; Validate ordered (SELECTOR PROPERTY VALUE ...) RULES without mutation and
;; return RULES. Selectors use ECSS strings; property identifiers are non-nil
;; symbols. Empty rules/declarations are allowed. Validate property names and
;; values against the consumer's schema separately. Values remain inert.
;;
;; Function: ecss-important (value)
;;;###autoload (autoload 'ecss-important "ecss" nil nil)
;; Return VALUE tagged as an important declaration.
;;
;; Error: ecss-invalid-declaration
;; Invalid ECSS declaration
;; Catch this condition with condition-case; failed calls do not return a value.
;;
;; Error: ecss-invalid-property-schema
;; Invalid ECSS property schema
;; Catch this condition with condition-case; failed calls do not return a value.
;;
;; Error: ecss-invalid-rule
;; Invalid ECSS rule
;; Catch this condition with condition-case; failed calls do not return a value.
;;
;; Error: ecss-invalid-selector
;; Invalid ECSS selector
;; Catch this condition with condition-case; failed calls do not return a value.
;;
;; Error: ecss-invalid-subject-adapter
;; Invalid ECSS subject adapter
;; Catch this condition with condition-case; failed calls do not return a value.
;;
;; Function: ecss-merge-declarations (schemas &rest declaration-groups)
;;;###autoload (autoload 'ecss-merge-declarations "ecss" nil nil)
;; Merge DECLARATION-GROUPS into canonical longhands using SCHEMAS.
;; Groups are applied from left to right.  Later values replace earlier values for
;; the same expanded longhand, including explicit nil declarations.
;;
;; Function: ecss-rule-scope (x)
;;;###autoload (autoload 'ecss-rule-scope "ecss" nil nil)
;; Access slot "scope" of `ecss-rule' struct X.
;;
;;
;; Function: ecss-rule-selector (x)
;;;###autoload (autoload 'ecss-rule-selector "ecss" nil nil)
;; Access slot "selector" of `ecss-rule' struct X.
;;
;;
;; Function: ecss-schema-package-create (package-id definitions)
;;;###autoload (autoload 'ecss-schema-package-create "ecss" nil nil)
;; Create immutable PACKAGE-ID schema registry from DEFINITIONS.
;;
;; Function: ecss-schema-package-id (package)
;;;###autoload (autoload 'ecss-schema-package-id "ecss" nil nil)
;; Return immutable PACKAGE identity.
;;
;; Function: ecss-schema-package-property-ids (package)
;;;###autoload (autoload 'ecss-schema-package-property-ids "ecss" nil nil)
;; Return canonical property identifiers owned by PACKAGE.
;;
;; Function: ecss-schema-set-canonical-id (schemas name)
;;;###autoload (autoload 'ecss-schema-set-canonical-id "ecss" nil nil)
;; Return canonical property identifier for NAME in SCHEMAS, or nil.
;;
;; Function: ecss-schema-set-compose (&rest packages)
;;;###autoload (autoload 'ecss-schema-set-compose "ecss" nil nil)
;; Compose immutable PACKAGES into one atomic schema set.
;;
;; Function: ecss-schema-set-package-ids (schemas)
;;;###autoload (autoload 'ecss-schema-set-package-ids "ecss" nil nil)
;; Return package identities composed into SCHEMAS.
;;
;; Function: ecss-schema-set-property (schemas id)
;;;###autoload (autoload 'ecss-schema-set-property "ecss" nil nil)
;; Return a defensive property schema copy for ID or alias in SCHEMAS.
;;
;; Function: ecss-schema-set-property-ids (schemas)
;;;###autoload (autoload 'ecss-schema-set-property-ids "ecss" nil nil)
;; Return property identifiers from SCHEMAS in registration order.
;;
;; Function: ecss-schema-set-property-metadata (schemas id)
;;;###autoload (autoload 'ecss-schema-set-property-metadata "ecss" nil nil)
;; Return detached property metadata for ID in SCHEMAS.
;;
;; Function: ecss-scope-create (root stylesheet &key parent (subjects t))
;;;###autoload (autoload 'ecss-scope-create "ecss" nil nil)
;; Mount a snapshot of STYLESHEET at ROOT with optional PARENT scope.
;; Ordinary selector branches address strict descendants; `&' addresses ROOT.
;; SUBJECTS is t (default) for unrestricted targets, or a proper list of subject
;; identities compared with eq.  nil selects none.  The list is snapshotted;
;; subjects and adapter trees remain host-owned.  Non-list membership signals
;; wrong-type-argument.  Listed subjects outside ROOT cannot match.  Membership
;; limits declaration targets, preserving structural traversal and inheritance.
;; PARENT is an optional scope association, supplied by keyword; it does not
;; automatically add or exclude subjects.  Pass every active scope to compute.
;;
;; Function: ecss-scope-stylesheet (x)
;;;###autoload (autoload 'ecss-scope-stylesheet "ecss" nil nil)
;; Access slot "stylesheet" of `ecss-scope' struct X.
;;
;;
;; Function: ecss-selector-match-p (selector subject &optional adapter)
;;;###autoload (autoload 'ecss-selector-match-p "ecss" nil nil)
;; Return non-nil when SELECTOR matches SUBJECT through optional ADAPTER.
;;
;; Function: ecss-selector-normalize (selector)
;;;###autoload (autoload 'ecss-selector-normalize "ecss" nil nil)
;; Return a validated defensive AST for string or structured SELECTOR.
;;
;; Function: ecss-selector-parse (selector)
;;;###autoload (autoload 'ecss-selector-parse "ecss" nil nil)
;; Parse CSS-like SELECTOR text into a structured selector AST.
;;
;; Function: ecss-selector-specificity (selector)
;;;###autoload (autoload 'ecss-selector-specificity "ecss" nil nil)
;; Return SELECTOR specificity as an (ID CLASS TYPE) list.
;;
;; Function: ecss-selector-subject-local-p (selector &optional scope-root-stable-p)
;;;###autoload (autoload 'ecss-selector-subject-local-p "ecss" nil nil)
;; Return non-nil when SELECTOR depends only on the matched subject.
;; Type, id, classes, attributes, states and local logical combinations qualify;
;; ancestor, child and sibling relationships do not.  Invalid selectors signal
;; `ecss-invalid-selector'.  With SCOPE-ROOT-STABLE-P, also allow `&' and `:scope':
;; the caller must prove the subject's relationship to the same scope root is
;; unchanged.  This does not establish membership, cascade or inheritance stability.
;;
;; Function: ecss-stylesheet-add-rule (stylesheet schemas selector declarations &key (origin 'author) layer scope)
;;;###autoload (autoload 'ecss-stylesheet-add-rule "ecss" nil nil)
;; Add SELECTOR and DECLARATIONS to STYLESHEET using SCHEMAS.
;; ORIGIN defaults to `author'.  LAYER follows declaration order.  SCOPE is an
;; optional selector limiting the rule to a matching subject or ancestor.
;;
;; Function: ecss-stylesheet-clear (stylesheet)
;;;###autoload (autoload 'ecss-stylesheet-clear "ecss" nil nil)
;; Remove all rules and layers from STYLESHEET.
;;
;; Function: ecss-stylesheet-create ()
;;;###autoload (autoload 'ecss-stylesheet-create "ecss" nil nil)
;; Create an empty independent stylesheet.
;;
;; Function: ecss-stylesheet-declare-layers (stylesheet layers &optional origin)
;;;###autoload (autoload 'ecss-stylesheet-declare-layers "ecss" nil nil)
;; Append unseen LAYERS to STYLESHEET for ORIGIN and return their order.
;; ORIGIN defaults to `author'.
;;
;; Function: ecss-stylesheet-layers (stylesheet &optional origin)
;;;###autoload (autoload 'ecss-stylesheet-layers "ecss" nil nil)
;; Return STYLESHEET layers for ORIGIN in declared order.
;; ORIGIN defaults to `author'.
;;
;; Function: ecss-stylesheet-rules (stylesheet)
;;;###autoload (autoload 'ecss-stylesheet-rules "ecss" nil nil)
;; Return defensive rule copies from STYLESHEET.
;;
;; Function: ecss-subject-adapter-create (&key type id classes attributes states parent children)
;;;###autoload (autoload 'ecss-subject-adapter-create "ecss" nil nil)
;; Create a subject adapter from the supplied callbacks.
;; TYPE, ID, CLASSES, ATTRIBUTES, STATES, PARENT, and CHILDREN each accept one
;; caller-owned subject and return the named field.
;;
;; Function: ecss-subject-attributes (x)
;;;###autoload (autoload 'ecss-subject-attributes "ecss" nil nil)
;; Access slot "attributes" of `ecss-subject' struct X.
;;
;;
;; Function: ecss-subject-children (x)
;;;###autoload (autoload 'ecss-subject-children "ecss" nil nil)
;; Access slot "children" of `ecss-subject' struct X.
;;
;;
;; Function: ecss-subject-classes (x)
;;;###autoload (autoload 'ecss-subject-classes "ecss" nil nil)
;; Access slot "classes" of `ecss-subject' struct X.
;;
;;
;; Function: ecss-subject-create (&key type id classes attributes states parent children)
;;;###autoload (autoload 'ecss-subject-create "ecss" nil nil)
;; Create a generic subject.
;; TYPE and ID identify it.  CLASSES and STATES are token lists.  ATTRIBUTES is
;; an alist.  PARENT and CHILDREN establish its initial tree position.
;;
;; Function: ecss-subject-id (x)
;;;###autoload (autoload 'ecss-subject-id "ecss" nil nil)
;; Access slot "id" of `ecss-subject' struct X.
;;
;;
;; Function: ecss-subject-parent (x)
;;;###autoload (autoload 'ecss-subject-parent "ecss" nil nil)
;; Access slot "parent" of `ecss-subject' struct X.
;;
;;
;; Function: ecss-subject-set-children (subject children)
;;;###autoload (autoload 'ecss-subject-set-children "ecss" nil nil)
;; Replace SUBJECT's CHILDREN and maintain their parent links.
;;
;; Function: ecss-subject-states (x)
;;;###autoload (autoload 'ecss-subject-states "ecss" nil nil)
;; Access slot "states" of `ecss-subject' struct X.
;;
;;
;; Function: ecss-subject-type (x)
;;;###autoload (autoload 'ecss-subject-type "ecss" nil nil)
;; Access slot "type" of `ecss-subject' struct X.
;;
;;
;; Function: ecss-var (name &rest fallback)
;;;###autoload (autoload 'ecss-var "ecss" nil nil)
;; Return a custom property reference to NAME with optional FALLBACK.
;;
;; Function: ecss-wide-value (kind)
;;;###autoload (autoload 'ecss-wide-value "ecss" nil nil)
;; Return a tagged CSS-wide value of KIND.
;;

;;; Code:

;;;###autoload
(eval-and-compile
  (add-to-list 'load-path
               (expand-file-name
                "lisp"
                (file-name-directory
                 (or (and load-file-name
                          ;; A native-compiled file lives in `eln-cache',
                          ;; where no sibling `lisp' directory exists.
                          (not (string-suffix-p ".eln" load-file-name))
                          load-file-name)
                     (bound-and-true-p byte-compile-current-file)
                     (locate-library "ecss")
                     buffer-file-name)))))

(require 'ecss-selector)
(require 'ecss-cascade)
(require 'ecss-file)

(provide 'ecss)
;;; ecss.el ends here
