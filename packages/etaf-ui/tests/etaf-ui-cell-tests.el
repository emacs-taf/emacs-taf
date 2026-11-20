;;; etaf-ui-cell-tests.el --- Public API acceptance -*- lexical-binding: t; -*-

;;; Commentary:
;; Test supported package inputs, outputs, errors and lifecycle.
;; Internal implementation details are outside this contract.

;;; Code:
(require 'cl-lib)
(require 'ert)
(require 'etaf-ui)

(defvar etaf-ui-cell-test--states nil)

(defvar etaf-ui-cell-test--removed nil)

(defun etaf-ui-cell-test--row-key (row)
  "Return ROW's stable identity."
  (plist-get row :id))

(defun etaf-ui-cell-test--name (row)
  "Return ROW's name as custom cell content."
  (plist-get row :name))

(defmacro etaf-ui-cell-test--with-buffer (name &rest body)
  "Execute BODY with a temporary mounted buffer bound to NAME."
  (declare (indent 1) (debug (symbolp body)))
  `(let ((,name (generate-new-buffer " *etaf-ui-cells*")))
     (unwind-protect (progn ,@body)
       (when-let* ((runtime (etaf-runtime-for-buffer ,name)))
         (etaf-unmount runtime))
       (when (buffer-live-p ,name) (kill-buffer ,name)))))

(etaf-define-component etaf-ui-cell-test-counter (&key row field value)
  "Retain one independent counter at the consuming row/column position."
  :setup
  (let* ((id (list (plist-get row :id) field))
         (count (etaf-ref 0))
         (ref (make-symbol "etaf-cell-counter")))
    (push (list id count ref) etaf-ui-cell-test--states)
    (etaf-on-unmounted (lambda () (push id etaf-ui-cell-test--removed)))
    (list count ref))
  :render
  (let* ((state (etaf-state))
         (count (car state)))
    (etaf-node
     'etaf-button
     (list :label (format "%s:%s:%s%s" (plist-get row :id) field
                          (etaf-value count) (if value (concat ":" value) ""))
           :ref (cadr state)
           :on-press (lambda () (cl-incf (etaf-value count))))
     nil)))

(defun etaf-ui-cell-test--counter-column (field)
  "Return a custom FIELD column containing independent state."
  (list :key field :label (symbol-name field) :width 12
        :cell (lambda (row)
                (etaf-node 'etaf-ui-cell-test-counter
                           (list :row row :field field) nil))))

(ert-deftest etaf-ui-cell-columns-require-unique-non-nil-keys ()
  "Reject ambiguous column identity with its index and offending key."
  (dolist (columns '(((:label "Missing"))
                     ((:key :name) (:key :name))))
    (etaf-ui-cell-test--with-buffer buffer
      (let ((message
             (error-message-string
              (should-error
               (etaf-mount
                buffer
                (etaf-view
                 (etaf-table :columns columns :rows nil
                             :row-key #'etaf-ui-cell-test--row-key)))))))
        (should (string-match-p "column" message))
        (should (string-match-p (if (= (length columns) 1) "1" "2")
                                message))
        (should (string-match-p (if (= (length columns) 1) "nil" ":name")
                                message))))))

(ert-deftest etaf-ui-cell-stateless-table-keeps-pure-render-support ()
  "Automatic row references do not introduce setup state into plain Tables."
  (dolist (columns '(((:key :name :width 12))
                     ((:key :name :width 12 :cell etaf-ui-cell-test--name))))
    (should
     (stringp (ebox-render
      (etaf-render
       (etaf-view
        (etaf-table :columns columns :rows '((:id 1 :name "Ada"))
                    :row-key #'etaf-ui-cell-test--row-key))))))))

(ert-deftest etaf-ui-cell-factory-rejects-ref-and-watch-creation ()
  "A factory cannot allocate persistent state or subscriptions during render."
  (dolist (operation '(create-ref watch watch-effect))
    (let* ((source (etaf-ref 0))
           (calls 0)
           (columns
            (list
             (list :key :illegal :width 12
                   :cell
                   (lambda (_row)
                     (pcase operation
                       ('create-ref (etaf-ref 0))
                       ('watch
                        (etaf-watch source (lambda (&rest _) (cl-incf calls))
                                    :immediate t))
                       ('watch-effect
                        (etaf-watch-effect
                         (lambda () (etaf-value source) (cl-incf calls)))))
                     "Unreachable")))))
      (etaf-ui-cell-test--with-buffer buffer
        (let ((failure
               (should-error
                (etaf-mount
                 buffer
                 (etaf-view
                  (etaf-table :rows '((:id 1)) :columns columns
                              :row-key #'etaf-ui-cell-test--row-key)))
                :type 'etaf-render-side-effect-error)))
          (should (equal (cdr failure) (list operation))))
        (should-not (etaf-runtime-for-buffer buffer))
        (setf (etaf-value source) 1)
        (should (zerop calls))))))

(ert-deftest etaf-ui-cell-row-and-column-reorder-retain-state ()
  "Counter state follows row and column keys, with one cleanup on deletion."
  (let* ((etaf-ui-cell-test--states nil)
         (etaf-ui-cell-test--removed nil)
         (rows (etaf-ref '((:id 1) (:id 2))))
         (columns (etaf-ref (list (etaf-ui-cell-test--counter-column :a)
                                 (etaf-ui-cell-test--counter-column :b)))))
    (etaf-ui-cell-test--with-buffer buffer
      (etaf-mount
       buffer
       (etaf-view
        (etaf-table :columns (etaf-value columns) :rows (etaf-value rows)
                    :row-key #'etaf-ui-cell-test--row-key)))
      (should (= 4 (length etaf-ui-cell-test--states)))
      (let* ((state (assoc '(1 :a) etaf-ui-cell-test--states))
             (ref (nth 2 state)))
        (etaf-dispatch-event (etaf-runtime-for-buffer buffer) ref 'press)
        (setf (etaf-value columns) (reverse (etaf-value columns)))
        (setf (etaf-value rows) (reverse (etaf-value rows)))
        (should (= 4 (length etaf-ui-cell-test--states)))
        (should-not etaf-ui-cell-test--removed)
        (etaf-dispatch-event (etaf-runtime-for-buffer buffer) ref 'press)
        (should (= 2 (etaf-value (cadr state))))
        (with-current-buffer buffer
          (should (string-match-p "1::a:2" (buffer-string)))))
      (setf (etaf-value rows) '((:id 2)))
      (should (= 2 (length etaf-ui-cell-test--removed)))
      (should (member '(1 :a) etaf-ui-cell-test--removed))
      (should (member '(1 :b) etaf-ui-cell-test--removed)))))

(ert-deftest etaf-ui-cell-grid-reorders-without-remounting-cells ()
  "DataGrid uses the same retained custom cells while preserving row identity."
  (let* ((etaf-ui-cell-test--states nil)
         (etaf-ui-cell-test--removed nil)
         (source (etaf-data-memory-source '((:id 1) (:id 2)) :id-key :id))
         (controller (etaf-data-controller source :auto-load t))
         (columns (etaf-ref (list (etaf-ui-cell-test--counter-column :a)
                                 (etaf-ui-cell-test--counter-column :b)))))
    (unwind-protect
        (etaf-ui-cell-test--with-buffer buffer
          (etaf-mount
           buffer
           (etaf-view
            (etaf-data-grid :controller controller :columns (etaf-value columns)
                            :row-key #'etaf-ui-cell-test--row-key)))
          (let* ((state (assoc '(1 :a) etaf-ui-cell-test--states))
                 (ref (nth 2 state)))
            (etaf-dispatch-event (etaf-runtime-for-buffer buffer) ref 'press)
            (setf (etaf-value columns) (reverse (etaf-value columns)))
            (setf (etaf-value (etaf-data-items controller)) '((:id 2) (:id 1)))
            (should (= 4 (length etaf-ui-cell-test--states)))
            (should-not etaf-ui-cell-test--removed)
            (etaf-dispatch-event (etaf-runtime-for-buffer buffer) ref 'press)
            (should (= 2 (etaf-value (cadr state))))
            (with-current-buffer buffer
              (should (string-match-p "1::a:2" (buffer-string)))))
          (setf (etaf-value (etaf-data-items controller)) '((:id 2)))
          (should (= 2 (length etaf-ui-cell-test--removed))))
      (etaf-data-stop controller))))

(ert-deftest etaf-ui-cell-duplicate-field-migration-retains-distinct-state ()
  "Name and Uppercase read the same field but retain distinct column identities."
  (let* ((etaf-ui-cell-test--states nil)
         (etaf-ui-cell-test--removed nil)
         (rows (etaf-ref '((:id 1 :name "Ada") (:id 2 :name "Lin"))))
         (columns
          (etaf-ref
           (mapcar
            (lambda (entry)
              (let ((key (car entry)) (transform (cdr entry)))
                (list :key key :label (if (eq key :name) "Name" "Uppercase")
                      :width 24
                      :cell
                      (lambda (row)
                        (etaf-node 'etaf-ui-cell-test-counter
                                   (list :row row :field key
                                         :value (funcall transform
                                                         (plist-get row :name)))
                                   nil)))))
            '((:name . identity) (:name-upper . upcase))))))
    (etaf-ui-cell-test--with-buffer buffer
      (etaf-mount
       buffer
       (etaf-view
        (etaf-table :rows (etaf-value rows) :columns (etaf-value columns)
                    :row-key #'etaf-ui-cell-test--row-key)))
      (let* ((runtime (etaf-runtime-for-buffer buffer))
             (name (assoc '(1 :name) etaf-ui-cell-test--states))
             (upper (assoc '(1 :name-upper) etaf-ui-cell-test--states))
             (other-name (assoc '(2 :name) etaf-ui-cell-test--states))
             (other-upper (assoc '(2 :name-upper) etaf-ui-cell-test--states)))
        (should (= 4 (length etaf-ui-cell-test--states)))
        (should-not (eq (cadr name) (cadr upper)))
        (should-not (eq (nth 2 name) (nth 2 upper)))
        (etaf-dispatch-event runtime (nth 2 name) 'press)
        (etaf-dispatch-event runtime (nth 2 upper) 'press)
        (etaf-dispatch-event runtime (nth 2 upper) 'press)
        (setf (etaf-value rows) '((:id 2 :name "Lin") (:id 1 :name "Grace")))
        (setf (etaf-value columns) (reverse (etaf-value columns)))
        (should (= 4 (length etaf-ui-cell-test--states)))
        (should-not etaf-ui-cell-test--removed)
        (etaf-dispatch-event runtime (nth 2 name) 'press)
        (etaf-dispatch-event runtime (nth 2 upper) 'press)
        (should (= 2 (etaf-value (cadr name))))
        (should (= 3 (etaf-value (cadr upper))))
        (should (zerop (etaf-value (cadr other-name))))
        (should (zerop (etaf-value (cadr other-upper))))
        (with-current-buffer buffer
          (dolist (label '("1::name:2:Grace" "1::name-upper:3:GRACE"
                           "2::name:0:Lin" "2::name-upper:0:LIN"))
            (should (string-match-p (regexp-quote label) (buffer-string)))))))))

(ert-deftest etaf-ui-cell-later-factory-error-retains-committed-handler ()
  "A failed later cell cannot replace an earlier cell's committed callback."
  (let* ((rows (etaf-ref '((:id 1 :name "Committed") (:id 2 :name "Later"))))
         (first-ref (make-symbol "etaf-cell-first"))
         pressed
         (columns
          (list
           (list :key :action :width 16
                 :cell
                 (lambda (row)
                   (when (plist-get row :fail) (error "Late cell failure"))
                   (let ((name (plist-get row :name)))
                     (etaf-node 'box
                                (list :ref (when (= 1 (plist-get row :id))
                                             first-ref)
                                      :on-press (lambda () (setq pressed name)))
                                (list name))))))))
    (etaf-ui-cell-test--with-buffer buffer
      (etaf-mount
       buffer
       (etaf-view
        (etaf-table :rows (etaf-value rows) :columns columns
                    :row-key #'etaf-ui-cell-test--row-key)))
      (let* ((runtime (etaf-runtime-for-buffer buffer))
             (generation (etaf-runtime-revision runtime))
             (text (with-current-buffer buffer (buffer-string))))
        (should-error
         (setf (etaf-value rows)
               '((:id 1 :name "Candidate") (:id 2 :name "Failure" :fail t))))
        (should (eq generation (etaf-runtime-revision runtime)))
        (should (equal-including-properties
                 text (with-current-buffer buffer (buffer-string))))
        (etaf-dispatch-event runtime first-ref 'press)
        (should (equal "Committed" pressed))
        (setf (etaf-value rows) '((:id 1 :name "Published") (:id 2)))
        (etaf-dispatch-event runtime first-ref 'press)
        (should (equal "Published" pressed))))))

(ert-deftest etaf-ui-cell-grid-publishes-current-rows-and-selection ()
  "Cells, row callbacks and selection follow current inputs under retained keys."
  (let* ((rows (cl-loop for id from 1 to 12
                        collect (list :id id :name (format "Row %d" id))))
         (source (etaf-data-memory-source rows :id-key :id))
         (controller (etaf-data-controller source :page-size 12 :auto-load t))
         (columns '((:key :name :width 12 :cell etaf-ui-cell-test--name)))
         (replacement (copy-sequence (nth 5 rows)))
         (row-ref (lambda (row) (intern (format "grid-row-%s" (plist-get row :id)))))
         pressed)
    (unwind-protect
        (etaf-ui-cell-test--with-buffer buffer
          (etaf-mount
           buffer
           (etaf-view
            (etaf-data-grid :controller controller :columns columns
                            :row-key #'etaf-ui-cell-test--row-key
                            :row-ref row-ref :on-row-press (lambda (row) (setq pressed row)))))
          (let ((runtime (etaf-runtime-for-buffer buffer)))
            (etaf-focus runtime 'grid-row-6)
            (setf (etaf-value (etaf-data-items controller))
                  (mapcar (lambda (row)
                            (if (= 6 (plist-get row :id)) replacement row)) rows))
            (etaf-dispatch-event runtime 'grid-row-6 'press)
            (should (eq pressed replacement))
            (should (eq (etaf-focused-host-ref runtime) 'grid-row-6))
            (setq replacement '(:id 6 :name "Changed"))
            (setf (etaf-value (etaf-data-items controller))
                  (mapcar (lambda (row)
                            (if (= 6 (plist-get row :id)) replacement row)) rows))
            (should (string-match-p "Changed" (with-current-buffer buffer (buffer-string))))
            (etaf-dispatch-event runtime 'grid-row-6 'press)
            (should (eq pressed replacement))
            (etaf-dispatch-event runtime 'grid-row-1 'press)
            (should (eq pressed (car rows)))
            (etaf-data-select-one controller 1)
            (etaf-data-select-one controller 2)
            (dolist (id '(1 2 6))
              (let ((class (plist-get (etaf-runtime-host-props-for
                                      runtime (funcall row-ref (list :id id))) :class)))
                (should (equal (not (null (string-match-p "selected" (format "%s" class))))
                               (= id 2)))))))
      (etaf-data-stop controller))))

(provide 'etaf-ui-cell-tests)
;;; etaf-ui-cell-tests.el ends here
