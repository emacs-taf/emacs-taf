;;; etaf-inspect.el --- On-demand Runtime introspection for ETAF -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Read-only on-demand introspection facade over mounted ETAF Runtimes, plus one
;; controlled binding setter for live debugging tools such as `etaf-devtools'.
;; Nothing in this module runs during ordinary rendering, layout or commits.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'ebox)
(require 'etaf-view)
(require 'etaf-component)
(require 'etaf-reactive)
(require 'etaf-context)
(require 'etaf-resource)
(require 'etaf-data)
(require 'etaf-runtime)
(require 'etaf-events)
(require 'etaf-keys)
(require 'etaf-regions)
(require 'etaf-help)

(defun etaf--inspect-preview (value &optional max-chars)
  "Return a cyclic-safe, property-free string preview of VALUE."
  (let* ((limit (or max-chars 120))
         (print-circle t)
         (print-length 10)
         (print-level 4)
         (print-escape-newlines t)
         (raw
          (cond
           ((stringp value)
            (format "%S" (substring-no-properties value)))
           ((or (null value) (eq value t) (numberp value) (symbolp value))
            (format "%S" value))
           ((functionp value) "#<function>")
           ((bufferp value) (format "#<buffer %s>" (buffer-name value)))
           ((windowp value) "#<window>")
           ((framep value) "#<frame>")
           ((etaf-runtime-p value)
            (format "#<etaf-runtime %s>"
                    (let ((buf (etaf-runtime-buffer value)))
                      (if (buffer-live-p buf) (buffer-name buf) "dead"))))
           ((etaf-ref-p value)
            (format "#<etaf-ref %s>" (etaf--inspect-preview (etaf-ref-value value) 48)))
           ((etaf-computed-p value)
            (format "#<etaf-computed %s>"
                    (if (etaf-computed-evaluated value)
                        (etaf--inspect-preview (etaf-computed-value value) 48)
                      "unevaluated")))
           ((etaf-resource-p value)
            (format "#<etaf-resource %s>" (etaf-resource-status value)))
           ((etaf-data-controller-p value)
            (format "#<etaf-data %s>" (etaf-data-status value)))
           ((hash-table-p value)
            (format "#<hash-table %d>" (hash-table-count value)))
           ((keymapp value) "#<keymap>")
           (t
            (condition-case nil
                (substring-no-properties (prin1-to-string value))
              (error "#<unprintable>"))))))
    (if (> (length raw) limit)
        (concat (substring raw 0 (max 1 (- limit 1))) "…")
      raw)))

(defun etaf--inspect-safe-value (value &optional depth)
  "Return a detached, cyclic-safe copy or summary of VALUE."
  (let ((d (or depth 0)))
    (cond
     ((or (null value) (eq value t) (numberp value) (symbolp value)) value)
     ((stringp value) (substring-no-properties value))
     ((> d 3) (etaf--inspect-preview value 80))
     ((or (functionp value) (bufferp value) (windowp value) (framep value)
          (hash-table-p value) (keymapp value) (etaf-runtime-p value)
          (etaf-ref-p value) (etaf-computed-p value)
          (etaf-resource-p value) (etaf-data-controller-p value)
          (recordp value))
      (etaf--inspect-preview value 80))
     ((proper-list-p value)
      (let ((out nil) (n 0))
        (dolist (item value)
          (when (< n 24)
            (push (etaf--inspect-safe-value item (1+ d)) out)
            (setq n (1+ n))))
        (nreverse out)))
     ((consp value)
      (cons (etaf--inspect-safe-value (car value) (1+ d))
            (etaf--inspect-safe-value (cdr value) (1+ d))))
     ((vectorp value)
      (let* ((len (min (length value) 24))
             (vec (make-vector len nil))
             (idx 0))
        (while (< idx len)
          (aset vec idx (etaf--inspect-safe-value (aref value idx) (1+ d)))
          (setq idx (1+ idx)))
        vec))
     (t (etaf--inspect-preview value 80)))))

(defun etaf--inspect-classes (props)
  "Extract normalized class list from Host PROPS."
  (let ((cls (plist-get props :class)))
    (cond
     ((stringp cls) (split-string cls nil t))
     ((proper-list-p cls)
      (delq nil (mapcar (lambda (c)
                          (cond ((stringp c) (substring-no-properties c))
                                ((symbolp c) (symbol-name c))
                                (t nil)))
                        cls)))
     ((symbolp cls) (and cls (list (symbol-name cls))))
     (t nil))))

(defun etaf--inspect-owner-instance (seg)
  "Return nearest enclosing Component `etaf--instance' of SEG, or nil."
  (let ((cur (etaf--seg-parent seg))
        found)
    (while (and cur (not found))
      (when (eq (etaf--seg-kind cur) 'comp)
        (setq found (etaf--seg-data cur)))
      (setq cur (etaf--seg-parent cur)))
    found))

