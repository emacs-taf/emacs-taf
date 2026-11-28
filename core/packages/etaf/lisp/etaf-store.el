;;; etaf-store.el --- Path-level fine-grained reactive store -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Path-level reactive state store built over ETAF's reactive cell graph.
;; Updating a nested path notifies only observers subscribed to that path, its
;; ancestors, and its descendants, never unrelated sibling branches.

;;; Code:

(require 'cl-lib)
(require 'etaf-reactive)

(define-error 'etaf-store-error "Invalid ETAF Store operation"
  'etaf-reactive-error)

(cl-defstruct (etaf-store (:constructor etaf--store-create) (:copier nil))
  "A path-level fine-grained reactive store."
  root initial cells name)

(defun etaf-store--plist-p (value)
  "Return non-nil when VALUE is nil or a keyword plist."
  (and (proper-list-p value)
       (zerop (% (length value) 2))
       (let ((tail value)
             (ok t))
         (while (and ok tail)
           (unless (keywordp (car tail))
             (setq ok nil))
           (setq tail (cddr tail)))
         ok)))

(defun etaf-store--deep-copy (value)
  "Return a detached copy of nested plists/lists in VALUE."
  (cond
   ((consp value) (copy-tree value t))
   ((vectorp value) (vconcat (mapcar #'etaf-store--deep-copy value)))
   (t value)))

(defun etaf-store--normalize-path (path)
  "Normalize PATH into a proper list of keyword segments."
  (let ((segments
         (cond
          ((null path) nil)
          ((keywordp path) (list path))
          ((proper-list-p path)
           (if (and (= (length path) 1) (listp (car path)))
               (car path)
             path))
          (t (signal 'etaf-store-error
                     (list "Store path must be a keyword or list of keywords" path))))))
    (dolist (seg segments)
      (unless (keywordp seg)
        (signal 'etaf-store-error
                (list "Store path segment must be a keyword" seg path))))
    segments))

(defun etaf-store--read-in (tree path)
  "Read value at normalized keyword PATH inside nested plist TREE."
  (let ((cur tree))
    (while (and path (etaf-store--plist-p cur))
      (setq cur (plist-get cur (pop path))))
    (if path nil cur)))

(defun etaf-store--write-in (tree path value)
  "Return a new nested plist tree with PATH set to VALUE."
  (if (null path)
      (progn
        (unless (etaf-store--plist-p value)
          (signal 'etaf-store-error
                  (list "Store root state must be a keyword plist" value)))
        value)
    (let* ((key (car path))
           (rest (cdr path))
           (base (if (etaf-store--plist-p tree) (copy-sequence tree) nil))
           (child (if rest
                      (etaf-store--write-in (plist-get base key) rest value)
                    value)))
      (plist-put base key child))))

(defun etaf-store--prefix-p (prefix path)
  "Return non-nil when list PREFIX is a strict or equal prefix of PATH."
  (let ((p prefix)
        (q path)
        (ok t))
    (while (and ok p)
      (if (and q (eq (car p) (car q)))
          (setq p (cdr p) q (cdr q))
        (setq ok nil)))
    ok))

(defun etaf-store--require (store)
  "Validate STORE and return it."
  (unless (etaf-store-p store)
    (signal 'wrong-type-argument (list 'etaf-store-p store)))
  store)

(defun etaf-store--cell-for (store path)
  "Return or lazily allocate the internal ref cell for normalized PATH in STORE.
Allocates via `etaf--ref-create' directly so first reads inside pure `:render'
never violate render side-effect boundaries."
  (let* ((cells (etaf-store-cells store))
         (cell (gethash path cells)))
    (unless cell
      (setq cell (etaf--ref-create
                  :value (etaf-store--read-in (etaf-store-root store) path)
                  :test #'equal
                  :name (or (etaf-store-name store) path 'etaf-store)))
      (puthash path cell cells))
    cell))

(defun etaf-store--notify-affected (store path)
  "Update and notify cells affected by a write at normalized PATH in STORE.
Notifies PATH itself, existing ancestor prefixes, and existing descendant paths."
  (let* ((root (etaf-store-root store))
         (cells (etaf-store-cells store))
         (to-update nil))
    (maphash
     (lambda (cell-path cell)
       (when (or (etaf-store--prefix-p cell-path path)
                 (etaf-store--prefix-p path cell-path))
         (push (cons cell-path cell) to-update)))
     cells)
    (when to-update
      (etaf-batch
        (dolist (entry to-update)
          (let ((new-val (etaf-store--read-in root (car entry))))
            (etaf-set-value (cdr entry) new-val)))))))

;;;###autoload
(cl-defun etaf-store-create (initial-state &key name)
  "Create a path-level fine-grained reactive store from plist INITIAL-STATE.
INITIAL-STATE must be nil or a keyword plist (which may nest keyword plists).
NAME optionally labels diagnostics."
  (etaf--assert-not-rendering 'create-store)
  (unless (etaf-store--plist-p initial-state)
    (signal 'etaf-store-error
            (list "Store initial state must be a keyword plist or nil" initial-state)))
  (let ((copy (etaf-store--deep-copy initial-state)))
    (etaf--store-create
     :root copy
     :initial (etaf-store--deep-copy copy)
     :cells (make-hash-table :test #'equal)
     :name name)))

;;;###autoload
(defun etaf-store-get (store &rest path)
  "Read value at PATH in STORE and subscribe only to that path.
PATH may be zero or more keyword arguments (e.g. `:user :name') or a single
list of keywords (e.g. `(:user :name)').  Empty PATH reads the root plist."
  (etaf-store--require store)
  (let* ((norm (etaf-store--normalize-path path))
         (cell (etaf-store--cell-for store norm)))
    (etaf-value cell)))

;;;###autoload
(defun etaf-store-set (store path value)
  "Set PATH in STORE to VALUE and notify only affected path subscribers.
PATH is a keyword, list of keywords, or nil for the root plist.  Unchanged
values under `equal' perform no notifications.  Return VALUE."
  (etaf--assert-not-rendering 'store-set)
  (etaf-store--require store)
  (let* ((norm (etaf-store--normalize-path path))
         (old (etaf-store--read-in (etaf-store-root store) norm)))
    (unless (equal old value)
      (setf (etaf-store-root store)
            (etaf-store--write-in (etaf-store-root store) norm value))
      (etaf-store--notify-affected store norm))
    value))

;;;###autoload
(defun etaf-store-update (store path function &rest arguments)
  "Update PATH in STORE by applying FUNCTION to its current value and ARGUMENTS.
Return the new value."
  (etaf--assert-not-rendering 'store-update)
  (etaf-store--require store)
  (unless (functionp function)
    (signal 'wrong-type-argument (list 'functionp function)))
  (let* ((norm (etaf-store--normalize-path path))
         (cur (etaf-store--read-in (etaf-store-root store) norm))
         (next (apply function cur arguments)))
    (etaf-store-set store norm next)))

;;;###autoload
(defun etaf-store-patch (store &rest pairs)
  "Apply alternating PATH VALUE PAIRS to STORE inside one reactive batch.
Each PATH is a keyword or list of keywords.  Return STORE."
  (etaf--assert-not-rendering 'store-patch)
  (etaf-store--require store)
  (unless (zerop (% (length pairs) 2))
    (signal 'etaf-store-error
            (list "Store patch requires alternating PATH VALUE pairs" pairs)))
  (etaf-batch
    (let ((tail pairs))
      (while tail
        (let ((path (pop tail))
              (val (pop tail)))
          (etaf-store-set store path val)))))
  store)

;;;###autoload
(defun etaf-store-select (store path &optional projector)
  "Return a scoped `etaf-computed' reading PATH in STORE.
When PROJECTOR is non-nil, apply it to the value at PATH.  Results compare with
`equal' so downstream observers skip unchanged derived values."
  (etaf--assert-not-rendering 'store-select)
  (etaf-store--require store)
  (when (and projector (not (functionp projector)))
    (signal 'wrong-type-argument (list 'functionp projector)))
  (let ((norm (etaf-store--normalize-path path)))
    (etaf-computed
     (lambda ()
       (let ((val (etaf-store-get store norm)))
         (if projector (funcall projector val) val)))
     :test #'equal
     :name (or (etaf-store-name store) norm 'etaf-store-select))))

;;;###autoload
(defun etaf-store-snapshot (store)
  "Return an untracked deep copy of STORE's current root plist."
  (etaf-store--require store)
  (etaf-store--deep-copy (etaf-store-root store)))

;;;###autoload
(defun etaf-store-reset (store &optional new-state)
  "Reset STORE to NEW-STATE (or its initial state) inside one reactive batch.
Notifies only paths whose values actually changed.  Return STORE."
  (etaf--assert-not-rendering 'store-reset)
  (etaf-store--require store)
  (let ((target (if new-state
                    (progn
                      (unless (etaf-store--plist-p new-state)
                        (signal 'etaf-store-error
                                (list "Store reset state must be a keyword plist" new-state)))
                      (etaf-store--deep-copy new-state))
                  (etaf-store--deep-copy (etaf-store-initial store)))))
    (setf (etaf-store-root store) target)
    (etaf-batch
      (maphash
       (lambda (cell-path cell)
         (etaf-set-value cell (etaf-store--read-in target cell-path)))
       (etaf-store-cells store)))
    store))

(provide 'etaf-store)
;;; etaf-store.el ends here
