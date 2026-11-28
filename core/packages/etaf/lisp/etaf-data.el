;;; etaf-data.el --- Data controller and sources -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; ETAF Data is a small reactive controller over explicit source capabilities.
;; A source is only a plist of callables; database, HTTP, file, and ORM
;; integrations belong in concrete source packages that provide those
;; callables.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'etaf-reactive)
(require 'etaf-observer)
(require 'etaf-async)

(define-error 'etaf-data-error "Invalid ETAF data operation")
(define-error 'etaf-data-stopped-error
  "ETAF data controller has been stopped"
  'etaf-data-error)

(defvar etaf-data--controller-id-counter 0)
(defvar etaf-data--operation-id-counter 0)
(defvar etaf-data--reconciliation-id-counter 0)

(cl-defstruct (etaf-data--controller
               (:constructor etaf-data--controller-create)
               (:predicate etaf-data-controller-p)
               (:conc-name etaf-data--controller-))
  "A reactive Data Controller."
  source scope query page page-size items total status error selection
  request-id request request-kind timeout loaded-p stopped-p auto-load-p
  item-key selection-snapshot selected-refs id mutation-outcome
  reconciliation-token last-load-key)

(defun etaf-data--signal-condition (condition)
  "Re-signal CONDITION data when non-nil."
  (when condition
    (signal (car condition) (cdr condition))))

(defun etaf-data--condition-object-p (condition)
  "Return non-nil when CONDITION is signalable condition data."
  (and (consp condition) (symbolp (car condition)) (proper-list-p (cdr condition))))

(defun etaf-data--capture-condition (function)
  "Call FUNCTION and return (:value VALUE) or (:condition CONDITION)."
  (condition-case condition
      (list :value (funcall function))
    ((error quit) (list :condition condition))))

(defun etaf-data-source (&rest capabilities)
  "Create a Data source from callable CAPABILITIES."
  (let ((load (plist-get capabilities :load))
        (provider (plist-get capabilities :provider)))
    (unless (functionp load)
      (signal 'wrong-type-argument (list 'functionp load)))
    (dolist (entry `((:mutate . ,(plist-get capabilities :mutate))
                    (:mutate-v2 . ,(plist-get capabilities :mutate-v2))
                    (:mutation-outcome . ,(plist-get capabilities :mutation-outcome))
                    (:mutate-batch . ,(plist-get capabilities :mutate-batch))
                    (:dispose . ,(plist-get capabilities :dispose))
                    (:item-key . ,(plist-get capabilities :item-key))))
      (when (and (cdr entry) (not (functionp (cdr entry))))
        (signal 'wrong-type-argument (list 'functionp (cdr entry)))))
    (when (and (plist-member capabilities :provider)
               (not (and provider (symbolp provider) (not (keywordp provider)))))
      (signal 'wrong-type-argument (list 'symbolp provider)))
    (append (list :etaf-data-source t) capabilities)))

(defun etaf-data-source-p (value)
  "Return non-nil when VALUE is an ETAF Data source."
  (and (listp value)
       (eq (plist-get value :etaf-data-source) t)
       (functionp (plist-get value :load))))

;;;###autoload
(defun etaf-data-source-capabilities (source)
  "Return a fresh plist of SOURCE's supported capabilities for composition."
  (unless (etaf-data-source-p source)
    (signal 'wrong-type-argument (list 'etaf-data-source-p source)))
  (cl-loop for key in '(:load :mutate :mutate-v2 :mutate-batch :dispose
                       :item-key :provider :name)
           when (plist-member source key)
           append (list key (plist-get source key))))

(defun etaf-data--source-function (source key required-p)
  "Return SOURCE capability KEY, requiring it when REQUIRED-P is non-nil."
  (unless (etaf-data-source-p source)
    (signal 'wrong-type-argument (list 'etaf-data-source-p source)))
  (let ((function (plist-get source key)))
    (when (and required-p (not (functionp function)))
      (signal 'etaf-data-error (list (format "ETAF Data source lacks %S capability" key))))
    function))

(defun etaf-data--source-provider (source)
  "Return SOURCE's observer provider."
  (or (plist-get source :provider) 'data))

(defun etaf-data--source-load (source query page page-size)
  "Invoke SOURCE load for QUERY, PAGE and PAGE-SIZE."
  (etaf-observer-with-stage
      ((etaf-data--source-provider source) 'load :page page :page-size page-size)
    (funcall (etaf-data--source-function source :load t) query page page-size)))

(defun etaf-data--source-mutate (source operation payload)
  "Invoke SOURCE v1 mutation OPERATION with PAYLOAD."
  (etaf-observer-with-stage
      ((etaf-data--source-provider source) 'mutate :operation operation)
    (funcall (etaf-data--source-function source :mutate t) operation payload)))

(defun etaf-data--source-mutate-v2-function (source)
  "Return SOURCE's optional v2 mutation function."
  (or (plist-get source :mutate-v2)
      (plist-get source :mutation-outcome)))

(defun etaf-data--source-mutate-v2 (source operation payload)
  "Invoke SOURCE v2 mutation OPERATION with PAYLOAD."
  (etaf-observer-with-stage
      ((etaf-data--source-provider source) 'mutate :operation operation
       :capability 'v2)
    (funcall (or (etaf-data--source-mutate-v2-function source)
                 (etaf-data--source-function source :mutate-v2 t))
             operation payload)))

(defun etaf-data--source-mutate-batch (source operations)
  "Invoke SOURCE batch mutation capability with OPERATIONS."
  (etaf-observer-with-stage
      ((etaf-data--source-provider source) 'mutate :operation 'mutate-many
       :capability 'batch)
    (funcall (etaf-data--source-function source :mutate-batch t) operations)))

(defun etaf-data--record-value (record key)
  "Return RECORD's value for KEY from plist, alist or hash table records."
  (cond
   ((hash-table-p record) (gethash key record))
   ((and (proper-list-p record) (zerop (% (length record) 2))
         (keywordp (car record)))
    (plist-get record key))
   ((listp record) (alist-get key record nil nil #'equal))
   (t nil)))

(defun etaf-data--record-matches-p (record query)
  "Return non-nil when RECORD matches memory source QUERY."
  (cond
   ((null query) t)
   ((functionp query) (funcall query record))
   ((stringp query)
    (string-match-p (regexp-quote (downcase query))
                    (downcase (prin1-to-string record))))
   ((and (listp query) (keywordp (car query)))
    (cl-loop for (key value) on query by #'cddr
             always (equal (etaf-data--record-value record key) value)))
   ((listp query)
    (cl-loop for (key . value) in query
             always (equal (etaf-data--record-value record key) value)))
   (t (equal record query))))

(defun etaf-data--slice (items page page-size)
  "Return ITEMS for PAGE and PAGE-SIZE."
  (let* ((safe-page (max 1 (or page 1)))
         (safe-page-size (max 1 (or page-size 20)))
         (start (* (1- safe-page) safe-page-size))
         (length (length items))
         (end (min length (+ start safe-page-size))))
    (cond ((>= start length) nil)
          ;; Source lists are replaced, never mutated, so a whole page shares them.
          ((and (zerop start) (= end length)) items)
          (t (cl-subseq items start end)))))

(defun etaf-data--memory-record-id (record id-key)
  "Return RECORD identity using ID-KEY."
  (if id-key (etaf-data--record-value record id-key) record))

(defun etaf-data--memory-replace (items id-key payload)
  "Return ITEMS with the record matching PAYLOAD replaced."
  (let* ((target-id (etaf-data--memory-record-id payload id-key))
         (matched-p nil)
         (next (mapcar (lambda (record)
                         (if (equal (etaf-data--memory-record-id record id-key)
                                    target-id)
                             (progn (setq matched-p t) payload)
                           record))
                       items)))
    (unless matched-p
      (error "No memory source record for id %S" target-id))
    next))

;;;###autoload
(cl-defun etaf-data-memory-source (items &key id-key name)
  "Create an in-memory Data source over ITEMS."
  (let ((records (etaf-ref (copy-sequence items)
                           :name (or name 'etaf-data-memory-source))))
    (etaf-data-source
     :name name
     :provider 'memory
     :item-key (and id-key
                    (lambda (record) (etaf-data--memory-record-id record id-key)))
     :load (lambda (query page page-size)
             (let* ((all (etaf-value records))
                    (filtered (if (null query) all
                                (cl-remove-if-not
                                 (lambda (record)
                                   (etaf-data--record-matches-p record query))
                                 all))))
               (list :items (etaf-data--slice filtered page page-size)
                     :total (length filtered)
                     :page (max 1 (or page 1))
                     :page-size (max 1 (or page-size 20)))))
     :mutate (lambda (operation payload)
               (pcase operation
                 ('insert
                  (setf (etaf-value records)
                        (append (etaf-value records) (list payload))))
                 ((or 'replace 'update)
                  (setf (etaf-value records)
                        (etaf-data--memory-replace (etaf-value records)
                                                   id-key payload)))
                 ('delete
                  (let ((target-id (if id-key payload
                                     (etaf-data--memory-record-id payload id-key))))
                    (setf (etaf-value records)
                          (cl-remove-if
                           (lambda (record)
                             (equal (etaf-data--memory-record-id record id-key)
                                    target-id))
                           (etaf-value records)))))
                 ('reset
                  (setf (etaf-value records) (copy-sequence payload)))
                 (_ (error "Unsupported memory source mutation: %S" operation)))
               (etaf-value records)))))

(defun etaf-data--normalize-result (result)
  "Return normalized source RESULT or signal."
  (unless (and (listp result) (or (null result) (keywordp (car result))))
    (error "ETAF Data source load must return a plist: %S" result))
  (unless (plist-member result :items)
    (error "ETAF Data source load result lacks :items"))
  result)

;;;###autoload
(defun etaf-data-source-load-page (source &optional query page page-size)
  "Load and normalize one SOURCE page without creating a Controller."
  (let* ((page (max 1 (or page 1)))
         (page-size (max 1 (or page-size 20)))
         (result (etaf-data--source-load source query page page-size)))
    (when (etaf--async-p result)
      (signal 'etaf-async-error
              (list "Asynchronous sources require a Data Controller")))
    (etaf-data--normalize-result result)))

(defun etaf-data--require-controller (controller)
  "Return CONTROLLER or signal when it is invalid or stopped."
  (unless (etaf-data-controller-p controller)
    (signal 'wrong-type-argument (list 'etaf-data-controller-p controller)))
  (when (etaf-data--controller-stopped-p controller)
    (signal 'etaf-data-stopped-error (list controller)))
  controller)

(defun etaf-data--mutation-outcome (controller)
  "Read CONTROLLER's mutation outcome ref."
  (etaf-value (etaf-data--controller-mutation-outcome controller)))

(gv-define-setter etaf-data--mutation-outcome (value controller)
  `(etaf-set-value (etaf-data--controller-mutation-outcome ,controller) ,value))

(defun etaf-data--item-identity (controller item)
  "Return ITEM's selection identity in CONTROLLER."
  (if-let* ((item-key (etaf-data--controller-item-key controller)))
      (funcall item-key item)
    item))

(defun etaf-data--ensure-selected-ref (controller identity)
  "Return CONTROLLER's stable boolean ref for IDENTITY."
  (let* ((refs (etaf-data--controller-selected-refs controller))
         (existing (gethash identity refs)))
    (or existing
        ;; Rows read these refs while binding, so creation must not count
        ;; as a rendering side effect: the controller owns the ref.
        (let ((created (etaf--ref-create
                        :value (not (null (member identity
                                                  (etaf-data--controller-selection-snapshot
                                                   controller))))
                        :name 'etaf-data-selected)))
          (puthash identity created refs)
          created))))

(defun etaf-data--prepare-selected-refs (controller)
  "Ensure selection refs exist for CONTROLLER's selected identities.
Refs for other loaded items are created when a row first asks for them."
  (dolist (identity (etaf-data--controller-selection-snapshot controller))
    (etaf-data--ensure-selected-ref controller identity)))

(defun etaf-data--make-load-key (controller &optional normalized)
  "Return CONTROLLER auto-load key, using NORMALIZED page metadata when present."
  (list (etaf-value (etaf-data--controller-query controller))
        (if (and normalized (plist-member normalized :page))
            (plist-get normalized :page)
          (etaf-value (etaf-data--controller-page controller)))
        (if (and normalized (plist-member normalized :page-size))
            (plist-get normalized :page-size)
          (etaf-value (etaf-data--controller-page-size controller)))))

(defun etaf-data--token-put (token key value)
  "Set KEY to VALUE in TOKEN and return TOKEN."
  (let ((cell token))
    (while (and cell (not (eq key (car cell))))
      (setq cell (cddr cell)))
    (if cell
        (setcar (cdr cell) value)
      (nconc token (list key value))))
  token)

(defun etaf-data--make-reconciliation-token
    (controller operation-id certainty result &optional adapter-token)
  "Create an opaque reconciliation token for CONTROLLER."
  (let ((id (cl-incf etaf-data--reconciliation-id-counter)))
    (let ((token (list :etaf-data-reconciliation-token/v1 id
                       :etaf-data-token t
                       :id id
                       :controller-id (etaf-data--controller-id controller)
                       :operation-id operation-id
                       :certainty certainty
                       :external-commit-certainty certainty
                       :result result
                       :mutation-result result
                       :state (pcase certainty
                                ('committed 'reconciliation-pending)
                                ('rolled-back 'rolled-back)
                                ('external-unknown 'external-unknown)
                                (_ 'external-unknown))
                       :attempt 0)))
      (when adapter-token
        (etaf-data--token-put token :adapter-token adapter-token))
      token)))

(defun etaf-data--normalize-mutation-outcome (raw &optional v2-p)
  "Normalize RAW mutation result into a public outcome envelope."
  (if (not v2-p)
      (list :certainty 'committed
            :external-commit-certainty 'committed
            :result raw
            :mutation-result raw)
    (unless (and (proper-list-p raw)
                 (zerop (% (length raw) 2))
                 (cl-loop for (key _value) on raw by #'cddr always (keywordp key)))
      (error "ETAF Data v2 mutation outcome is not a plist: %S" raw))
    (let* ((certainty (or (plist-get raw :certainty)
                          (plist-get raw :external-commit-certainty)))
           (external (or (plist-get raw :external-commit-certainty) certainty))
           (has-result (plist-member raw :result))
           (has-mutation-result (plist-member raw :mutation-result))
           (result (and has-result (plist-get raw :result)))
           (mutation-result (and has-mutation-result (plist-get raw :mutation-result)))
           (error-data (and (plist-member raw :error) (plist-get raw :error))))
      (unless (eq certainty external)
        (error "ETAF Data v2 mutation outcome has conflicting certainty: %S" raw))
      (unless (memq certainty '(committed rolled-back external-unknown))
        (error "ETAF Data v2 mutation outcome has invalid certainty: %S" certainty))
      (when (and has-result has-mutation-result (not (equal result mutation-result)))
        (error "ETAF Data v2 mutation outcome has conflicting results: %S" raw))
      (when (and (eq certainty 'committed) (not (or has-result has-mutation-result)))
        (error "ETAF Data v2 committed outcome lacks a mutation result: %S" raw))
      (when (and (eq certainty 'committed) error-data)
        (error "ETAF Data v2 committed outcome cannot carry :error: %S" raw))
      (when (and error-data (not (etaf-data--condition-object-p error-data)))
        (error "ETAF Data v2 outcome :error is not a condition: %S" raw))
      (when (and (eq certainty 'rolled-back)
                 (not (etaf-data--condition-object-p error-data)))
        (error "ETAF Data v2 rolled-back outcome lacks a condition: %S" raw))
      (list :certainty certainty
            :external-commit-certainty certainty
            :result (if has-result result mutation-result)
            :mutation-result (if has-mutation-result mutation-result result)
            :reconciliation-token (plist-get raw :reconciliation-token)
            :error error-data
            :raw raw))))

(defun etaf-data--publish-loading (controller request-id &optional outcome)
  "Publish a loading marker for current REQUEST-ID."
  (when (= request-id (etaf-data--controller-request-id controller))
    (etaf-batch
      (when outcome
        (setf (etaf-data--mutation-outcome controller) outcome))
      (setf (etaf-value (etaf-data--controller-error controller)) nil
            (etaf-value (etaf-data--controller-status controller))
            (if (and (etaf-data--controller-loaded-p controller)
                     (eq (etaf-data--controller-request-kind controller) 'load))
                'refreshing
              'loading)))))

(defun etaf-data--publish-success
    (controller request-id result &optional outcome token)
  "Publish successful RESULT for current REQUEST-ID."
  (when (= request-id (etaf-data--controller-request-id controller))
    (let ((normalized (etaf-data--normalize-result result)))
      (etaf-data--prepare-selected-refs controller)
      (etaf-batch
        (when token
          (etaf-data--token-put token :state 'reconciled)
          (setf (etaf-data--controller-reconciliation-token controller) token))
        (when outcome
          (setf (etaf-data--mutation-outcome controller) outcome))
        (setf (etaf-value (etaf-data--controller-items controller))
              (plist-get normalized :items)
              (etaf-value (etaf-data--controller-total controller))
              (or (plist-get normalized :total)
                  (length (plist-get normalized :items))))
        (when (plist-member normalized :page)
          (setf (etaf-value (etaf-data--controller-page controller))
                (plist-get normalized :page)))
        (when (plist-member normalized :page-size)
          (setf (etaf-value (etaf-data--controller-page-size controller))
                (plist-get normalized :page-size)))
        (setf (etaf-value (etaf-data--controller-error controller)) nil
              (etaf-value (etaf-data--controller-status controller)) 'success
              (etaf-data--controller-loaded-p controller) t
              (etaf-data--controller-last-load-key controller)
              (etaf-data--make-load-key controller normalized)))
      result)))

(defun etaf-data--publish-error
    (controller request-id condition &optional outcome token)
  "Publish CONDITION as current REQUEST-ID's terminal error state."
  (when (= request-id (etaf-data--controller-request-id controller))
    (etaf-batch
      (when token
        (when (eq (plist-get token :state) 'reconciliation-pending)
          (etaf-data--token-put token :state 'reconciliation-error))
        (setf (etaf-data--controller-reconciliation-token controller) token))
      (when outcome
        (setf (etaf-data--mutation-outcome controller) outcome))
      (setf (etaf-value (etaf-data--controller-error controller)) condition
            (etaf-value (etaf-data--controller-status controller))
            (if (eq (car condition) 'etaf-async-cancelled) 'cancelled 'error)))))

(defun etaf-data--finish-load
    (controller request-id result source-condition outcome token)
  "Publish one load completion and return its result/condition envelope."
  (if source-condition
      (progn
        (etaf-data--publish-error controller request-id source-condition outcome token)
        (list :request-id request-id :condition source-condition
              :source-condition source-condition))
    (let ((normalization (etaf-data--capture-condition
                          (lambda () (etaf-data--normalize-result result)))))
      (if-let* ((condition (plist-get normalization :condition)))
          (progn
            (etaf-data--publish-error controller request-id condition outcome token)
            (list :request-id request-id :condition condition
                  :source-condition condition))
        (etaf-data--publish-success controller request-id result outcome token)
        (list :request-id request-id :result result)))))

(defun etaf-data--begin-request (controller kind)
  "Cancel obsolete work and begin a request of KIND."
  (etaf--assert-not-rendering 'load-data)
  (let ((previous (etaf-data--controller-request controller))
        (previous-kind (etaf-data--controller-request-kind controller)))
    (when (and previous (etaf--load-task-pending-p previous)
               (eq kind 'mutate) (eq previous-kind 'mutate))
      (signal 'etaf-data-error (list "A mutation is already pending")))
    (etaf--load-abort previous
                      (when (eq previous-kind 'mutate)
                        '(etaf-async-cancelled))))
  (setf (etaf-data--controller-request-kind controller) kind)
  (cl-incf (etaf-data--controller-request-id controller)))

(defun etaf-data--load-request (controller &optional outcome token)
  "Start a load, optionally reconciling mutation OUTCOME and TOKEN."
  (let* ((request-id (etaf-data--begin-request controller 'load))
         (envelope (list :request-id request-id :pending-p t))
         task)
    (setf (etaf-data--controller-last-load-key controller)
          (etaf-data--make-load-key controller))
    (setq task
          (etaf--load-task-create
           :scope (etaf-data--controller-scope controller)
           :timeout (etaf-data--controller-timeout controller)
           :success (lambda (raw)
                      (unless (etaf-data--controller-stopped-p controller)
                        (setq envelope
                              (etaf-data--finish-load
                               controller request-id raw nil outcome token))))
           :failure (lambda (condition)
                      (unless (etaf-data--controller-stopped-p controller)
                        (setq envelope
                              (etaf-data--finish-load
                               controller request-id nil condition outcome token))))))
    (setf (etaf-data--controller-request controller) task)
    (etaf-data--publish-loading controller request-id outcome)
    (etaf--load-start
     task
     (lambda ()
       (etaf-data--source-load
        (etaf-data--controller-source controller)
        (etaf-value (etaf-data--controller-query controller))
        (etaf-value (etaf-data--controller-page controller))
        (etaf-value (etaf-data--controller-page-size controller)))))
    envelope))

;;;###autoload
(cl-defun etaf-data-controller
    (source &key query (page 1) (page-size 20) selection auto-load name
            item-key owner-scope initial-result timeout)
  "Create a reactive Data Controller for SOURCE."
  (etaf--load-check-timeout timeout)
  (unless (etaf-data-source-p source)
    (signal 'wrong-type-argument (list 'etaf-data-source-p source)))
  (setq item-key (or item-key (plist-get source :item-key)))
  (unless (or (null item-key) (functionp item-key))
    (signal 'wrong-type-argument (list 'functionp item-key)))
  (when (and initial-result auto-load)
    (error "ETAF Data :initial-result and :auto-load are mutually exclusive"))
  (let* ((initial-result (and initial-result
                              (etaf-data--normalize-result initial-result)))
         (initial-items (and initial-result (plist-get initial-result :items)))
         (initial-page (if (and initial-result (plist-member initial-result :page))
                           (plist-get initial-result :page)
                         page))
         (initial-page-size (if (and initial-result
                                     (plist-member initial-result :page-size))
                                (plist-get initial-result :page-size)
                              page-size))
         (owner-scope (or owner-scope (etaf-current-effect-scope)))
         (scope (if owner-scope
                    (etaf-scope-run
                     owner-scope
                     (lambda () (etaf-effect-scope :name (or name 'etaf-data))))
                  (etaf-effect-scope :detached t :name (or name 'etaf-data))))
         (controller
          (etaf-data--controller-create
           :source source
           :scope scope
           :query (etaf-ref query :name 'etaf-data-query)
           :page (etaf-ref initial-page :name 'etaf-data-page)
           :page-size (etaf-ref initial-page-size :name 'etaf-data-page-size)
           :items (etaf-ref initial-items :name 'etaf-data-items)
           :total (etaf-ref (if initial-result
                                (or (plist-get initial-result :total)
                                    (length initial-items))
                              0)
                            :name 'etaf-data-total)
           :status (etaf-ref (if initial-result 'success 'idle)
                             :name 'etaf-data-status)
           :error (etaf-ref nil :name 'etaf-data-error)
           :selection (etaf-ref (copy-sequence selection)
                                :name 'etaf-data-selection)
           :selection-snapshot (copy-sequence selection)
           :selected-refs (make-hash-table :test #'equal)
           :id (cl-incf etaf-data--controller-id-counter)
           :mutation-outcome (etaf-ref nil :name 'etaf-data-mutation-outcome)
           :request-id 0
           :timeout timeout
           :loaded-p (not (null initial-result))
           :auto-load-p auto-load
           :last-load-key (and initial-result nil)
           :item-key item-key)))
    (when initial-result
      (setf (etaf-data--controller-last-load-key controller)
            (etaf-data--make-load-key controller initial-result)))
    (etaf-data--prepare-selected-refs controller)
    (etaf-scope-run
        scope
      (lambda ()
        (etaf-watch
         (etaf-data--controller-selection controller)
         (lambda (new-selection old-selection)
           (setf (etaf-data--controller-selection-snapshot controller)
                 (copy-sequence new-selection))
           (dolist (identity new-selection)
             (etaf-data--ensure-selected-ref controller identity))
           (let ((old-set (make-hash-table :test #'equal))
                 (new-set (make-hash-table :test #'equal))
                 (selected-refs (etaf-data--controller-selected-refs controller)))
             (dolist (identity old-selection) (puthash identity t old-set))
             (dolist (identity new-selection) (puthash identity t new-set))
             (maphash (lambda (identity _present)
                        (unless (gethash identity new-set)
                          (when-let* ((selected-ref (gethash identity selected-refs)))
                            (setf (etaf-value selected-ref) nil))))
                      old-set)
             (maphash (lambda (identity _present)
                        (unless (gethash identity old-set)
                          (when-let* ((selected-ref (gethash identity selected-refs)))
                            (setf (etaf-value selected-ref) t))))
                      new-set)))
         :name 'etaf-data-selection-index)
        (when auto-load
          (etaf-watch
           (lambda () (etaf-data--make-load-key controller))
           (lambda (key _old)
             (when (and (etaf-data--controller-auto-load-p controller)
                        (not (etaf-data--controller-stopped-p controller))
                        (not (equal key (etaf-data--controller-last-load-key controller))))
               (etaf-data-load controller)))
           :immediate t
           :test #'equal
           :name 'etaf-data-auto-load))
        (etaf-on-scope-dispose
         (lambda ()
           (setf (etaf-data--controller-stopped-p controller) t)
           (unwind-protect
               (etaf--load-abort (etaf-data--controller-request controller))
             (setf (etaf-data--controller-request controller) nil)
             (clrhash (etaf-data--controller-selected-refs controller))
             (when-let* ((dispose (etaf-data--source-function source :dispose nil)))
               (funcall dispose)))))))
    controller))

;;;###autoload
(defun etaf-data-load (controller)
  "Start CONTROLLER's source load; return the synchronous result or nil pending."
  (etaf-data--require-controller controller)
  (let ((request (etaf-data--load-request controller)))
    (etaf-data--signal-condition (plist-get request :condition))
    (plist-get request :result)))

;;;###autoload
(defun etaf-data-reload (controller)
  "Reload CONTROLLER; return the synchronous result or nil while pending."
  (etaf-data-load controller))

(defun etaf-data--finalize-outcome (controller operation-id outcome)
  "Attach a Data reconciliation token to OUTCOME."
  (let* ((result (or (plist-get outcome :mutation-result)
                     (plist-get outcome :result)))
         (token (etaf-data--make-reconciliation-token
                 controller operation-id (plist-get outcome :certainty) result
                 (plist-get outcome :reconciliation-token))))
    (setq outcome (plist-put outcome :reconciliation-token token))
    (setf (etaf-data--controller-reconciliation-token controller) token)
    outcome))

(defun etaf-data--finish-mutation
    (controller operation operation-id request-id v2-p raw condition)
  "Publish mutation completion and reconcile committed outcomes."
  (let (outcome)
    (setq outcome
          (cond
           (condition
            (list :certainty 'external-unknown
                  :external-commit-certainty 'external-unknown
                  :result nil :mutation-result nil
                  :error condition))
           (v2-p
            (let ((normalized (etaf-data--capture-condition
                               (lambda () (etaf-data--normalize-mutation-outcome raw t)))))
              (if-let* ((normalization-error (plist-get normalized :condition)))
                  (list :certainty 'external-unknown
                        :external-commit-certainty 'external-unknown
                        :result nil :mutation-result nil
                        :error normalization-error
                        :raw raw)
                (plist-get normalized :value))))
           (t (etaf-data--normalize-mutation-outcome raw nil))))
    (setq outcome (append outcome (list :operation operation
                                        :operation-id operation-id
                                        :pending-p nil)))
    (setq outcome (etaf-data--finalize-outcome controller operation-id outcome))
    (if (eq (plist-get outcome :certainty) 'committed)
        (let ((request (etaf-data--load-request controller outcome
                                                (plist-get outcome :reconciliation-token))))
          (plist-put request :result (plist-get outcome :mutation-result)))
      (let ((failure (or (plist-get outcome :error)
                         (list 'etaf-data-error
                               (format "ETAF Data mutation %S was %s"
                                       operation (plist-get outcome :certainty))))))
        (etaf-data--publish-error controller request-id failure outcome
                                  (plist-get outcome :reconciliation-token))
        (list :condition failure :source-condition failure)))))

;;;###autoload
(defun etaf-data-mutate (controller operation payload)
  "Run source OPERATION with PAYLOAD and then reconcile its result."
  (etaf-data--require-controller controller)
  (let* ((source (etaf-data--controller-source controller))
         (operation-id (cl-incf etaf-data--operation-id-counter))
         (request-id (etaf-data--begin-request controller 'mutate))
         (v2-p (functionp (etaf-data--source-mutate-v2-function source)))
         (invoked nil)
         result condition task)
    (setf (etaf-data--controller-reconciliation-token controller) nil)
    (setq task
          (etaf--load-task-create
           :scope (etaf-data--controller-scope controller)
           :timeout (etaf-data--controller-timeout controller)
           :success (lambda (raw)
                      (when (and (not (etaf-data--controller-stopped-p controller))
                                 (= request-id (etaf-data--controller-request-id controller)))
                        (let ((completion (etaf-data--finish-mutation
                                           controller operation operation-id
                                           request-id v2-p raw nil)))
                          (setq result (plist-get completion :result)
                                condition (plist-get completion :condition)))))
           :failure (lambda (error-data)
                      (when (and (not (etaf-data--controller-stopped-p controller))
                                 (= request-id (etaf-data--controller-request-id controller)))
                        (let ((completion (etaf-data--finish-mutation
                                           controller operation operation-id
                                           request-id v2-p nil error-data)))
                          (setq result (plist-get completion :result)
                                condition (plist-get completion :condition)))))))
    (setf (etaf-data--controller-request controller) task)
    (etaf-data--publish-loading
     controller request-id
     (list :certainty 'external-unknown
           :external-commit-certainty 'external-unknown
           :pending-p t
           :operation operation
           :operation-id operation-id))
    (condition-case err
        (etaf--load-start
         task
         (lambda ()
           (setq invoked t)
           (if v2-p
               (etaf-data--source-mutate-v2 source operation payload)
             (etaf-data--source-mutate source operation payload))))
      ((error quit)
       (etaf--load-abort task)
       (let* ((certainty (if invoked 'external-unknown 'rolled-back))
              (outcome (list :certainty certainty
                             :external-commit-certainty certainty
                             :pending-p nil
                             :operation operation
                             :operation-id operation-id
                             :error err)))
         (setf (etaf-data--mutation-outcome controller) outcome))
       (signal (car err) (cdr err))))
    (etaf-data--signal-condition condition)
    result))

(defun etaf-data--normalize-mutation-operations (operations)
  "Return validated mutation OPERATIONS."
  (unless (and (listp operations) operations)
    (signal 'etaf-data-error
            (list "ETAF Data mutate-many needs a non-empty operation list")))
  (mapcar (lambda (entry)
            (unless (and (proper-list-p entry) (= 2 (length entry)) (car entry))
              (signal 'etaf-data-error
                      (list (format "ETAF Data mutation entry must be (OPERATION PAYLOAD): %S"
                                    entry))))
            (list (car entry) (cadr entry)))
          operations))

(defun etaf-data--mutation-changes (results)
  "Return summed :changes in RESULTS when every reporting value is integral."
  (let ((changes (delq nil (mapcar (lambda (result)
                                     (and (listp result) (plist-get result :changes)))
                                   results))))
    (when (and changes (cl-every #'integerp changes))
      (apply #'+ changes))))

;;;###autoload
(defun etaf-data-mutate-many (controller operations)
  "Apply OPERATIONS to CONTROLLER's source and reconcile once."
  (etaf-data--require-controller controller)
  (let* ((operations (etaf-data--normalize-mutation-operations operations))
         (source (etaf-data--controller-source controller))
         (batch-function (plist-get source :mutate-batch))
         (operation-id (cl-incf etaf-data--operation-id-counter))
         (request-id (etaf-data--begin-request controller 'mutate))
         completed results condition invoked)
    (setf (etaf-data--controller-reconciliation-token controller) nil)
    (etaf-data--publish-loading
     controller request-id
     (list :certainty 'external-unknown
           :external-commit-certainty 'external-unknown
           :pending-p t
           :operation 'mutate-many
           :operation-id operation-id))
    (condition-case err
        (progn
          (setq invoked t)
          (setq results
                (if (functionp batch-function)
                    (let ((raw (etaf-data--source-mutate-batch source operations)))
                      (when (etaf--async-p raw)
                        (signal 'etaf-data-error
                                (list "ETAF Data :mutate-batch must complete synchronously")))
                      (unless (and (proper-list-p raw)
                                   (= (length raw) (length operations)))
                        (signal 'etaf-data-error
                                (list (format "ETAF Data :mutate-batch returned %S results for %S operations"
                                              (safe-length raw)
                                              (length operations)))))
                      (when (cl-some #'etaf--async-p raw)
                        (signal 'etaf-data-error
                                (list "ETAF Data :mutate-batch must complete synchronously")))
                      raw)
                  (dolist (entry operations)
                    (let ((raw (etaf-data--source-mutate source (car entry) (cadr entry))))
                      (when (etaf--async-p raw)
                        (signal 'etaf-data-error
                                (list "ETAF Data mutate-many requires synchronous :mutate results")))
                      (push raw completed)))
                  (nreverse completed))))
      ((error quit) (setq condition err)))
    (let* ((result (and (null condition)
                        (append (list :operation 'mutate-many :results results)
                                (when-let* ((changes (etaf-data--mutation-changes results)))
                                  (list :changes changes)))))
           (outcome (if condition
                        (list :certainty 'external-unknown
                              :external-commit-certainty 'external-unknown
                              :result nil :mutation-result nil
                              :error condition
                              :results (nreverse completed)
                              :operation 'mutate-many
                              :operation-id operation-id
                              :pending-p nil)
                      (list :certainty 'committed
                            :external-commit-certainty 'committed
                            :result result :mutation-result result
                            :operation 'mutate-many
                            :operation-id operation-id
                            :pending-p nil))))
      (setq outcome (if invoked
                        (etaf-data--finalize-outcome controller operation-id outcome)
                      outcome))
      (if condition
          (progn
            (etaf-data--publish-error controller request-id condition outcome
                                      (plist-get outcome :reconciliation-token))
            (etaf-data--signal-condition condition))
        (let ((request (etaf-data--load-request
                        controller outcome (plist-get outcome :reconciliation-token))))
          (etaf-data--signal-condition (plist-get request :condition))
          result)))))

;;;###autoload
(defun etaf-data-cancel (controller)
  "Cancel CONTROLLER's pending request without stopping it; return CONTROLLER."
  (etaf--assert-not-rendering 'cancel-data)
  (etaf-data--require-controller controller)
  (etaf--load-abort (etaf-data--controller-request controller) '(etaf-async-cancelled))
  controller)

;;;###autoload
(defun etaf-data-retry-reconciliation (controller)
  "Reload a committed mutation without replaying its source mutation."
  (setq controller (etaf-data--require-controller controller))
  (let* ((outcome (etaf-data--mutation-outcome controller))
         (token (and outcome (plist-get outcome :reconciliation-token))))
    (when (and outcome token
               (eq (plist-get outcome :certainty) 'committed)
               (memq (plist-get token :state)
                     '(reconciliation-pending reconciliation-error)))
      (etaf-data--token-put token :attempt (1+ (or (plist-get token :attempt) 0)))
      (let ((request (etaf-data--load-request controller outcome token)))
        (etaf-data--signal-condition (plist-get request :condition))
        (plist-get request :result)))))

;;;###autoload
(defun etaf-data-stop (controller)
  "Stop CONTROLLER, dispose its Scope, and return cleanup errors."
  (unless (etaf-data-controller-p controller)
    (signal 'wrong-type-argument (list 'etaf-data-controller-p controller)))
  (unless (etaf-data--controller-stopped-p controller)
    (setf (etaf-data--controller-stopped-p controller) t)
    (etaf-scope-stop (etaf-data--controller-scope controller))))

(defun etaf-data-query (controller)
  "Return CONTROLLER's query ref."
  (etaf-data--controller-query (etaf-data--require-controller controller)))

(defun etaf-data-page (controller)
  "Return CONTROLLER's page ref."
  (etaf-data--controller-page (etaf-data--require-controller controller)))

(defun etaf-data-page-size (controller)
  "Return CONTROLLER's page-size ref."
  (etaf-data--controller-page-size (etaf-data--require-controller controller)))

(defun etaf-data-items (controller)
  "Return CONTROLLER's loaded items ref."
  (etaf-data--controller-items (etaf-data--require-controller controller)))

(defun etaf-data-total (controller)
  "Return CONTROLLER's total matching item count ref."
  (etaf-data--controller-total (etaf-data--require-controller controller)))

(defun etaf-data-status (controller)
  "Return CONTROLLER's status ref."
  (etaf-data--controller-status (etaf-data--require-controller controller)))

(defun etaf-data-error (controller)
  "Return CONTROLLER's observable error ref."
  (etaf-data--controller-error (etaf-data--require-controller controller)))

;;;###autoload
(defun etaf-data-mutation-outcome (controller)
  "Return a copy of CONTROLLER's latest mutation outcome envelope."
  (copy-tree (etaf-data--mutation-outcome
              (etaf-data--require-controller controller))))

;;;###autoload
(defun etaf-data-reconciliation-token (controller)
  "Return CONTROLLER's current opaque reconciliation token, if any."
  (copy-tree (etaf-data--controller-reconciliation-token
              (etaf-data--require-controller controller))))

;;;###autoload
(defun etaf-data-reconciliation-state (controller)
  "Return CONTROLLER's current reconciliation state symbol, if any."
  (let ((token (etaf-data--controller-reconciliation-token
                (etaf-data--require-controller controller))))
    (and token (plist-get token :state))))

(defun etaf-data-selection (controller)
  "Return CONTROLLER's selected identity list ref."
  (etaf-data--controller-selection (etaf-data--require-controller controller)))

;;;###autoload
(defun etaf-data-item-identity (controller item)
  "Return ITEM's stable selection identity in CONTROLLER."
  (etaf-data--item-identity (etaf-data--require-controller controller) item))

;;;###autoload
(defun etaf-data-selected-ref (controller identity)
  "Return CONTROLLER's stable boolean selection ref for IDENTITY."
  (etaf-data--ensure-selected-ref (etaf-data--require-controller controller) identity))

;;;###autoload
(defun etaf-data-selected-item (controller &optional item-key)
  "Return the loaded item matching CONTROLLER's first selected identity."
  (let* ((controller (etaf-data--require-controller controller))
         (identity (car (etaf-value (etaf-data-selection controller))))
         (items (etaf-value (etaf-data-items controller)))
         (key (or item-key (etaf-data--controller-item-key controller) #'identity)))
    (when identity
      (cl-find identity items :key key :test #'equal))))

;;;###autoload
(defun etaf-data-set-query (controller query)
  "Set CONTROLLER query to QUERY and return QUERY."
  (setf (etaf-value (etaf-data-query controller)) query))

;;;###autoload
(defun etaf-data-set-page (controller page)
  "Set CONTROLLER page to PAGE and return PAGE."
  (setf (etaf-value (etaf-data-page controller)) page))

;;;###autoload
(defun etaf-data-set-page-size (controller page-size)
  "Set CONTROLLER page size to PAGE-SIZE and return PAGE-SIZE."
  (setf (etaf-value (etaf-data-page-size controller)) page-size))

;;;###autoload
(defun etaf-data-next-page (controller)
  "Move CONTROLLER to the next page and return the new page."
  (setq controller (etaf-data--require-controller controller))
  (let ((next (1+ (etaf-value (etaf-data-page controller)))))
    (etaf-data-set-page controller next)
    (unless (etaf-data--controller-auto-load-p controller)
      (etaf-data-load controller))
    next))

;;;###autoload
(defun etaf-data-previous-page (controller)
  "Move CONTROLLER to the previous page and return the new page."
  (setq controller (etaf-data--require-controller controller))
  (let ((previous (max 1 (1- (etaf-value (etaf-data-page controller))))))
    (etaf-data-set-page controller previous)
    (unless (etaf-data--controller-auto-load-p controller)
      (etaf-data-load controller))
    previous))

;;;###autoload
(cl-defun etaf-data-select (controller identity &optional (selected-p t))
  "Select or deselect IDENTITY in CONTROLLER."
  (let* ((selection-ref (etaf-data-selection controller))
         (selection (etaf-value selection-ref)))
    (setf (etaf-value selection-ref)
          (if selected-p
              (cl-adjoin identity selection :test #'equal)
            (cl-remove identity selection :test #'equal)))))

;;;###autoload
(defun etaf-data-select-one (controller identity)
  "Replace CONTROLLER selection with the single IDENTITY."
  (let ((selection-ref (etaf-data-selection controller)))
    (setf (etaf-value selection-ref)
          (if (null identity) nil (list identity)))))

;;;###autoload
(defun etaf-data-selected-p (controller identity)
  "Return non-nil when IDENTITY is selected in CONTROLLER."
  (member identity (etaf-value (etaf-data-selection controller))))

;;;###autoload
(defun etaf-data-clear-selection (controller)
  "Clear CONTROLLER selection and return nil."
  (setf (etaf-value (etaf-data-selection controller)) nil))

(provide 'etaf-data)

;;; etaf-data.el ends here
