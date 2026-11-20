;;; etaf-component.el --- ETAF Component definitions -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Components have one public definition boundary with two authoring
;; frontends: compiled `:view' DSL and ordinary Elisp `:render'.  Optional
;; `:bindings' initializes named instance values; optional `:setup' registers
;; lifecycle work.  Opaque setup results remain an advanced authoring option.

;;; Code:

(require 'cl-lib)
(require 'macroexp)
(require 'etaf-reactive)
(require 'etaf-view)
(require 'ecss)
(require 'etaf-compiler)

(define-error 'etaf-component-definition-error
  "Invalid ETAF Component definition"
  'etaf-view-error)

(cl-defstruct (etaf--slot-content (:constructor etaf--slot-content-create))
  "Internal caller ownership metadata for one slot entry."
  owner-component-id children)

(cl-defstruct (etaf--component-bindings
               (:constructor etaf--component-bindings-create))
  "Instance-owned lexical values."
  values)

(defvar etaf--raw-slot-read-p nil
  "Set while a Component render uses public raw slot accessors.")

(defvar etaf--component-phase nil
  "Dynamic Component phase, either `setup', `render', or nil.")

(defvar etaf--current-component-state nil
  "Opaque setup result supplied by the current Runtime Component context.")

(defvar etaf--current-component-setup-defined-p nil
  "Whether the current Component definition declares setup.")

(defvar etaf--current-component-setup-complete-p nil
  "Whether the current Component instance completed setup.")

(defconst etaf--component-reserved-props
  '(key if else-if else for)
  "Framework names forbidden in Component business prop declarations.")

(defun etaf--component-definition-error (format-string &rest arguments)
  "Signal a Component definition error from FORMAT-STRING and ARGUMENTS."
  (signal 'etaf-component-definition-error
          (list (apply #'format format-string arguments))))

(defun etaf--parse-component-props (arguments)
  "Return prop names from Component argument declaration ARGUMENTS."
  (unless (proper-list-p arguments)
    (etaf--component-definition-error
     "Component prop declaration must be a proper list: %S" arguments))
  (let ((tail arguments)
        prop-names)
    (when tail
      (unless (eq (pop tail) '&key)
        (etaf--component-definition-error
         "Component props must use (&key NAME ...), got %S" arguments)))
    (dolist (entry tail)
      (unless (or (symbolp entry)
                  (and (proper-list-p entry) (= (length entry) 2)
                       (symbolp (car entry))))
        (etaf--component-definition-error
         "Component props must be NAME or (NAME DEFAULT): %S" entry))
      (let ((name (if (consp entry) (car entry) entry)))
        (when (or (keywordp name) (memq name '(nil t))
                  (string-prefix-p "&" (symbol-name name)))
          (etaf--component-definition-error
           "Component prop name must be an ordinary symbol: %S" name))
        (when (memq name prop-names)
          (etaf--component-definition-error
           "Duplicate Component prop: %S" name))
        (when (memq name etaf--component-reserved-props)
          (etaf--component-definition-error
           "Component prop %S is reserved by the View grammar" name))
        (push name prop-names)))
    (nreverse prop-names)))

(defun etaf--component-prop-key (name)
  "Return the public keyword used to pass prop NAME."
  (if (keywordp name)
      name
    (intern (concat ":" (symbol-name name)))))

(defun etaf-current-prop (name)
  "Return current Component prop NAME.

NAME is normally an ordinary symbol used by the `:setup' lexical shorthand.
The function is also useful to code that deliberately avoids that shorthand.
During view/render the read is reactive: the calling binding re-runs when
the caller later supplies a different value."
  (let ((props etaf--current-component-props))
    (if (vectorp props)
        (let ((index (cl-position
                      (if (keywordp name)
                          (intern (substring (symbol-name name) 1))
                        name)
                      (aref props 0))))
          (and index (etaf-value (aref props (1+ index)))))
      (plist-get props (etaf--component-prop-key name)))))

;;;###autoload
(defun etaf-state ()
  "Return the current Component instance's exact setup result.
The accessor is valid only while rendering a Component that declares setup.
A defined setup may return nil; setup presence is tracked independently.
Components using named bindings must refer to those values directly."
  (unless (and (eq etaf--component-phase 'render)
               etaf--current-component-instance)
    (etaf--component-definition-error
     "ETAF state is available only during Component view/render"))
  (unless etaf--current-component-setup-defined-p
    (etaf--component-definition-error
     "Current Component does not declare :setup"))
  (unless etaf--current-component-setup-complete-p
    (etaf--component-definition-error
     "Current Component setup has not completed"))
  (if (etaf--component-bindings-p etaf--current-component-state)
      (etaf--component-definition-error
       "Current Component uses :bindings; refer to its named values directly")
    etaf--current-component-state))

;;;###autoload
(defun etaf-component-set-styles (name styles)
  "Replace the static style form for Component NAME with STYLES.

STYLES must use the same `((SELECTOR PROPERTY VALUE ...) ...)'
contract accepted by `etaf-define-component'.  This small runtime authoring
hook is useful to tools which reload a stylesheet without redefining the
Component itself, such as a source/preview playground.  The next mount or
render observes the replacement; existing mounted runtimes are not flushed
implicitly."
  (let ((spec (and (boundp 'etaf--view-registry)
                   (gethash name etaf--view-registry))))
    (unless (and (symbolp name) (etaf--component-spec-p spec))
      (etaf--component-definition-error
       "Unknown ETAF Component: %S" name))
    (etaf--validate-styles-form styles name)
    (setf (etaf--component-spec-styles spec) styles)
    styles))

(defun etaf-component-styles (name)
  "Return the current static style form for Component NAME."
  (let ((spec (and (boundp 'etaf--view-registry)
                   (gethash name etaf--view-registry))))
    (unless (and (symbolp name) (etaf--component-spec-p spec))
      (etaf--component-definition-error
       "Unknown ETAF Component: %S" name))
    (etaf--component-spec-styles spec)))

;;;###autoload
(defun etaf-component-redefine-run (function)
  "Run FUNCTION while allowing intentional Component redefinition.

Duplicate Component definitions remain errors except for unchanged declarations
reloaded from the same library, which keep their original definition.  Authoring
tools use this boundary after disposing the old Runtime to replace a declaration
or refresh its captured values, even when its source text is unchanged."
  (unless (functionp function)
    (signal 'wrong-type-argument (list 'functionp function)))
  (let ((etaf--allow-component-redefinition t))
    (funcall function)))

(defvar etaf--render-parent-style-owners nil
  "Style owners of the Component whose View is being rendered.")

(declare-function etaf-theme-token-p "etaf-context" (value))

(defun etaf--slot-composable-children (name content)
  "Return NAME's CONTENT as caller-owned composable children."
  (let ((children (if (etaf--slot-content-p content)
                      (etaf--slot-content-children content) content))
        (owner-id (and (etaf--slot-content-p content)
                       (etaf--slot-content-owner-component-id content))))
    (mapcar (lambda (child)
              (etaf--slot-projection-create
               :name name :captured-p t
               :content (etaf--slot-content-create :owner-component-id owner-id
                                                   :children (list child))
               :style-owners etaf--render-parent-style-owners))
            children)))

(defun etaf--current-slot-entries ()
  "Return the current Component's slot alist, tracking a mounted slot cell."
  (if etaf--current-component-slots-ref
      (etaf-value etaf--current-component-slots-ref)
    etaf--current-component-slots))

(defun etaf-current-slots ()
  "Return the current Component's slot alist of opaque composable children."
  (unless (eq etaf--component-phase 'render)
    (etaf--component-definition-error
     "Slots are available only during Component view/render"))
  (setq etaf--raw-slot-read-p t)
  (mapcar (lambda (entry)
            (cons (car entry)
                  (etaf--slot-composable-children (car entry) (cdr entry))))
          (etaf--current-slot-entries)))

(defun etaf-current-slot (name &optional fallback)
  "Return caller-owned composable children for NAME, or FALLBACK when absent."
  (unless (eq etaf--component-phase 'render)
    (etaf--component-definition-error
     "Slots are available only during Component view/render"))
  (setq etaf--raw-slot-read-p t)
  (let ((entry (assq name (etaf--current-slot-entries))))
    (if entry
        (etaf--slot-composable-children name (cdr entry))
      fallback)))

(defun etaf--component-prop-bindings (props)
  "Return lexical bindings for the current Component PROPS."
  (mapcar (lambda (prop)
            `(,prop (etaf-current-prop ',prop)))
          props))

(defun etaf--component-validate-bindings (name bindings props)
  "Validate NAME's sequential BINDINGS and return their distinct names.
PROPS cannot be shadowed by instance bindings."
  (unless (proper-list-p bindings)
    (etaf--component-definition-error
     "Component %S :bindings must be a proper binding list" name))
  (let (names)
    (dolist (binding bindings)
      (unless (and (proper-list-p binding) (= (length binding) 2)
                   (symbolp (car binding))
                   (not (or (keywordp (car binding))
                            (memq (car binding) '(nil t))
                            (string-prefix-p "&" (symbol-name (car binding))))))
        (etaf--component-definition-error
         "Component %S binding must be (NAME INITIALIZER): %S" name binding))
      (when (or (memq (car binding) names) (memq (car binding) props))
        (etaf--component-definition-error
         "Component %S binding %S duplicates a binding or prop" name (car binding)))
      (push (car binding) names))
    (nreverse names)))

(defun etaf--component-default-resolver (arguments)
  "Compile ARGUMENTS into an instance-default resolver, or nil."
  (when (cl-some #'consp (cdr arguments))
    (let ((input (make-symbol "input"))
          (cache (make-symbol "defaults"))
          bindings)
      (dolist (entry (cdr arguments))
        (let* ((name (if (consp entry) (car entry) entry))
               (key (etaf--component-prop-key name)))
          (push
           `(,name
             ,(if (consp entry)
                  `(if (plist-member ,input ,key)
                       (plist-get ,input ,key)
                     (unless (plist-member ,cache ,key)
                       (setq ,cache (plist-put ,cache ,key ,(cadr entry))))
                     (setq ,input
                           (plist-put ,input ,key (plist-get ,cache ,key)))
                     (plist-get ,input ,key))
                `(plist-get ,input ,key)))
           bindings)))
      `(lambda (,input ,cache)
         (setq ,input (copy-sequence ,input)
               ,cache (copy-sequence ,cache))
         (let* ,(nreverse bindings)
           (ignore ,@(mapcar (lambda (entry)
                              (if (consp entry) (car entry) entry))
                            (cdr arguments)))
           (cons ,input ,cache))))))

(defvar etaf--validating-component-name nil
  "Component whose resolved inputs are currently being validated.")

(defun etaf-check-prop (property value valid-p expected &optional component)
  "Return VALUE when VALID-P is non-nil; otherwise report an input error.
PROPERTY is a keyword and EXPECTED is a description string. COMPONENT names
the input owner, defaulting to the Component whose `:validate' form is running.
Helpers called outside validation supply COMPONENT explicitly. Checks must not
mutate input values or perform external effects. Failure signals
`etaf-component-call-error' naming the component, property, received value and
expectation. Large values are abbreviated in the message."
  (let ((component (or component etaf--validating-component-name)))
    (unless (and (symbolp component) component (keywordp property) (stringp expected))
      (signal 'etaf-component-definition-error
              (list "Input checks require a Component name, keyword property and expectation string")))
    (unless valid-p
      (let ((print-level 4) (print-length 8))
        (signal 'etaf-component-call-error
                (list (format "Component %S property %S received %S; expected %s"
                              component property value expected)))))
    value))

(defun etaf--component-resolve-input (spec props defaults)
  "Resolve and validate SPEC's PROPS, returning (PROPS . DEFAULTS).
Neither input is mutated. Validation follows defaults and precedes setup,
rendering, and publication of tracked prop sources."
  (let ((resolved (if-let* ((resolver (etaf--component-spec-defaults spec)))
                      (funcall resolver props defaults)
                    (cons props defaults))))
    (when-let* ((validate (etaf--component-spec-validate spec)))
      (let ((etaf--validating-component-name (etaf--component-spec-name spec)))
        (funcall validate (car resolved))))
    resolved))

(defun etaf--validate-styles-form (form name)
  "Validate static rule list FORM against the Ebox schema for Component NAME."
  (unless (proper-list-p form)
    (etaf--component-definition-error "Component %S requires a style rule list" name))
  (condition-case err
      (ebox-style-compile-rules
       ;; Theme sources belong to ETAF and resolve at Host lowering.  Check
       ;; their property identity here, and let that boundary validate the
       ;; actual declaration value against Ebox together with Host inputs.
       (mapcar
        (lambda (rule)
          (if (not (and (consp rule) (proper-list-p rule)
                        (zerop (% (length (cdr rule)) 2)))) rule
            (let (static)
              (cl-loop for (property value) on (cdr rule) by #'cddr
                       do (setq static
                                (append static
                                        (list property
                                              (if (etaf-theme-token-p value)
                                                  (ecss-wide-value 'initial)
                                                value)))))
              (cons (car rule) static))))
        form))
    (error (etaf--component-definition-error
            "Component %S rejected :styles: %s" name (error-message-string err))))
  form)

(defun etaf--component-form-contains-head-p (form heads)
  "Return non-nil when executable FORM contains a call headed by HEADS."
  (cond
   ((atom form) nil)
   ((memq (car form) '(quote function)) nil)
   ((memq (car form) heads) t)
   (t (cl-some (lambda (part)
                 (etaf--component-form-contains-head-p part heads))
               form))))

;;;###autoload
(defmacro etaf-define-component (name arguments &rest clauses)
  "Define Component NAME from prop ARGUMENTS and CLAUSES.

Reloading an identical declaration from the same library (source or bytecode)
retains its original definition, captured values and mounted instances.  This
is not hot replacement: changed declarations, other libraries and ordinary
evaluated duplicates still signal `etaf-component-call-error'.  To replace a
definition or refresh its captured values, dispose its Runtimes and use
`etaf-component-redefine-run'.

Choose exactly one authoring frontend:

  (etaf-define-component NAME (&key PROPS)
    [:bindings ((NAME INITIALIZER) ...)]
    [:validate ORDINARY-ELISP]
    [:setup SETUP]
    :view VIEW
    :styles ((SELECTOR ATTR ...)))

or:

  (etaf-define-component NAME (&key PROPS)
    [:bindings ((NAME INITIALIZER) ...)]
    [:validate ORDINARY-ELISP]
    [:setup SETUP]
    :render ORDINARY-ELISP
    :styles ((SELECTOR ATTR ...)))

`:bindings' initializes named values once, in let* order, before optional
`:setup'.  Initializers can use initial props and earlier bindings.  Setup,
both View frontends and their callbacks can refer directly to these stable
values.  Names must be distinct ordinary symbols, not declared props.
Ref/computed/watch/local-ref ownership remains the Component Scope; failed
initialization disposes it.  Reorder retains values; replacement/unmount
releases the instance.  Rebinding a lexical name with setq does not replace
its stored value: mutate refs explicitly through `etaf-value'.

With named bindings, optional `:setup' performs initialization; its return
value is ignored.  Without bindings, setup can return opaque state read by
the advanced `etaf-state' accessor, but not a render function.  `:view'
is unquoted DSL; `:render' is ordinary Elisp returning the same typed View,
usually through `etaf-view'.  `etaf-node' also constructs Views
programmatically.  Both frontends use the same prop and slot rules.  Declared
props are lexical snapshots for each setup or render evaluation; callbacks
may refer to them directly.  Passed refs retain identity and live value reads.
Business prop values use the reactive shallow equality rule: replacing an
object updates the retained instance even when its contents compare equal.
Keyed list items follow the same rule; keys retain instances, not old inputs.
Keep reactive value reads inside the View properties or expressions they
update.  Use `etaf-prop' in a binding initializer for a tracked input; a plain
prop variable in initialization is an initial snapshot.

Props accept NAME or (NAME DEFAULT) after &key.  Defaults evaluate in order
on first missing input and can read earlier props.  Explicit nil is supplied.
Mounted instances retain successfully published defaults until replacement or
unmount; pure rendering evaluates defaults anew.  Default expressions must be
safe to retry after rejected publication; allocate mutable values explicitly.

Optional `:validate' runs ordinary Elisp with resolved lexical props after
defaults, before bindings/setup or updated inputs are published. Its return is
ignored; use `etaf-check-prop' or signal an error to reject input. It runs on
pure rendering and mounted input evaluation. Validation must be pure and may
run again; it cannot depend on instance bindings, state, slots or lifecycle.
Validate passed reactive handles by their public type, leaving their live value
reads and value-dependent checks in rendering. A failed update retains the old
published props and callbacks; it does not undo the caller's business ref write."
  (declare (indent 2) (debug defun))
  (unless (symbolp name)
    (etaf--component-definition-error
     "Component name must be a symbol: %S" name))
  (let ((declaration (let ((print-circle t) (print-length nil) (print-level nil)
                           (print-gensym t) (print-quoted t)
                           (print-escape-newlines t) (print-escape-control-characters t)
                           (print-escape-nonascii t) (print-escape-multibyte t)
                           (print-continuous-numbering nil))
                       (secure-hash 'sha256 (prin1-to-string (list name arguments clauses)))))
        (docstring (when (stringp (car clauses)) (pop clauses)))
        view-form
        render-form
        setup-form
        validate-form
        bindings-form
        styles-form
        saw-view
        saw-render
        saw-setup
        saw-validate
        saw-bindings
        saw-styles)
    (while clauses
      (let ((keyword (pop clauses)))
        (unless (keywordp keyword)
          (etaf--component-definition-error
           "Expected a Component definition keyword, got %S" keyword))
        (unless clauses
          (etaf--component-definition-error
           "Component %S keyword %S has no value" name keyword))
        (pcase keyword
          (:view
           (when saw-view
             (etaf--component-definition-error
              "Component %S has duplicate :view" name))
           (setq view-form (pop clauses) saw-view t))
          (:render
           (when saw-render
             (etaf--component-definition-error
              "Component %S has duplicate :render" name))
           (setq render-form (pop clauses) saw-render t))
          (:setup
           (when saw-setup
             (etaf--component-definition-error
              "Component %S has duplicate :setup" name))
           (setq setup-form (pop clauses) saw-setup t))
          (:validate
           (when saw-validate
             (etaf--component-definition-error
              "Component %S has duplicate :validate" name))
           (setq validate-form (pop clauses) saw-validate t))
          (:bindings
           (when saw-bindings
             (etaf--component-definition-error
              "Component %S has duplicate :bindings" name))
           (setq bindings-form (pop clauses) saw-bindings t))
          (:styles
           (when saw-styles
             (etaf--component-definition-error
              "Component %S has duplicate :styles" name))
           (setq styles-form (pop clauses) saw-styles t))
          (_
           (etaf--component-definition-error
            "Unknown Component definition keyword %S" keyword)))))
    (when (and saw-view saw-render)
      (etaf--component-definition-error
       "Component %S must choose :view or :render, not both" name))
    (unless (or saw-view saw-render)
      (etaf--component-definition-error
       "Component %S requires exactly one of :view or :render" name))
    (when (and saw-setup
               (etaf--component-form-contains-head-p
                setup-form '(etaf-view etaf-node)))
      (etaf--component-definition-error
       "Component %S :setup cannot construct View structure" name))
    (when (and saw-setup
               (consp setup-form)
               (memq (car setup-form) '(lambda function)))
      (etaf--component-definition-error
       "Component %S :setup cannot return a render function" name))
    (let* ((props (etaf--parse-component-props arguments))
           (binding-names (etaf--component-validate-bindings name bindings-form props))
           (binding-values (make-symbol "instance-values"))
           (render-bindings
            (and binding-names
                 `((,binding-values
                    (etaf--component-bindings-values etaf--current-component-state))
                   ,@(cl-loop for binding in binding-names for index from 0
                              collect `(,binding (aref ,binding-values ,index))))))
           (styles-form (etaf--validate-styles-form styles-form name))
           (definition-symbol
            (intern (format "%s--etaf-component-definition" name)))
           (cells (make-symbol "cells"))
           (render-lambda
            `(lambda (,cells etaf--component-slots)
               (let ((etaf--current-component-props ,cells)
                     (etaf--current-component-slots etaf--component-slots)
                     (etaf--component-phase 'render))
                 ,(let ((etaf--compiling-component-props (append props binding-names)))
                    ;; Expand every embedded View inside its Component prop
                    ;; grammar, including Views produced by lexical macros.
                    ;; A `:view' runs once per instance, so each prop name
                    ;; reads its reactive cell wherever the View evaluates
                    ;; it; a `:render' re-runs and snapshots tracked values.
                    ;; Nested let/lambda bindings retain normal Elisp shadowing.
                    (macroexpand-all
                     (if saw-view
                         `(cl-symbol-macrolet
                              ,(cl-loop for prop in props for index from 1
                                        collect `(,prop (etaf-value (aref ,cells ,index))))
                            (let* ,render-bindings
                              (ignore ,@binding-names)
                              ,(etaf-compiler-expand-view view-form :projection)))
                       `(let ,(etaf--component-prop-bindings props)
                          (ignore ,@props)
                          (let* ,render-bindings
                            (ignore ,@binding-names)
                            ,render-form)))
                     macroexpand-all-environment)))))
           (setup-lambda
            (when (or saw-setup binding-names)
              `(lambda (etaf--component-props _etaf--component-slots)
                 (let ((etaf--current-component-props etaf--component-props)
                       (etaf--current-component-slots nil)
                       (etaf--component-phase 'setup))
                   (let ,(etaf--component-prop-bindings props)
                     (ignore ,@props)
                     ,(if binding-names
                          `(let* ,bindings-form
                             ,setup-form
                             (etaf--component-bindings-create
                              :values (vector ,@binding-names)))
                        setup-form)))))))
      `(progn
         (defvar ,definition-symbol nil
           ,(or docstring (format "Definition of ETAF Component `%s'." name)))
         (setq ,definition-symbol
               (etaf--register-component
                ',name
                (etaf--component-spec-create
                 :name ',name
                 :props ',props
                 :defaults ,(etaf--component-default-resolver arguments)
                 :validate ,(when saw-validate
                              `(lambda (etaf--validated-props)
                                 (let ,(mapcar
                                        (lambda (prop)
                                          `(,prop (plist-get etaf--validated-props
                                                             ,(etaf--component-prop-key prop))))
                                        props)
                                   (ignore ,@props)
                                   ,validate-form)))
                 :render ,render-lambda
                 :view-p ,saw-view
                 :setup ,setup-lambda
                 :styles ',styles-form)
                ,declaration))
         ',name))))

(provide 'etaf-component)

;;; etaf-component.el ends here
