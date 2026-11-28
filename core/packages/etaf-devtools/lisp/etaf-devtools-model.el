;;; etaf-devtools-model.el --- Reactive session state for etaf-devtools -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Owns the reactive state of one `etaf-devtools' session: attached target
;; Runtime, active tab, tree mode/search/expansion, selected Component/Host
;; snapshots, live ref editing draft, flush history ring, performance recorder
;; flag and diagnostics log.  Views read refs and never perform side effects.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'etaf)
(require 'etaf-devtools-core)
(require 'etaf-devtools-overlay)
(require 'etaf-devtools-target)

(cl-defstruct (etaf-devtools-session
               (:constructor etaf-devtools--session-make))
  "Reactive state container for one `etaf-devtools' instance."
  target-ref
  targets-ref
  pinned-ref
  dock-ref
  tab-ref
  narrow-detail-ref
  tree-mode-ref
  search-ref
  expanded-ref
  tree-ref
  selected-kind-ref
  selected-id-ref
  host-snap-ref
  comp-snap-ref
  style-filter-ref
  style-only-specified-ref
  edit-binding-ref
  edit-draft-ref
  edit-error-ref
  highlight-ref
  picker-active-ref
  recording-ref
  flush-history-ref
  perf-ops-ref
  selected-op-id-ref
  focus-snap-ref
  logs-ref
  viewport-preset-ref
  status-msg-ref
  listener
  refresh-timer
  window-hook
  alive-p)

(defun etaf-devtools--node-uid (kind id)
  "Return stable composite key `(KIND . ID)' for tree expansion/selection."
  (cons kind id))

(defun etaf-devtools--log-push (session level message)
  "Append a formatted log row to SESSION's diagnostics log."
  (let* ((now (format-time-string "%H:%M:%S"))
         (entry (list :time now :level level :message message))
         (cur (etaf-value (etaf-devtools-session-logs-ref session)))
         (next (cons entry (if (>= (length cur) 120)
                               (cl-subseq cur 0 119)
                             cur))))
    (etaf-set-value (etaf-devtools-session-logs-ref session) next)))

