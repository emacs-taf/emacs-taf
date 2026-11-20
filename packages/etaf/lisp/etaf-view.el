;;; etaf-view.el --- Unified ETAF View grammar -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; This file owns the small structural language shared by Hosts and
;; Components.  It deliberately does not render, mutate buffers, or implement
;; lifecycle.  `etaf-view' compiles one structural form into a short-lived
;; View value; the renderer lowers that value to Ebox later.

;;; Code:

(require 'cl-lib)
(require 'ebox)

(define-error 'etaf-view-error "Invalid ETAF View")
(define-error 'etaf-view-syntax-error "Invalid ETAF View syntax"
  'etaf-view-error)
(define-error 'etaf-component-call-error "Invalid ETAF Component call"
  'etaf-view-error)

(cl-defstruct (etaf--view-node
               (:constructor etaf--view-node-create))
  "Internal normalized description of one Host View."
  name
  token
  props
  children)

(cl-defstruct (etaf--expr
               (:constructor etaf--expr-create))
  "Internal executable interpolation or compiler-owned structural program."
  (kind 'interpolation)
  token
  thunk
  range-snapshot
  range-key
  range-item)

(cl-defstruct (etaf--component-spec
               (:constructor etaf--component-spec-create))
  "Internal definition of one ETAF Component."
  name
  props
  defaults
  render
  setup
  styles
  validate
  view-p)

(cl-defstruct (etaf--component-call
               (:constructor etaf--component-call-create))
  "Internal Component invocation retained until rendering."
  spec
  props
  attrs
  slots)

(cl-defstruct (etaf--slot-input
               (:constructor etaf--slot-input-create))
  "Call-site contribution to a named Component slot."
  name
  children)

(cl-defstruct (etaf--slot-projection
               (:constructor etaf--slot-projection-create))
  "A Component View request for one slot and its fallback children."
  name
  token
  fallback
  captured-p content style-owners)

(defconst etaf--host-names
  '(text box fragment row column flex grid image)
  "Minimal unstyled Hosts implemented by ETAF core.

Product Components such as Button belong to `etaf-ui'; they are not added to
this list merely to make a demo convenient.  `image' renders one fixed-size
local media block through the Ebox image protocol; see the `etaf--image-node'
lowering for its :src, :columns, :rows, :adapter and :inset properties.")

(defconst etaf--host-marker 'etaf--host
  "Value stored in the View registry for a built-in Host.")

(defconst etaf--directive-properties '(:if :else-if :else :for)
  "Compiler-owned DSL properties rejected by ordinary node construction.")

(defconst etaf--semantic-props
  '(:class :id :role :disabled :tab-index :ref :use
    :help-echo :pointer :hover-style :hover-content :drag-lock-modifier
    :drag-edge :hover-group :sticky :keys :help :focus-group :focus-scope
    :key-scope :region :on-direction)
  "ETAF Host metadata outside the Ebox style schema.")

(defun etaf--aria-property-p (property)
  "Return non-nil when PROPERTY is in the ETAF aria namespace."
  (and (keywordp property)
       (string-prefix-p ":aria-" (symbol-name property))))

(defun etaf--event-property-p (property)
  "Return non-nil when PROPERTY is an ETAF event callback property."
  (and (keywordp property)
       (string-prefix-p ":on-" (symbol-name property))))

(defun etaf--semantic-property-p (property)
  "Return non-nil when PROPERTY belongs to ETAF Runtime metadata."
  (or (memq property etaf--semantic-props)
      (etaf--aria-property-p property)
      (etaf--event-property-p property)))

(defun etaf--host-attribute-p (property)
  "Return non-nil when PROPERTY belongs to the shared Host attribute domain."
  (or (ebox-style-schema-id property)
      (etaf--semantic-property-p property)))

(defconst etaf--ordinary-elisp-heads
  '(and or not if when unless cond case pcase
    let let* letrec letrec* prog prog1 prog2 progn
    while dolist dotimes cl-loop mapcar mapc mapcan
    save-excursion save-restriction save-window-excursion
    condition-case condition-case-unless-debug unwind-protect
    catch throw signal error user-error quote function lambda
    setq setq-default setf psetf psetq incf decf push pop
    funcall apply apply-partially progn eval macroexpand)
  "Elisp heads that must appear inside `expr', not as View children.")