(defun etaf--inspect-root-host-ids (seg)
  "Return top-level committed Host IDs directly owned by Component SEG."
  (let ((out nil))
    (cl-labels ((walk (node)
                  (when (and node (etaf--seg-live node))
                    (pcase (etaf--seg-kind node)
                      ('host (push (etaf--host-id (etaf--seg-data node)) out))
                      ('comp nil)
                      ('pres nil)
                      (_ (dolist (kid (etaf--seg-kids node)) (walk kid)))))))
      (dolist (kid (etaf--seg-kids seg))
        (walk kid)))
    (nreverse out)))

(defun etaf--inspect-component-source-file (spec)
  "Return source file defining Component SPEC, or nil."
  (let ((sym (etaf--component-spec-definition-symbol spec)))
    (when sym
      (or (symbol-file sym 'defvar)
          (let ((name (etaf--component-spec-name spec)))
            (and name (symbol-file name 'defun)))))))

(defun etaf--inspect-component-props-summary (inst)
  "Return a short display summary of Component INST's non-nil scalar props."
  (let ((cells (etaf--instance-cells inst))
        (parts nil)
        (count 0))
    (when (vectorp cells)
      (let ((names (aref cells 0))
            (idx 1))
        (dolist (pname names)
          (when (and (< count 3) (< idx (length cells)))
            (let* ((cell (aref cells idx))
                   (val (and (etaf-ref-p cell) (etaf-ref-value cell))))
              (when (and val
                         (or (stringp val) (numberp val)
                             (and (symbolp val) (not (eq val t)))))
                (push (format ":%s %s" pname (etaf--inspect-preview val 24)) parts)
                (setq count (1+ count)))))
          (setq idx (1+ idx)))))
    (mapconcat #'identity (nreverse parts) " ")))

(defun etaf--inspect-tree-collect (seg host-ids focused-node)
  "Collect unified Component + Host read-only tree under SEG."
  (when (and seg (etaf--seg-live seg))
    (pcase (etaf--seg-kind seg)
      ('pres nil)
      ('surface nil)
      ('overlay nil)
      ('comp
       (let* ((inst (etaf--seg-data seg))
              (spec (etaf--instance-spec inst))
              (children nil))
         (dolist (kid (etaf--seg-kids seg))
           (setq children
                 (nconc children (etaf--inspect-tree-collect kid host-ids focused-node))))
         (list
          (list :kind 'component
                :id (etaf--instance-id inst)
                :name (etaf--component-spec-name spec)
                :key (let ((k (etaf--seg-key seg)))
                       (etaf--inspect-safe-value (and (consp k) (cdr k))))
                :source-file (etaf--inspect-component-source-file spec)
                :render-count (etaf--instance-render-count inst)
                :props-summary (etaf--inspect-component-props-summary inst)
                :root-host-ids (etaf--inspect-root-host-ids seg)
                :children children))))
      ('host
       (let* ((host (etaf--seg-data seg))
              (id (etaf--host-id host))
              (item (etaf--seg-src seg))
              (tag (etaf--view-node-name item))
              (node (etaf--seg-node seg))
              (outer (etaf--seg-outer-node seg))
              (props (etaf--host-props host))
              (geo (or (and node (ebox-node-geometry node))
                       (and outer (not (eq outer node))
                            (ebox-node-geometry outer))))
              (bucket (etaf--host-presentation host))
              (pres-keys (and bucket
                              (delete-dups
                               (mapcar #'etaf--pres-key
                                       (etaf--pb-all-entries bucket)))))
              (text-preview
               (when (eq tag 'text)
                 (let ((raw (or (etaf--host-text host) "")))
                   (etaf--inspect-preview raw 48))))
              (children nil))
         (puthash id seg host-ids)
         (dolist (kid (etaf--seg-kids seg))
           (setq children
                 (nconc children (etaf--inspect-tree-collect kid host-ids focused-node))))
         (list
          (list :kind 'host
                :id id
                :tag tag
                :ref (etaf--inspect-safe-value (etaf--host-ref host))
                :dom-id (let ((did (plist-get props :id)))
                          (and (stringp did) (substring-no-properties did)))
                :classes (etaf--inspect-classes props)
                :text-preview text-preview
                :presentations pres-keys
                :geometry geo
                :focusable-p (and (numberp (plist-get (etaf--host-eprops host) :tab-index))
                                  (>= (plist-get (etaf--host-eprops host) :tab-index) 0)
                                  (not (plist-get props :disabled)))
                :focused-p (and focused-node (eq node focused-node) t)
                :disabled-p (and (plist-get props :disabled) t)
                :has-press-p (and (functionp (plist-get props :on-press))
                                  (not (plist-get props :disabled)) t)
                :children children))))
      (_
       (let ((result nil))
         (dolist (kid (etaf--seg-kids seg) result)
           (setq result
                 (nconc result (etaf--inspect-tree-collect kid host-ids focused-node)))))))))

;;;###autoload
(defun etaf-runtime-list ()
  "Return a list of all currently mounted live ETAF Runtimes.
Ordered by ascending mount identity."
  (let ((out nil))
    (maphash (lambda (buf runtime)
               (when (and (buffer-live-p buf)
                          (etaf-runtime-p runtime)
                          (etaf-runtime-mounted-p runtime))
                 (push runtime out)))
             etaf--runtimes)
    (sort out (lambda (a b)
                (< (or (etaf-runtime-mount-id a) 0)
                   (or (etaf-runtime-mount-id b) 0))))))

;;;###autoload
(defun etaf-runtime-inspect-tree (&optional runtime)
  "Return mounted RUNTIME's unified Component and Host tree as read-only data.
RUNTIME defaults to the active or current-buffer Runtime.  Each node plist has
`:kind' (`component' or `host'), `:id', metadata and `:children'.  Transient
surfaces and presentation companions are excluded."
  (let* ((runtime (etaf-runtime-require-mounted runtime))
         (table (or (etaf-runtime-host-ids runtime)
                    (setf (etaf-runtime-host-ids runtime)
                          (make-hash-table :test #'eql))))
         (buf (etaf-runtime-buffer runtime))
         (focused (and (buffer-live-p buf) (ebox-focused-node buf))))
    (clrhash table)
    (etaf--inspect-tree-collect (etaf-runtime-root runtime) table focused)))

;;;###autoload
(defun etaf-runtime-host-id-at (runtime &optional position)
  "Return `(INNERMOST-HOST-ID ... ROOT-HOST-ID)' at POSITION in RUNTIME, or nil.
POSITION defaults to `point' in RUNTIME's buffer.  Presentation companion
nodes resolve to their owning application Host."
  (setq runtime (etaf-runtime-require-mounted runtime))
  (let ((buf (etaf-runtime-buffer runtime)))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (let* ((pos (or position (point)))
               (node (and (>= pos (point-min)) (<= pos (point-max))
                          (ebox-node-at pos buf)))
               (nodes (etaf-runtime-nodes runtime))
               (seg nil))
          (while (and node (not seg))
            (setq seg (gethash node nodes))
            (unless seg
              (setq node (ebox-node-parent node))))
          (when seg
            (let ((ids nil)
                  (cur seg))
              (while cur
                (when (and (eq (etaf--seg-kind cur) 'host)
                           (etaf--seg-live cur)
                           (not (etaf--inspect-inside-pres-p cur)))
                  (push (etaf--host-id (etaf--seg-data cur)) ids))
                (setq cur (etaf--seg-parent cur)))
              (nreverse ids))))))))

(defun etaf--inspect-inside-pres-p (seg)
  "Return non-nil when SEG lies inside a presentation companion segment."
  (let ((cur (etaf--seg-parent seg))
        found)
    (while (and cur (not found))
      (when (eq (etaf--seg-kind cur) 'pres)
        (setq found t))
      (setq cur (etaf--seg-parent cur)))
    found))

(defun etaf--inspect-decorate-style (runtime style-info)
  "Replace Ebox scope roots in STYLE-INFO with Component owner metadata."
  (when style-info
    (let* ((nodes (etaf-runtime-nodes runtime))
           (rules
            (mapcar
             (lambda (rule)
               (let* ((root (plist-get rule :scope-root))
                      (rseg (and root (gethash root nodes)))
                      (owner (and rseg
                                  (or (and (etaf--seg-ctx rseg)
                                           (etaf--ictx-owner (etaf--seg-ctx rseg)))
                                      (etaf--inspect-owner-instance rseg))))
                      (spec (and owner (etaf--instance-spec owner)))
                      (decls
                       (mapcar
                        (lambda (d)
                          (list :property (plist-get d :property)
                                :value (etaf--inspect-safe-value (plist-get d :value))
                                :value-preview (etaf--inspect-preview (plist-get d :value) 60)
                                :winner (plist-get d :winner)))
                        (plist-get rule :declarations))))
                 (list :origin (plist-get rule :origin)
                       :inline (plist-get rule :inline)
                       :selector (plist-get rule :selector)
                       :specificity (plist-get rule :specificity)
                       :layer (plist-get rule :layer)
                       :owner-component-id (and owner (etaf--instance-id owner))
                       :owner-component-name (and spec (etaf--component-spec-name spec))
                       :declarations decls)))
             (plist-get style-info :matched-rules))))
      (list :values (etaf--inspect-safe-value (plist-get style-info :values))
            :specified (copy-sequence (plist-get style-info :specified))
            :custom-properties (etaf--inspect-safe-value
                                (plist-get style-info :custom-properties))
            :provenance (etaf--inspect-safe-value (plist-get style-info :provenance))
            :matched-rules rules
            :states (copy-sequence (plist-get style-info :states))
            :diagnostics (etaf--inspect-safe-value (plist-get style-info :diagnostics))))))

;;;###autoload
(defun etaf-runtime-inspect-host (runtime host-id)
  "Return detailed read-only inspection snapshot for HOST-ID in RUNTIME, or nil.
Signals `etaf-runtime-error' when RUNTIME is not mounted or HOST-ID is not an
integer.  Computes box metrics, on-demand ECSS provenance and exact painted
row spans without modifying the buffer or caches."
  (setq runtime (etaf-runtime-require-mounted runtime))
  (unless (integerp host-id)
    (signal 'etaf-runtime-error (list "Host ID must be an integer" host-id)))
  (when-let* ((seg (etaf--runtime-seg-by-id runtime host-id)))
    (let* ((host (etaf--seg-data seg))
           (item (etaf--seg-src seg))
           (tag (etaf--view-node-name item))
           (node (etaf--seg-node seg))
           (props (etaf--host-props host))
           (eprops (etaf--host-eprops host))
           (owner (etaf--inspect-owner-instance seg))
           (owner-spec (and owner (etaf--instance-spec owner)))
           (bucket (etaf--host-presentation host))
           (buf (etaf-runtime-buffer runtime))
           (focused (and (buffer-live-p buf) (ebox-focused-node buf)))
           (geos (etaf-runtime-host-geometries runtime (list host-id)))
           (geo-entry (cdr (assq host-id geos)))
           (box-metrics (and node (ebox-node-box-metrics node)))
           (style-raw (and node (ebox-node-inspect-style node)))
           (row-spans (and node (ebox-node-row-spans node))))
      (list :id host-id
            :tag tag
            :ref (etaf--inspect-safe-value (etaf--host-ref host))
            :dom-id (let ((did (plist-get props :id)))
                      (and (stringp did) (substring-no-properties did)))
            :classes (etaf--inspect-classes props)
            :text (when (eq tag 'text) (etaf--inspect-safe-value (etaf--host-text host)))
            :owner-component-id (and owner (etaf--instance-id owner))
            :owner-component-name (and owner-spec (etaf--component-spec-name owner-spec))
            :props (etaf--inspect-safe-value (etaf--sanitize-host-props props))
            :resolved-props (etaf--inspect-safe-value (etaf--sanitize-host-props eprops))
            :behaviors (mapcar (lambda (b)
                                 (or (and (consp b) (car b))
                                     (etaf--inspect-preview b 32)))
                               (etaf--host-behaviors host))
            :presentations (and bucket
                                (mapcar (lambda (entry)
                                          (list :key (etaf--pres-key entry)
                                                :mode (etaf--pres-mode entry)
                                                :priority (etaf--pres-priority entry)))
                                        (etaf--pb-all-entries bucket)))
            :box-metrics box-metrics
            :style (etaf--inspect-decorate-style runtime style-raw)
            :row-spans row-spans
            :geometry (when geo-entry
                        (list :x (plist-get geo-entry :x)
                              :y (plist-get geo-entry :y)
                              :width (plist-get geo-entry :width)
                              :height (plist-get geo-entry :height)))
            :visible-p (and geo-entry (plist-get geo-entry :visible-p) t)
            :clip-top (and geo-entry (plist-get geo-entry :clip-top))
            :clip-bottom (and geo-entry (plist-get geo-entry :clip-bottom))
            :focusable-p (and (numberp (plist-get eprops :tab-index))
                              (>= (plist-get eprops :tab-index) 0)
                              (not (plist-get props :disabled)) t)
            :focused-p (and focused (eq node focused) t)
            :disabled-p (and (plist-get props :disabled) t)
            :has-press-p (and (functionp (plist-get props :on-press))
                              (not (plist-get props :disabled)) t)))))

(defun etaf--inspect-source-subs (source)
  "Return human-readable summary strings for active subscribers of SOURCE."
  (let ((out nil)
        (n 0))
    (dolist (sub (etaf--source-subs source))
      (when (< n 12)
        (cond
         ((and (etaf-effect-p sub) (etaf-effect-active sub))
          (push (format "effect:%s" (or (etaf-effect-name sub) (etaf-effect-id sub))) out)
          (setq n (1+ n)))
         ((and (etaf-computed-p sub) (etaf-computed-active sub))
          (push (format "computed:%s" (or (etaf-computed-name sub) "anon")) out)
          (setq n (1+ n))))))
    (nreverse out)))

(defun etaf--inspect-computed-deps (comp)
  "Return human-readable names for dependencies of computed COMP."
  (let ((out nil)
        (n 0))
    (dolist (dep (etaf-computed-deps comp))
      (when (< n 12)
        (push (cond
               ((etaf-ref-p dep) (format "ref:%s" (or (etaf-ref-name dep) "anon")))
               ((etaf-computed-p dep) (format "computed:%s" (or (etaf-computed-name dep) "anon")))
               (t "source"))
              out)
        (setq n (1+ n))))
    (nreverse out)))

(defun etaf--inspect-binding-entry (name val)
  "Build detached binding inspection plist for NAME and VAL."
  (cond
   ((etaf-ref-p val)
    (let ((inner (etaf-ref-value val)))
      (list :name name
            :kind 'ref
            :value (etaf--inspect-safe-value inner)
            :value-preview (etaf--inspect-preview inner 80)
            :version (etaf-ref-version val)
            :sub-count (etaf-ref-nsubs val)
            :dep-count 0
            :deps nil
            :subs (etaf--inspect-source-subs val)
            :editable-p t)))
   ((etaf-computed-p val)
    (let ((inner (and (etaf-computed-evaluated val) (etaf-computed-value val))))
      (list :name name
            :kind 'computed
            :value (etaf--inspect-safe-value inner)
            :value-preview (if (etaf-computed-evaluated val)
                               (etaf--inspect-preview inner 80)
                             "<unevaluated>")
            :version (etaf-computed-version val)
            :sub-count (etaf-computed-nsubs val)
            :dep-count (length (etaf-computed-deps val))
            :deps (etaf--inspect-computed-deps val)
            :subs (etaf--inspect-source-subs val)
            :editable-p nil)))
   ((etaf-resource-p val)
    (let ((st (etaf-resource-status val)))
      (list :name name
            :kind 'resource
            :status st
            :value (etaf--inspect-safe-value (etaf-resource-value val))
            :value-preview (etaf--inspect-preview (etaf-resource-value val) 80)
            :error-preview (when-let* ((err (etaf-resource-error val)))
                             (etaf--inspect-preview err 80))
            :editable-p nil)))
   ((etaf-data-controller-p val)
    (list :name name
          :kind 'data-controller
          :status (etaf-data-status val)
          :total (etaf-data-total val)
          :page (etaf-data-page val)
          :page-size (etaf-data-page-size val)
          :value-preview (format "page %s · total %s · %s"
                                 (etaf-data-page val)
                                 (etaf-data-total val)
                                 (etaf-data-status val))
          :editable-p nil))
   (t
    (list :name name
          :kind 'value
          :value (etaf--inspect-safe-value val)
          :value-preview (etaf--inspect-preview val 80)
          :editable-p nil))))

(defun etaf--inspect-context-chain (ctx)
  "Collect effective Context bindings from CTX and its ancestors."
  (let ((seen (make-hash-table :test #'eq))
        (cur ctx)
        (out nil))
    (while cur
      (when (etaf-context-p cur)
        (maphash (lambda (k v)
                   (unless (gethash k seen)
                     (puthash k t seen)
                     (push (list :key k
                                 :value-preview (etaf--inspect-preview v 64))
                           out)))
                 (etaf-context-values cur))
        (setq cur (etaf-context-parent cur))))
    (nreverse out)))

;;;###autoload
(defun etaf-runtime-inspect-component (runtime instance-id)
  "Return detailed read-only snapshot for Component INSTANCE-ID in RUNTIME, or nil.
Signals `etaf-runtime-error' when RUNTIME is not mounted or INSTANCE-ID is not
an integer."
  (setq runtime (etaf-runtime-require-mounted runtime))
  (unless (integerp instance-id)
    (signal 'etaf-runtime-error (list "Instance ID must be an integer" instance-id)))
  (when-let* ((inst (gethash instance-id (etaf-runtime-instances runtime)))
              ((not (etaf--instance-dead inst))))
    (let* ((spec (etaf--instance-spec inst))
           (seg (etaf--instance-seg inst))
           (cells (etaf--instance-cells inst))
           (props-list nil)
           (bindings-list nil)
           (state (etaf--instance-state inst))
           (bnames (etaf--component-spec-binding-names spec))
           (hosts (etaf-runtime-hosts runtime))
           (lrefs nil))
      (when (vectorp cells)
        (let ((names (aref cells 0))
              (idx 1))
          (dolist (pname names)
            (when (< idx (length cells))
              (let* ((cell (aref cells idx))
                     (val (and (etaf-ref-p cell) (etaf-ref-value cell))))
                (push (list :name pname
                            :value (etaf--inspect-safe-value val)
                            :value-preview (etaf--inspect-preview val 80))
                      props-list)))
            (setq idx (1+ idx)))))
      (cond
       ((and (etaf--component-bindings-p state)
             (vectorp (etaf--component-bindings-values state)))
        (let ((vals (etaf--component-bindings-values state))
              (idx 0))
          (while (< idx (length vals))
            (let ((bname (or (nth idx bnames) (intern (format "binding-%d" idx)))))
              (push (etaf--inspect-binding-entry bname (aref vals idx)) bindings-list))
            (setq idx (1+ idx)))))
       ((etaf--instance-setup-p inst)
        (push (etaf--inspect-binding-entry 'state state) bindings-list)))
      (dolist (entry (etaf--instance-local-refs inst))
        (let* ((hseg (gethash (cdr entry) hosts))
               (hid (and hseg (etaf--seg-live hseg)
                         (etaf--host-id (etaf--seg-data hseg)))))
          (push (list :name (car entry) :host-id hid) lrefs)))
      (list :id instance-id
            :name (etaf--component-spec-name spec)
            :key (let ((k (etaf--seg-key seg)))
                   (etaf--inspect-safe-value (and (consp k) (cdr k))))
            :source-file (etaf--inspect-component-source-file spec)
            :definition-symbol (etaf--component-spec-definition-symbol spec)
            :root-host-ids (etaf--inspect-root-host-ids seg)
            :render-count (etaf--instance-render-count inst)
            :props (nreverse props-list)
            :bindings (nreverse bindings-list)
            :context (etaf--inspect-context-chain (etaf--instance-context inst))
            :local-refs (nreverse lrefs)))))

;;;###autoload
(defun etaf-runtime-set-component-binding (runtime instance-id binding-name new-value)
  "Write NEW-VALUE to writable `etaf-ref' BINDING-NAME of INSTANCE-ID in RUNTIME.
Return t on success.  Signals `etaf-runtime-error' when RUNTIME is unmounted,
INSTANCE-ID is unknown, BINDING-NAME is absent, or the binding is not a
writable `etaf-ref'.  Forbidden during rendering."
  (etaf--assert-not-rendering 'set-component-binding)
  (setq runtime (etaf-runtime-require-mounted runtime))
  (unless (integerp instance-id)
    (signal 'etaf-runtime-error (list "Instance ID must be an integer" instance-id)))
  (unless (symbolp binding-name)
    (signal 'etaf-runtime-error (list "Binding name must be a symbol" binding-name)))
  (let ((inst (gethash instance-id (etaf-runtime-instances runtime))))
    (unless (and inst (not (etaf--instance-dead inst)))
      (signal 'etaf-runtime-error (list "Unknown Component instance" instance-id)))
    (let* ((spec (etaf--instance-spec inst))
           (state (etaf--instance-state inst))
           (bnames (etaf--component-spec-binding-names spec))
           (idx (cl-position binding-name bnames :test #'eq)))
      (unless (and idx (etaf--component-bindings-p state)
                   (< idx (length (etaf--component-bindings-values state))))
        (signal 'etaf-runtime-error
                (list "Unknown Component binding" binding-name instance-id)))
      (let ((cell (aref (etaf--component-bindings-values state) idx)))
        (unless (etaf-ref-p cell)
          (signal 'etaf-runtime-error
                  (list "Component binding is not a writable etaf-ref" binding-name)))
        (etaf-set-value cell new-value)
        t))))

;;;###autoload
(defun etaf-runtime-inspect-focus (runtime)
  "Return detached focus, region and key-scope diagnostics for mounted RUNTIME."
  (setq runtime (etaf-runtime-require-mounted runtime))
  (let* ((buf (etaf-runtime-buffer runtime))
         (nodes (etaf-runtime-nodes runtime))
         (focused-node (and (buffer-live-p buf) (ebox-focused-node buf)))
         (focused-seg (and focused-node (gethash focused-node nodes)))
         (focused-id (and focused-seg (eq (etaf--seg-kind focused-seg) 'host)
                          (etaf--host-id (etaf--seg-data focused-seg))))
         (raw-stops (and (buffer-live-p buf) (ebox-focus-stops buf)))
         (stops nil)
         (hosts (etaf-runtime-hosts runtime))
         (regions
          (mapcar (lambda (reg)
                    (let* ((rref (plist-get reg :ref))
                           (hseg (gethash rref hosts))
                           (hid (and hseg (etaf--seg-live hseg)
                                     (etaf--host-id (etaf--seg-data hseg)))))
                      (list :id (plist-get reg :id)
                            :label (plist-get reg :label)
                            :key (plist-get reg :key)
                            :host-id hid
                            :enter (etaf--inspect-safe-value (plist-get reg :enter))
                            :neighbors (etaf--inspect-safe-value (plist-get reg :neighbors)))))
                  (etaf--regions-collect runtime))))
    (dolist (node raw-stops)
      (when-let* ((seg (gethash node nodes))
                  ((eq (etaf--seg-kind seg) 'host))
                  ((etaf--seg-live seg)))
        (let* ((host (etaf--seg-data seg))
               (props (etaf--host-props host))
               (eprops (etaf--host-eprops host))
               (tag (etaf--view-node-name (etaf--seg-src seg))))
          (push (list :host-id (etaf--host-id host)
                      :tag tag
                      :ref (etaf--inspect-safe-value (etaf--host-ref host))
                      :label (or (and (stringp (plist-get props :aria-label))
                                      (substring-no-properties (plist-get props :aria-label)))
                                 (and (eq tag 'text)
                                      (etaf--inspect-preview (etaf--host-text host) 32)))
                      :tab-index (plist-get eprops :tab-index)
                      :focus-group (plist-get eprops :focus-group)
                      :focused-p (and (eq node focused-node) t)
                      :disabled-p (and (plist-get props :disabled) t))
                stops))))
    (list :focused-host-id focused-id
          :focused-host-ref (etaf--inspect-safe-value (etaf-focused-host-ref runtime))
          :input-active-p (and (etaf-input-active-p runtime) t)
          :direction-scheme etaf-direction-scheme
          :stops (nreverse stops)
          :regions regions
          :help (etaf-help-data runtime))))

;;;###autoload
(defun etaf-runtime-commit-summary (runtime)
  "Return lightweight summary plist of mounted RUNTIME's latest commit.
Includes `:rev', `:new-instances', `:updated-instances', `:retired-instances'
and `:update-report' without walking the tree."
  (setq runtime (etaf-runtime-require-mounted runtime))
  (list :rev (etaf-runtime-rev runtime)
        :new-instances (etaf-runtime-last-new-count runtime)
        :updated-instances (etaf-runtime-last-updated-count runtime)
        :retired-instances (etaf-runtime-last-retired-count runtime)
        :update-report (etaf-runtime-update-report runtime)))

(provide 'etaf-inspect)
;;; etaf-inspect.el ends here
