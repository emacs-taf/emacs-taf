;;; etaf-ui-table-adaptive-tests.el --- Public API acceptance -*- lexical-binding: t; -*-

;;; Commentary:
;; Test supported package inputs, outputs, errors and lifecycle.
;; Internal implementation details are outside this contract.

;;; Code:
(require 'cl-lib)
(require 'ert)
(require 'etaf-ui)

(defvar etaf-ui-adaptive-test--states nil)

(defvar etaf-ui-adaptive-test--removed nil)

(etaf-define-component etaf-ui-adaptive-test-actions (&key row)
  "Keep independent action state in ROW's adaptive table cell."
  :setup
  (let ((state (list (plist-get row :id) (etaf-ref 0)
                     (etaf-inject 'adaptive-table-context nil t))))
    (push state etaf-ui-adaptive-test--states)
    (etaf-on-unmounted
     (lambda () (push (car state) etaf-ui-adaptive-test--removed)))
    state)
  :render
  (let ((count (cadr (etaf-state)))
        (id (plist-get row :id)))
    (etaf-view
     (row :item-gap '(ch 1)
      (etaf-button :label "Complete"
                   :ref (intern (format "adaptive-complete-%s" id))
                   :on-press (lambda () (cl-incf (etaf-value count))))
      (etaf-button :label "Delete"
                   :ref (intern (format "adaptive-delete-%s" id))
                   :on-press #'ignore)))))

(defun etaf-ui-adaptive-test--action-cell (row)
  "Build ROW's action cell, rejecting explicit bad candidates."
  (when (plist-get row :fail) (error "Rejected adaptive cell"))
  (etaf-node 'etaf-ui-adaptive-test-actions (list :row row) nil))

(etaf-define-component etaf-ui-adaptive-test-provider
    (&key rows columns controller theme selected)
  "Render a Table or CONTROLLER's DataGrid in the same themed environment."
  :setup
  (progn
    (etaf-provide 'adaptive-table-context "consumer-context")
    (etaf-theme-provide theme)
    nil)
  :render
  (let ((selection selected))
    (etaf-node
     (if controller 'etaf-data-grid 'etaf-table)
     (append
      (list :columns columns :row-key (lambda (row) (plist-get row :id))
            :row-ref (lambda (row) (intern (format "adaptive-row-%s" (plist-get row :id))))
            :on-row-press (lambda (row) (setf (etaf-value selection) (plist-get row :id)))
            :row-selected-p (lambda (row) (equal (etaf-value selection) (plist-get row :id))))
      (if controller (list :controller controller) (list :rows rows)))
     nil)))

(defun etaf-ui-adaptive-test--columns ()
  "Return an expanding title and a fixed character action track."
  (list '(:key :title :label "Task" :width (fr 1))
        '(:key :actions :label "Actions" :width 22
          :cell etaf-ui-adaptive-test--action-cell)))

(ert-deftest etaf-ui-adaptive-columns-reject-invalid-fractional-weights ()
  "Invalid fractional tracks identify the offending column before mounting."
  (dolist (width '((fr) (fr 0) (fr -1) (fr "wide") (fr 1 extra)))
    (let ((message
           (error-message-string
            (should-error
             (etaf-render
              (etaf-view
               (etaf-table
                :columns (list (list :key :title :width width))
                :rows nil :row-key #'identity)))))))
      (should (string-match-p "column 1 (:title)" message))
      (should (string-match-p "POSITIVE-WEIGHT" message)))))

(ert-deftest etaf-ui-adaptive-cells-retain-identity-and-failed-candidates ()
  "Adaptive row/column reorders preserve local state and rollback ownership."
  (let* ((etaf-ui-adaptive-test--states nil)
         (etaf-ui-adaptive-test--removed nil)
         (rows (etaf-ref '((:id 1 :title "First") (:id 2 :title "Second"))))
         (columns (etaf-ref (etaf-ui-adaptive-test--columns)))
         (theme (etaf-ref nil))
         (selected (etaf-ref nil))
         (buffer (generate-new-buffer " *adaptive-retention*")))
    (unwind-protect
        (progn
          (etaf-mount
           buffer
           (etaf-view
            (etaf-ui-adaptive-test-provider
             :rows (etaf-value rows) :columns (etaf-value columns)
             :theme theme :selected selected)))
          (let ((runtime (etaf-runtime-for-buffer buffer)))
            (etaf-runtime-refit (etaf-runtime-for-buffer buffer) 420 30)
            (etaf-dispatch-event runtime 'adaptive-complete-1 'press)
            ;; Width is geometry, not cell ownership.  Keep the same keys and
            ;; action Component through both fixed-to-fr and fr-to-fixed paths.
            (dolist (width '(18 (fr 1) 26 (fr 2)))
              (setf (etaf-value columns)
                    (list (list :key :title :label "Task" :width width)
                          (cadr (etaf-ui-adaptive-test--columns))))
              (should (= 2 (length etaf-ui-adaptive-test--states)))
              (should-not etaf-ui-adaptive-test--removed)
              (should (= 1 (etaf-value (cadr (assq 1 etaf-ui-adaptive-test--states))))))
            (setf (etaf-value columns) (reverse (etaf-value columns))
                  (etaf-value rows) (reverse (etaf-value rows)))
            (should (= 2 (length etaf-ui-adaptive-test--states)))
            (should-not etaf-ui-adaptive-test--removed)
            (let ((text (with-current-buffer buffer (buffer-string)))
                  (generation (etaf-runtime-revision runtime)))
              (should-error
               (setf (etaf-value rows)
                     '((:id 1 :title "Candidate") (:id 2 :title "Rejected" :fail t))))
              (should (eq generation (etaf-runtime-revision runtime)))
              (should (equal-including-properties text (with-current-buffer buffer (buffer-string)))))
            (etaf-dispatch-event runtime 'adaptive-complete-1 'press)
            (should (= 2 (etaf-value (cadr (assq 1 etaf-ui-adaptive-test--states)))))
            (setf (etaf-value rows) '((:id 1 :title "Recovered")))
            (should (equal '(2) etaf-ui-adaptive-test--removed))))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer))) (etaf-unmount runtime))
      (kill-buffer buffer))))

(ert-deftest etaf-ui-table-string-column-keys-read-equal-alist-keys ()
  "Table and DataGrid read string keys in both fixed and adaptive cells."
  (dolist (grid-p '(nil t))
    (dolist (width '(12 (fr 1)))
      (let* ((column-key (copy-sequence "name"))
             (row-key (copy-sequence "name"))
             (rows (list (list (cons :id 1) (cons row-key "Ada"))))
             (controller
              (and grid-p
                   (etaf-data-controller
                    (etaf-data-memory-source rows :id-key :id)
                    :page-size 10 :auto-load t)))
             (buffer (generate-new-buffer " *string-column-key*")))
        (should (equal column-key row-key))
        (should-not (eq column-key row-key))
        (unwind-protect
            (progn
              (etaf-mount
               buffer
               (etaf-node
                (if grid-p 'etaf-data-grid 'etaf-table)
                (append
                 (list :columns (list (list :key column-key :label "Name"
                                            :width width))
                       :row-key (lambda (row) (alist-get :id row)))
                 (if grid-p (list :controller controller) (list :rows rows)))
                nil)
               '(:viewport-width 300 :viewport-height 10))
              (should (string-match-p "Ada" (with-current-buffer buffer
                                               (buffer-string)))))
          (when-let* ((runtime (etaf-runtime-for-buffer buffer)))
            (etaf-unmount runtime))
          (when controller (etaf-data-stop controller))
          (kill-buffer buffer))))))

(provide 'etaf-ui-table-adaptive-tests)
;;; etaf-ui-table-adaptive-tests.el ends here