(defun etaf-devtools--expand-default (tree depth)
  "Build hash-table of initially expanded node UIDs up to DEPTH."
  (let ((table (make-hash-table :test #'equal)))
    (cl-labels ((walk (nodes d)
                  (when (< d depth)
                    (dolist (node nodes)
                      (when (plist-get node :children)
                        (puthash (etaf-devtools--node-uid
                                  (plist-get node :kind)
                                  (plist-get node :id))
                                 t table)
                        (walk (plist-get node :children) (1+ d)))))))
      (walk tree 0))
    table))

(defun etaf-devtools--first-host-id (tree)
  "Return first Host `:id' in TREE in document order, or nil."
  (cl-loop for node in tree
           for hit = (if (eq (plist-get node :kind) 'host)
                         (plist-get node :id)
                       (etaf-devtools--first-host-id (plist-get node :children)))
           when hit return hit))

(defun etaf-devtools--first-node (tree mode)
  "Return first selectable `(KIND . ID)' in TREE for MODE.
Prefers the first Component so Styles and State both populate immediately."
  (or (cl-loop for node in tree
               for kind = (plist-get node :kind)
               for hit = (if (eq kind 'component)
                             (cons kind (plist-get node :id))
                           (etaf-devtools--first-node (plist-get node :children) 'components))
               when hit return hit)
      (when (eq mode 'full)
        (when-let* ((hid (etaf-devtools--first-host-id tree)))
          (cons 'host hid)))))

(defun etaf-devtools--find-in-tree (tree kind id)
  "Find node plist matching KIND and ID inside TREE."
  (cl-loop for node in tree
           for hit = (if (and (eq (plist-get node :kind) kind)
                              (eql (plist-get node :id) id))
                         node
                       (etaf-devtools--find-in-tree (plist-get node :children) kind id))
           when hit return hit))

(defun etaf-devtools--ancestors-of (tree target-kind target-id)
  "Return list of ancestor UIDs from root down to TARGET-KIND/TARGET-ID."
  (cl-labels ((walk (nodes path)
                (cl-loop for node in nodes
                         for uid = (etaf-devtools--node-uid
                                    (plist-get node :kind)
                                    (plist-get node :id))
                         for hit = (if (and (eq (plist-get node :kind) target-kind)
                                            (eql (plist-get node :id) target-id))
                                       (nreverse path)
                                     (walk (plist-get node :children) (cons uid path)))
                         when hit return hit)))
    (walk tree nil)))

(defun etaf-devtools--refresh-selection-snaps (session &optional highlight)
  "Recompute Host and Component inspection snapshots for SESSION's selection."
  (let ((rt (etaf-value (etaf-devtools-session-target-ref session)))
        (kind (etaf-value (etaf-devtools-session-selected-kind-ref session)))
        (id (etaf-value (etaf-devtools-session-selected-id-ref session))))
    (if (not (and rt (etaf-runtime-mounted-p rt) id))
        (progn
          (etaf-set-value (etaf-devtools-session-host-snap-ref session) nil)
          (etaf-set-value (etaf-devtools-session-comp-snap-ref session) nil)
          (when highlight (etaf-devtools--overlay-clear-selection)))
      (let ((host-snap nil)
            (comp-snap nil)
            (hl-host-id nil))
        (condition-case nil
            (pcase kind
              ('host
               (setq host-snap (etaf-runtime-inspect-host rt id)
                     hl-host-id id)
               (when-let* ((cid (plist-get host-snap :owner-component-id)))
                 (setq comp-snap (etaf-runtime-inspect-component rt cid))))
              ('component
               (setq comp-snap (etaf-runtime-inspect-component rt id))
               (when-let* ((root-id (car (plist-get comp-snap :root-host-ids))))
                 (setq host-snap (etaf-runtime-inspect-host rt root-id)
                       hl-host-id root-id))))
          (error nil))
        (etaf-set-value (etaf-devtools-session-host-snap-ref session) host-snap)
        (etaf-set-value (etaf-devtools-session-comp-snap-ref session) comp-snap)
        (when highlight
          (if hl-host-id
              (etaf-devtools--overlay-highlight-host rt hl-host-id nil)
            (etaf-devtools--overlay-clear-selection)))))))

(defun etaf-devtools--refresh-focus (session)
  "Refresh focus, regions and key-scope diagnostics snapshot for SESSION."
  (let ((rt (etaf-value (etaf-devtools-session-target-ref session))))
    (etaf-set-value
     (etaf-devtools-session-focus-snap-ref session)
     (when (and rt (etaf-runtime-mounted-p rt))
       (condition-case nil
           (etaf-runtime-inspect-focus rt)
         (error nil))))))

(defun etaf-devtools--refresh-perf (session)
  "Refresh `etaf-performance-records' snapshot for SESSION."
  (let* ((rt (etaf-value (etaf-devtools-session-target-ref session)))
         (buf (and rt (etaf-runtime-buffer rt)))
         (bname (and (buffer-live-p buf) (buffer-name buf)))
         (all (etaf-performance-records))
         (matching-ids
          (when (and bname all)
            (let ((tbl (make-hash-table :test #'eql)))
              (dolist (row (plist-get (etaf-performance-report-data all) :operations))
                (when (equal (plist-get row :buffer-name) bname)
                  (puthash (plist-get row :id) t tbl)))
              tbl)))
         (filtered (if matching-ids
                       (cl-remove-if-not
                        (lambda (op)
                          (gethash (etaf-performance-operation-id op) matching-ids))
                        all)
                     all)))
    (etaf-set-value (etaf-devtools-session-perf-ops-ref session)
                    (cl-subseq filtered 0 (min 50 (length filtered))))))

(defun etaf-devtools--refresh-target (session &optional highlight)
  "Refresh tree, selection snapshots and active tab diagnostics for SESSION."
  (when (etaf-devtools-session-alive-p session)
    (let* ((candidates (etaf-devtools--candidate-runtimes))
           (cur (etaf-value (etaf-devtools-session-target-ref session)))
           (live (and cur (etaf-runtime-mounted-p cur) (memq cur candidates) cur))
           (rt (or live (car candidates))))
      (etaf-batch
       (etaf-set-value (etaf-devtools-session-targets-ref session) candidates)
       (unless (eq rt cur)
         (etaf-set-value (etaf-devtools-session-target-ref session) rt)
         (etaf-set-value (etaf-devtools-session-selected-kind-ref session) nil)
         (etaf-set-value (etaf-devtools-session-selected-id-ref session) nil)
         (etaf-set-value (etaf-devtools-session-edit-binding-ref session) nil)
         (etaf-set-value (etaf-devtools-session-edit-error-ref session) nil)
         (etaf-set-value (etaf-devtools-session-recording-ref session) nil))
       (if (not rt)
           (progn
             (etaf-set-value (etaf-devtools-session-tree-ref session) nil)
             (etaf-set-value (etaf-devtools-session-host-snap-ref session) nil)
             (etaf-set-value (etaf-devtools-session-comp-snap-ref session) nil)
             (etaf-set-value (etaf-devtools-session-focus-snap-ref session) nil)
             (etaf-set-value (etaf-devtools-session-highlight-ref session) nil)
             (etaf-devtools--overlay-clear-selection))
         (let* ((tree (condition-case nil
                          (etaf-runtime-inspect-tree rt)
                        (error nil)))
                (exp (etaf-value (etaf-devtools-session-expanded-ref session))))
           (when (or (not (hash-table-p exp)) (= (hash-table-count exp) 0))
             (setq exp (etaf-devtools--expand-default tree 3))
             (etaf-set-value (etaf-devtools-session-expanded-ref session) exp))
           (etaf-set-value (etaf-devtools-session-tree-ref session) tree)
           (etaf-set-value (etaf-devtools-session-highlight-ref session)
                           (etaf-devtools--highlight-enabled-p rt))
           (let ((sk (etaf-value (etaf-devtools-session-selected-kind-ref session)))
                 (sid (etaf-value (etaf-devtools-session-selected-id-ref session))))
             (unless (and sk sid (etaf-devtools--find-in-tree tree sk sid))
               (when-let* ((first (etaf-devtools--first-node
                                   tree (etaf-value (etaf-devtools-session-tree-mode-ref session)))))
                 (etaf-set-value (etaf-devtools-session-selected-kind-ref session) (car first))
                 (etaf-set-value (etaf-devtools-session-selected-id-ref session) (cdr first)))))
           (etaf-devtools--refresh-selection-snaps session highlight)
           (when (eq (etaf-value (etaf-devtools-session-tab-ref session)) 'keys)
             (etaf-devtools--refresh-focus session))
           (when (eq (etaf-value (etaf-devtools-session-tab-ref session)) 'perf)
             (etaf-devtools--refresh-perf session))))))))

(defun etaf-devtools--schedule-refresh (session)
  "Debounced refresh of SESSION after target commits or flushes."
  (when (etaf-devtools-session-alive-p session)
    (when (timerp (etaf-devtools-session-refresh-timer session))
      (cancel-timer (etaf-devtools-session-refresh-timer session)))
    (setf (etaf-devtools-session-refresh-timer session)
          (run-with-timer 0.05 nil
                          (lambda ()
                            (when (etaf-devtools-session-alive-p session)
                              (setf (etaf-devtools-session-refresh-timer session) nil)
                              (etaf-devtools--refresh-target session t)))))))

(defun etaf-devtools--session-select-node (session kind id &optional expand-ancestors enter-detail)
  "Select node KIND/ID in SESSION, expanding ancestors and updating overlays."
  (let ((tree (etaf-value (etaf-devtools-session-tree-ref session))))
    (when (and expand-ancestors tree)
      (let* ((old (etaf-value (etaf-devtools-session-expanded-ref session)))
             (next (if (hash-table-p old) (copy-hash-table old)
                     (make-hash-table :test #'equal))))
        (dolist (uid (etaf-devtools--ancestors-of tree kind id))
          (puthash uid t next))
        (etaf-set-value (etaf-devtools-session-expanded-ref session) next))))
  (etaf-batch
   (etaf-set-value (etaf-devtools-session-selected-kind-ref session) kind)
   (etaf-set-value (etaf-devtools-session-selected-id-ref session) id)
   (etaf-set-value (etaf-devtools-session-edit-binding-ref session) nil)
   (etaf-set-value (etaf-devtools-session-edit-error-ref session) nil)
   (when enter-detail
     (etaf-set-value (etaf-devtools-session-narrow-detail-ref session) t))
   (etaf-devtools--refresh-selection-snaps session t)))

(defun etaf-devtools--session-toggle-expand (session kind id)
  "Toggle expanded state of node KIND/ID in SESSION."
  (let* ((uid (etaf-devtools--node-uid kind id))
         (old (etaf-value (etaf-devtools-session-expanded-ref session)))
         (next (if (hash-table-p old) (copy-hash-table old)
                 (make-hash-table :test #'equal))))
    (if (gethash uid next)
        (remhash uid next)
      (puthash uid t next))
    (etaf-set-value (etaf-devtools-session-expanded-ref session) next)))

(defun etaf-devtools--session-set-target (session runtime &optional pin)
  "Attach SESSION to RUNTIME and refresh snapshots."
  (when (and runtime (etaf-runtime-mounted-p runtime)
             (not (etaf-devtools--own-runtime-p runtime)))
    (etaf-devtools--session-stop-recording session)
    (etaf-batch
     (etaf-set-value (etaf-devtools-session-target-ref session) runtime)
     (when pin (etaf-set-value (etaf-devtools-session-pinned-ref session) t))
     (etaf-set-value (etaf-devtools-session-expanded-ref session) (make-hash-table :test #'equal))
     (etaf-set-value (etaf-devtools-session-selected-kind-ref session) nil)
     (etaf-set-value (etaf-devtools-session-selected-id-ref session) nil)
     (etaf-set-value (etaf-devtools-session-viewport-preset-ref session) 'auto))
    (etaf-devtools--log-push session 'info
                             (format "附着目标 %s" (etaf-devtools--runtime-label runtime)))
    (etaf-devtools--refresh-target session t)))

(defun etaf-devtools--session-start-recording (session)
  "Attach `etaf-performance' recorder to SESSION's target Runtime."
  (let ((rt (etaf-value (etaf-devtools-session-target-ref session))))
    (if (not (and rt (etaf-runtime-mounted-p rt)))
        (etaf-set-value (etaf-devtools-session-status-msg-ref session) "没有可录制的目标 Runtime")
      (condition-case err
          (progn
            (etaf-performance-start rt)
            (etaf-set-value (etaf-devtools-session-recording-ref session) t)
            (etaf-set-value (etaf-devtools-session-status-msg-ref session) "正在录制性能阶段...")
            (etaf-devtools--log-push session 'info "开启 etaf-performance 深度录制"))
        (error
         (let ((msg (format "无法录制: %s" (error-message-string err))))
           (etaf-set-value (etaf-devtools-session-status-msg-ref session) msg)
           (etaf-devtools--log-push session 'warn msg)))))))

(defun etaf-devtools--session-stop-recording (session)
  "Detach `etaf-performance' recorder from SESSION's target Runtime."
  (when (etaf-value (etaf-devtools-session-recording-ref session))
    (let ((rt (etaf-value (etaf-devtools-session-target-ref session))))
      (when (and rt (etaf-runtime-mounted-p rt))
        (ignore-errors (etaf-performance-stop rt)))
      (etaf-set-value (etaf-devtools-session-recording-ref session) nil)
      (etaf-devtools--refresh-perf session)
      (etaf-set-value (etaf-devtools-session-status-msg-ref session) "已停止录制")
      (etaf-devtools--log-push session 'info "停止性能录制"))))

(defun etaf-devtools--session-toggle-recording (session)
  "Toggle `etaf-performance' recording on SESSION's target Runtime."
  (if (etaf-value (etaf-devtools-session-recording-ref session))
      (etaf-devtools--session-stop-recording session)
    (etaf-devtools--session-start-recording session)))

(defun etaf-devtools--session-begin-edit-binding (session binding-name current-preview)
  "Start in-place editing of writable ref BINDING-NAME in SESSION."
  (etaf-batch
   (etaf-set-value (etaf-devtools-session-edit-binding-ref session) binding-name)
   (etaf-set-value (etaf-devtools-session-edit-draft-ref session) (or current-preview ""))
   (etaf-set-value (etaf-devtools-session-edit-error-ref session) nil)))

(defun etaf-devtools--session-cancel-edit-binding (session)
  "Cancel active binding edit in SESSION."
  (etaf-batch
   (etaf-set-value (etaf-devtools-session-edit-binding-ref session) nil)
   (etaf-set-value (etaf-devtools-session-edit-error-ref session) nil)))

(defun etaf-devtools--session-commit-edit-binding (session &optional explicit-value has-explicit)
  "Commit edited binding value to target Component instance in SESSION."
  (let ((rt (etaf-value (etaf-devtools-session-target-ref session)))
        (comp (etaf-value (etaf-devtools-session-comp-snap-ref session)))
        (bname (etaf-value (etaf-devtools-session-edit-binding-ref session))))
    (when (and rt (etaf-runtime-mounted-p rt) comp bname)
      (condition-case err
          (let ((val (if has-explicit
                         explicit-value
                       (etaf-devtools--parse-lisp-input
                        (etaf-value (etaf-devtools-session-edit-draft-ref session))))))
            (etaf-runtime-set-component-binding rt (plist-get comp :id) bname val)
            (etaf-batch
             (etaf-set-value (etaf-devtools-session-edit-binding-ref session) nil)
             (etaf-set-value (etaf-devtools-session-edit-error-ref session) nil)
             (etaf-set-value (etaf-devtools-session-status-msg-ref session)
                             (format "已更新 %s = %s" bname (etaf-devtools--safe-print val 40))))
            (etaf-devtools--log-push session 'info
                                     (format "修改 %s.%s = %s"
                                             (plist-get comp :name) bname
                                             (etaf-devtools--safe-print val 48)))
            (etaf-devtools--refresh-target session t))
        (error
         (etaf-set-value (etaf-devtools-session-edit-error-ref session)
                         (error-message-string err)))))))

(defun etaf-devtools--session-toggle-bool-binding (session bname cur-val)
  "Directly toggle boolean `etaf-ref' BNAME in SESSION's selected Component."
  (let ((rt (etaf-value (etaf-devtools-session-target-ref session)))
        (comp (etaf-value (etaf-devtools-session-comp-snap-ref session))))
    (when (and rt (etaf-runtime-mounted-p rt) comp)
      (condition-case err
          (progn
            (etaf-runtime-set-component-binding rt (plist-get comp :id) bname (not cur-val))
            (etaf-set-value (etaf-devtools-session-status-msg-ref session)
                            (format "已切换 %s = %S" bname (not cur-val)))
            (etaf-devtools--refresh-target session t))
        (error
         (etaf-set-value (etaf-devtools-session-edit-error-ref session)
                         (error-message-string err)))))))

(defun etaf-devtools--session-apply-viewport (session preset)
  "Apply simulated viewport PRESET to SESSION's target Runtime."
  (let ((rt (etaf-value (etaf-devtools-session-target-ref session))))
    (when (and rt (etaf-runtime-mounted-p rt))
      (condition-case err
          (progn
            (pcase preset
              ('wide (etaf-runtime-refit rt 1280 42))
              ('ordinary (etaf-runtime-refit rt 960 34))
              ('compact (etaf-runtime-refit rt 640 28))
              ('short (etaf-runtime-refit rt 960 20))
              (_ (etaf-runtime-refit rt nil nil)))
            (etaf-set-value (etaf-devtools-session-viewport-preset-ref session) preset)
            (etaf-set-value (etaf-devtools-session-status-msg-ref session)
                            (format "目标视口已切至 %s" preset))
            (etaf-devtools--log-push session 'info (format "视口预设 → %s" preset))
            (etaf-devtools--refresh-target session t))
        (error
         (etaf-set-value (etaf-devtools-session-status-msg-ref session)
                         (format "视口切换失败: %s" (error-message-string err))))))))

(defun etaf-devtools--record-flush (session runtime summary-or-report is-commit)
  "Append or merge flush/commit metrics into SESSION's ring buffer."
  (let* ((report (if is-commit
                     (plist-get summary-or-report :update-report)
                   summary-or-report))
         (rev (or (and is-commit (plist-get summary-or-report :rev))
                  (and (etaf-runtime-mounted-p runtime) (etaf-runtime-revision runtime))
                  0))
         (fnum (plist-get report :flush))
         (new-c (if is-commit (or (plist-get summary-or-report :new-instances) 0) 0))
         (upd-c (if is-commit (or (plist-get summary-or-report :updated-instances) 0) 0))
         (ret-c (if is-commit (or (plist-get summary-or-report :retired-instances) 0) 0))
         (cur (etaf-value (etaf-devtools-session-flush-history-ref session)))
         (head (car cur))
         (same-flush (and head fnum (eql fnum (plist-get head :flush-num))))
         (entry (list :time (format-time-string "%H:%M:%S")
                      :rev rev
                      :flush-num fnum
                      :kind (if (or is-commit (and same-flush (eq (plist-get head :kind) 'commit)))
                                'commit 'flush)
                      :strategy (or (plist-get report :strategy)
                                    (and same-flush (plist-get head :strategy))
                                    'lines)
                      :edits (or (plist-get report :edits)
                                 (and same-flush (plist-get head :edits)) 0)
                      :lines (or (plist-get report :lines)
                                 (and same-flush (plist-get head :lines)) 0)
                      :new (if is-commit new-c (if same-flush (or (plist-get head :new) 0) 0))
                      :updated (if is-commit upd-c (if same-flush (or (plist-get head :updated) 0) 0))
                      :retired (if is-commit ret-c (if same-flush (or (plist-get head :retired) 0) 0))))
         (cap (max 10 etaf-devtools-max-flush-history))
         (tail (if same-flush (cdr cur) cur))
         (next (cons entry (if (>= (length tail) cap)
                               (cl-subseq tail 0 (1- cap))
                             tail))))
    (etaf-set-value (etaf-devtools-session-flush-history-ref session) next)
    (when (and (not same-flush) (eq (plist-get entry :strategy) 'full))
      (etaf-devtools--log-push
       session 'warn
       (format "rev #%d 触发全量重绘 (%d 行)" rev (plist-get entry :lines))))))

(defun etaf-devtools--session-create (&optional initial-target dock)
  "Create and wire a live `etaf-devtools-session' for INITIAL-TARGET."
  (let* ((candidates (etaf-devtools--candidate-runtimes))
         (target (or (and initial-target
                          (etaf-runtime-mounted-p initial-target)
                          (not (etaf-devtools--own-runtime-p initial-target))
                          initial-target)
                     (car candidates)))
         (session
          (etaf-devtools--session-make
           :target-ref (etaf-ref target :name 'dt-target)
           :targets-ref (etaf-ref candidates :name 'dt-targets)
           :pinned-ref (etaf-ref nil :name 'dt-pinned)
           :dock-ref (etaf-ref (or dock etaf-devtools-default-dock) :name 'dt-dock)
           :tab-ref (etaf-ref 'tree :name 'dt-tab)
           :narrow-detail-ref (etaf-ref nil :name 'dt-narrow-detail)
           :tree-mode-ref (etaf-ref 'full :name 'dt-tree-mode)
           :search-ref (etaf-ref "" :name 'dt-search)
           :expanded-ref (etaf-ref (make-hash-table :test #'equal) :name 'dt-expanded)
           :tree-ref (etaf-ref nil :name 'dt-tree)
           :selected-kind-ref (etaf-ref nil :name 'dt-sel-kind)
           :selected-id-ref (etaf-ref nil :name 'dt-sel-id)
           :host-snap-ref (etaf-ref nil :name 'dt-host-snap)
           :comp-snap-ref (etaf-ref nil :name 'dt-comp-snap)
           :style-filter-ref (etaf-ref "" :name 'dt-style-filter)
           :style-only-specified-ref (etaf-ref t :name 'dt-style-spec)
           :edit-binding-ref (etaf-ref nil :name 'dt-edit-binding)
           :edit-draft-ref (etaf-ref "" :name 'dt-edit-draft)
           :edit-error-ref (etaf-ref nil :name 'dt-edit-err)
           :highlight-ref (etaf-ref (and target (etaf-devtools--highlight-enabled-p target)) :name 'dt-hl)
           :picker-active-ref (etaf-ref nil :name 'dt-picker)
           :recording-ref (etaf-ref nil :name 'dt-rec)
           :flush-history-ref (etaf-ref nil :name 'dt-flushes)
           :perf-ops-ref (etaf-ref nil :name 'dt-perf-ops)
           :selected-op-id-ref (etaf-ref nil :name 'dt-sel-op)
           :focus-snap-ref (etaf-ref nil :name 'dt-focus-snap)
           :logs-ref (etaf-ref nil :name 'dt-logs)
           :viewport-preset-ref (etaf-ref 'auto :name 'dt-vp)
           :status-msg-ref (etaf-ref "" :name 'dt-status)
           :alive-p t)))
    (let ((listener
           (lambda (event runtime data)
             (when (etaf-devtools-session-alive-p session)
               (let ((cur (etaf-value (etaf-devtools-session-target-ref session))))
                 (pcase event
                   ('mount
                    (etaf-devtools--log-push session 'info
                                             (format "挂载 %s" (etaf-devtools--runtime-label runtime)))
                    (etaf-devtools--schedule-refresh session))
                   ('unmount
                    (etaf-devtools--log-push session 'info
                                             (format "卸载 %s" (etaf-devtools--runtime-label runtime)))
                    (when (eq runtime cur)
                      (etaf-devtools--overlay-clear-selection)
                      (etaf-set-value (etaf-devtools-session-recording-ref session) nil))
                    (etaf-devtools--schedule-refresh session))
                   ('commit
                    (when (eq runtime cur)
                      (etaf-devtools--record-flush session runtime data t)
                      (when (etaf-value (etaf-devtools-session-recording-ref session))
                        (etaf-devtools--refresh-perf session))
                      (etaf-devtools--schedule-refresh session)))
                   ('flush
                    (when (eq runtime cur)
                      (when (and data
                                 (not (equal (plist-get data :flush)
                                             (let ((head (car (etaf-value (etaf-devtools-session-flush-history-ref session)))))
                                               (and head (plist-get head :flush-num))))))
                        (etaf-devtools--record-flush session runtime data nil))
                      (etaf-devtools--schedule-refresh session)))))))))
      (setf (etaf-devtools-session-listener session) listener)
      (etaf-devtools--add-listener listener))
    (let ((whook
           (lambda (&rest _)
             (when (and (etaf-devtools-session-alive-p session)
                        (not (etaf-value (etaf-devtools-session-pinned-ref session)))
                        (not (etaf-value (etaf-devtools-session-picker-active-ref session))))
               (let ((rt (etaf-runtime-for-buffer (current-buffer))))
                 (when (and rt
                            (etaf-runtime-mounted-p rt)
                            (not (etaf-devtools--own-runtime-p rt))
                            (not (eq rt (etaf-value (etaf-devtools-session-target-ref session)))))
                   (etaf-devtools--session-set-target session rt)))))))
      (setf (etaf-devtools-session-window-hook session) whook)
      (add-hook 'window-buffer-change-functions whook)
      (add-hook 'window-selection-change-functions whook))
    (when target
      (etaf-devtools--log-push session 'info
                               (format "已连接 %s" (etaf-devtools--runtime-label target))))
    (etaf-devtools--refresh-target session nil)
    session))

(defun etaf-devtools--session-dispose (session)
  "Cleanly release all listeners, timers, recordings and overlays of SESSION."
  (when (and session (etaf-devtools-session-alive-p session))
    (setf (etaf-devtools-session-alive-p session) nil)
    (etaf-devtools--session-stop-recording session)
    (when (timerp (etaf-devtools-session-refresh-timer session))
      (cancel-timer (etaf-devtools-session-refresh-timer session)))
    (setf (etaf-devtools-session-refresh-timer session) nil)
    (when-let* ((listener (etaf-devtools-session-listener session)))
      (etaf-devtools--remove-listener listener)
      (setf (etaf-devtools-session-listener session) nil))
    (when-let* ((whook (etaf-devtools-session-window-hook session)))
      (remove-hook 'window-buffer-change-functions whook)
      (remove-hook 'window-selection-change-functions whook)
      (setf (etaf-devtools-session-window-hook session) nil))
    (etaf-devtools--overlay-clear-selection)))

(provide 'etaf-devtools-model)
;;; etaf-devtools-model.el ends here