(defvar etaf--view-registry (make-hash-table :test #'eq)
  "Registry of Hosts and Components used by structural View calls.")

(defvar etaf--component-declarations (make-hash-table :test #'eq :weakness 'key)
  "Library and declaration fingerprint for each loaded Component definition.
Metadata stays outside the spec so existing consumers' compiled constructors
remain valid when only the provider is upgraded.")

(defvar etaf--allow-component-redefinition nil
  "When non-nil, permit an explicit authoring tool to replace Components.

Normal ETAF loading keeps duplicate definitions as errors.  Tools such as a
source playground may bind this variable around an intentional reload after
disposing the old Runtime.")

(defvar etaf--current-component-props nil
  "Dynamic props of the Component currently being evaluated.")

(defvar etaf--current-component-slots nil
  "Dynamic slots of the Component currently being evaluated.")

(defvar etaf--current-component-slots-ref nil
  "Reactive slot cell of the mounted Component currently being evaluated.")

(defvar etaf--current-component-instance nil
  "Dynamic Component instance currently being evaluated.")

(defvar etaf--compiling-component-props nil
  "Component prop names visible to the current DSL macro expansion.")

(defun etaf--syntax-error (format-string &rest arguments)
  "Signal a View syntax error formatted from FORMAT-STRING and ARGUMENTS."
  (signal 'etaf-view-syntax-error
          (list (apply #'format format-string arguments))))

(defun etaf--component-error (format-string &rest arguments)
  "Signal a Component call error formatted from FORMAT-STRING and ARGUMENTS."
  (signal 'etaf-component-call-error
          (list (apply #'format format-string arguments))))

(defun etaf--keyword-for-name (name)
  "Return the property keyword corresponding to symbol NAME."
  (intern (concat ":" (symbol-name name))))

(defun etaf--register-component (name spec &optional declaration)
  "Register Component SPEC under exact registry NAME.
DECLARATION is its source fingerprint, or nil for previously compiled callers.
An unchanged declaration loaded from the same library reuses its definition.
Ordinary evaluation has no library identity and cannot replace a definition."
  (unless (and (symbolp name) (etaf--component-spec-p spec))
    (signal 'wrong-type-argument (list 'etaf--component-spec-p spec)))
  (let* ((existing (gethash name etaf--view-registry))
         (previous (and existing (gethash existing etaf--component-declarations)))
         (library (and load-in-progress load-file-name
                       (file-name-sans-extension (file-truename load-file-name)))))
    (cond
     ((eq existing etaf--host-marker)
      (etaf--component-error "Component %S conflicts with a core Host" name))
     ((or (eq existing spec)
          (and previous library declaration (not etaf--allow-component-redefinition)
               (equal library (car previous))
               (equal declaration (cdr previous))))
      ;; Keep retained instances, captured values and compiled Views together;
      ;; loading bytecode after source must not replace their shared definition.
      existing)
     ((and existing (not etaf--allow-component-redefinition))
      (etaf--component-error "Component %S is already registered" name))
     (t
      (puthash name spec etaf--view-registry)
      (when (and library declaration)
        (puthash spec (cons library declaration) etaf--component-declarations))
      (when (fboundp 'etaf-compiler-note-registry-change)
        (etaf-compiler-note-registry-change))
      spec))))

(defun etaf--register-core-hosts ()
  "Register the exact core Host names."
  (dolist (name etaf--host-names)
    (puthash name etaf--host-marker etaf--view-registry)))

(etaf--register-core-hosts)

(defun etaf--validate-property-plist (props)
  "Validate evaluated View PROPS and return a defensive copy."
  (unless (and (proper-list-p props) (zerop (% (length props) 2)))
    (etaf--component-error "View properties must be keyword/value pairs: %S"
                           props))
  (let ((copy nil)
        (seen nil)
        (tail props))
    (while tail
      (let ((key (pop tail))
            (value (pop tail)))
        (unless (keywordp key)
          (etaf--component-error "View property name must be a keyword: %S"
                                 key))
        (when (memq key seen)
          (etaf--component-error "Duplicate View property: %S" key))
        (push key seen)
        (push key copy)
        (push value copy)))
    (nreverse copy)))

(defun etaf--resolve-property-value (value)
  "Resolve one lazily compiled property VALUE."
  (if (etaf--expr-p value)
      (etaf--resolve-property-value (funcall (etaf--expr-thunk value)))
    value))

(defun etaf--resolve-property-plist (props)
  "Resolve all lazy values in PROPS while preserving its keys.
PROPS itself is returned when it holds no lazy value; callers do not modify
the result."
  (if (not (cl-loop for (_key value) on props by #'cddr
                    thereis (etaf--expr-p value)))
      props
    (let ((copy nil)
          (tail props))
      (while tail
        (push (pop tail) copy)
        (push (etaf--resolve-property-value (pop tail)) copy))
      (nreverse copy))))

(defun etaf--property-domain-key (property)
  "Return PROPERTY's canonical Host-domain key."
  (or (ebox-style-canonical-name property) property))

(defun etaf--plist-set (props key value)
  "Return PROPS with KEY set to VALUE while preserving source order."
  (if (plist-member props key)
      (let ((copy (copy-sequence props)))
        (plist-put copy key value)
        copy)
    (append props (list key value))))

(defun etaf--plist-remove-domain (props property)
  "Return PROPS without any alias in PROPERTY's canonical domain."
  (let ((domain (etaf--property-domain-key property)))
    (cl-loop for (key value) on props by #'cddr
             unless (eq (etaf--property-domain-key key) domain)
             append (list key value))))

(defun etaf--class-tokens (value)
  "Return normalized class tokens from resolved VALUE."
  (cond
   ((null value) nil)
   ((stringp value) (split-string value "[[:space:]]+" t))
   ((symbolp value) (list (symbol-name value)))
   ((proper-list-p value)
    (cl-mapcan #'etaf--class-tokens value))
   (t
    (etaf--component-error "Invalid class value: %S" value))))

(defun etaf--merge-class-values (root-value caller-value)
  "Return stable union of ROOT-VALUE and CALLER-VALUE class tokens."
  (let (seen result)
    (dolist (token (append (etaf--class-tokens root-value)
                           (etaf--class-tokens caller-value)))
      (unless (member token seen)
        (push token seen)
        (push token result)))
    (nreverse result)))

(defun etaf--compose-event-callbacks (primary secondary)
  "Compose PRIMARY then SECONDARY, preserving the primary return value.
An error stops the chain.  This shared value operation lives with View
composition so pure render and Runtime Behavior use the same contract."
  (dolist (callback (list primary secondary))
    (unless (or (null callback) (functionp callback))
      (etaf--component-error "Event callback must be a function or nil: %S"
                             callback)))
  (cond
   ((null primary) secondary)
   ((null secondary) primary)
   (t
    (lambda (&rest arguments)
      (prog1 (apply primary arguments)
        (apply secondary arguments))))))

(defun etaf--owned-semantic-property-p (property)
  "Return non-nil when fallthrough PROPERTY must preserve root semantics."
  (or (eq property :role)
      (and (etaf--aria-property-p property)
           (not (memq property '(:aria-label :aria-description))))))

(defun etaf--merge-use-input (root-value caller-value)
  "Concatenate possibly lazy ROOT-VALUE and CALLER-VALUE Behavior sources.
Runtime validates all names before installing any resources."
  (let ((root (etaf--resolve-property-value root-value))
        (caller (etaf--resolve-property-value caller-value)))
    (append (if (proper-list-p root) root (list root))
            (if (proper-list-p caller) caller (list caller)))))

(defun etaf--lazy-merge (function &rest inputs)
  "Combine INPUTS with FUNCTION, deferring when any input is lazy.
Static inputs combine now; otherwise the result is a property thunk that
resolves every input when the consuming Host evaluates it."
  (if (cl-some #'etaf--expr-p inputs)
      (etaf--expr-create
       :thunk (lambda ()
                (apply function (mapcar #'etaf--resolve-property-value inputs))))
    (apply function inputs)))

(defun etaf--merge-host-attrs (props attrs &optional tag component-name)
  "Merge caller ATTRS into root Host PROPS for TAG.
Non-nil visual attributes override defaults; class and Behavior sources merge.
Callbacks append, disabled combines with OR, and owned semantic conflicts
are rejected.  Lazy inputs stay lazy so the consuming Host tracks them.
COMPONENT-NAME labels diagnostics."
  (let ((result (copy-sequence props))
        (tail attrs))
    (while tail
      (let* ((key (pop tail))
             (value (pop tail))
             (style-p (not (null (ebox-style-schema-id key)))))
        (when (and tag style-p
                   (not (ebox-style-property-accepted-p tag key)))
          (etaf--component-error
           "Component %S root Host %S rejects attribute %S"
           component-name tag key))
        (cond
         ((eq key :class)
          (setq result
                (etaf--plist-set
                 result :class
                 (etaf--lazy-merge #'etaf--merge-class-values
                                   (plist-get result :class) value))))
         ((etaf--event-property-p key)
          (setq result
                (etaf--plist-set
                 result key
                 (etaf--lazy-merge #'etaf--compose-event-callbacks
                                   (plist-get result key) value))))
         ((eq key :use)
          (setq result
                (etaf--plist-set
                 result key
                 (etaf--lazy-merge #'etaf--merge-use-input
                                   (plist-get result key) value))))
         ((eq key :keys)
          ;; The caller's bindings come first so they shadow the root's.
          (setq result
                (etaf--plist-set
                 result key
                 (etaf--lazy-merge (lambda (inner outer) (append outer inner))
                                   (plist-get result key) value))))
         ((eq key :disabled)
          (setq result
                (etaf--plist-set
                 result key
                 (etaf--lazy-merge
                  (lambda (inner outer)
                    (unless (and (memq inner '(nil t)) (memq outer '(nil t)))
                      (etaf--component-error
                       "Component %S :disabled must be boolean" component-name))
                    (or inner outer))
                  (plist-get result key) value))))
         (style-p
          (let* ((domain (etaf--property-domain-key key))
                 (old (cl-loop for (k v) on result by #'cddr
                               when (eq (etaf--property-domain-key k) domain)
                               return v)))
            (cond
             ((etaf--expr-p value)
              (setq result
                    (append (etaf--plist-remove-domain result key)
                            (list key (etaf--lazy-merge
                                       (lambda (outer inner) (or outer inner))
                                       value old)))))
             (value
              (setq result
                    (append (etaf--plist-remove-domain result key)
                            (list key value)))))))
         ((and (etaf--owned-semantic-property-p key)
               (plist-member result key))
          (setq result
                (etaf--plist-set
                 result key
                 (etaf--lazy-merge
                  (lambda (inner outer)
                    (unless (equal inner outer)
                      (etaf--component-error
                       "Component %S root Host %S owns %S; conflicting fallthrough value %S"
                       component-name tag key outer))
                    inner)
                  (plist-get result key) value))))
         ((plist-member result key)
          (setq result (etaf--plist-set result key value)))
         (t
          (setq result (append result (list key value)))))))
    result))

(defun etaf--forward-component-attrs (call attrs component-name)
  "Return copied root Component CALL receiving caller ATTRS.
COMPONENT-NAME identifies the forwarding owner for diagnostics."
  (let* ((copy (copy-sequence call))
         (spec (etaf--component-call-spec call))
         (declared (mapcar #'etaf--component-prop-key
                           (etaf--component-spec-props spec)))
         (props (copy-sequence (etaf--component-call-props call)))
         (forwarded (copy-sequence (etaf--component-call-attrs call)))
         (tail attrs))
    (while tail
      (let ((key (pop tail))
            (value (pop tail)))
        (if (memq key declared)
            ;; Consuming a declared prop must retain the inner declaration
            ;; and the outer subscription, and must not forward either twice.
            (setq props
                  (etaf--merge-host-attrs props (list key value)
                                         nil component-name))
          (setq forwarded
                (etaf--merge-host-attrs
                 forwarded (list key value) nil component-name)))))
    (setf (etaf--component-call-props copy) props
          (etaf--component-call-attrs copy) forwarded)
    copy))

(defun etaf--apply-component-attrs (value attrs component-name)
  "Apply resolved fallthrough ATTRS to COMPONENT-NAME root VALUE."
  (if (null attrs)
      value
    (cond
     ((stringp value)
      (etaf--view-node-create
       :name 'text :props (copy-sequence attrs) :children (list value)))
     ((etaf--view-node-p value)
      (when (eq (etaf--view-node-name value) 'fragment)
        (etaf--component-error
         "Component %S has multiple roots; Host attrs have no target"
         component-name))
      (let ((copy (copy-sequence value)))
        (setf (etaf--view-node-props copy)
              (etaf--merge-host-attrs
               (etaf--view-node-props value) attrs
               (etaf--view-node-name value) component-name))
        copy))
     ((etaf--component-call-p value)
      (etaf--forward-component-attrs value attrs component-name))
     (t
      (etaf--component-error
       "Component %S cannot apply Host attrs to %S" component-name value)))))

(defun etaf--compile-property-value (form)
  "Compile property FORM as a constant or a render-time thunk."
  (if (or (null form) (numberp form) (stringp form) (characterp form)
          (keywordp form) (eq form t)
          (and (consp form) (memq (car form) '(quote function))))
      form
    `(etaf--expr-create :thunk (lambda () ,form))))

(defun etaf--compile-property-plist (props)
  "Compile alternating property FORMS in PROPS into a generated property list."
  (let (compiled)
    (while props
      (let ((key (pop props))
            (value (pop props)))
        (setq compiled
              (append compiled
                      (list key (etaf--compile-property-value value))))))
    compiled))

(defun etaf--validate-key (key)
  "Validate identity KEY and return its immutable boundary value."
  (unless (and key (or (symbolp key) (stringp key) (integerp key)))
    (etaf--component-error
     "View keys must be non-nil symbols, integers, or strings: %S" key))
  (if (stringp key) (copy-sequence key) key))

(defun etaf--parse-attributes-and-children (items)
  "Split structural ITEMS into `(PROPS . CHILDREN)'.

All keyword attributes must precede the first non-keyword child.  Values are
returned as unevaluated forms because they are ordinary Elisp expressions in
the generated code."
  (let (props children seen children-started)
    (while items
      (let ((item (pop items)))
        (if (keywordp item)
            (progn
              (when children-started
                (etaf--syntax-error
                 "Attributes must precede children; found %S after a child"
                 item))
              (unless items
                (etaf--syntax-error "Missing value for View property %S"
                                    item))
              (when (memq item seen)
                (etaf--syntax-error "Duplicate View property %S" item))
              (push item seen)
              (let ((value (pop items)))
                (push item props)
                (push value props)))
          (setq children-started t)
          (push item children))))
    (cons (nreverse props) (nreverse children))))

(defun etaf--parse-expr-form (items)
  "Return the sole ordinary Elisp form from interpolation ITEMS."
  (unless (= (length items) 1)
    (etaf--syntax-error "Expr accepts exactly one form: (expr FORM)"))
  (car items))

(defun etaf--constant-slot-name (form)
  "Return the static slot symbol represented by FORM, or signal an error."
  (unless (and (consp form)
               (eq (car form) 'quote)
               (null (cddr form)))
    (etaf--syntax-error
     "Slot names must be quoted stable symbols: %S" form))
  (let ((name (cadr form)))
    (unless (and (symbolp name) (not (keywordp name))
                 (not (memq name '(nil t))))
      (etaf--syntax-error
       "Slot names must be stable non-keyword symbols: %S" form))
    name))

(defun etaf--compile-slot-form (items slot-mode)
  "Compile a slot form with ITEMS according to SLOT-MODE.

SLOT-MODE is `:projection' while compiling a Component's own View and
`:input' while compiling the children supplied to a Component call.  An
input slot must have an explicit `:name'; ordinary trailing children already
belong to the anonymous `default' slot."
  (let* ((parts (etaf--parse-attributes-and-children items))
         (props (car parts))
         (children (cdr parts))
         (name-supplied-p (plist-member props :name))
         (name (if name-supplied-p
                   (etaf--constant-slot-name (plist-get props :name))
                 'default)))
    (unless (or (null props)
                (and (= (length props) 2) (eq (car props) :name)))
      (etaf--syntax-error "Slot accepts only the optional :name attribute"))
    (when (and (eq slot-mode :input) (not name-supplied-p))
      (etaf--syntax-error
       "A named slot input requires :name; ordinary children fill default"))
    (let ((compiled (mapcar (lambda (child)
                              (etaf--compile-child-form child slot-mode))
                            children)))
      (if (eq slot-mode :projection)
          (let ((token (gensym "etaf-slot-site-")))
            `(etaf--slot-projection-create
              :name ',name
              :token ',token
              :fallback (list ,@compiled)))
        `(etaf--slot-input-create
          :name ',name
          :children (list ,@compiled))))))

(defun etaf--ordinary-expression-head-p (head)
  "Return non-nil when HEAD denotes ordinary Elisp computation."
  (or (memq head etaf--ordinary-elisp-heads)
      (special-form-p head)
      (and (symbolp head) (fboundp head))))

(defun etaf--compile-expr-form (items)
  "Compile an `expr' form with ITEMS into an executable View value."
  (let ((token (gensym "etaf-expr-site-")))
    `(etaf--expr-create
    :kind 'interpolation
    :token ',token
    :thunk (lambda () ,(etaf--parse-expr-form items)))))

(defun etaf--structural-program-p (value)
  "Return non-nil when VALUE is a compiler-owned structural program."
  (and (etaf--expr-p value)
       (memq (etaf--expr-kind value) '(branch keyed-list))))

(defun etaf--view-form-parts (form)
  "Return parsed `(TAG PROPS CHILDREN)' for directive-capable FORM."
  (unless (and (consp form) (symbolp (car form))
               (not (memq (car form) '(expr slot))))
    (etaf--syntax-error "Directive requires a View node: %S" form))
  (let ((parts (etaf--parse-attributes-and-children (cdr form))))
    (list (car form) (car parts) (cdr parts))))

(defun etaf--view-directive-properties (props)
  "Return directive entries present in raw PROPS."
  (cl-loop for (key value) on props by #'cddr
           when (memq key etaf--directive-properties)
           append (list key value)))

(defun etaf--validate-directive-set (directives)
  "Validate one node's raw DIRECTIVES and return them."
  (let ((branch-count
         (cl-count-if (lambda (key) (plist-member directives key))
                      '(:if :else-if :else))))
    (when (> branch-count 1)
      (etaf--syntax-error "A View node accepts one branch directive"))
    (when (and (> branch-count 0) (plist-member directives :for))
      (etaf--syntax-error "Branch directives cannot share a node with :for"))
    (when (and (plist-member directives :else)
               (not (eq (plist-get directives :else) t)))
      (etaf--syntax-error ":else requires literal t")))
  directives)

(defun etaf--view-without-directives (form)
  "Return raw View FORM without compiler directive properties."
  (pcase-let ((`(,tag ,props ,children) (etaf--view-form-parts form)))
    (cons tag
          (append
           (cl-loop for (key value) on props by #'cddr
                    unless (memq key etaf--directive-properties)
                    append (list key value))
           children))))

(defun etaf--compile-branch-children (first rest slot-mode)
  "Compile branch FIRST and adjacent arms from REST under SLOT-MODE.
Return `(COMPILED . REMAINING)' for one compiler-owned Range program."
  (let ((arms nil)
        (remaining rest)
        (saw-else nil)
        done)
    (cl-labels
        ((add-arm
          (form kind condition)
          (let ((parts (etaf--view-form-parts form)))
            (etaf--validate-directive-set
             (etaf--view-directive-properties (nth 1 parts)))
            (push (list kind condition
                        (etaf--compile-view-form
                         (etaf--view-without-directives form) slot-mode))
                  arms))))
      (let* ((directives
              (etaf--view-directive-properties
               (nth 1 (etaf--view-form-parts first)))))
        (add-arm first :if (plist-get directives :if)))
      (while (and remaining (not done))
        (let* ((candidate (car remaining))
               (parts (and (consp candidate) (symbolp (car candidate))
                           (not (memq (car candidate) '(expr slot)))
                           (etaf--view-form-parts candidate)))
               (directives (and parts
                                (etaf--view-directive-properties
                                 (nth 1 parts)))))
          (cond
           ((and directives (plist-member directives :else-if))
            (when saw-else
              (etaf--syntax-error ":else-if cannot follow :else"))
            (add-arm candidate :else-if (plist-get directives :else-if))
            (setq remaining (cdr remaining)))
           ((and directives (plist-member directives :else))
            (when saw-else
              (etaf--syntax-error "A branch chain accepts one :else"))
            (setq saw-else t)
            (add-arm candidate :else (plist-get directives :else))
            (setq remaining (cdr remaining)))
           (t (setq done t))))))
    (let ((token (gensym "etaf-branch-site-"))
          (ordered (nreverse arms))
          (selector (gensym "etaf-branch-arm-"))
          (index -1))
      (cons
       `(let ((,selector
               (lambda (arm)
                 (pcase arm
                   ,@(let ((i -1))
                       (mapcar (lambda (arm) `(,(cl-incf i) ,(nth 2 arm)))
                               ordered))))))
          (etaf--expr-create
           :kind 'branch
           :token ',token
           :range-snapshot
           (lambda ()
             (cond
              ,@(mapcar
                 (lambda (arm)
                   (cl-incf index)
                   (pcase (car arm)
                     (:else `(t ,index))
                     (_ `(,(nth 1 arm) ,index))))
                 ordered)))
           :range-item ,selector
           :thunk nil))
       remaining))))

(defun etaf--compile-for-child (form slot-mode)
  "Compile one keyed `:for' View FORM for SLOT-MODE."
  (pcase-let* ((`(,_tag ,props ,_children) (etaf--view-form-parts form))
               (directives
                (etaf--validate-directive-set
                 (etaf--view-directive-properties props)))
               (for-form (plist-get directives :for)))
    (when (cl-some (lambda (key) (plist-member directives key))
                   '(:if :else-if :else))
      (etaf--syntax-error "Branch directives cannot share a node with :for"))
    (unless (and (proper-list-p for-form) (= (length for-form) 2)
                 (symbolp (car for-form))
                 (not (keywordp (car for-form)))
                 (not (memq (car for-form) '(nil t))))
      (etaf--syntax-error ":for must be (ITEM ITEMS): %S" for-form))
    (when (memq (car for-form) etaf--compiling-component-props)
      (etaf--syntax-error ":for item %S conflicts with a Component prop"
                          (car for-form)))
    (unless (plist-member props :key)
      (etaf--syntax-error ":for requires an explicit :key"))
    (let* ((item (car for-form))
           (items-form (cadr for-form))
           (key-form (plist-get props :key))
           (cell (make-symbol "item-cell"))
           (compiled (etaf--compile-view-form
                      (etaf--view-without-directives form) slot-mode))
           (token (gensym "etaf-keyed-list-site-")))
      ;; Each retained row reads its item through a reactive cell, so a new
      ;; item object under the same key updates the row's bindings in place.
      `(etaf--expr-create
        :kind 'keyed-list
        :token ',token
        :range-snapshot
        (lambda ()
          (let ((items ,items-form))
            (unless (proper-list-p items)
              (etaf--component-error
               ":for collection must be a proper list: %S" items))
            items))
        :range-key (lambda (,item) (etaf--validate-key ,key-form))
        :range-item
        (lambda (,cell)
          (cl-symbol-macrolet ((,item (etaf-value ,cell)))
            ,compiled))))))

(defun etaf--compile-child-sequence (children slot-mode)
  "Compile sibling CHILDREN with branch and keyed-list SLOT-MODE structure."
  (let (compiled)
    (while children
      (let* ((form (car children))
             (parts (and (consp form) (symbolp (car form))
                         (not (memq (car form) '(expr slot)))
                         (etaf--view-form-parts form)))
             (directives
              (and parts
                   (etaf--validate-directive-set
                    (etaf--view-directive-properties (nth 1 parts))))))
        (cond
         ((and directives (plist-member directives :if))
          (pcase-let ((`(,value . ,remaining)
                       (etaf--compile-branch-children
                        form (cdr children) slot-mode)))
            (push value compiled)
            (setq children remaining)))
         ((and directives (plist-member directives :for))
          (push (etaf--compile-for-child form slot-mode) compiled)
          (setq children (cdr children)))
         ((and directives
               (or (plist-member directives :else-if)
                   (plist-member directives :else)))
          (etaf--syntax-error "Orphan branch arm: %S" form))
         (t
          (push (etaf--compile-child-form form slot-mode) compiled)
          (setq children (cdr children))))))
    (nreverse compiled)))

(defun etaf--compile-child-form (form &optional slot-mode)
  "Compile structural child FORM into code returning a View value.

SLOT-MODE distinguishes Component-owned projections from call-site inputs."
  (cond
   ((null form) nil)
   ((stringp form) `(quote ,form))
   ((and (consp form) (eq (car form) 'expr))
    (etaf--compile-expr-form (cdr form)))
   ((and (consp form) (eq (car form) 'slot))
    (etaf--compile-slot-form (cdr form) slot-mode))
   ((and (consp form) (symbolp (car form)))
    (when (and (null (gethash (car form) etaf--view-registry))
               (etaf--ordinary-expression-head-p (car form)))
      (etaf--syntax-error
       "Elisp expression %S must be inside (expr FORM)" (car form)))
    (etaf--compile-view-form form slot-mode))
   ((consp form)
    (etaf--syntax-error "Invalid View child form: %S" form))
   (t
    (etaf--syntax-error
     "View children must be strings, nil, View forms, or expr results: %S"
     form))))

(defun etaf--compile-view-form (form &optional slot-mode)
  "Compile one structural View FORM into runtime construction code.

SLOT-MODE distinguishes Component-owned projections from call-site inputs."
  (cond
   ((null form) nil)
   ((stringp form) `(etaf--text-view-from-string ,form))
   ((not (and (consp form) (symbolp (car form))))
    (etaf--syntax-error "View form must start with a symbol: %S" form))
   ((eq (car form) 'expr)
    (etaf--compile-expr-form (cdr form)))
   ((eq (car form) 'slot)
    ;; A render closure returned from `:setup' invokes `etaf-view' later than
    ;; the Component definition macro, so the public macro defaults to
    ;; projection mode.  An unowned projection simply uses its fallback.
    (etaf--compile-slot-form (cdr form) slot-mode))
   (t
    (let* ((parts (etaf--parse-attributes-and-children (cdr form)))
           (props (car parts))
           (children (cdr parts))
           (host-view-p (eq (gethash (car form) etaf--view-registry)
                            etaf--host-marker))
           (child-slot-mode (if host-view-p slot-mode :input)))
      (let ((token (and (memq (car form) '(fragment etaf-fragment))
                        (gensym "etaf-fragment-site-"))))
        `(etaf--view-call ',(car form)
                          (list ,@(etaf--compile-property-plist props))
                          (list ,@(etaf--compile-child-sequence
                                   children child-slot-mode))
                          ,(and token `',token)))))))

;;;###autoload
(defmacro etaf-view (form &optional _environment)
  "Construct a normalized ETAF View from structural FORM.

FORM uses one grammar for Hosts and Component calls:

  (NAME :PROPERTY VALUE ... CHILD ...)

Properties must come first and children must come last.  Property values are
ordinary Elisp expressions.  In structural child positions, `(expr FORM)'
returns nil, strings, typed Views, or proper sequences of those values.
Inside a `text' Host, an expression must return one string.

The optional ENVIRONMENT is ignored; Emacs 31 passes the macro environment
when it eagerly expands top-level forms, and the macro must accept it."
  (declare (indent 1) (debug (form)))
  (if (fboundp 'etaf-compiler-expand-view)
      (etaf-compiler-expand-view form :projection)
    (etaf--compile-view-form form :projection)))

(defun etaf--component-prop-key (name)
  "Return the keyword used to pass Component prop NAME."
  (if (keywordp name)
      name
    (etaf--keyword-for-name name)))

(defun etaf--partition-component-input (spec props)
  "Partition SPEC input PROPS into business props and Host attrs.
Return `(BUSINESS ATTRS)'.  `:key' remains framework-owned input metadata."
  (let ((declared (mapcar #'etaf--component-prop-key
                          (etaf--component-spec-props spec)))
        (tail (etaf--validate-property-plist props))
        (attr-domains (make-hash-table :test #'eq))
        business
        attrs)
    (while tail
      (let ((key (pop tail))
            (value (pop tail)))
        (cond
         ((or (eq key :key) (memq key declared))
          (setq business (append business (list key value))))
         ((etaf--host-attribute-p key)
          (let ((domain (etaf--property-domain-key key)))
            (when (gethash domain attr-domains)
              (etaf--component-error
               "Duplicate Component Host attribute domain: %S" key))
            (puthash domain t attr-domains)
            (setq attrs (append attrs (list domain value)))))
         (t
          (etaf--component-error
           "Unknown prop or Host attribute %S for Component %S"
           key (etaf--component-spec-name spec))))))
    (list business attrs)))

(defun etaf--component-business-props (call)
  "Return CALL's declared business props without framework `:key'."
  (cl-loop for (key value) on (etaf--component-call-props call) by #'cddr
           unless (eq key :key)
           append (list key value)))

(defun etaf--typed-view-child-p (value)
  "Return non-nil when VALUE is one already validated View child."
  (or (null value)
      (stringp value)
      ;; Code-mode setup may retain a structural program (for example, a
      ;; direct Range expression) and pass that opaque value to `etaf-node'.
      ;; It is still validated and interpreted only at the renderer boundary;
      ;; arbitrary lists remain rejected here.
      (etaf--expr-p value)
      (etaf--view-node-p value)
      (etaf--component-call-p value)
      (etaf--slot-projection-p value)))

(defun etaf--validate-component-render-result (value component-name)
  "Return typed VALUE or reject COMPONENT-NAME's ambiguous render result."
  (unless (etaf--typed-view-child-p value)
    (etaf--component-error
     "Component %S must render nil, a string, or one typed View; got %S"
     component-name value))
  value)

(defun etaf--validate-code-children (children context)
  "Return a detached CHILDREN spine after typed validation for CONTEXT.
CONTEXT is a node tag symbol or a string naming the children's owner."
  (unless (proper-list-p children)
    (etaf--component-error "%s children must be a proper list: %S"
                           (etaf--children-context context) children))
  (dolist (child children)
    (unless (etaf--typed-view-child-p child)
      (etaf--component-error
       "%s child must be nil, string, or typed View: %S"
       (etaf--children-context context) child)))
  (copy-sequence children))

(defun etaf--children-context (context)
  "Return CONTEXT, a node tag symbol or owner string, as message text."
  (if (symbolp context) (format "Node %S" context) context))

(defun etaf--validate-code-slots (slots)
  "Return typed named SLOTS as internal slot inputs."
  (unless (proper-list-p slots)
    (etaf--component-error "Named slots must be a proper alist: %S" slots))
  (let (seen result)
    (dolist (entry slots (nreverse result))
      (unless (and (consp entry)
                   (symbolp (car entry))
                   (not (keywordp (car entry)))
                   (not (memq (car entry) '(nil t))))
        (etaf--component-error "Invalid named slot entry: %S" entry))
      (when (memq (car entry) seen)
        (etaf--component-error "Duplicate Component slot %S" (car entry)))
      (push (car entry) seen)
      (push (etaf--slot-input-create
             :name (car entry)
             :children (etaf--validate-code-children
                        (cdr entry) (format "Slot %S" (car entry))))
            result))))

;;;###autoload
(defun etaf-node (tag props children &optional named-slots)
  "Construct one typed View node from evaluated ordinary Elisp values.
TAG is an exact Host or Component registry symbol.  PROPS is a keyword plist,
CHILDREN is a list of typed View children, and NAMED-SLOTS is a Component-only
alist from stable slot symbols to typed child lists."
  (unless (symbolp tag)
    (etaf--component-error "Node tag must be a symbol: %S" tag))
  (setq props (etaf--validate-property-plist props))
  (dolist (directive etaf--directive-properties)
    (when (plist-member props directive)
      (etaf--component-error
       "Code node %S rejects DSL directive %S" tag directive)))
  (when (plist-member props :key)
    (setq props
          (plist-put props :key
                     (etaf--validate-key (plist-get props :key)))))
  (let* ((entry (gethash tag etaf--view-registry))
         (children (etaf--validate-code-children children tag))
         (slot-inputs (etaf--validate-code-slots named-slots)))
    (when (and slot-inputs (eq entry etaf--host-marker))
      (etaf--component-error "Host %S does not accept named slots" tag))
    (etaf--view-call tag props (append children slot-inputs))))

(defun etaf--text-view-from-string (value)
  "Return one normalized Text View containing string VALUE."
  (etaf--view-node-create :name 'text :props nil :children (list value)))

(defun etaf--normalize-structural-child (child)
  "Normalize static structural CHILD without evaluating expressions."
  (cond
   ((stringp child) (etaf--text-view-from-string child))
   ((etaf--slot-input-p child)
    (let ((copy (copy-sequence child)))
      (setf (etaf--slot-input-children copy)
            (mapcar #'etaf--normalize-structural-child
                    (etaf--slot-input-children child)))
      copy))
   (t child)))

(defun etaf--view-call (name props children &optional token)
  "Construct NAME from PROPS and CHILDREN, retaining optional site TOKEN."
  (unless (symbolp name)
    (etaf--syntax-error "View name must be a symbol: %S" name))
  (setq props (etaf--validate-property-plist props))
  (let* ((entry (gethash name etaf--view-registry))
         (host-name (and (eq entry etaf--host-marker)
                         name))
         (children
          (if (eq host-name 'text)
              children
            (mapcar #'etaf--normalize-structural-child children))))
    (cond
     ((eq entry etaf--host-marker)
      (when (and (eq host-name 'text) (/= (length children) 1))
        (etaf--syntax-error
         "Text requires exactly one string or expr payload"))
      (when (plist-member props :key)
        (etaf--validate-key
         (etaf--resolve-property-value (plist-get props :key))))
     (etaf--view-node-create
       :name host-name
       :token token
       :props props
       :children children))
     ((etaf--component-spec-p entry)
      (pcase-let* ((`(,business-props ,attrs)
                    (etaf--partition-component-input entry props)))
        (let (default-children named-slots)
        (dolist (child children)
          (if (etaf--slot-input-p child)
              (progn
                (when (assq (etaf--slot-input-name child) named-slots)
                  (etaf--component-error
                   "Duplicate Component slot %S" (etaf--slot-input-name child)))
                (push (cons (etaf--slot-input-name child)
                            (etaf--slot-input-children child))
                      named-slots))
            (push child default-children)))
        (setq default-children (nreverse default-children)
              named-slots (nreverse named-slots))
        (when (and default-children (assq 'default named-slots))
          (etaf--component-error
           "Component default slot has both children and an explicit input"))
        (etaf--component-call-create
         :spec entry
         :props business-props
         :attrs attrs
         :slots (if default-children
                    (cons (cons 'default default-children) named-slots)
                  named-slots)))))
     (t
      (etaf--component-error "Unknown ETAF Host or Component: %S" name)))))

(provide 'etaf-view)

;;; etaf-view.el ends here
