;;; etaf-host-bridge.el --- Host properties, styles, Ebox bridge and Host queries -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; Evaluation contexts, Host property resolution, Theme and Component style
;; application, Ebox node property bridging, Host geometry queries and direct
;; retained Host updates.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'ebox)
(require 'etaf-reactive)
(require 'etaf-animation)
(require 'etaf-context)
(require 'etaf-view)
(require 'etaf-component)
(require 'etaf-txn)

;; The native predicate is absent from Emacs builds without image support.
(declare-function imagep "image.c" (spec))
(declare-function etaf--dispatch-activation "etaf-events" (runtime host-ref))
(declare-function etaf--keys-validate "etaf-keys" (keys))
(declare-function etaf--region-validate "etaf-regions" (region))
(declare-function etaf--keys-register "etaf-keys" (runtime keys))
(declare-function etaf-dispatch-event "etaf-events" (runtime host-ref kind &optional payload payload-p))
(declare-function etaf--sticky-refresh "etaf-runtime" (runtime))
(declare-function etaf-runtime-require-mounted "etaf-runtime" (&optional runtime))
(defvar etaf--drag-cancel-p)

;;;; Evaluation contexts

(defun etaf--ctx-inner (ctx)
  "Return CTX's context for descendants of one of its Hosts."
  (if (not (etaf--ictx-root-p ctx))
      ctx
    (or (etaf--ictx-inner ctx)
        (setf (etaf--ictx-inner ctx)
              (etaf--ictx-make :runtime (etaf--ictx-runtime ctx)
                               :owner (etaf--ictx-owner ctx)
                               :root-p nil
                               :context (etaf--ictx-context ctx)
                               :theme (etaf--ictx-theme ctx))))))

(defun etaf--ctx-theme (ctx)
  "Return the Theme source inherited by CTX, without reading it."
  (let ((theme (etaf--ictx-theme ctx)))
    (if (not (eq theme 'unset))
        theme
      (setf (etaf--ictx-theme ctx)
            (let ((etaf--current-context (etaf--ictx-context ctx)))
              (etaf--theme-source))))))

(defun etaf--ctx-call (ctx function &optional phase)
  "Call FUNCTION with CTX's Component environment and return its value.
PHASE is `render' (the default) or `lifecycle' for a retained effect that
must run outside the pure render phase."
  (let* ((instance (etaf--ictx-owner ctx))
         (spec (and instance (etaf--instance-spec instance)))
         (etaf--current-ictx ctx)
         (etaf--current-runtime (etaf--ictx-runtime ctx))
         (etaf--current-context (etaf--ictx-context ctx))
         (etaf--current-component-instance instance)
         (etaf--current-component-props (and instance (etaf--instance-cells instance)))
         (etaf--current-component-slots-ref
          (and instance (etaf--instance-slots-ref instance)))
         (etaf--current-component-state (and instance (etaf--instance-state instance)))
         (etaf--current-component-setup-defined-p
          (and spec (etaf--component-spec-setup spec) t))
         (etaf--current-component-setup-complete-p
          (and instance (etaf--instance-setup-p instance)))
         (etaf--render-parent-style-owners (and instance (etaf--instance-pctx instance)))
         (etaf--component-phase (and instance (if (eq phase 'lifecycle) 'setup 'render)))
         (etaf--render-phase-p (not (eq phase 'lifecycle))))
    (funcall function)))

(defun etaf--wrap-component-environment (function)
  "Return FUNCTION wrapped to run in the current Component environment.
A watcher, effect or computed getter created during Component setup or a
Runtime operation keeps that operation's Context, Runtime and lifecycle
phase on every later reactive run.  The wrapper forwards any arguments,
because watcher callbacks receive the new and old values."
  (let ((ctx etaf--current-ictx))
    (if (null ctx)
        function
      (lambda (&rest arguments)
        (etaf--ctx-call ctx (lambda () (apply function arguments)) 'lifecycle)))))

;; Name the hook with a function of its own.  `etaf-reactive' owns
;; `etaf--effect-environment' and delegates through this hook, so pointing the
;; hook at that wrapper would call it again from inside itself.
(defun etaf-runtime--animation-owner-buffer ()
  "Return the buffer of the currently active Runtime, or nil."
  (when-let* ((runtime (etaf-current-runtime)))
    (etaf-runtime-buffer runtime)))

(setq etaf--effect-environment-function #'etaf--wrap-component-environment)
(setq etaf-animation--owner-buffer-function #'etaf-runtime--animation-owner-buffer)

(defun etaf--note-update (ctx)
  "Record that an effect owned by CTX's instance re-ran."
  (let ((instance (etaf--ictx-owner ctx)))
    (when (and instance (etaf--instance-mounted-p instance)
               (not (etaf--instance-updated-p instance)))
      (let ((runtime (etaf--ictx-runtime ctx)))
        (setf (etaf--instance-updated-p instance) t)
        (push instance (etaf-runtime-updated-instances runtime))
        (etaf--runtime-touch runtime)))))

(defun etaf--effect (ctx owner function &optional quiet)
  "Run FUNCTION for OWNER in CTX now and return its retained effect, or nil.
Without a Runtime, FUNCTION runs once untracked.  An effect that read no
reactive source can never re-run, so it is released immediately.  Unless
QUIET, each later run records an update of CTX's Component instance."
  (if (null (etaf--ictx-runtime ctx))
      (progn (etaf-untracked (etaf--ctx-call ctx function)) nil)
    (let* ((first t)
           (effect
            (etaf-reactive-effect-create
             (lambda ()
               (if first
                   (setq first nil)
                 (unless quiet (etaf--note-update ctx)))
               (etaf--ctx-call ctx function))
             :phase 1 :owner owner :scope nil :data etaf--txn)))
      (when etaf--txn (push effect (etaf--txn-created etaf--txn)))
      (condition-case err
          (etaf-reactive-effect-run effect)
        ((error quit)
         (etaf-reactive-effect-stop effect t)
         (signal (car err) (cdr err))))
      (if (etaf-effect-deps effect)
          effect
        (etaf-reactive-effect-stop effect t)
        nil))))

(defun etaf--effect-rerun (effect)
  "Run retained EFFECT again now."
  (when (and effect (etaf-effect-active effect))
    (etaf-reactive-effect-run effect)))

(defun etaf--stop (effect)
  "Stop EFFECT when non-nil; a rollback revives a committed effect."
  (when (and effect (etaf-effect-active effect))
    (when (and etaf--txn (not (etaf--txn-fresh-p effect)))
      (push effect (etaf--txn-stopped etaf--txn)))
    (etaf-reactive-effect-stop effect t)))

;;;; Host properties

(defun etaf--behavior-source-p (value)
  "Return non-nil when VALUE has the public `:use' source grammar."
  (or (null value)
      (symbolp value)
      (etaf-behavior-spec-p value)
      (and (proper-list-p value)
           (cl-every (lambda (entry)
                       (or (symbolp entry) (etaf-behavior-spec-p entry)))
                     value))))

(defun etaf--validate-semantic-properties (props)
  "Return PROPS after validating ETAF Runtime-owned metadata values."
  (cl-loop for (property value) on props by #'cddr
           do
           (cond
            ((eq property :ref)
             (unless (or (null value) (symbolp value) (functionp value)
                         (and (consp value) (eq (car value) 'etaf-host)))
               (signal 'etaf-renderer-error
                       (list ":ref must be a symbol, function, or nil"))))
            ((eq property :role)
             (unless (or (null value) (symbolp value) (stringp value))
               (signal 'etaf-renderer-error
                       (list ":role must be a symbol, string, or nil"))))
            ((etaf--aria-property-p property)
             (unless (or (null value) (stringp value) (numberp value)
                         (symbolp value))
               (signal 'etaf-renderer-error
                       (list (format "%S has an invalid semantic value"
                                     property)))))
            ((etaf--event-property-p property)
             (unless (or (null value) (functionp value))
               (signal 'etaf-renderer-error
                       (list (format "%S must be a function or nil"
                                     property)))))
            ((eq property :disabled)
             (unless (memq value '(nil t))
               (signal 'etaf-renderer-error
                       (list ":disabled must be boolean"))))
            ((eq property :sticky)
             (unless (memq value '(nil top))
               (signal 'etaf-renderer-error
                       (list ":sticky must be `top' or nil"))))
            ((eq property :translate)
             (unless (memq value '(nil t yes no content))
               (signal 'etaf-renderer-error
                       (list ":translate must be t, `yes', `no', `content' or nil"))))
            ((eq property :tab-index)
             (unless (or (null value) (integerp value))
               (signal 'etaf-renderer-error
                       (list ":tab-index must be an integer or nil"))))
            ((eq property :focus-group)
             (unless (memq value '(nil vertical horizontal grid))
               (signal 'etaf-renderer-error
                       (list ":focus-group must be vertical, horizontal, grid or nil"))))
            ((eq property :focus-scope)
             (unless (memq value '(nil modal))
               (signal 'etaf-renderer-error
                       (list ":focus-scope must be `modal' or nil"))))
            ((eq property :key-scope)
             (unless (memq value '(nil local))
               (signal 'etaf-renderer-error
                       (list ":key-scope must be `local' or nil"))))
            ((eq property :keys)
             (etaf--keys-validate value))
            ((eq property :help)
             (unless (or (null value) (stringp value)
                         (and (proper-list-p value) (cl-every #'stringp value)))
               (signal 'etaf-renderer-error
                       (list ":help must be a string or a list of strings"))))
            ((eq property :on-direction)
             (unless (or (null value) (functionp value))
               (signal 'etaf-renderer-error
                       (list ":on-direction must be a function or nil"))))
            ((eq property :region)
             (etaf--region-validate value))
            ((eq property :use)
             (unless (or (etaf--behavior-source-p value)
                         (and (proper-list-p value)
                              (cl-every #'etaf-behavior-spec-p value)))
               (signal 'etaf-renderer-error
                       (list ":use must be a Behavior symbol, spec, or proper list"))))))
  props)

(defun etaf--behavior-specs (value)
  "Normalize resolved `:use' VALUE to a list of Behavior specs."
  (cl-labels
      ((resolve
        (entry)
        (cond
         ((etaf-behavior-spec-p entry) entry)
         ((and (symbolp entry) (fboundp entry))
          (let ((spec (funcall entry)))
            (unless (etaf-behavior-spec-p spec)
              (signal 'etaf-behavior-error
                      (list (format "Behavior constructor %S returned %S"
                                    entry spec))))
            spec))
         ((symbolp entry)
          (signal 'etaf-behavior-error
                  (list (format "Unknown Behavior constructor: %S" entry))))
         (t
          (signal 'etaf-behavior-error
                  (list (format "Invalid :use entry: %S" entry)))))))
    (let ((specs
           (cond
            ((null value) nil)
            ((or (symbolp value) (etaf-behavior-spec-p value))
             (list (resolve value)))
            ((proper-list-p value) (mapcar #'resolve value))
            (t
             (signal 'etaf-behavior-error
                     (list ":use must be a Behavior symbol, spec, or proper list")))))
          names)
      (dolist (spec specs)
        (let ((name (etaf-behavior-spec-name spec)))
          (when (memq name names)
            (signal 'etaf-behavior-error
                    (list (format "Duplicate Behavior on one Host: %S" name))))
          (push name names)))
      specs)))

(defun etaf--merge-behavior-props (props tag)
  "Return resolved PROPS of Host TAG with its `:use' Behavior attributes merged."
  (etaf--validate-semantic-properties props)
  (let* ((specs (etaf--behavior-specs (plist-get props :use)))
         (merged (etaf--plist-set props :use specs)))
    (dolist (spec specs)
      (let ((attributes (etaf--resolve-property-plist
                         (etaf-behavior-spec-attributes spec))))
        (etaf--validate-semantic-properties attributes)
        (while attributes
          (let ((key (pop attributes)) (value (pop attributes)))
            (cond
             ((or (etaf--event-property-p key) (eq key :disabled)
                  (etaf--owned-semantic-property-p key))
              (setq merged (etaf--merge-host-attrs
                            merged (list key value) tag
                            (etaf-behavior-spec-name spec))))
             ((eq key :keys)
              ;; The Host's own bindings shadow its Behaviors' bindings.
              (setq merged (etaf--plist-set
                            merged :keys (append (plist-get merged :keys) value))))
             ((not (plist-member merged key))
              (setq merged (append merged (list key value)))))))))
    merged))

(defun etaf--interaction-boundary-p (props)
  "Return non-nil when resolved PROPS describe an interaction boundary.
Disabled and callbackless controls still own their hit area.  Ordinary text
with only a reference or accessibility label remains part of its parent."
  (or (functionp (plist-get props :on-press))
      (functionp (plist-get props :on-drag))
      (plist-get props :disabled)
      (numberp (plist-get props :tab-index))
      (member (let ((role (plist-get props :role)))
                (if (symbolp role) (symbol-name role) role))
              '("button" "checkbox" "combobox" "link" "menuitem" "option"
                "radio" "slider" "spinbutton" "switch" "tab" "textbox"
                "treeitem"))))

(defun etaf--semantic-props-p (props)
  "Return non-nil when PROPS carry a non-nil ETAF semantic property."
  (cl-loop for (key value) on props by #'cddr
           thereis (and value (etaf--semantic-property-p key))))

(defun etaf--event-kind (property)
  "Return the event kind named by `:on-' PROPERTY."
  (intern (substring (symbol-name property) 4)))

(defun etaf--props-handlers (props)
  "Return the event handler alist of resolved Host PROPS."
  (let (handlers)
    (cl-loop for (key value) on props by #'cddr
             when (and (etaf--event-property-p key) (functionp value))
             do (push (cons (etaf--event-kind key) value) handlers))
    (nreverse handlers)))

(defun etaf--activation-keymap (runtime host ref press drag lock edge)
  "Return HOST's activation keymap dispatching REF in RUNTIME."
  (let ((key (list ref press drag lock edge))
        (cached (etaf--host-keymap host)))
    (if (and cached (equal (car cached) key))
        (cdr cached)
      (let ((map (ebox-keymap-create
                  :activate
                  (when press
                    (lambda () (etaf--dispatch-activation runtime ref)))
                  :drag
                  (when drag
                    (lambda (gesture)
                      (when (and (etaf-runtime-mounted-p runtime)
                                 (cdr (assq 'drag (etaf-runtime-handler-for runtime ref))))
                        (let ((etaf--drag-cancel-p
                               (eq (plist-get gesture :phase) 'cancel)))
                          (etaf-dispatch-event runtime ref 'drag gesture t)))))
                  :drag-lock-modifier lock
                  :drag-edge edge)))
        (setf (etaf--host-keymap host) (cons key map))
        map))))

(defun etaf--relay-dispatcher (runtime host ref kind)
  "Return HOST's stable Ebox function dispatching KIND events of REF in RUNTIME.
KIND is `swipe' or `scroll'.  The function identity stays constant across
renders, so a re-rendered `:on-swipe' or `:on-scroll' callback does not
invalidate layout."
  (let ((cached (assq kind (etaf--host-relays host))))
    (if (and cached (eq (cadr cached) ref))
        (cddr cached)
      (let ((fn (lambda (value)
                  (when (and (etaf-runtime-mounted-p runtime)
                             (cdr (assq kind (etaf-runtime-handler-for runtime ref))))
                    (etaf-dispatch-event runtime ref kind value t)))))
        (setf (etaf--host-relays host)
              (cons (cons kind (cons ref fn))
                    (assq-delete-all kind (etaf--host-relays host))))
        fn))))

;;;; Theme

(defvar etaf--theme-host-default-cache
  (make-hash-table :test #'eq :weakness 'key)
  "Theme value to (Host name to resolved accepted defaults).")

(defun etaf--theme-host-defaults (theme name)
  "Return THEME's resolved defaults accepted by Host NAME."
  (if (null theme)
      nil
    (let* ((by-name (or (gethash theme etaf--theme-host-default-cache)
                        (puthash theme (make-hash-table :test #'eq)
                                 etaf--theme-host-default-cache)))
           (cached (gethash name by-name 'none)))
      (if (not (eq cached 'none))
          cached
        (let ((tail theme) result)
          (while tail
            (let ((key (pop tail)) (value (pop tail)))
              (when (and (keywordp key)
                         (ebox-style-schema-id key)
                         (ebox-style-property-accepted-p name key))
                (let ((resolved (etaf--theme-token-resolve-from-theme
                                 (etaf-theme-token key value) theme)))
                  (when resolved
                    (push key result)
                    (push resolved result))))))
          (puthash name (nreverse result) by-name))))))

(defun etaf--ctx-theme-value (ctx)
  "Return CTX's Theme plist, tracking a reactive Theme source."
  (let ((source (etaf--ctx-theme ctx)))
    (etaf--theme-source-value source nil t)))

(defun etaf--theme-hover-token-p (value)
  "Return non-nil when a `:hover-style' plist VALUE carries a Theme token."
  (and (proper-list-p value)
       (cl-loop for (_key item) on value by #'cddr
                thereis (etaf-theme-token-p item))))

(defun etaf--resolve-theme-plist (props theme)
  "Return PROPS with Theme tokens resolved from THEME.
Tokens nested in a `:hover-style' plist resolve too: Ebox turns that plist
into a native mouse face, where an unresolved token is an invalid attribute
and the hover paint is lost."
  (if (not (cl-loop for (key value) on props by #'cddr
                    thereis (or (etaf-theme-token-p value)
                                (and (eq key :hover-style)
                                     (etaf--theme-hover-token-p value)))))
      props
    (cl-loop for (key value) on props by #'cddr
             append (list key
                          (cond
                           ((etaf-theme-token-p value)
                            (etaf--theme-token-resolve-from-theme value theme))
                           ((eq key :hover-style)
                            (etaf--resolve-theme-plist value theme))
                           (t value))))))

;;;; Component styles

(defun etaf--instance-rules (instance theme)
  "Return INSTANCE's Component rule snapshot for THEME."
  (let* ((rules (etaf--component-spec-styles (etaf--instance-spec instance)))
         (key (etaf--instance-style-key instance)))
    (if (and key (eq (car key) theme) (eq (cdr key) rules))
        (etaf--instance-style-revision instance)
      (let ((resolved (mapcar (lambda (rule)
                                (cons (car rule)
                                      (etaf--resolve-theme-plist (cdr rule) theme)))
                              rules)))
        (setf (etaf--instance-style-key instance) (cons theme rules)
              (etaf--instance-style-revision instance)
              (ebox-style-scope-with-rules (etaf--instance-style-scope instance)
                                           resolved))))))

;;;; Ebox properties

(defconst etaf--rejected-host-props
  '(:face :surface-properties :selector-attributes :selector-state
    :ecss-scopes :ecss-scope-roots :interactions)
  "Ebox metadata ETAF Hosts must not author directly.")

(defconst etaf--affordance-props
  '(:help-echo :pointer :hover-style :hover-content :drag-lock-modifier
    :hover-group)
  "Host affordances passed to Ebox even on non-activating Hosts.")

(defun etaf--attribute-name (key)
  "Return selector attribute name of semantic KEY."
  (substring (symbol-name key) 1))

(defun etaf--image-props (props)
  "Return prepared Ebox image of resolved image PROPS."
  (let ((src (plist-get props :src))
        (columns (plist-get props :columns))
        (rows (plist-get props :rows))
        (adapter (or (plist-get props :adapter) 'auto))
        (inset (plist-get props :inset)))
    (unless (or (stringp src)
                (and (consp src) (eq (car src) 'image)
                     (proper-list-p (cdr src))
                     (symbolp (plist-get (cdr src) :type))
                     (or (stringp (plist-get (cdr src) :data))
                         (stringp (plist-get (cdr src) :file)))))
      (signal 'etaf-renderer-error
              (list (format "Image :src must be a file path or an image descriptor with :type and :data or :file: %S"
                            src))))
    (dolist (pair (list (cons :columns columns) (cons :rows rows)))
      (unless (and (integerp (cdr pair)) (> (cdr pair) 0))
        (signal 'etaf-renderer-error
                (list (format "Image %s must be a positive integer: %S"
                              (car pair) (cdr pair))))))
    (unless (memq adapter '(auto kitty text placeholder))
      (signal 'etaf-renderer-error
              (list (format "Image :adapter must be auto, kitty, text or placeholder: %S"
                            adapter))))
    (unless (or (null inset)
                (and (consp inset) (natnump (car inset)) (natnump (cdr inset))))
      (signal 'etaf-renderer-error
              (list (format "Image :inset must be nil or (TOP . BOTTOM) pixels: %S"
                            inset))))
    (ebox-image-prepare src columns rows :adapter adapter :inset inset)))

(defun etaf--compute-eprops (name props ctx theme runtime host ref)
  "Return the Ebox properties of Host NAME with resolved PROPS.
CTX supplies Component styles, THEME supplies tokens and defaults.  RUNTIME,
HOST and REF are non-nil for a mounted Host, which receives a keymap."
  (let ((tail props) (image-p (eq name 'image)) result attributes)
    (while tail
      (let ((key (pop tail)) (value (pop tail)))
        (cond
         ((memq key etaf--rejected-host-props)
          (signal 'etaf-renderer-error
                  (list (format "%S is not a canonical ETAF property" key))))
         ((eq key :content)
          (signal 'etaf-renderer-error
                  (list "Use View children for content, not :content")))
         ((memq key '(:class :id :key))
          (when value (push key result) (push value result)))
         ((eq key :role)
          (when value (push (cons "role" value) attributes)))
         ((memq key '(:focus-group :focus-scope))
          (when value (push key result) (push value result)))
         ((etaf--aria-property-p key)
          (push (cons (etaf--attribute-name key) value) attributes))
         ((or (etaf--semantic-property-p key) (eq key :styles)) nil)
         ((and image-p (memq key '(:src :columns :rows :adapter :inset))) nil)
         (t
          (when (etaf-theme-token-p value)
            (setq value (etaf--theme-token-resolve-from-theme value theme)))
          (when value (push key result) (push value result))))))
    ;; RESULT is built in reverse: each pair pushes its key, then its value.
    (when attributes
      (push :attributes result) (push (nreverse attributes) result))
    (when (etaf--interaction-boundary-p props)
      (let* ((disabled (plist-get props :disabled))
             (press (functionp (plist-get props :on-press)))
             (drag (functionp (plist-get props :on-drag)))
             (map (and runtime (or press drag) (not disabled)
                       (etaf--activation-keymap runtime host ref press drag
                                          (plist-get props :drag-lock-modifier)
                                          (plist-get props :drag-edge)))))
        (when map (push :keymap result) (push map result))
        (when (plist-get props :tab-index)
          (push :tab-index result) (push (plist-get props :tab-index) result))
        (when disabled (push :disabled result) (push t result))
        (when (and (or press drag) (not disabled) (not (plist-member props :pointer)))
          (push :pointer result) (push 'hand result))))
    (when (and runtime (functionp (plist-get props :on-swipe))
               (not (plist-get props :disabled)))
      (push :swipe result)
      (push (etaf--relay-dispatcher runtime host ref 'swipe) result))
    (when (and runtime (functionp (plist-get props :on-scroll))
               (not (plist-get props :disabled)))
      (push :scroll result)
      (push (etaf--relay-dispatcher runtime host ref 'scroll) result))
    (dolist (key etaf--affordance-props)
      (when (plist-member props key)
        (let ((value (plist-get props key)))
          ;; A hover style is a plist Ebox turns into a native mouse face;
          ;; resolve its tokens like any other Host style value.
          (when (and (eq key :hover-style)
                     (etaf--theme-hover-token-p value))
            (setq value (etaf--resolve-theme-plist value theme)))
          (push key result) (push value result))))
    (unless image-p
      (when-let* ((defaults (etaf--theme-host-defaults theme name)))
        (push :defaults result) (push defaults result)))
    (when-let* ((owner (etaf--ictx-owner ctx))
                (scope (or (etaf--instance-style-scope owner)
                           (and (etaf--component-spec-styles
                                 (etaf--instance-spec owner))
                                (setf (etaf--instance-style-scope owner)
                                      (ebox-style-scope-create nil))))))
      (push :ecss-scopes result) (push (list scope) result)
      (when (etaf--ictx-root-p ctx)
        (push :ecss-scope-roots result)
        (push (list (etaf--instance-rules owner theme)) result)))
    (setq result (nreverse result))
    (if (not image-p)
        result
      (append (cl-loop for (key value) on result by #'cddr
                       unless (ebox-style-schema-id key)
                       append (list key value))
              (list :image (etaf--image-props props))))))


;;;; Host queries

(defun etaf--runtime-host-seg (runtime ref)
  "Return RUNTIME's mounted Host segment registered as REF, or nil."
  (gethash ref (etaf-runtime-hosts runtime)))

(defun etaf-runtime-host-node (runtime ref)
  "Return the Ebox node of RUNTIME's Host REF, or nil."
  (let ((seg (etaf--runtime-host-seg runtime ref)))
    (and seg (etaf--seg-node seg))))

(defun etaf-host-ref-row-spans (runtime host-ref)
  "Return the committed Ebox `(ROW BEG END)' row spans of HOST-REF in RUNTIME.
Returns nil when HOST-REF is absent or has no committed layout spans."
  (when-let* ((node (etaf-runtime-host-node runtime host-ref)))
    (ebox-node-row-spans node)))

(defun etaf-runtime-overlay-active-p (&optional runtime)
  "Return non-nil when RUNTIME has an active root surface or named root overlay.
RUNTIME defaults to the current mounted Runtime."
  (let ((rt (etaf-runtime-require-mounted runtime)))
    (and (or (etaf-runtime-surface rt)
             (etaf-runtime-overlay-entries rt))
         t)))

(defun etaf-runtime-node-host-ref (runtime node)
  "Return the reference of RUNTIME's nearest registered Host at or above NODE."
  (let ((nodes (etaf-runtime-nodes runtime)) found)
    (while (and node (not found))
      (let ((seg (gethash node nodes)))
        (if seg
            (setq found (etaf--host-ref (etaf--seg-data seg)))
          (setq node (ebox-node-parent node)))))
    found))

(defun etaf--walk-hosts (runtime function)
  "Call FUNCTION with each registered Host segment of RUNTIME in order."
  (let ((stack (append (delq nil (list (etaf-runtime-root runtime)
                                       (etaf-runtime-surface runtime)))
                       (mapcar #'cdr (etaf-runtime-overlay-entries runtime)))))
    (while stack
      (let ((seg (pop stack)))
        (when (and (eq (etaf--seg-kind seg) 'host)
                   (etaf--host-reg (etaf--seg-data seg)))
          (funcall function seg))
        (setq stack (append (etaf--seg-kids seg) stack))))))

(defun etaf--seg-ancestor-refs (seg)
  "Return the registered Host references above SEG, nearest first."
  (let ((parent (etaf--seg-parent seg)) refs)
    (while parent
      (when (and (eq (etaf--seg-kind parent) 'host)
                 (etaf--host-reg (etaf--seg-data parent)))
        (push (etaf--host-ref (etaf--seg-data parent)) refs))
      (setq parent (etaf--seg-parent parent)))
    (nreverse refs)))

;;;###autoload
(defun etaf-runtime-host-props-for (runtime host-ref)
  "Return a fresh copy of RUNTIME's semantic Host props for HOST-REF, or nil."
  (let ((seg (etaf--runtime-host-seg runtime host-ref)))
    (and seg (copy-sequence (etaf--host-props (etaf--seg-data seg))))))

;;;###autoload
(defun etaf-runtime-host-props-entries (runtime)
  "Return RUNTIME's mounted semantic Hosts as ((REF . PROPS) ...) in order."
  (let (entries)
    (etaf--walk-hosts runtime
                      (lambda (seg)
                        (let ((host (etaf--seg-data seg)))
                          (push (cons (etaf--host-ref host)
                                      (copy-sequence (etaf--host-props host)))
                                entries))))
    (nreverse entries)))

;;;###autoload
(defun etaf-runtime-handler-for (runtime host-ref)
  "Return HOST-REF's event handlers in RUNTIME as ((KIND . FUNCTION) ...)."
  (let ((seg (etaf--runtime-host-seg runtime host-ref)))
    (and seg (etaf--props-handlers (etaf--host-props (etaf--seg-data seg))))))

;;;###autoload
(defun etaf-runtime-handler-entries (runtime)
  "Return RUNTIME's Hosts with handlers as ((REF (KIND . FUNCTION) ...) ...)."
  (let (entries)
    (etaf--walk-hosts runtime
                      (lambda (seg)
                        (let* ((host (etaf--seg-data seg))
                               (handlers (etaf--props-handlers (etaf--host-props host))))
                          (when handlers
                            (push (cons (etaf--host-ref host) handlers) entries)))))
    (nreverse entries)))

;;;###autoload
(defun etaf-runtime-host-ancestor-refs (runtime host-ref)
  "Return the semantic Host references above HOST-REF in RUNTIME, nearest first."
  (let ((seg (etaf--runtime-host-seg runtime host-ref)))
    (and seg (etaf--seg-ancestor-refs seg))))

;;;###autoload
(defun etaf-runtime-host-ancestries (runtime host-refs)
  "Return a table from each of HOST-REFS to its lineage in RUNTIME.
A lineage lists the Host reference itself, then its semantic ancestors'
references, nearest first.  Unknown references are absent."
  (let ((table (make-hash-table :test #'equal)))
    (dolist (ref host-refs table)
      (when-let* ((seg (etaf--runtime-host-seg runtime ref)))
        (puthash ref (cons ref (etaf--seg-ancestor-refs seg)) table)))))

;;;; Retained Host updates

(defun etaf--require-host-node (runtime ref)
  "Return RUNTIME's node for Host REF or signal `etaf-runtime-error'."
  (or (etaf-runtime-host-node runtime ref)
      (signal 'etaf-runtime-error (list "Unknown committed Host" ref))))

;;;###autoload
(defun etaf-runtime-update-host-contents (runtime updates)
  "Replace Host contents in mounted RUNTIME from UPDATES, ((REF . CONTENT) ...).
CONTENT is a string or an image from `create-image'.  Builds without native
image support accept strings only.  Every target validates before the first
change; invalid content signals `etaf-runtime-error'.  Return t."
  (setq runtime (etaf-runtime-require-mounted runtime))
  (unless (and (proper-list-p updates)
               (cl-every (lambda (entry)
                           (and (consp entry)
                                (or (stringp (cdr entry))
                                    (and (fboundp 'imagep) (imagep (cdr entry))))))
                         updates))
    (signal 'etaf-runtime-error (list "Invalid Host content updates" updates)))
  (let ((nodes (mapcar (lambda (entry)
                         (let ((node (etaf--require-host-node runtime (car entry))))
                           (unless (ebox-node-text-p node)
                             (signal 'etaf-runtime-error
                                     (list "Host cannot hold content" (car entry))))
                           node))
                       updates)))
    (ebox-with-batch
      (cl-loop for node in nodes for entry in updates
               do (ebox-node-set-text
                   node (if (stringp (cdr entry)) (cdr entry)
                          (propertize " " 'display (cdr entry))))))
    (cl-incf (etaf-runtime-rev runtime))
    (when (etaf-runtime-sticky runtime)
      (etaf--sticky-refresh runtime))
    t))

;;;###autoload
(defun etaf-runtime-update-host-content (runtime host-ref content)
  "Replace HOST-REF's content in mounted RUNTIME with string or image CONTENT."
  (etaf-runtime-update-host-contents runtime (list (cons host-ref content))))

;;;###autoload
(defun etaf-runtime-update-host-geometries (runtime updates)
  "Set Host geometry in mounted RUNTIME from UPDATES, ((REF . PLIST) ...).
Each PLIST holds Ebox position, size or layer properties.  Return t."
  (setq runtime (etaf-runtime-require-mounted runtime))
  (unless (and (proper-list-p updates)
               (cl-every (lambda (entry) (and (consp entry) (proper-list-p (cdr entry))))
                         updates))
    (signal 'etaf-runtime-error (list "Invalid Host geometry updates" updates)))
  (let ((nodes (mapcar (lambda (entry) (etaf--require-host-node runtime (car entry)))
                       updates)))
    (condition-case err
        (ebox-with-batch
          (cl-loop for node in nodes for entry in updates
                   do (cl-loop for (key value) on (cdr entry) by #'cddr
                               do (ebox-node-put node key value))))
      (error (signal 'etaf-runtime-error
                     (list "Host geometry update rejected" (mapcar #'car updates) err))))
    (cl-incf (etaf-runtime-rev runtime))
    (when (etaf-runtime-sticky runtime)
      (etaf--sticky-refresh runtime))
    t))

;;;###autoload
(defun etaf-runtime-update-host-geometry (runtime host-ref &rest geometry)
  "Set HOST-REF's GEOMETRY properties in mounted RUNTIME and return t."
  (etaf-runtime-update-host-geometries runtime (list (cons host-ref geometry))))

(provide 'etaf-host-bridge)
;;; etaf-host-bridge.el ends here
