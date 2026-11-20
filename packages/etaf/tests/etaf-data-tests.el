;;; etaf-data-tests.el --- Public Data API acceptance -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Public tests for the standalone ETAF Data controller.

;;; Code:

(require 'cl-lib)
(require 'ert)
(require 'etaf)

(defconst etaf-data-test-records
  '((:id 1 :name "Ada" :group "compiler")
    (:id 2 :name "Grace" :group "systems")
    (:id 3 :name "Alan" :group "compiler")
    (:id 4 :name "Barbara" :group "compiler"))
  "Records shared by Data tests.")

(defun etaf-data-test--ids (items)
  "Return :id values from ITEMS."
  (mapcar (lambda (item) (etaf-data-test--record-value item :id)) items))

(defun etaf-data-test--controller-ids (controller)
  "Return current loaded ids from CONTROLLER."
  (etaf-data-test--ids (etaf-value (etaf-data-items controller))))

(defun etaf-data-test--record-value (record key)
  "Return RECORD value for KEY in test data."
  (cond
   ((hash-table-p record) (gethash key record))
   ((and (proper-list-p record) (keywordp (car record))) (plist-get record key))
   ((listp record) (alist-get key record nil nil #'equal))))

(defun etaf-data-test--wait (&optional seconds)
  "Let timers run for SECONDS."
  (accept-process-output nil (or seconds 0.05)))

(ert-deftest etaf-data-memory-source-loads-pages-and-query-forms ()
  "Memory sources support paging and all public query forms."
  (let* ((hash (make-hash-table :test #'equal))
         (records (append etaf-data-test-records
                          (list '((:id . 5) (:name . "Edsger") (:group . "systems"))
                                hash)))
         (source (etaf-data-memory-source records :id-key :id :name 'memory)))
    (puthash :id 6 hash)
    (puthash :name "Frances" hash)
    (puthash :group "compiler" hash)
    (should (equal (plist-get (etaf-data-source-capabilities source) :provider)
                   'memory))
    (should (equal '(1 2)
                   (etaf-data-test--ids
                    (plist-get (etaf-data-source-load-page source nil 1 2)
                               :items))))
    (should (equal '(3 4)
                   (etaf-data-test--ids
                    (plist-get (etaf-data-source-load-page source nil 2 2)
                               :items))))
    (should (= 4 (plist-get (etaf-data-source-load-page
                             source '(:group "compiler") 1 10)
                            :total)))
    (should (equal '(2 5)
                   (etaf-data-test--ids
                    (plist-get (etaf-data-source-load-page
                                source '((:group . "systems")) 1 10)
                               :items))))
    (should (equal '(1 3 4 6)
                   (etaf-data-test--ids
                    (plist-get (etaf-data-source-load-page
                                source (lambda (row)
                                         (equal (etaf-data-test--record-value row :group)
                                                "compiler"))
                                1 10)
                               :items))))
    (should (equal '(2)
                   (etaf-data-test--ids
                    (plist-get (etaf-data-source-load-page source "Grace" 1 10)
                               :items))))
    (should (equal (list (car etaf-data-test-records))
                   (plist-get (etaf-data-source-load-page
                               source (car etaf-data-test-records) 1 10)
                              :items)))))

(ert-deftest etaf-data-status-refreshing-retains-items ()
  "Refreshing keeps accepted items until the asynchronous completion lands."
  (let (resolve)
    (let* ((source (etaf-data-source
                    :load (lambda (_query _page _page-size)
                            (etaf-async
                             (lambda (ok _reject)
                               (setq resolve ok)
                               nil)))))
           (controller (etaf-data-controller
                        source :initial-result '(:items ((:id 1)) :total 1))))
      (unwind-protect
          (progn
            (should-not (etaf-data-load controller))
            (should (eq (etaf-value (etaf-data-status controller)) 'refreshing))
            (should (equal '((:id 1)) (etaf-value (etaf-data-items controller))))
            (funcall resolve '(:items ((:id 2)) :total 1))
            (should (eq (etaf-value (etaf-data-status controller)) 'success))
            (should (equal '(2) (etaf-data-test--controller-ids controller))))
        (etaf-data-stop controller)))))

(ert-deftest etaf-data-async-load-success-error-cancel-and-timeout ()
  "Asynchronous loads publish success, error, cancellation and timeout states."
  (let (resolve reject cancel-called)
    (let* ((source (etaf-data-source
                    :load (lambda (&rest _args)
                            (etaf-async
                             (lambda (ok fail)
                               (setq resolve ok
                                     reject fail)
                               (lambda () (setq cancel-called t)))))))
           (controller (etaf-data-controller source)))
      (unwind-protect
          (progn
            (should-not (etaf-data-load controller))
            (funcall resolve '(:items ((:id 7)) :total 1))
            (should (eq 'success (etaf-value (etaf-data-status controller))))
            (should (equal '(7) (etaf-data-test--controller-ids controller)))
            (etaf-data-load controller)
            (funcall reject '(error "network"))
            (should (eq 'error (etaf-value (etaf-data-status controller))))
            (should (equal '(7) (etaf-data-test--controller-ids controller)))
            (etaf-data-load controller)
            (etaf-data-cancel controller)
            (should cancel-called)
            (should (eq 'cancelled (etaf-value (etaf-data-status controller))))
            (should (eq 'etaf-async-cancelled
                        (car (etaf-value (etaf-data-error controller))))))
        (etaf-data-stop controller))))
  (let (cancelled)
    (let* ((source (etaf-data-source
                    :load (lambda (&rest _args)
                            (etaf-async
                             (lambda (_ok _fail)
                               (lambda () (setq cancelled t)))))))
           (controller (etaf-data-controller source :timeout 0.01)))
      (unwind-protect
          (progn
            (etaf-data-load controller)
            (etaf-data-test--wait 0.08)
            (should cancelled)
            (should (eq 'error (etaf-value (etaf-data-status controller))))
            (should (eq 'etaf-async-timeout
                        (car (etaf-value (etaf-data-error controller))))))
        (etaf-data-stop controller)))))

(ert-deftest etaf-data-memory-source-mutations-publish-outcomes ()
  "Memory insert, update, delete, replace and reset reconcile the controller."
  (let* ((source (etaf-data-memory-source etaf-data-test-records :id-key :id))
         (controller (etaf-data-controller source :page-size 10 :auto-load t)))
    (unwind-protect
        (progn
          (etaf-data-mutate controller 'insert '(:id 5 :name "Edsger" :group "systems"))
          (should (equal '(1 2 3 4 5) (etaf-data-test--controller-ids controller)))
          (should (eq 'committed
                      (plist-get (etaf-data-mutation-outcome controller) :certainty)))
          (etaf-data-mutate controller 'update '(:id 2 :name "Grace Hopper" :group "navy"))
          (should (equal "Grace Hopper"
                         (plist-get (cadr (etaf-value (etaf-data-items controller)))
                                    :name)))
          (etaf-data-mutate controller 'delete 1)
          (should (equal '(2 3 4 5) (etaf-data-test--controller-ids controller)))
          (etaf-data-mutate controller 'replace '(:id 3 :name "Alan Turing" :group "logic"))
          (should (member "Alan Turing"
                          (mapcar (lambda (row) (plist-get row :name))
                                  (etaf-value (etaf-data-items controller)))))
          (etaf-data-mutate controller 'reset '((:id 9 :name "Reset")))
          (should (equal '(9) (etaf-data-test--controller-ids controller))))
      (etaf-data-stop controller))))

(ert-deftest etaf-data-v2-certainty-outcomes-are-reported ()
  "V2 committed, rolled-back and unknown outcomes shape mutation envelopes."
  (let* ((rows '((:id 1)))
         (committed (etaf-data-source
                     :load (lambda (&rest _args) (list :items rows :total 1))
                     :mutate-v2 (lambda (_operation payload)
                                  (setq rows (list payload))
                                  (list :certainty 'committed :result payload))))
         (controller (etaf-data-controller committed :auto-load t)))
    (unwind-protect
        (progn
          (should (equal '(:id 2) (etaf-data-mutate controller 'replace '(:id 2))))
          (let ((outcome (etaf-data-mutation-outcome controller)))
            (should (eq 'committed (plist-get outcome :certainty)))
            (should (plist-get outcome :reconciliation-token)))
          (should (eq 'reconciled (etaf-data-reconciliation-state controller))))
      (etaf-data-stop controller)))
  (let* ((rolled (etaf-data-source
                  :load (lambda (&rest _args) '(:items nil :total 0))
                  :mutate-v2 (lambda (&rest _args)
                               '(:certainty rolled-back :error (error "nope")))))
         (controller (etaf-data-controller rolled)))
    (unwind-protect
        (progn
          (should-error (etaf-data-mutate controller 'insert '(:id 1)) :type 'error)
          (should (eq 'rolled-back
                      (plist-get (etaf-data-mutation-outcome controller) :certainty))))
      (etaf-data-stop controller)))
  (let* ((unknown (etaf-data-source
                   :load (lambda (&rest _args) '(:items nil :total 0))
                   :mutate-v2 (lambda (&rest _args)
                                '(:certainty external-unknown))))
         (controller (etaf-data-controller unknown)))
    (unwind-protect
        (progn
          (should-error (etaf-data-mutate controller 'insert '(:id 1))
                        :type 'etaf-data-error)
          (should (eq 'external-unknown
                      (plist-get (etaf-data-mutation-outcome controller)
                                 :certainty))))
      (etaf-data-stop controller))))

(ert-deftest etaf-data-async-mutation-publishes-pending-outcome ()
  "Asynchronous mutations expose pending and completed outcome envelopes."
  (let (resolve rows)
    (let* ((source (etaf-data-source
                    :load (lambda (&rest _args)
                            (list :items rows :total (length rows)))
                    :mutate (lambda (_operation payload)
                              (etaf-async
                               (lambda (ok _fail)
                                 (setq resolve (lambda ()
                                                 (setq rows (list payload))
                                                 (funcall ok payload)))
                                 nil)))))
           (controller (etaf-data-controller source)))
      (unwind-protect
          (progn
            (should-not (etaf-data-mutate controller 'insert '(:id 8)))
            (let ((outcome (etaf-data-mutation-outcome controller)))
              (should (plist-get outcome :pending-p))
              (should (eq 'external-unknown (plist-get outcome :certainty))))
            (funcall resolve)
            (let ((outcome (etaf-data-mutation-outcome controller)))
              (should-not (plist-get outcome :pending-p))
              (should (eq 'committed (plist-get outcome :certainty))))
            (should (equal '(8) (etaf-data-test--controller-ids controller))))
        (etaf-data-stop controller)))))

(ert-deftest etaf-data-mutate-many-reconciles-and-reports-prefix-failure ()
  "Mutate-many uses batch capabilities and records failure prefixes."
  (let ((batch-calls 0)
        rows)
    (let* ((source (etaf-data-source
                    :load (lambda (&rest _args) (list :items rows :total (length rows)))
                    :mutate-batch (lambda (operations)
                                    (cl-incf batch-calls)
                                    (setq rows (mapcar #'cadr operations))
                                    '((:changes 1) (:changes 2)))))
           (controller (etaf-data-controller source)))
      (unwind-protect
          (let ((result (etaf-data-mutate-many
                         controller '((insert (:id 1)) (insert (:id 2))))))
            (should (= 1 batch-calls))
            (should (equal '((:changes 1) (:changes 2))
                           (plist-get result :results)))
            (should (= 3 (plist-get result :changes)))
            (should (equal '(1 2) (etaf-data-test--controller-ids controller))))
        (etaf-data-stop controller))))
  (let ((calls 0))
    (let* ((source (etaf-data-source
                    :load (lambda (&rest _args) '(:items nil :total 0))
                    :mutate (lambda (_operation payload)
                              (cl-incf calls)
                              (when (= calls 2)
                                (error "second failed"))
                              (list :ok payload))))
           (controller (etaf-data-controller source)))
      (unwind-protect
          (progn
            (should-error
             (etaf-data-mutate-many controller
                                    '((insert (:id 1)) (insert (:id 2))))
             :type 'error)
            (let ((outcome (etaf-data-mutation-outcome controller)))
              (should (eq 'external-unknown (plist-get outcome :certainty)))
              (should (equal '((:ok (:id 1))) (plist-get outcome :results)))))
        (etaf-data-stop controller)))))

(ert-deftest etaf-data-retry-reconciliation-reloads-without-replaying-mutation ()
  "Retry reloads a committed mutation after read-side failure only once."
  (let ((mutations 0)
        (loads 0)
        (fail-load t))
    (let* ((source (etaf-data-source
                    :load (lambda (&rest _args)
                            (cl-incf loads)
                            (if fail-load
                                (error "refresh failed")
                              '(:items ((:id 10)) :total 1)))
                    :mutate-v2 (lambda (_operation payload)
                                 (cl-incf mutations)
                                 (list :certainty 'committed :result payload))))
           (controller (etaf-data-controller source)))
      (unwind-protect
          (progn
            (should-error (etaf-data-mutate controller 'insert '(:id 10))
                          :type 'error)
            (should (= 1 mutations))
            (should (= 1 loads))
            (should (eq 'reconciliation-error
                        (etaf-data-reconciliation-state controller)))
            (setq fail-load nil)
            (etaf-data-retry-reconciliation controller)
            (should (= 1 mutations))
            (should (= 2 loads))
            (should (equal '(10) (etaf-data-test--controller-ids controller)))
            (should (eq 'reconciled (etaf-data-reconciliation-state controller))))
        (etaf-data-stop controller)))))

(ert-deftest etaf-data-selection-apis-and-selected-ref-stability ()
  "Selection helpers maintain stable per-identity refs."
  (let* ((source (etaf-data-memory-source etaf-data-test-records :id-key :id))
         (controller (etaf-data-controller source :page-size 10 :auto-load t)))
    (unwind-protect
        (let ((one-a (etaf-data-selected-ref controller 1))
              (one-b (etaf-data-selected-ref controller 1))
              (two (etaf-data-selected-ref controller 2)))
          (should (eq one-a one-b))
          (should-not (etaf-value one-a))
          (etaf-data-select controller 1)
          (should (etaf-value one-a))
          (should-not (etaf-value two))
          (should (equal 1 (plist-get (etaf-data-selected-item controller) :id)))
          (etaf-data-select-one controller 2)
          (should-not (etaf-value one-a))
          (should (etaf-value two))
          (setf (etaf-value (etaf-data-selection controller)) '(1 2))
          (should (etaf-value one-a))
          (should (etaf-value two))
          (etaf-data-select controller 2 nil)
          (should (etaf-value one-a))
          (should-not (etaf-value two))
          (should (equal '(1) (etaf-value (etaf-data-selection controller)))))
      (etaf-data-stop controller))))

(ert-deftest etaf-data-stop-disposes-source-and-rejects-access ()
  "Stop returns cleanup errors, cancels work and rejects later operations."
  (let (cancelled)
    (let* ((source (etaf-data-source
                    :load (lambda (&rest _args)
                            (etaf-async
                             (lambda (_ok _fail)
                               (lambda () (setq cancelled t)))))
                    :dispose (lambda () (error "dispose failed"))))
           (controller (etaf-data-controller source)))
      (etaf-data-load controller)
      (let ((errors (etaf-data-stop controller)))
        (should cancelled)
        (should (= 1 (length errors)))
        (should (eq 'error (caar errors))))
      (should-error (etaf-data-load controller) :type 'etaf-data-stopped-error)
      (should-error (etaf-data-items controller) :type 'etaf-data-stopped-error))))

(ert-deftest etaf-data-initial-result-seeds-without-loading ()
  "Prepared initial results seed a successful controller."
  (let ((loads 0))
    (let* ((source (etaf-data-source
                    :load (lambda (_query page page-size)
                            (cl-incf loads)
                            (list :items '((:id 9)) :total 42
                                  :page page :page-size page-size))))
           (prepared (etaf-data-source-load-page source nil 3 5))
           (controller (etaf-data-controller source :initial-result prepared)))
      (unwind-protect
          (progn
            (should (= 1 loads))
            (should (eq 'success (etaf-value (etaf-data-status controller))))
            (should (equal '(9) (etaf-data-test--controller-ids controller)))
            (should (= 42 (etaf-value (etaf-data-total controller))))
            (should (= 3 (etaf-value (etaf-data-page controller))))
            (should (= 5 (etaf-value (etaf-data-page-size controller))))
            (should-error
             (etaf-data-controller source :initial-result prepared :auto-load t)))
        (etaf-data-stop controller)))))

(ert-deftest etaf-data-owner-scope-disposes-controller ()
  "Owner scope disposal stops its child controller."
  (let* ((scope (etaf-effect-scope :detached t))
         controller)
    (etaf-scope-run
     scope
     (lambda ()
       (setq controller
             (etaf-data-controller
              (etaf-data-memory-source etaf-data-test-records :id-key :id)
              :auto-load t))))
    (should (equal '(1 2 3 4) (etaf-data-test--controller-ids controller)))
    (etaf-scope-stop scope)
    (should-error (etaf-data-load controller) :type 'etaf-data-stopped-error)))

(ert-deftest etaf-data-completion-publishes-atomically ()
  "Items, total and status change in one observer turn for a completion."
  (let (resolve events stop)
    (let* ((source (etaf-data-source
                    :load (lambda (&rest _args)
                            (etaf-async
                             (lambda (ok _fail)
                               (setq resolve ok)
                               nil)))))
           (controller (etaf-data-controller source)))
      (unwind-protect
          (progn
            (setq stop
                  (etaf-watch
                   (lambda ()
                     (list (etaf-value (etaf-data-items controller))
                           (etaf-value (etaf-data-total controller))
                           (etaf-value (etaf-data-status controller))))
                   (lambda (new _old) (push new events))
                   :test #'equal))
            (etaf-data-load controller)
            (setq events nil)
            (funcall resolve '(:items ((:id 1) (:id 2)) :total 2))
            (should (= 1 (length events)))
            (should (equal '(((:id 1) (:id 2)) 2 success) (car events))))
        (when stop (funcall stop))
        (etaf-data-stop controller)))))

(provide 'etaf-data-tests)
;;; etaf-data-tests.el ends here
