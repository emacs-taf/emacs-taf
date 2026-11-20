;;; etaf-compiler.el --- Automatic View blueprint lowering -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; `etaf-view' lowers supported structured topology into an embedded blueprint
;; as part of ordinary macro expansion.  Runtime instantiation constructs only
;; nodes on paths containing dynamic property holes.  Unsupported structural
;; forms use the existing View expansion unchanged.  There is no standalone
;; App artifact or user-managed precompilation workflow.

;;; Code:

(require 'cl-lib)
(require 'etaf-view)

(defconst etaf-compiler-blueprint-abi "etaf-view-blueprint/2")

(defvar etaf-compiler--static-cache (make-hash-table :test #'equal))
(defvar etaf-compiler--site-token-cache (make-hash-table :test #'equal))
(defvar etaf-compiler--registry-epoch 0)
(defvar etaf-compiler--instantiate-count 0)
(defvar etaf-compiler--last-blueprint nil)

(defun etaf-compiler-note-registry-change ()
  "Invalidate the static Component-call cache after a registry change."
  (cl-incf etaf-compiler--registry-epoch)
  (clrhash etaf-compiler--static-cache))

(defun etaf-compiler-clear-cache ()
  "Clear all process-local compiled View materializations."
  (interactive)
  (clrhash etaf-compiler--static-cache)
  (clrhash etaf-compiler--site-token-cache))

(defun etaf-compiler--site-token (blueprint block)
  "Return the stable opaque token for compiled BLOCK in BLUEPRINT."
  (let* ((key (list (plist-get blueprint :id)
                    (plist-get block :path)))
         (missing (make-symbol "etaf-compiled-site-token-missing"))
         (token (gethash key etaf-compiler--site-token-cache missing)))
    (if (not (eq token missing))
        token
      (setq token (list 'etaf-compiled-site
                        (plist-get blueprint :id)
                        (plist-get block :path)))
      (puthash key token etaf-compiler--site-token-cache)
      token)))

(defun etaf-compiler-statistics ()
  "Return a read-only snapshot of compiler runtime statistics."
  (list :abi etaf-compiler-blueprint-abi
        :instantiations etaf-compiler--instantiate-count
        :static-cache-entries (hash-table-count etaf-compiler--static-cache)
        :last-blueprint
        (and etaf-compiler--last-blueprint
             (list :id (plist-get etaf-compiler--last-blueprint :id)
                   :static-nodes
                   (plist-get etaf-compiler--last-blueprint :static-nodes)
                   :dynamic-nodes
                   (plist-get etaf-compiler--last-blueprint :dynamic-nodes)
                   :hole-count
                   (plist-get etaf-compiler--last-blueprint :hole-count)))
        :registry-epoch etaf-compiler--registry-epoch))

(defun etaf-compiler--literal (form)
  "Return `(t . VALUE)' when FORM is a portable literal, otherwise nil."
  (cond
   ((or (null form) (eq form t) (numberp form) (stringp form)
        (characterp form) (keywordp form))
    (cons t form))
   ((and (consp form) (eq (car form) 'quote) (null (cddr form)))
    (cons t (cadr form)))
   (t nil)))

(defun etaf-compiler--compile-property (form programs)
  "Compile property FORM, returning `(DESCRIPTOR . PROGRAMS)'."
  (if-let* ((literal (etaf-compiler--literal form)))
      (cons (list :kind 'static :value (cdr literal)) programs)
    (let ((index (length programs)))
      (cons (list :kind 'hole :index index)
            (append programs (list `(lambda () ,form)))))))

(defun etaf-compiler--form-directives (form)
  "Return validated compiler directives from raw View FORM, or nil."
  (when (and (consp form) (symbolp (car form))
             (not (memq (car form) '(expr slot))))
    (let ((props
           (car (etaf--parse-attributes-and-children (cdr form)))))
      (etaf--validate-directive-set
       (etaf--view-directive-properties props)))))

(defun etaf-compiler--compile-program-block (kind code path programs)
  "Compile structural KIND from executable CODE at PATH using PROGRAMS."
  (let ((index (length programs)))
    (list (list :kind kind :path path :hole index :static-p nil)
          (append programs (list `(lambda () ,code))))))

(defun etaf-compiler--compile-children
    (children path programs slot-mode)
  "Compile sibling CHILDREN below PATH, extending PROGRAMS.
SLOT-MODE selects ordinary projection or slot compilation."
  (let ((child-index 0)
        blocks)
    (while children
      (let* ((form (car children))
             (directives (etaf-compiler--form-directives form))
             compiled
             consumed)
        (cond
         ((and directives (plist-member directives :if))
          (pcase-let ((`(,code . ,remaining)
                       (etaf--compile-branch-children
                        form (cdr children) slot-mode)))
            (setq compiled
                  (etaf-compiler--compile-program-block
                   'branch code (append path (list child-index)) programs)
                  consumed (- (length children) (length remaining))
                  children remaining)))
         ((and directives (plist-member directives :for))
          (setq compiled
                (etaf-compiler--compile-program-block
                 'keyed-list
                 (etaf--compile-for-child form slot-mode)
                 (append path (list child-index)) programs)
                consumed 1
                children (cdr children)))
         ((and directives
               (or (plist-member directives :else-if)
                   (plist-member directives :else)))
          (etaf--syntax-error "Orphan branch arm: %S" form))
         (t
          (setq compiled
                (etaf-compiler--compile-block
                 form (append path (list child-index)) programs slot-mode)
                consumed 1
                children (cdr children))))
        (setq programs (cadr compiled)
              blocks (append blocks (list (car compiled))))
        (cl-incf child-index consumed)))
    (list blocks programs)))

(defun etaf-compiler--compile-block (form path programs slot-mode)
  "Compile View FORM at PATH using PROGRAMS and SLOT-MODE.
Return `(BLOCK PROGRAMS)' or nil."
  (cond
   ((or (null form) (stringp form))
    (list (list :kind 'literal :value form :path path :static-p t) programs))
   ((not (and (consp form) (symbolp (car form))))
    (etaf--syntax-error "View form must start with a tag symbol: %S" form))
   ((eq (car form) 'expr)
    (let ((index (length programs)))
      (list (list :kind 'expr :path path :hole index :static-p nil)
            (append programs
                    (list `(lambda () ,(etaf--parse-expr-form (cdr form))))))))
   ((eq (car form) 'slot)
    (etaf-compiler--compile-program-block
     'slot (etaf--compile-slot-form (cdr form) slot-mode) path programs))
   ((and (null (gethash (car form) etaf--view-registry))
         (etaf--ordinary-expression-head-p (car form)))
    (etaf--syntax-error
     "Elisp expression %S must be inside (expr FORM)" (car form)))
   (t
    (let* ((parts (etaf--parse-attributes-and-children (cdr form)))
           (props (car parts))
           (children (cdr parts))
           (host-view-p
            (eq (gethash (car form) etaf--view-registry) etaf--host-marker))
           (child-slot-mode (if host-view-p slot-mode :input))
           (compiled-props nil)
           (all-static t)
           (tail props))
      (while tail
        (let* ((key (pop tail))
               (value (pop tail))
               (compiled (etaf-compiler--compile-property value programs))
               (descriptor (car compiled)))
          (setq programs (cdr compiled))
          (unless (eq (plist-get descriptor :kind) 'static)
            (setq all-static nil))
          (setq compiled-props
                (append compiled-props (list key descriptor)))))
      (pcase-let* ((`(,compiled-children ,next-programs)
                    (etaf-compiler--compile-children
                     children path programs child-slot-mode)))
        (dolist (block compiled-children)
          (unless (plist-get block :static-p) (setq all-static nil)))
        (list (list :kind 'node :name (car form) :path path
                    :props compiled-props :children compiled-children
                    :static-p all-static)
              next-programs))))))

(defun etaf-compiler--block-counts (block)
  "Return `(STATIC . DYNAMIC)' node counts below BLOCK."
  (if (eq (plist-get block :kind) 'literal)
      (cons 0 0)
    (let ((static (if (plist-get block :static-p) 1 0))
          (dynamic (if (plist-get block :static-p) 0 1)))
      (dolist (child (plist-get block :children))
        (pcase-let ((`(,child-static . ,child-dynamic)
                     (etaf-compiler--block-counts child)))
          (cl-incf static child-static)
          (cl-incf dynamic child-dynamic)))
      (cons static dynamic))))

(defun etaf-compiler--compile (form &optional slot-mode)
  "Compile FORM under optional SLOT-MODE into a View blueprint.
Return `(BLUEPRINT PROGRAM-CODE...)', or nil."
  (pcase-let* ((`(,roots ,programs)
                (etaf-compiler--compile-children
                 (list form) nil nil (or slot-mode :projection)))
               (root (car roots)))
    (unless (and root (null (cdr roots)))
      (etaf--syntax-error "A View blueprint requires exactly one root"))
    (let* ((programs programs)
           (id (secure-hash 'sha256 (prin1-to-string form)))
           (counts (etaf-compiler--block-counts root)))
      (cons (list :kind 'etaf/view-blueprint
                  :abi etaf-compiler-blueprint-abi
                  :id id :root root
                  :static-nodes (car counts)
                  :dynamic-nodes (cdr counts)
                  :hole-count (length programs))
            programs))))

(defun etaf-compiler--closed-plist-p (value allowed)
  "Return non-nil when VALUE is a duplicate-free plist using ALLOWED keys."
  (and (proper-list-p value)
       (zerop (% (length value) 2))
       (let ((tail value)
             seen
             valid)
         (setq valid t)
         (while (and valid tail)
           (let ((key (pop tail)))
             (pop tail)
             (if (or (not (memq key allowed)) (memq key seen))
                 (setq valid nil)
               (push key seen))))
         valid)))

(defun etaf-compiler--valid-property-descriptor-p (descriptor hole-count)
  "Return non-nil for one bounded property DESCRIPTOR using HOLE-COUNT."
  (and (proper-list-p descriptor)
       (pcase (plist-get descriptor :kind)
         ('static
          (and (etaf-compiler--closed-plist-p descriptor '(:kind :value))
               (plist-member descriptor :value)))
         ('hole
          (and (etaf-compiler--closed-plist-p descriptor '(:kind :index))
               (natnump (plist-get descriptor :index))
               (< (plist-get descriptor :index) hole-count)))
         (_ nil))))

(defun etaf-compiler--valid-property-block-p (props hole-count)
  "Return non-nil for a canonical property block PROPS using HOLE-COUNT."
  (and (proper-list-p props)
       (zerop (% (length props) 2))
       (let ((tail props)
             seen
             valid)
         (setq valid t)
         (while (and valid tail)
           (let ((key (pop tail))
                 (descriptor (pop tail)))
             (if (or (not (keywordp key))
                     (memq key seen)
                     (not (etaf-compiler--valid-property-descriptor-p
                           descriptor hole-count)))
                 (setq valid nil)
               (push key seen))))
         valid)))

(defun etaf-compiler--valid-block-p (block hole-count)
  "Return non-nil when BLOCK is valid for current View IR HOLE-COUNT."
  (and (proper-list-p block)
       (proper-list-p (plist-get block :path))
       (booleanp (plist-get block :static-p))
       (pcase (plist-get block :kind)
         ('literal
          (and (etaf-compiler--closed-plist-p
                block '(:kind :value :path :static-p))
               (plist-member block :value)
               (or (null (plist-get block :value))
                   (stringp (plist-get block :value)))
               (plist-get block :static-p)))
         ((or 'expr 'branch 'keyed-list 'slot)
          (and (etaf-compiler--closed-plist-p
                block '(:kind :path :hole :static-p))
               (natnump (plist-get block :hole))
               (< (plist-get block :hole) hole-count)
               (not (plist-get block :static-p))))
         ('node
          (and (etaf-compiler--closed-plist-p
                block '(:kind :name :path :props :children :static-p))
               (symbolp (plist-get block :name))
               (etaf-compiler--valid-property-block-p
                (plist-get block :props) hole-count)
               (proper-list-p (plist-get block :children))
               (cl-every (lambda (child)
                           (etaf-compiler--valid-block-p child hole-count))
                         (plist-get block :children))))
         (_ nil))))

(defun etaf-compiler--valid-blueprint-p (blueprint program-count)
  "Return non-nil when BLUEPRINT is closed and matches PROGRAM-COUNT."
  (and (etaf-compiler--closed-plist-p
        blueprint
        '(:kind :abi :id :root :static-nodes :dynamic-nodes :hole-count))
       (eq (plist-get blueprint :kind) 'etaf/view-blueprint)
       (equal (plist-get blueprint :abi) etaf-compiler-blueprint-abi)
       (stringp (plist-get blueprint :id))
       (natnump (plist-get blueprint :static-nodes))
       (natnump (plist-get blueprint :dynamic-nodes))
       (natnump (plist-get blueprint :hole-count))
       (= program-count (plist-get blueprint :hole-count))
       (etaf-compiler--valid-block-p
        (plist-get blueprint :root) program-count)))

(defun etaf-compiler--materialize (blueprint block programs)
  "Materialize BLOCK from BLUEPRINT using PROGRAMS."
  (let* ((static-p (plist-get block :static-p))
         (cache-key (and static-p
                         (list (plist-get blueprint :id)
                               (plist-get block :path)
                               etaf-compiler--registry-epoch)))
         (missing (make-symbol "etaf-compiled-missing"))
         (cached (and cache-key
                      (gethash cache-key etaf-compiler--static-cache missing))))
    (if (and cache-key (not (eq cached missing)))
        cached
      (let ((value
             (pcase (plist-get block :kind)
               ;; The compiler's literal block is also used for a root string.
               ;; Keep the same canonicalization as the non-compiled View path:
               ;; a bare string is a Text View, while nil remains an empty
               ;; structural value.
               ('literal
                (let ((literal (plist-get block :value)))
                  (if (and (stringp literal)
                           (= (length (plist-get block :path)) 1))
                      (etaf--text-view-from-string literal)
                    literal)))
               ('expr
                (etaf--expr-create
                 :token (etaf-compiler--site-token blueprint block)
                 :thunk (aref programs (plist-get block :hole))))
               ((or 'branch 'keyed-list)
                (let ((program
                       (funcall (aref programs (plist-get block :hole)))))
                  (unless (and (etaf--expr-p program)
                               (eq (etaf--expr-kind program)
                                   (plist-get block :kind)))
                    (error "Invalid ETAF structural program for %S"
                           (plist-get block :kind)))
                  program))
               ('slot
                (let ((slot
                       (funcall (aref programs (plist-get block :hole)))))
                  (unless (or (etaf--slot-projection-p slot)
                              (etaf--slot-input-p slot))
                    (error "Invalid ETAF slot program"))
                  slot))
               ('node
                (let ((props nil))
                  (cl-loop for (key descriptor) on (plist-get block :props)
                           by #'cddr
                           do (setq props
                                   (append
                                    props
                                    (list
                                     key
                                     (if (eq (plist-get descriptor :kind)
                                             'static)
                                         (plist-get descriptor :value)
                                       (etaf--expr-create
                                        :thunk
                                        (aref programs
                                              (plist-get descriptor
                                                         :index))))))))
                  (etaf--view-call
                   (plist-get block :name) props
                   (mapcar (lambda (child)
                             (etaf-compiler--materialize
                              blueprint child programs))
                           (plist-get block :children))
                   (list 'etaf-compiled-site
                         (plist-get blueprint :id)
                         (plist-get block :path)))))
               (_ (error "Unknown ETAF compiled block: %S" block)))))
        (when cache-key
          (puthash cache-key value etaf-compiler--static-cache))
        value))))

;;;###autoload
(defun etaf-compiler-instantiate (blueprint programs)
  "Instantiate automatically lowered View BLUEPRINT with dynamic PROGRAMS."
  (unless (and (vectorp programs)
               (etaf-compiler--valid-blueprint-p
                blueprint (length programs)))
    (error "Invalid or incompatible ETAF View blueprint"))
  (cl-incf etaf-compiler--instantiate-count)
  (setq etaf-compiler--last-blueprint blueprint)
  (etaf-compiler--materialize
   blueprint (plist-get blueprint :root) programs))

(defun etaf-compiler-expand-view (form &optional slot-mode)
  "Return compiler expansion for View FORM.
SLOT-MODE distinguishes Component projections from call-site slot inputs."
  (let* ((compiled (etaf-compiler--compile
                    form (or slot-mode :projection)))
         (blueprint (car compiled)))
    `(etaf-compiler-instantiate
      ',blueprint (vector ,@(cdr compiled)))))

(provide 'etaf-compiler)
;;; etaf-compiler.el ends here
