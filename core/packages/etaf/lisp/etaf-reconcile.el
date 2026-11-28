;;; etaf-reconcile.el --- Retained segment tree building, patching and disposal -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; View item normalization, segment geometry, keyed list and branch
;; reconciliation, Host segments, Behaviors, Regions, Slots, Component
;; instances, disposal and Component accessors.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'ebox)
(require 'etaf-reactive)
(require 'etaf-context)
(require 'etaf-observer)
(require 'etaf-behavior)
(require 'etaf-view)
(require 'etaf-component)
(require 'etaf-txn)
(require 'etaf-host-bridge)

(declare-function etaf--pb-effective-text "etaf-presentation" (host bucket))
(declare-function etaf--pb-empty-p "etaf-presentation" (bucket))

;;;; View items

(defun etaf--flatten-into (value acc)
  "Push VALUE's View items onto ACC, last first, and return ACC."
  (cond
   ((null value) acc)
   ((stringp value) (cons (etaf--text-view-from-string value) acc))
   ((or (etaf--view-node-p value) (etaf--component-call-p value)
        (etaf--slot-projection-p value) (etaf--expr-p value))
    (cons value acc))
   ((and (consp value) (proper-list-p value))
    (dolist (item value acc)
      (setq acc (etaf--flatten-into item acc))))
   (t (signal 'etaf-renderer-error
              (list (format "Unresolved View item: %S" value))))))

(defun etaf--flatten (value)
  "Return VALUE's View items as a fresh list."
  (nreverse (etaf--flatten-into value nil)))

(defun etaf--item-key (item)
  "Return ITEM's identity key: a cons matched by `eq' car and `equal' cdr."
  (cond
   ((etaf--view-node-p item)
    (let ((name (etaf--view-node-name item))
          (key (plist-get (etaf--view-node-props item) :key)))
      (when key (setq key (etaf--resolve-property-value key)))
      (cons name (if (eq name 'fragment)
                     (or key (etaf--view-node-token item))
                   key))))
   ((etaf--component-call-p item)
    (let ((key (plist-get (etaf--component-call-props item) :key)))
      (cons (etaf--component-call-spec item)
            (and key (etaf--resolve-property-value key)))))
   ((etaf--expr-p item)
    (cons (etaf--expr-token item) (etaf--expr-kind item)))
   ((etaf--slot-projection-p item)
    (cons 'slot
          (if (etaf--slot-projection-captured-p item)
              (list (etaf--slot-projection-name item) 'captured
                    (etaf--item-key
                     (car (etaf--slot-content-children
                           (etaf--slot-projection-content item)))))
            (list (etaf--slot-projection-name item)
                  (etaf--slot-projection-token item)))))
   ((stringp item) (list 'text))))

(defsubst etaf--key-match-p (left right)
  "Return non-nil when identity keys LEFT and RIGHT denote one segment."
  (and (eq (car left) (car right)) (equal (cdr left) (cdr right))))

(defun etaf--next-id (runtime)
  "Allocate a RUNTIME-unique positive integer, or 0 without a Runtime."
  (if runtime (cl-incf (etaf-runtime-next-id runtime)) 0))

;;;; Segment geometry

(defsubst etaf--seg-outer-node (seg)
  "Return the Ebox node that represents Host SEG in its parent."
  (let* ((host (etaf--seg-data seg))
         (bucket (and host (etaf--host-presentation host))))
    (if bucket
        (or (etaf--pb-outer bucket) (etaf--seg-node seg))
      (etaf--seg-node seg))))

(defsubst etaf--host-kids-parent (seg)
  "Return the Ebox node that holds SEG's own application children."
  (let* ((host (and (eq (etaf--seg-kind seg) 'host) (etaf--seg-data seg)))
         (bucket (and host (etaf--host-presentation host))))
    (if (and bucket (etaf--pb-holder bucket))
        (etaf--pb-holder bucket)
      (etaf--seg-node seg))))

(defun etaf--pres-pin-companion-inside (phys parent)
  "Keep PHYS's `companion-inside' slots ordered at the tail of PARENT.
Return non-nil when any slot moved."
  (let* ((host (and (eq (etaf--seg-kind phys) 'host) (etaf--seg-data phys)))
         (bucket (and host (etaf--host-presentation host)))
         (slots (and bucket
                     (cl-loop for entry in (etaf--pb-companions bucket)
                              when (and (eq (etaf--pres-mode entry) 'companion-inside)
                                        (etaf--pres-slot entry)
                                        (eq (ebox-node-parent (etaf--pres-slot entry)) parent))
                              collect (etaf--pres-slot entry)))))
    (when slots
      (let* ((total (ebox-node-child-count parent))
             (start (- total (length slots)))
             (moved nil)
             (idx start))
        (when (>= start 0)
          (dolist (slot slots)
            (unless (= (ebox-node-index slot) idx)
              (etaf--node-move slot idx)
              (setq moved t))
            (setq idx (1+ idx))))
        moved))))

(defun etaf--seg-collect (seg acc)
  "Push SEG's physical nodes onto ACC, last first, and return ACC."
  (if (eq (etaf--seg-kind seg) 'host)
      (let ((node (etaf--seg-outer-node seg)))
        (if node (cons node acc) acc))
    (dolist (kid (etaf--seg-kids seg) acc)
      (setq acc (etaf--seg-collect kid acc)))))

(defun etaf--seg-nodes (seg)
  "Return SEG's physical nodes in order."
  (nreverse (etaf--seg-collect seg nil)))

(defun etaf--kids-nodes (seg)
  "Return the physical nodes of SEG's kids in order."
  (let (acc)
    (dolist (kid (etaf--seg-kids seg))
      (setq acc (etaf--seg-collect kid acc)))
    (nreverse acc)))

(defun etaf--seg-first-node (seg)
  "Return SEG's first physical node, or nil."
  (if (eq (etaf--seg-kind seg) 'host)
      (etaf--seg-outer-node seg)
    (cl-some #'etaf--seg-first-node (etaf--seg-kids seg))))

(defun etaf--seg-last-node (seg)
  "Return SEG's last physical node, or nil."
  (if (eq (etaf--seg-kind seg) 'host)
      (etaf--seg-outer-node seg)
    (let ((kids (etaf--seg-kids seg)))
      (and kids
           (or (etaf--seg-last-node (car (last kids)))
               (cl-some #'etaf--seg-last-node (cdr (reverse kids))))))))

(defun etaf--seg-phys (seg)
  "Return the Host, presentation or root segment whose node list holds SEG's nodes."
  (let ((parent (etaf--seg-parent seg)))
    (while (not (memq (etaf--seg-kind parent) '(host root surface overlay pres)))
      (setq parent (etaf--seg-parent parent)))
    parent))

(defun etaf--seg-prev-node (seg)
  "Return the physical node just before SEG's region, or nil."
  (let ((child seg) (parent (etaf--seg-parent seg)) found)
    (while parent
      (let ((tail (etaf--seg-kids parent)) before)
        (while (and tail (not (eq (car tail) child)))
          (push (car tail) before)
          (setq tail (cdr tail)))
        (setq found (cl-some #'etaf--seg-last-node before)))
      (if (or found (memq (etaf--seg-kind parent) '(host root surface overlay pres)))
          (setq parent nil)
        (setq child parent parent (etaf--seg-parent parent))))
    found))

(defun etaf--seg-anchor-prev (seg)
  "Return the node before live region SEG, read before SEG changes.
SEG must not be a Host: a Host's own kids start its node list."
  (let ((first (etaf--seg-first-node seg)))
    (if (and first (ebox-node-parent first))
        (ebox-node-child (ebox-node-parent first) (1- (ebox-node-index first)))
      (etaf--seg-prev-node seg))))

(defun etaf--seg-runtime (seg)
  "Return SEG's Runtime, or nil in a pure render."
  (etaf--ictx-runtime (etaf--seg-ctx seg)))

(defun etaf--root-dirty (runtime)
  "Mark RUNTIME's top-level node list as changed."
  (when runtime
    (setf (etaf-runtime-root-dirty runtime) t)
    (etaf--runtime-changed runtime)))

(defun etaf--place (seg prev)
  "Place live SEG's region nodes contiguously after PREV.
For a Host SEG, place its kids' nodes from the start of its node."
  (let* ((runtime (etaf--seg-runtime seg))
         (phys (if (memq (etaf--seg-kind seg) '(host root surface overlay pres))
                   seg (etaf--seg-phys seg))))
    (if (memq (etaf--seg-kind phys) '(root overlay))
        (etaf--root-dirty runtime)
      (let* ((parent (etaf--host-kids-parent phys))
             (index (cond (prev (1+ (ebox-node-index prev)))
                         ((eq (etaf--seg-kind phys) 'surface)
                          (ebox-node-child-count parent))
                         (t 0)))
            (nodes (if (eq phys seg) (etaf--kids-nodes seg) (etaf--seg-nodes seg)))
            changed)
        (dolist (node nodes)
          (let ((at (ebox-node-parent node)))
            (cond
             ((and (eq at parent) (= (ebox-node-index node) index)))
             ((eq at parent)
              (etaf--node-move node (if (< (ebox-node-index node) index)
                                        (1- index) index))
              (setq changed t))
             (t
              (when at (etaf--node-remove node))
              (etaf--node-insert parent node index)
              (setq changed t))))
          (setq index (1+ (ebox-node-index node))))
        (when (etaf--pres-pin-companion-inside phys parent)
          (setq changed t))
        (when changed (etaf--runtime-changed runtime))))))

(defun etaf--detach (seg node)
  "Remove disposed SEG's NODE from its live parent."
  (let ((runtime (etaf--seg-runtime seg))
        (parent (ebox-node-parent node)))
    (when runtime
      (if (or (null parent) (eq parent (etaf-runtime-wrapper runtime)))
          (etaf--root-dirty runtime)
        (etaf--node-remove node)
        (etaf--runtime-changed runtime)))))


;;;; Value identity

(defun etaf--value-same-p (left right)
  "Return non-nil when LEFT and RIGHT are the same View input.
Reactive sources and functions compare by identity, conses recursively and
other values with `equal'."
  (cond
   ((or (etaf-ref-p left) (etaf-computed-p left) (functionp left)
        (etaf--expr-p left))
    (eq left right))
   ((consp left)
    (and (consp right)
         (etaf--value-same-p (car left) (car right))
         (etaf--value-same-p (cdr left) (cdr right))))
   (t (equal left right))))

;;;; Building and patching segments

(defun etaf--item-kind (item)
  "Return the segment kind of View ITEM."
  (cond
   ((etaf--view-node-p item)
    (if (eq (etaf--view-node-name item) 'fragment) 'frag 'host))
   ((etaf--component-call-p item) 'comp)
   ((etaf--expr-p item)
    (pcase (etaf--expr-kind item)
      ('branch 'branch)
      ('keyed-list 'list)
      (_ 'expr)))
   ((etaf--slot-projection-p item) 'slot)
   (t (signal 'etaf-renderer-error
              (list (format "Unresolved View item: %S" item))))))

(defun etaf--explicit-key-p (item)
  "Return non-nil when ITEM carries an explicit `:key'."
  (cond
   ((etaf--view-node-p item) (plist-get (etaf--view-node-props item) :key))
   ((etaf--component-call-p item)
    (plist-get (etaf--component-call-props item) :key))))

(define-hash-table-test 'etaf--identity-key
  #'etaf--key-match-p (lambda (key) (sxhash-equal (cdr key))))

(defun etaf--check-keys (items keys)
  "Signal when explicitly keyed ITEMS repeat one of their KEYS.
A short list is scanned directly; a long one is indexed, so checking a
list stays linear in its length."
  (let (seen table (count 0))
    (cl-loop for item in items for key in keys
             when (etaf--explicit-key-p item)
             do (when (if table (gethash key table)
                        (cl-member key seen :test #'etaf--key-match-p))
                  (signal 'etaf-renderer-error
                          (list (format "View has duplicate sibling key: %S"
                                        (cdr key)))))
             (cond
              (table (puthash key t table))
              ((< (setq count (1+ count)) 16) (push key seen))
              (t (setq table (make-hash-table :test 'etaf--identity-key
                                              :size (length keys)))
                 (dolist (old (cons key seen)) (puthash old t table)))))))

(defun etaf--build-items (items keys parent ctx)
  "Build segments for ITEMS with KEYS under PARENT in CTX; return them.
A failure disposes the segments already built."
  (let (built)
    (condition-case err
        (progn
          (while items
            (push (etaf--build (pop items) (pop keys) parent ctx) built))
          (nreverse built))
      ((error quit)
       (dolist (seg built) (etaf--dispose seg nil))
       (signal (car err) (cdr err))))))

(defun etaf--build-list (items parent ctx)
  "Build segments for View ITEMS under PARENT in CTX."
  (let ((keys (mapcar #'etaf--item-key items)))
    (etaf--check-keys items keys)
    (etaf--build-items items keys parent ctx)))

(defun etaf--build (item key parent ctx)
  "Build and return the segment of View ITEM with KEY under PARENT in CTX.
A failure disposes everything the segment acquired and re-signals."
  (let ((seg (etaf--seg-make :kind (etaf--item-kind item) :parent parent
                             :ctx ctx :src item :key key :txn etaf--txn)))
    (condition-case err
        (progn
          (pcase (etaf--seg-kind seg)
            ('host (etaf--host-init seg))
            ('frag (setf (etaf--seg-kids seg)
                         (etaf--build-list
                          (etaf--flatten (etaf--view-node-children item)) seg ctx)))
            ('comp (etaf--comp-init seg))
            ('slot (etaf--slot-init seg))
            (_ (etaf--region-init seg)))
          (setf (etaf--seg-live seg) t)
          seg)
      ((error quit)
       (etaf--dispose seg nil)
       (signal (car err) (cdr err))))))

(defun etaf--patch (seg item)
  "Update live SEG to render ITEM, which has SEG's identity key."
  (pcase (etaf--seg-kind seg)
    ('host (etaf--host-patch seg item))
    ('frag
     (setf (etaf--seg-src seg) item)
     (etaf--patch-kids seg (etaf--flatten (etaf--view-node-children item))
                       (etaf--seg-ctx seg)))
    ('comp (etaf--comp-patch seg item))
    ('slot
     (etaf--stop (etaf--seg-effect seg))
     (setf (etaf--seg-src seg) item (etaf--seg-effect seg) nil)
     (etaf--slot-init seg))
    (_
     (etaf--stop (etaf--seg-effect seg))
     (setf (etaf--seg-src seg) item (etaf--seg-effect seg) nil)
     (when (eq (etaf--seg-kind seg) 'branch)
       (setf (etaf--seg-data seg) 'unset))
     (etaf--region-init seg))))

(defun etaf--patch-kids (seg items ctx)
  "Make SEG's kids render View ITEMS, building new kids in CTX.
Kids whose identity key matches are kept and patched; others are built or
disposed.  When SEG is live its nodes are moved into place."
  (let* ((old (etaf--seg-kids seg))
         (keys (mapcar #'etaf--item-key items)))
    (etaf--check-keys items keys)
    (if (and (= (length old) (length keys))
             (cl-loop for kid in old for key in keys
                      always (etaf--key-match-p (etaf--seg-key kid) key)))
        (cl-loop for kid in old for item in items
                 unless (eq (etaf--seg-src kid) item)
                 do (etaf--patch kid item))
      (let* ((live (etaf--seg-live seg))
             (prev (and live (not (memq (etaf--seg-kind seg) '(host root surface overlay pres)))
                        (etaf--seg-anchor-prev seg)))
             (pool (copy-sequence old))
             new matched fresh)
        (condition-case err
            (cl-loop for item in items for key in keys
                     do (let ((hit (if (and pool (etaf--key-match-p
                                                   (etaf--seg-key (car pool)) key))
                                       (car pool)
                                     (cl-find-if (lambda (kid)
                                                   (etaf--key-match-p
                                                    (etaf--seg-key kid) key))
                                                 pool))))
                          (if hit
                              (progn (setq pool (delq hit pool))
                                     (push (cons hit item) matched)
                                     (push hit new))
                            (let ((built (etaf--build item key seg ctx)))
                              (push built fresh)
                              (push built new)))))
          ((error quit)
           (dolist (kid fresh) (etaf--dispose kid nil))
           (signal (car err) (cdr err))))
        (setf (etaf--seg-kids seg) (nreverse new))
        (dolist (kid pool) (etaf--dispose kid live))
        (when live (etaf--place seg prev))
        (dolist (entry (nreverse matched))
          (unless (eq (etaf--seg-src (car entry)) (cdr entry))
            (etaf--patch (car entry) (cdr entry))))))))

;;;; Host segments

(defun etaf--host-generated-ref (seg)
  "Return SEG's generated Host reference."
  (let ((host (etaf--seg-data seg)))
    (or (etaf--host-gref host)
        (setf (etaf--host-gref host)
              (let ((runtime (etaf--seg-runtime seg)))
                (list 'etaf-host (and runtime (etaf-runtime-mount-id runtime))
                      (etaf--host-id host)))))))

(defun etaf--host-dynamic-p (props ctx)
  "Return non-nil when Host PROPS in CTX need a retained binding."
  (or (cl-loop for (_key value) on props by #'cddr
               thereis (etaf--expr-p value))
      (plist-get props :use)
      (let ((theme (etaf--ctx-theme ctx)))
        (or (etaf-ref-p theme) (etaf-computed-p theme)))))

(defun etaf--host-sync (seg)
  "Resolve Host SEG's properties and apply them to its node."
  (let* ((host (etaf--seg-data seg))
         (item (etaf--seg-src seg))
         (name (etaf--view-node-name item))
         (ctx (etaf--seg-ctx seg))
         (runtime (etaf--ictx-runtime ctx))
         (resolved (etaf--resolve-property-plist (etaf--view-node-props item)))
         (theme (etaf--ctx-theme-value ctx))
         (node (etaf--seg-node seg)))
    (unless (and node (etaf--host-restyle host name resolved theme node runtime))
      (let* ((props (if (plist-get resolved :use)
                        (etaf--merge-behavior-props resolved name)
                      (etaf--validate-semantic-properties resolved)))
             (ref (or (plist-get props :ref) (etaf--host-generated-ref seg)))
             (eprops (etaf--compute-eprops name props ctx theme runtime host ref)))
        (setf (etaf--host-props host) (etaf--resolve-theme-plist props theme)
              (etaf--host-ref host) ref
              (etaf--host-rprops host) resolved
              (etaf--host-theme host) theme)
        (unless (equal eprops (etaf--host-eprops host))
          (let ((old (etaf--host-eprops host)))
            (setf (etaf--host-eprops host) eprops)
            (when node
              (etaf--node-set-props node eprops old)
              (etaf--runtime-changed runtime))))
        (when node (etaf--host-commit seg))))))

(defsubst etaf--plain-style-key-p (key)
  "Return non-nil when Host property KEY passes to Ebox as a plain style."
  (not (or (memq key '(:key :styles :content :use))
           (etaf--semantic-property-p key)
           (memq key etaf--rejected-host-props))))

(defun etaf--host-restyle (host name props theme node runtime)
  "Apply resolved PROPS to mounted HOST when only plain style values changed.
NAME is the Host name, THEME the current Theme and NODE HOST's Ebox node.
Return non-nil when PROPS were applied, or nil when they need the full
property computation: keys, metadata, Behaviors or the Theme changed."
  (let ((old (etaf--host-rprops host))
        (eprops (etaf--host-eprops host)))
    (when (and old eprops (not (eq name 'image))
               (eq theme (etaf--host-theme host)))
      (let ((a old) (b props) (ok t) changed)
        (while (and ok a b)
          (let ((key (car b)) (value (cadr b)))
            (cond
             ((not (eq key (car a))) (setq ok nil))
             ((eq value (cadr a)))
             ;; Callbacks and metadata compare by identity: a new closure
             ;; over equal contents must still replace the committed one.
             ((not (etaf--plain-style-key-p key)) (setq ok nil))
             ((equal value (cadr a)))
             (t
              (when (etaf-theme-token-p value)
                (setq value (etaf--theme-token-resolve-from-theme value theme)))
              (when (and (eq key :hover-style)
                         (etaf--theme-hover-token-p value))
                (setq value (etaf--resolve-theme-plist value theme)))
              ;; A nil value drops its key from the Ebox properties.
              (if (and value (plist-get eprops key))
                  (push (cons key value) changed)
                (setq ok nil)))))
          (setq a (cddr a) b (cddr b)))
        (when (and ok (null a) (null b))
          (setf (etaf--host-rprops host) props)
          (when changed
            (let ((new (copy-sequence eprops)))
              (dolist (entry changed) (plist-put new (car entry) (cdr entry)))
              (setf (etaf--host-props host) (etaf--resolve-theme-plist props theme)
                    (etaf--host-eprops host) new)
              (etaf--node-set-props node new eprops)
              (etaf--runtime-changed runtime)))
          t)))))

(defun etaf--host-bind-props (seg)
  "Bind Host SEG's properties, retaining an effect when they are dynamic."
  (let ((ctx (etaf--seg-ctx seg)))
    (if (etaf--host-dynamic-p (etaf--view-node-props (etaf--seg-src seg)) ctx)
        (setf (etaf--seg-effect seg)
              (etaf--effect ctx seg (lambda () (etaf--host-sync seg))))
      (etaf--ctx-call ctx (lambda () (etaf--host-sync seg))))))

(defun etaf--text-value (value)
  "Return Text payload VALUE as one string."
  (cond
   ((stringp value) value)
   ((null value) "")
   ((and (proper-list-p value) (cl-every #'stringp value))
    (apply #'concat value))
   (t (signal 'etaf-renderer-error
              (list "Text payload must resolve to one string")))))

(defun etaf--text-set (seg text)
  "Show TEXT in Text Host SEG."
  (let ((host (etaf--seg-data seg)))
    (unless (equal-including-properties text (etaf--host-text host))
      (let* ((bucket (etaf--host-presentation host))
             (old (if bucket
                      (etaf--pb-effective-text host bucket)
                    (etaf--host-text host)))
             (runtime (etaf--seg-runtime seg)))
        (setf (etaf--host-text host) text)
        (when bucket
          (let ((remaining
                 (cl-remove-if #'etaf--pres-text-override
                               (etaf--pb-overrides bucket))))
            (unless (eq (length remaining) (length (etaf--pb-overrides bucket)))
              (setf (etaf--pb-overrides bucket) remaining)
              (when (and (etaf--pb-active-override bucket)
                         (etaf--pres-text-override (etaf--pb-active-override bucket)))
                (setf (etaf--pb-active-override bucket) (car remaining)))))
          (when (etaf--pb-empty-p bucket)
            (setf (etaf--host-presentation host) nil
                  bucket nil)
            (when (and runtime (etaf-runtime-presentations runtime))
              (etaf--jremhash seg (etaf-runtime-presentations runtime)))))
        (let ((desired (if bucket
                           (etaf--pb-effective-text host bucket)
                         text)))
          (when-let* ((node (etaf--seg-node seg)))
            (etaf--node-set-text node desired old)
            (etaf--runtime-changed runtime)))))))

(defun etaf--text-bind (seg)
  "Bind Text Host SEG's payload."
  (let* ((host (etaf--seg-data seg))
         (children (etaf--view-node-children (etaf--seg-src seg)))
         (payload (car children)))
    (when (cdr children)
      (signal 'etaf-renderer-error
              (list "Text requires exactly one string or expr payload")))
    (if (etaf--expr-p payload)
        (setf (etaf--host-payload host)
              (etaf--effect (etaf--seg-ctx seg) seg
                            (lambda ()
                              (etaf--text-set
                               seg (etaf--text-value
                                    (funcall (etaf--expr-thunk payload)))))))
      (etaf--text-set seg (etaf--text-value payload)))))

(defun etaf--host-init (seg)
  "Build Host SEG's binding, children and node."
  (let* ((item (etaf--seg-src seg))
         (name (etaf--view-node-name item))
         (ctx (etaf--seg-ctx seg))
         (host (etaf--host-make :id (etaf--next-id (etaf--ictx-runtime ctx))
                               :txn etaf--txn)))
    (setf (etaf--seg-data seg) host)
    (unless (memq name '(text box row column flex grid image))
      (signal 'etaf-renderer-error
              (list (format "Expected text, image, box, row, column, flex, or grid Host; received %S"
                            name))))
    (etaf--host-bind-props seg)
    (cond
     ((eq name 'text)
      (etaf--text-bind seg)
      (setf (etaf--seg-node seg)
            (ebox-text-create (etaf--host-text host) (etaf--host-eprops host))))
     (t
      (when (and (eq name 'image) (etaf--view-node-children item))
        (signal 'etaf-renderer-error (list "Image Host takes no children")))
      (setf (etaf--seg-kids seg)
            (etaf--build-list (etaf--flatten (etaf--view-node-children item))
                              seg (etaf--ctx-inner ctx)))
      (setf (etaf--seg-node seg)
            (ebox-node-create name (etaf--host-eprops host)
                              (etaf--kids-nodes seg)))))
    (etaf--host-commit seg)))

(defun etaf--host-patch (seg item)
  "Make live Host SEG render ITEM."
  (let ((old (etaf--seg-src seg))
        (host (etaf--seg-data seg)))
    (setf (etaf--seg-src seg) item)
    (unless (and (eq (etaf--view-node-props old) (etaf--view-node-props item))
                 (null (etaf--seg-effect seg)))
      (etaf--stop (etaf--seg-effect seg))
      (setf (etaf--seg-effect seg) nil)
      (etaf--host-bind-props seg))
    (if (eq (etaf--view-node-name item) 'text)
        (unless (equal-including-properties (etaf--view-node-children old)
                                            (etaf--view-node-children item))
          (etaf--stop (etaf--host-payload host))
          (setf (etaf--host-payload host) nil)
          (etaf--text-bind seg))
      (etaf--patch-kids seg (etaf--flatten (etaf--view-node-children item))
                        (etaf--ctx-inner (etaf--seg-ctx seg))))))

(defun etaf--host-unregister (runtime host)
  "Remove HOST's registered reference from RUNTIME."
  (when-let* ((ref (etaf--host-reg host)))
    (let* ((hosts (etaf-runtime-hosts runtime))
           (seg (gethash ref hosts)))
      (when (and seg (eq (etaf--seg-data seg) host))
        (etaf--jremhash ref hosts)))
    (setf (etaf--host-reg host) nil)))

(defun etaf--host-commit (seg)
  "Register Host SEG's reference and synchronize its Behaviors."
  (when-let* ((runtime (etaf--seg-runtime seg)))
    (let* ((host (etaf--seg-data seg))
           (ref (etaf--host-ref host)))
      (if (etaf--semantic-props-p (etaf--host-props host))
          (progn
            (unless (equal ref (etaf--host-reg host))
              (etaf--host-unregister runtime host)
              (etaf--jputhash ref seg (etaf-runtime-hosts runtime))
              (setf (etaf--host-reg host) ref))
            (etaf--jputhash (etaf--seg-node seg) seg (etaf-runtime-nodes runtime))
            (when-let* ((keys (plist-get (etaf--host-props host) :keys)))
              (etaf--keys-register runtime keys)))
        (when (etaf--host-reg host)
          (etaf--host-unregister runtime host)
          (etaf--jremhash (etaf--seg-node seg) (etaf-runtime-nodes runtime))))
      (when (if (plist-get (etaf--host-props host) :sticky)
                (not (equal ref (etaf-runtime-sticky runtime)))
              (equal ref (etaf-runtime-sticky runtime)))
        (setf (etaf-runtime-sticky runtime)
              (and (plist-get (etaf--host-props host) :sticky) ref))
        (etaf--runtime-changed runtime))
      (etaf--host-sync-behaviors seg))))

;;;; Behaviors

(defun etaf--behavior-same-p (left right)
  "Return non-nil when Behavior specs LEFT and RIGHT install the same thing."
  (and (eq (etaf-behavior-spec-name left) (etaf-behavior-spec-name right))
       (eq (etaf-behavior-spec-install left) (etaf-behavior-spec-install right))
       (etaf--value-same-p (etaf-behavior-spec-attributes left)
                           (etaf-behavior-spec-attributes right))))

(defun etaf--behavior-cleanup (runtime states)
  "Run the cleanups of Behavior STATES, recording failures on RUNTIME.
States installed by the current transaction are cleaned now; committed
states are cleaned when the transaction commits."
  (when etaf--txn
    (let ((fresh (etaf--txn-installs etaf--txn)) now later)
      (dolist (state states)
        (if (memq state fresh)
            (progn (setq fresh (delq state fresh)) (push state now))
          (push state later)))
      (setf (etaf--txn-installs etaf--txn) fresh)
      (when later
        (setq later (nreverse later))
        (etaf--txn-defer (lambda () (etaf--behavior-cleanup runtime later))))
      (setq states (nreverse now))))
  (dolist (state states)
    (when-let* ((cleanup (cddr state)))
      (condition-case err
          (let ((etaf--render-phase-p nil)
                (etaf--current-runtime runtime))
            (etaf-untracked (funcall cleanup)))
        ((error quit) (push err (etaf-runtime-errors runtime)))))))

(defun etaf--behavior-install (runtime spec props ref)
  "Install Behavior SPEC for Host PROPS with REF; return its cleanup."
  (when-let* ((install (etaf-behavior-spec-install spec)))
    (let* ((etaf--render-phase-p nil)
           (etaf--current-runtime runtime)
           (etaf--current-behavior-context
            (etaf--behavior-context-create
             :runtime runtime :host-props (etaf--plist-set props :ref ref)))
           (cleanup (etaf-untracked (funcall install))))
      (unless (or (null cleanup) (functionp cleanup))
        (signal 'etaf-behavior-error
                (list (format "Behavior %S installer must return cleanup"
                              (etaf-behavior-spec-name spec)))))
      cleanup)))

(defun etaf--host-sync-behaviors (seg)
  "Install, keep or clean up Host SEG's Behaviors."
  (let* ((runtime (etaf--seg-runtime seg))
         (host (etaf--seg-data seg))
         (props (etaf--host-props host))
         (specs (and (not (plist-get props :disabled)) (plist-get props :use)))
         (ref (etaf--host-ref host))
         (old (etaf--host-behaviors host)))
    (when (or specs old)
      (let (kept wanted)
        (dolist (spec specs)
          (let ((state (cl-find-if (lambda (state)
                                     (and (etaf--behavior-same-p (car state) spec)
                                          (equal (cadr state) ref)))
                                   old)))
            (when state
              (setq old (remq state old))
              (push state kept))
            (push (cons spec state) wanted)))
        (etaf--behavior-cleanup runtime old)
        (let (states)
          (condition-case err
              (dolist (entry (nreverse wanted))
                (push (or (cdr entry)
                          (let ((state (cons (car entry)
                                             (cons ref (etaf--behavior-install
                                                        runtime (car entry) props ref)))))
                            (when etaf--txn
                              (push state (etaf--txn-installs etaf--txn)))
                            state))
                      states))
            ((error quit)
             (setf (etaf--host-behaviors host)
                   (append states (cl-set-difference kept states :test #'eq)))
             (signal (car err) (cdr err))))
          (setf (etaf--host-behaviors host) (nreverse states)))))))

;;;; Regions

(defun etaf--region-init (seg)
  "Bind expression, branch or keyed-list region SEG."
  (let* ((ctx (etaf--seg-ctx seg))
         (expr (etaf--seg-src seg)))
    (setf (etaf--seg-effect seg)
          (etaf--effect
           ctx seg
           (pcase (etaf--seg-kind seg)
             ('expr
              (lambda ()
                (let ((value (funcall (etaf--expr-thunk expr))))
                  (etaf-untracked
                    (etaf--patch-kids seg (etaf--flatten value) ctx)))))
             ('branch
              (when (null (etaf--seg-data seg))
                (setf (etaf--seg-data seg) 'unset))
              (lambda ()
                (let ((arm (funcall (etaf--expr-range-snapshot expr))))
                  (unless (eql arm (etaf--seg-data seg))
                    (etaf-untracked
                      (etaf--patch-kids
                       seg (etaf--flatten (funcall (etaf--expr-range-item expr) arm))
                       ctx))
                    (setf (etaf--seg-data seg) arm)))))
             ('list
              (lambda ()
                (let ((items (funcall (etaf--expr-range-snapshot expr))))
                  (etaf-untracked (etaf--patch-list seg items))))))))))

(defun etaf--row-build (seg key item itemfn)
  "Build one keyed row of list SEG for ITEM with KEY using ITEMFN."
  (let* ((ctx (etaf--seg-ctx seg))
         (cell (etaf--ref-create :value item))
         (row (etaf--seg-make :kind 'row :parent seg :ctx ctx :src item
                              :key key :data cell :txn etaf--txn)))
    (condition-case err
        (progn
          (setf (etaf--seg-kids row)
                (etaf--build-list (etaf--flatten (funcall itemfn cell)) row ctx)
                (etaf--seg-live row) t)
          row)
      ((error quit)
       (etaf--dispose row nil)
       (signal (car err) (cdr err))))))

(defun etaf--row-repatch (row itemfn)
  "Patch ROW's kids against ITEMFN's View of its cell."
  (etaf--patch-kids row (etaf--flatten (funcall itemfn (etaf--seg-data row)))
                    (etaf--seg-ctx row)))

(defmacro etaf--row-src (row)
  "Read the item shown by list ROW without a type check."
  `(aref ,row ,(cl-struct-slot-offset 'etaf--seg 'src)))

(defun etaf--row-matches-p (row item keyfn)
  "Return non-nil when retained ROW can show ITEM: same item or same key."
  (or (eq (etaf--seg-src row) item)
      (equal (etaf--seg-key row) (funcall keyfn item))))

(defun etaf--patch-list (seg items)
  "Make keyed-list SEG show ITEMS, retaining rows by key.
Leading and trailing rows that still match cost one comparison each and
allocate nothing, so appending or editing near either end of a long list
stays proportional to the change."
  (let* ((expr (etaf--seg-src seg))
         (keyfn (etaf--expr-range-key expr))
         (itemfn (etaf--expr-range-item expr))
         (data (etaf--seg-data seg))
         (table (or (car data) (make-hash-table :test #'equal)))
         (itemfn-changed (and data (not (eq (cdr data) itemfn))))
         (live (etaf--seg-live seg))
         (old (etaf--seg-kids seg))
         (otail old) (itail items) (plen 0) (slen 0) (last-cell nil)
         changed-rows)
    ;; Matching leading rows.  Rows still showing the same item are
    ;; skipped with one unchecked slot read each.
    (while (and otail itail (eq (etaf--row-src (car otail)) (car itail)))
      (setq last-cell otail otail (cdr otail) itail (cdr itail)))
    (when last-cell (setq plen (- (length old) (length otail))))
    (while (and otail itail
                (etaf--row-matches-p (car otail) (car itail) keyfn))
      (unless (eq (etaf--seg-src (car otail)) (car itail))
        (push (cons (car otail) (car itail)) changed-rows))
      (setq last-cell otail otail (cdr otail) itail (cdr itail) plen (1+ plen)))
    ;; Matching trailing rows, compared from the end of what remains.
    (let ((ovec (and otail itail (vconcat otail)))
          (ivec (and otail itail (vconcat itail))))
      (when ovec
        (let ((oi (1- (length ovec))) (ii (1- (length ivec))))
          (while (and (>= oi 0) (>= ii 0)
                      (etaf--row-matches-p (aref ovec oi) (aref ivec ii) keyfn))
            (unless (eq (etaf--seg-src (aref ovec oi)) (aref ivec ii))
              (push (cons (aref ovec oi) (aref ivec ii)) changed-rows))
            (setq oi (1- oi) ii (1- ii) slen (1+ slen))))))
    (let* ((mid-old (if (zerop slen) otail (butlast otail slen)))
           (suffix (and (> slen 0) (last otail slen)))
           (mid-items (if (zerop slen) itail (butlast itail slen)))
           (mid-keys (mapcar keyfn mid-items))
           (mid-old-set (and mid-old (make-hash-table :test #'eq)))
           (seen (and (cdr mid-keys) (make-hash-table :test #'equal)))
           prev mid-rows fresh)
      (dolist (row mid-old) (puthash row t mid-old-set))
      (dolist (key mid-keys)
        (when (or (and seen (gethash key seen))
                  (let ((row (gethash key table)))
                    (and row (not (and mid-old-set (gethash row mid-old-set))))))
          (signal 'etaf-runtime-error
                  (list "Keyed Range keys must be unique" key)))
        (when seen (puthash key t seen)))
      (when (and live (or mid-old mid-items))
        (setq prev (or (and last-cell (etaf--seg-last-node (car last-cell)))
                       (and (> plen 1)
                            (cl-some #'etaf--seg-last-node
                                     (reverse (take plen old))))
                       (etaf--seg-anchor-prev seg))))
      (condition-case err
          (cl-loop for item in mid-items for key in mid-keys
                   do (let ((row (gethash key table)))
                        (if row
                            (progn (remhash row mid-old-set)
                                   (unless (eq (etaf--seg-src row) item)
                                     (push (cons row item) changed-rows))
                                   (push row mid-rows))
                          (let ((built (etaf--row-build seg key item itemfn)))
                            (push built fresh)
                            (push built mid-rows)))))
        ((error quit)
         (dolist (row fresh) (etaf--dispose row nil))
         (signal (car err) (cdr err))))
      (setq mid-rows (nreverse mid-rows))
      ;; Changed items flow through each reused row's cell.
      (dolist (entry changed-rows)
        (let* ((row (car entry)) (item (cdr entry)) (cell (etaf--seg-data row)))
          (setf (etaf--seg-src row) item)
          (unless (eq (etaf-ref-value cell) item)
            (etaf--cell-install cell item))))
      (dolist (row mid-old)
        (when (gethash row mid-old-set)
          (etaf--jremhash (etaf--seg-key row) table)
          (etaf--dispose row live)))
      (dolist (row fresh) (etaf--jputhash (etaf--seg-key row) row table))
      (unless (and (null mid-old) (null mid-rows))
        (setf (etaf--seg-kids seg)
              (cond
               ((and (null mid-old) (null suffix) (null otail) last-cell)
                ;; Pure append: the retained prefix is the whole old list.
                (let ((cell last-cell))
                  (etaf--journal (lambda () (setcdr cell nil))))
                (setcdr last-cell mid-rows)
                old)
               (t (append (take plen old) mid-rows suffix)))))
      (setf (etaf--seg-data seg) (cons table itemfn))
      (when itemfn-changed
        (dolist (row (etaf--seg-kids seg))
          (unless (memq row fresh)
            (etaf--row-repatch row itemfn))))
      (when (and live mid-rows)
        (etaf--place-rows seg mid-rows prev)))))

(defun etaf--place-rows (seg rows prev)
  "Place live list SEG's ROWS contiguously after node PREV."
  (let ((phys (etaf--seg-phys seg))
        (runtime (etaf--seg-runtime seg)))
    (if (eq (etaf--seg-kind phys) 'root)
        (etaf--root-dirty runtime)
      (let ((parent (etaf--host-kids-parent phys))
            (index (if prev (1+ (ebox-node-index prev)) 0))
            changed)
        (dolist (row rows)
          (dolist (node (etaf--seg-nodes row))
            (let ((at (ebox-node-parent node)))
              (cond
               ((and (eq at parent) (= (ebox-node-index node) index)))
               ((eq at parent)
                (etaf--node-move node (if (< (ebox-node-index node) index)
                                          (1- index) index))
                (setq changed t))
               (t
                (when at (etaf--node-remove node))
                (etaf--node-insert parent node index)
                (setq changed t))))
            (setq index (1+ (ebox-node-index node)))))
        (when (etaf--pres-pin-companion-inside phys parent)
          (setq changed t))
        (when changed (etaf--runtime-changed runtime))))))

;;;; Slots

(defun etaf--slot-init (seg)
  "Bind slot projection SEG."
  (let* ((projection (etaf--seg-src seg))
         (ctx (etaf--seg-ctx seg)))
    (if (etaf--slot-projection-captured-p projection)
        (let* ((content (etaf--slot-projection-content projection))
               (owners (etaf--slot-projection-style-owners projection))
               (owner-ctx
                (cond
                 ((null owners) ctx)
                 ((eq (etaf--ictx-runtime owners) (etaf--ictx-runtime ctx))
                  (etaf--ctx-inner owners))
                 (t
                  ;; Cross-Runtime portal projection: keep the caller's Context
                  ;; and Theme while rebinding Runtime and instance ownership to
                  ;; the target Runtime that mounts the projected Hosts.
                  (etaf--ictx-make
                   :runtime (etaf--ictx-runtime ctx)
                   :owner (etaf--ictx-owner ctx)
                   :root-p nil
                   :context (or (etaf--ictx-context owners)
                                (etaf--ictx-context ctx))
                   :theme (or (etaf--ctx-theme owners)
                              (etaf--ictx-theme ctx)))))))
          (etaf--patch-kids seg (etaf--flatten (etaf--slot-content-children content))
                            owner-ctx))
      (let ((name (etaf--slot-projection-name projection))
            (owner (etaf--ictx-owner ctx)))
        (setf (etaf--seg-effect seg)
              (etaf--effect
               ctx seg
               (lambda ()
                 (let* ((entry (assq name (etaf--current-slot-entries)))
                        (mode (if entry 'entry 'fallback)))
                   (etaf-untracked
                     (unless (eq mode (etaf--seg-data seg))
                       (dolist (kid (etaf--seg-kids seg))
                         (etaf--dispose kid (etaf--seg-live seg)))
                       (setf (etaf--seg-kids seg) nil)
                       (setf (etaf--seg-data seg) mode))
                     (if entry
                         (let ((content (cdr entry)))
                           (etaf--patch-kids
                            seg
                            (etaf--flatten (if (etaf--slot-content-p content)
                                               (etaf--slot-content-children content)
                                             content))
                            (etaf--ctx-inner
                             (if owner (etaf--instance-pctx owner) ctx))))
                       (etaf--patch-kids
                        seg (etaf--flatten (etaf--slot-projection-fallback projection))
                        ctx)))))))))))

;;;; Components

(defun etaf--comp-write-inputs (inst)
  "Resolve INST's business props and write the changed prop cells."
  (let* ((call (etaf--instance-call inst))
         (spec (etaf--instance-spec inst))
         (raw (etaf--resolve-property-plist (etaf--component-business-props call)))
         (resolved (etaf--component-resolve-input
                    spec raw (etaf--instance-defaults inst)))
         (props (car resolved))
         (cells (etaf--instance-cells inst)))
    (setf (etaf--instance-defaults inst) (cdr resolved))
    (cl-loop for name in (etaf--component-spec-props spec) for index from 1
             do (let ((value (plist-get props (etaf--component-prop-key name)))
                      (cell (aref cells index)))
                  (unless (etaf--reactive-same-p (etaf-ref-value cell) value)
                    (etaf--cell-install cell value))))))

(defun etaf--comp-bind-inputs (inst)
  "Bind INST's business props, retaining an effect when they are dynamic."
  (let ((pctx (etaf--instance-pctx inst)))
    (if (cl-loop for (_key value) on (etaf--component-call-props
                                      (etaf--instance-call inst))
                 by #'cddr
                 thereis (etaf--expr-p value))
        (setf (etaf--instance-input-effect inst)
              (etaf--effect pctx (etaf--instance-seg inst)
                            (lambda () (etaf--comp-write-inputs inst))
                            t))
      (etaf--ctx-call pctx (lambda () (etaf--comp-write-inputs inst))))))

(defun etaf--comp-setup (inst)
  "Run INST's setup in its own detached Scope."
  (let* ((spec (etaf--instance-spec inst))
         (runtime (etaf--instance-runtime inst))
         (ctx (etaf--instance-ctx inst))
         (etaf--render-phase-p nil)
         (scope (etaf-effect-scope :detached t
                                   :name (etaf--component-spec-name spec))))
    (setf (etaf--instance-scope inst) scope)
    (when-let* ((seg (etaf--instance-seg inst)))
      (puthash scope seg etaf--scope-segments))
    (let* ((etaf--component-phase 'setup)
           (etaf--current-ictx ctx)
           (etaf--current-component-instance inst)
           (etaf--current-runtime runtime)
           (etaf--current-context (etaf--ictx-context ctx))
           (state (etaf-untracked
                    (etaf-scope-run
                     scope
                     (lambda ()
                       (funcall (etaf--component-spec-setup spec)
                                (etaf--instance-cells inst) nil))))))
      (when (functionp state)
        (signal 'etaf-runtime-error
                (list (format "Component %S :setup returned a function"
                              (etaf--component-spec-name spec)))))
      (setf (etaf--instance-state inst) state
            (etaf--instance-setup-p inst) t))))

(defun etaf--comp-attrs (inst)
  "Return INST's fallthrough Host attrs, evaluated in the caller's context."
  (let ((attrs (etaf--component-call-attrs (etaf--instance-call inst)))
        (pctx (etaf--instance-pctx inst)))
    (if (not (cl-loop for (_key value) on attrs by #'cddr
                      thereis (etaf--expr-p value)))
        attrs
      (cl-loop for (key value) on attrs by #'cddr
               append (list key
                            (if (etaf--expr-p value)
                                (let ((thunk (etaf--expr-thunk value)))
                                  (etaf--expr-create
                                   :thunk (lambda () (etaf--ctx-call pctx thunk))))
                              value))))))

(defun etaf--comp-show (seg view)
  "Show Component SEG's rendered VIEW."
  (let* ((inst (etaf--seg-data seg))
         (name (etaf--component-spec-name (etaf--instance-spec inst)))
         (items nil))
    (etaf--validate-component-render-result view name)
    (setf (etaf--instance-view inst) view
          items (etaf--flatten
                 (etaf--apply-component-attrs view (etaf--comp-attrs inst) name)))
    (if (and etaf--boundary-sync-error-function
             (gethash seg etaf--seg-boundaries))
        (condition-case err
            (etaf--patch-kids seg items (etaf--instance-ctx inst))
          (error
           (funcall etaf--boundary-sync-error-function seg err)))
      (etaf--patch-kids seg items (etaf--instance-ctx inst)))))

(defun etaf--comp-bind-render (seg)
  "Render Component SEG once, or bind its `:render' in an effect."
  (let* ((inst (etaf--seg-data seg))
         (spec (etaf--instance-spec inst))
         (ctx (etaf--instance-ctx inst))
         (render (etaf--component-spec-render spec))
         (cells (etaf--instance-cells inst)))
    (if (etaf--component-spec-view-p spec)
        (etaf--comp-show
         seg (etaf-untracked
               (etaf--ctx-call
                ctx (lambda ()
                      (funcall render cells (etaf--component-call-slots
                                             (etaf--instance-call inst)))))))
      (setf (etaf--seg-effect seg)
            (etaf--effect
             ctx seg
             (lambda ()
               (let ((view (funcall render cells
                                    (etaf--component-call-slots
                                     (etaf--instance-call inst)))))
                 (etaf-untracked (etaf--comp-show seg view)))))))))

(defun etaf--comp-init (seg)
  "Create Component SEG's instance, run its setup and render it."
  (let* ((call (etaf--seg-src seg))
         (spec (etaf--component-call-spec call))
         (pctx (etaf--seg-ctx seg))
         (runtime (etaf--ictx-runtime pctx))
         (id (etaf--next-id runtime))
         (setup (etaf--component-spec-setup spec))
         (names (etaf--component-spec-props spec))
         (inst (etaf--instance-make
                :id id :runtime runtime :spec spec :seg seg :pctx pctx :call call
                :txn etaf--txn
                :cells (vconcat (list names)
                                (mapcar (lambda (_) (etaf--ref-create)) names))
                :slots-ref (and runtime (etaf--ref-create
                                         :value (etaf--component-call-slots call))))))
    (setf (etaf--seg-data seg) inst
          (etaf--instance-ctx inst)
          (etaf--ictx-make
           :runtime runtime :owner inst :root-p t
           :context (if setup
                        (etaf--context-create :parent (etaf--ictx-context pctx)
                                              :owner-id id)
                      (etaf--ictx-context pctx))
           :theme (if setup 'unset (etaf--ictx-theme pctx))))
    (when runtime
      (etaf--jputhash id inst (etaf-runtime-instances runtime))
      (when etaf--txn (push inst (etaf--txn-instances etaf--txn))))
    ;; Inputs are validated first, so invalid props report the same error
    ;; with or without a Runtime.
    (etaf--comp-bind-inputs inst)
    (when (and setup (null runtime))
      (signal 'etaf-renderer-error
              (list "Stateful Component requires `etaf-mount'")))
    (when setup (etaf--comp-setup inst))
    (etaf--comp-bind-render seg)
    (when runtime
      (push inst (etaf-runtime-new-instances runtime))
      (etaf--runtime-touch runtime))))

(defun etaf--comp-patch (seg call)
  "Give live Component SEG the new CALL from its re-rendered parent."
  (let* ((inst (etaf--seg-data seg))
         (old (etaf--instance-call inst))
         (slots (etaf--component-call-slots call))
         (ref (etaf--instance-slots-ref inst)))
    (setf (etaf--seg-src seg) call
          (etaf--instance-call inst) call)
    (unless (and (eq (etaf--component-call-props old) (etaf--component-call-props call))
                 (null (etaf--instance-input-effect inst)))
      (etaf--stop (etaf--instance-input-effect inst))
      (setf (etaf--instance-input-effect inst) nil)
      (etaf--comp-bind-inputs inst))
    (when (and ref (not (eq slots (etaf-ref-value ref))))
      (etaf--cell-install ref slots))
    (unless (etaf--value-same-p (etaf--component-call-attrs old)
                                (etaf--component-call-attrs call))
      (etaf--comp-show seg (etaf--instance-view inst)))))

(defun etaf--comp-dispose (seg detach)
  "Dispose Component SEG, detaching its nodes when DETACH."
  (let ((inst (etaf--seg-data seg)))
    (etaf--stop (etaf--seg-effect seg))
    (when inst (etaf--stop (etaf--instance-input-effect inst)))
    (dolist (kid (etaf--seg-kids seg)) (etaf--dispose kid detach))
    (when inst
      (setf (etaf--instance-dead inst) t)
      (let ((runtime (etaf--instance-runtime inst)))
        (when-let* ((scope (etaf--instance-scope inst)))
          (let ((stop (lambda ()
                        (let ((errors (let ((etaf--render-phase-p nil))
                                        (etaf-scope-stop scope))))
                          (when runtime
                            (setf (etaf-runtime-errors runtime)
                                  (append errors (etaf-runtime-errors runtime))))))))
            (if (and etaf--txn (not (eq (etaf--instance-txn inst) etaf--txn)))
                (etaf--txn-defer stop)
              (funcall stop))))
        (when runtime
          (etaf--jremhash (etaf--instance-id inst) (etaf-runtime-instances runtime))
          (when (etaf--instance-mounted-p inst)
            (push inst (etaf-runtime-retired-instances runtime))
            (etaf--runtime-touch runtime)))))))

;;;; Disposal

(defun etaf--dispose (seg detach)
  "Dispose SEG and its descendants; remove its nodes from Ebox when DETACH."
  (pcase (etaf--seg-kind seg)
    ('host
     (let ((host (etaf--seg-data seg))
           (runtime (etaf--seg-runtime seg))
           (outer (and (etaf--seg-data seg) (etaf--seg-outer-node seg))))
       (etaf--stop (etaf--seg-effect seg))
       (when host
         (etaf--stop (etaf--host-payload host))
         (when-let* ((bucket (etaf--host-presentation host)))
           (setf (etaf--host-presentation host) nil)
           (when (and runtime (etaf-runtime-presentations runtime))
             (etaf--jremhash seg (etaf-runtime-presentations runtime)))
           (dolist (entry (etaf--pb-companions bucket))
             (when-let* ((pseg (etaf--pres-seg entry)))
               (etaf--dispose pseg nil)))
           (when-let* ((ov (etaf--pb-active-override bucket))
                       (pseg (etaf--pres-seg ov)))
             (etaf--dispose pseg nil)))
         (when runtime
           (etaf--host-unregister runtime host)
           (when-let* ((host-ids (etaf-runtime-host-ids runtime)))
             (etaf--jremhash (etaf--host-id host) host-ids))
           (when (etaf--seg-node seg)
             (etaf--jremhash (etaf--seg-node seg) (etaf-runtime-nodes runtime)))
           (let ((states (etaf--host-behaviors host)))
             (setf (etaf--host-behaviors host) nil)
             (etaf--behavior-cleanup runtime states))))
       (dolist (kid (etaf--seg-kids seg)) (etaf--dispose kid nil))
       (when (and detach (or outer (etaf--seg-node seg)) (etaf--seg-live seg))
         (etaf--detach seg (or outer (etaf--seg-node seg))))))
    ('pres
     (etaf--stop (etaf--seg-effect seg))
     (dolist (kid (etaf--seg-kids seg)) (etaf--dispose kid nil)))
    ('comp (etaf--comp-dispose seg detach))
    (_
     (etaf--stop (etaf--seg-effect seg))
     (dolist (kid (etaf--seg-kids seg)) (etaf--dispose kid detach))))
  (setf (etaf--seg-effect seg) nil
        (etaf--seg-live seg) nil))

;;;; Component accessors

(defun etaf--require-setup (operation)
  "Signal unless a mounted Component's setup is running for OPERATION."
  (unless (and (eq etaf--component-phase 'setup)
               (etaf--instance-p etaf--current-component-instance)
               etaf--current-runtime)
    (etaf--component-definition-error "%s requires Component setup" operation))
  etaf--current-component-instance)

;;;###autoload
(defun etaf-prop (name)
  "Return the current Component's read-only reactive input NAME.
Call during setup, then read the result with `etaf-value' inside computed
getters, watchers or View expressions.  NAME is a declared prop symbol or
keyword; defaults are included.  A plain prop variable is a snapshot taken
when setup ran, while this source follows later inputs."
  (let* ((inst (etaf--require-setup "etaf-prop"))
         (key (and (symbolp name) (etaf--component-prop-key name)))
         (names (etaf--component-spec-props (etaf--instance-spec inst)))
         (index (cl-position key (mapcar #'etaf--component-prop-key names))))
    (unless index
      (etaf--component-definition-error
       "Component %S has no declared prop %S"
       (etaf--component-spec-name (etaf--instance-spec inst)) name))
    (or (cdr (assq key (etaf--instance-prop-sources inst)))
        (let* ((cell (aref (etaf--instance-cells inst) (1+ index)))
               (source (etaf-computed (lambda () (etaf-value cell))
                                      :name name)))
          (push (cons key source) (etaf--instance-prop-sources inst))
          source))))

;;;###autoload
(defun etaf-local-ref (name)
  "Return an instance-local Host reference named NAME during Component setup.
NAME is a non-nil symbol or string.  Equal names in one instance return the
same opaque reference; different instances never share it.  Pass it to a
Host's `:ref' and to Host query, focus or event APIs."
  (let ((inst (etaf--require-setup "etaf-local-ref")))
    (unless (and name (or (symbolp name) (stringp name)))
      (etaf--component-definition-error
       "Local reference name must be a non-nil symbol or string: %S" name))
    (or (cdr (assoc name (etaf--instance-local-refs inst)))
        (let ((ref (make-symbol (format "etaf-local-%s" name))))
          (push (cons (if (stringp name) (copy-sequence name) name) ref)
                (etaf--instance-local-refs inst))
          ref))))

(defun etaf--push-hook (callback slot operation)
  "Add CALLBACK to the setup instance's lifecycle SLOT for OPERATION."
  (unless (functionp callback)
    (signal 'wrong-type-argument (list 'functionp callback)))
  (unless (and (eq etaf--component-phase 'setup)
               (etaf--instance-p etaf--current-component-instance))
    (error "%s requires Component setup" operation))
  (let ((inst etaf--current-component-instance))
    (pcase slot
      ('mounted (push callback (etaf--instance-mounted-hooks inst)))
      ('updated (push callback (etaf--instance-updated-hooks inst)))
      ('unmounted (push callback (etaf--instance-unmounted-hooks inst)))))
  callback)

;;;###autoload
(defun etaf-on-mounted (callback)
  "Run CALLBACK after the current Component first appears on screen."
  (etaf--push-hook callback 'mounted "etaf-on-mounted"))

;;;###autoload
(defun etaf-on-updated (callback)
  "Run CALLBACK after a commit in which the current Component re-rendered."
  (etaf--push-hook callback 'updated "etaf-on-updated"))

;;;###autoload
(defun etaf-on-unmounted (callback)
  "Run CALLBACK after the current Component leaves the screen."
  (etaf--push-hook callback 'unmounted "etaf-on-unmounted"))

(provide 'etaf-reconcile)
;;; etaf-reconcile.el ends here
