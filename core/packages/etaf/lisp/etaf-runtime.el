;;; etaf-runtime.el --- Fine-grained retained ETAF Runtime -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; A mounted View becomes one retained segment tree whose Host segments own
;; Ebox nodes directly.  Records and transactions live in `etaf-txn', Ebox
;; bridging and Host queries in `etaf-host-bridge', segment reconciliation in
;; `etaf-reconcile', and presentation/overlay layers in `etaf-presentation'.
;; This module owns root mounting, commit lifecycle, runtime lookup, sticky
;; Hosts, observation and viewport refit.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'ebox)
(require 'etaf-reactive)
(require 'etaf-animation)
(require 'etaf-context)
(require 'etaf-observer)
(require 'etaf-behavior)
(require 'etaf-view)
(require 'etaf-component)
(require 'etaf-txn)
(require 'etaf-host-bridge)
(require 'etaf-reconcile)
(require 'etaf-presentation)

(declare-function etaf--keys-install "etaf-keys" (runtime))
(declare-function etaf--keys-uninstall "etaf-keys" (runtime))

;;;; Root

(defun etaf--root-init (seg)
  "Bind root SEG, whose source is a View or a zero-argument function."
  (let ((ctx (etaf--seg-ctx seg))
        (src (etaf--seg-src seg)))
    (setf (etaf--seg-effect seg)
          (etaf--effect ctx seg
                        (lambda ()
                          (let ((value (if (functionp src) (funcall src) src)))
                            (etaf-untracked
                              (etaf--patch-kids seg (etaf--flatten value) ctx))))))))

(defun etaf--root-ctx (runtime)
  "Return a root evaluation context for RUNTIME, which may be nil."
  (etaf--ictx-make :runtime runtime :root-p nil
                   :context (etaf--context-create :owner-id 0)))

(defun etaf--root-sync (runtime)
  "Mount RUNTIME's top-level nodes when they changed."
  (when (etaf-runtime-root-dirty runtime)
    (setf (etaf-runtime-root-dirty runtime) nil)
    (let* ((nodes (etaf--kids-nodes (etaf-runtime-root runtime)))
           (overlays (etaf-runtime-overlay-entries runtime))
           (has-floating (or (etaf-runtime-surface runtime) overlays))
           (desired
            (if (and nodes (null (cdr nodes))
                     (not has-floating))
                (car nodes)
              (let ((wrapper (or (etaf-runtime-wrapper runtime)
                                 (setf (etaf-runtime-wrapper runtime)
                                       (ebox-node-create 'column nil)))))
                ;; A modal or named overlay needs a viewport canvas even when
                ;; the application is a single text Host or an intrinsically
                ;; short column.  Keep its original nodes and geometry; only
                ;; this outer canvas grows.  Node-owned scroll offsets survive
                ;; mounting.
                (ebox-node-set-props
                 wrapper
                 (when has-floating
                   (list :width 'stretch
                         :height (if (cdr (etaf-runtime-viewport runtime))
                                     '(vh 100)
                                   '(lh 32)))))
                ;; Include retained surface and overlay nodes in the
                ;; replacement itself.  Detaching and reattaching them would
                ;; discard Ebox's mounted projection while the outer canvas
                ;; identity stays unchanged.
                (ebox-node-replace-children
                 wrapper (append nodes
                                 (when-let* ((surface (etaf-runtime-surface runtime)))
                                   (etaf--kids-nodes surface))
                                 (cl-loop for (_k . oseg) in overlays
                                          append (etaf--kids-nodes oseg))))
                wrapper)))
           (buffer (etaf-runtime-buffer runtime)))
      ;; Managed transient and overlay content share the mounted tree, not
      ;; another buffer or Ebox mount.  Move them with a replaced root.
      (when-let* ((surface (etaf-runtime-surface runtime)))
        (setf (etaf--seg-node surface) desired))
      (dolist (entry overlays)
        (setf (etaf--seg-node (cdr entry)) desired))
      (unless (eq desired (etaf-runtime-mounted-root runtime))
        (when (and (ebox-node-parent desired)
                   (eq (ebox-node-parent desired) (etaf-runtime-wrapper runtime)))
          (ebox-node-remove desired))
        (when (buffer-live-p buffer)
          (let ((viewport (etaf-runtime-fixed-viewport runtime)))
            ;; Root replacement preserves this Runtime's observation lifetime,
            ;; including the new engine mount's first flush.
            (ebox-mount buffer desired :width (car viewport) :height (cdr viewport)
                        :observer (and (etaf-runtime-observer runtime)
                                       #'etaf--runtime-forward-ebox-report))))
        (setf (etaf-runtime-mounted-root runtime) desired
              (etaf-runtime-changed runtime) t)))))

;;;; Commit and lifecycle

(defun etaf--run-hooks (runtime hooks &optional inst)
  "Run lifecycle HOOKS in RUNTIME, collecting failures in the drain."
  (dolist (hook (reverse hooks))
    (condition-case err
        (let ((etaf--current-runtime runtime)
              (etaf--render-phase-p nil))
          (funcall hook))
      ((error quit)
       (unless (and inst etaf--boundary-hook-error-function
                    (funcall etaf--boundary-hook-error-function inst err))
         (push err etaf--drain-errors))))))

(defun etaf--runtime-commit (runtime)
  "Bring RUNTIME's buffer up to date and run its lifecycle hooks."
  (etaf--root-sync runtime)
  (let ((did-commit nil)
        (app-changed (etaf-runtime-app-changed runtime)))
    (setf (etaf-runtime-app-changed runtime) nil)
    (when (etaf-runtime-changed runtime)
      (setf (etaf-runtime-changed runtime) nil)
      (ebox-flush)
      (cl-incf (etaf-runtime-rev runtime))
      (etaf--sticky-refresh runtime)
      (setq did-commit t))
    (let ((mounted (etaf-runtime-new-instances runtime))
          (updated (etaf-runtime-updated-instances runtime))
          (retired (etaf-runtime-retired-instances runtime)))
      (when (and (not did-commit) (or mounted updated))
        (ebox-flush))
      (setf (etaf-runtime-last-new-count runtime) (length mounted)
            (etaf-runtime-last-updated-count runtime) (length updated)
            (etaf-runtime-last-retired-count runtime) (length retired))
      (setf (etaf-runtime-new-instances runtime) nil
            (etaf-runtime-updated-instances runtime) nil
            (etaf-runtime-retired-instances runtime) nil)
      (dolist (inst updated)
        (setf (etaf--instance-updated-p inst) nil)
        (cl-incf (etaf--instance-render-count inst)))
      (dolist (inst (reverse mounted))
        (unless (etaf--instance-dead inst)
          (setf (etaf--instance-mounted-p inst) t)
          (etaf--run-hooks runtime (etaf--instance-mounted-hooks inst) inst)))
      (dolist (inst (reverse updated))
        (unless (or (etaf--instance-dead inst) (memq inst mounted))
          (etaf--run-hooks runtime (etaf--instance-updated-hooks inst) inst)))
      (dolist (inst (reverse retired))
        (etaf--run-hooks runtime (etaf--instance-unmounted-hooks inst))))
    (when (and did-commit app-changed (> (etaf-runtime-rev runtime) 1)
               (etaf-runtime-mounted-p runtime))
      (etaf--run-runtime-hooks 'etaf-runtime-after-commit-functions runtime))))

(defvar etaf--in-viewport-prepare nil
  "Non-nil while draining viewport-prepare updates before `ebox-refit' settles.")

(defun etaf--drain-commit ()
  "Commit every dirty Runtime; return non-nil when one was committed.
When a pre or render effect failed, first roll back the transaction so
only work committed before it remains."
  (let ((txn etaf--txn))
    (prog1
        (if (and txn (null etaf--dirty-runtimes) (not etaf--drain-failed)
                 (etaf--txn-pristine-p txn))
            ;; Nothing ran since the last commit; keep its transaction.
            nil
          (etaf--drain-commit-1 txn))
      ;; Flush any viewport refit queued by `ebox-refit' before post-flush
      ;; effects and `etaf-next-tick' callbacks inspect layout geometry.
      (when etaf--in-viewport-prepare
        (ebox-flush)))))

(defun etaf--txn-pristine-p (txn)
  "Return non-nil when TXN recorded nothing since it began."
  (not (or (car (etaf--txn-ran txn)) (etaf--txn-undo txn) (etaf--txn-cells txn)
           (etaf--txn-created txn) (etaf--txn-stopped txn) (etaf--txn-installs txn)
           (etaf--txn-instances txn) (etaf--txn-deferred txn))))

(defun etaf--drain-commit-1 (txn)
  "Finish TXN, commit every dirty Runtime and begin the next transaction."
  (setq etaf--txn nil etaf--run-log nil)
  (when txn
    (if etaf--drain-failed
        (progn (setq etaf--drain-failed nil)
               (etaf--txn-rollback txn))
      (etaf--txn-commit txn)))
  (prog1
      (when etaf--dirty-runtimes
        (let ((runtimes (nreverse etaf--dirty-runtimes)))
          (setq etaf--dirty-runtimes nil)
          (dolist (runtime runtimes)
            (setf (etaf-runtime-dirty runtime) nil)
            (when (etaf-runtime-mounted-p runtime)
              (etaf--runtime-commit runtime)))
          t))
    (setq etaf--txn (etaf--txn-begin)
          etaf--run-log (etaf--txn-ran etaf--txn))))

(defun etaf--drain-around (loop)
  "Run the drain LOOP in one Ebox batch and one transaction per commit."
  (when (and etaf--parked-effects
             (or etaf--retry-parked (aref etaf--queues 0) (aref etaf--queues 1)))
    (etaf--requeue-parked))
  (let* ((etaf--txn (etaf--txn-begin))
         (etaf--run-log (etaf--txn-ran etaf--txn))
         (etaf--retry-parked nil))
    (ebox-call-with-batch loop)))

(setq etaf--drain-commit-function #'etaf--drain-commit
      etaf--drain-around-function #'etaf--drain-around)

;;;; Mounting

(defun etaf--validate-mount-options (options)
  "Return valid mount OPTIONS."
  (unless (proper-list-p options)
    (signal 'etaf-runtime-error (list "Mount options must be a plist" options)))
  (cl-loop for (key value) on options by #'cddr
           do (pcase key
                (:viewport-width
                 (unless (or (null value) (and (numberp value) (> value 0)))
                   (signal 'etaf-runtime-error (list "Invalid :viewport-width" value))))
                (:viewport-height
                 (unless (or (null value) (and (numberp value) (> value 0)))
                   (signal 'etaf-runtime-error (list "Invalid :viewport-height" value))))
                (:observer
                 (unless (or (null value) (functionp value))
                   (signal 'etaf-runtime-error (list "Invalid :observer" value))))
                (:text-selection
                 (unless (memq value '(nil t))
                   (signal 'etaf-runtime-error (list "Invalid :text-selection" value))))
                (:meta
                 (unless (or (null value)
                             (and (proper-list-p value) (zerop (% (length value) 2))))
                   (signal 'etaf-runtime-error (list "Invalid :meta" value))))
                (_ (signal 'etaf-runtime-error (list "Unknown mount option" key)))))
  options)

(defun etaf--runtime-forward-ebox-report (_buffer report)
  "Forward Ebox flush REPORT into the active observed operation."
  (etaf-observer-emit (append (list :provider 'ebox :stage 'flush)
                             (cl-loop for (key value) on report by #'cddr
                                      unless (memq key '(:provider :stage))
                                      append (list key value)))))

(defun etaf--runtime-buffer-killed ()
  "Unmount the Runtime of the buffer being killed."
  (when-let* ((runtime (gethash (current-buffer) etaf--runtimes)))
    (ignore-errors (etaf--runtime-unmount-now runtime))))

;;;###autoload
(defun etaf-runtime-mount (buffer-or-name view &optional options)
  "Mount VIEW into BUFFER-OR-NAME and return the live buffer.
VIEW is a View or a zero-argument function returning one.  OPTIONS may
provide `:viewport-width' in pixels, `:viewport-height' in lines, `:observer'
(a one-argument report sink installed before the first render), and
`:text-selection' (t to enable native Emacs mark and pointer text selection)."
  (etaf--assert-not-rendering 'mount-runtime)
  (setq options (etaf--validate-mount-options options))
  (let* ((etaf--txn nil)
         (etaf--run-log nil)
         (buffer (get-buffer-create buffer-or-name))
         (old (gethash buffer etaf--runtimes)))
    (when old (etaf--runtime-unmount-now old))
    (let* ((runtime (etaf--runtime-make
                     :buffer buffer :mounted-p t
                     :mount-id (cl-incf etaf--mount-counter)
                     :fixed-viewport (cons (plist-get options :viewport-width)
                                     (plist-get options :viewport-height))
                     :observer (plist-get options :observer)
                     :view view))
           (root (etaf--seg-make :kind 'root :src view
                                 :ctx (etaf--root-ctx runtime))))
      (setf (etaf-runtime-root runtime) root)
      (puthash buffer runtime etaf--runtimes)
      (with-current-buffer buffer
        (add-hook 'kill-buffer-hook #'etaf--runtime-buffer-killed nil t)
        ;; Capture the buffer's native cursor so optional input-modality hiding
        ;; (`etaf-cursor-follows-input-modality', nil by default) and unmount
        ;; always restore the caller's exact cursor state.
        (unless etaf--mount-cursor
          (setq etaf--mount-cursor
                (cons (local-variable-p 'cursor-type) cursor-type)))
        (when (plist-member options :text-selection)
          (unless etaf--mount-text-selection
            (setq etaf--mount-text-selection
                  (cons (local-variable-p 'ebox-allow-text-selection)
                        ebox-allow-text-selection)))
          (setq-local ebox-allow-text-selection
                      (and (plist-get options :text-selection) t)))
        (add-hook 'pre-command-hook #'etaf--cursor-input-modality nil t)
        ;; The canvas is a rendering, not a document: text typed into it would
        ;; be overwritten by the next paint and could never reach the source.
        ;; Ebox writes through `inhibit-read-only', so painting still works.
        (setq buffer-read-only t))
      (etaf--keys-install runtime)
      (condition-case err
          (etaf--runtime-run-operation
           runtime 'mount "mount"
           (lambda ()
             (etaf-call-with-batch
              (lambda ()
                ;; Initialise in the buffer the View is mounted into: a
                ;; component's `:setup' runs here, and it asks this buffer what
                ;; window it is drawn in.  Running it in whatever buffer the
                ;; caller happened to have current gave every mount the wrong
                ;; answer — a player embedded in a panel recorded `*scratch*'.
                (with-current-buffer buffer
                  (etaf--root-init root)
                  (setf (etaf--seg-live root) t)
                  (etaf--root-dirty runtime))))))
        ((error quit)
         (etaf--runtime-unmount-now runtime)
         (signal (car err) (cdr err))))
      (when (etaf-runtime-observer runtime)
        (ebox-buffer-set-observer buffer #'etaf--runtime-forward-ebox-report))
      (when (plist-member options :meta)
        (etaf--runtime-install-meta runtime (plist-get options :meta) t))
      (etaf--run-runtime-hooks 'etaf-runtime-mount-functions runtime)
      buffer)))

;;;###autoload
(defun etaf-mount (buffer-or-name view &optional options)
  "Mount VIEW into BUFFER-OR-NAME with OPTIONS and return its buffer.
See `etaf-runtime-mount'."
  (etaf-runtime-mount buffer-or-name view options))

(defun etaf--runtime-set-surface (runtime view origin)
  "Present transient VIEW in RUNTIME, inheriting ORIGIN's Context.
Nil VIEW disposes the surface.  The retained application nodes share a
viewport canvas with its absolute root-layer Hosts.  Application Components
are not remounted and their state, subscriptions and node scroll offsets
are retained."
  (etaf--assert-not-rendering 'present-surface)
  (etaf-call-with-batch
   (lambda ()
     (if (null view)
         (when-let* ((surface (etaf-runtime-surface runtime)))
           (setf (etaf-runtime-surface runtime) nil)
           (etaf--dispose surface t)
           (etaf--runtime-changed runtime))
       (when (etaf-runtime-surface runtime)
         (signal 'etaf-runtime-error (list "A transient surface is already open")))
       (let* ((source (or (etaf--runtime-host-seg runtime origin)
                          (etaf-runtime-root runtime)))
              (ctx (etaf--ictx-make
                    :runtime runtime
                    :context (etaf--ictx-context (etaf--seg-ctx source))))
              (surface (etaf--seg-make
                        :kind 'surface :src view :ctx ctx
                        :node (etaf-runtime-mounted-root runtime))))
         (condition-case err
             (progn
               (etaf--root-init surface)
               (setf (etaf--seg-live surface) t
                     (etaf-runtime-surface runtime) surface)
               (etaf--root-dirty runtime))
           ((error quit)
            (etaf--dispose surface nil)
            (signal (car err) (cdr err)))))))))

(defun etaf--runtime-unmount-now (runtime)
  "Dispose RUNTIME's segments and release its buffer, idempotently."
  (when (etaf-runtime-mounted-p runtime)
    (etaf--run-runtime-hooks 'etaf-runtime-unmount-functions runtime)
    (setf (etaf-runtime-mounted-p runtime) nil)
    (let ((buffer (etaf-runtime-buffer runtime))
          (root (etaf-runtime-root runtime))
          (etaf--render-phase-p nil)
          (etaf--txn nil)
          (etaf--run-log nil))
      (when (eq (gethash buffer etaf--runtimes) runtime)
        (remhash buffer etaf--runtimes))
      (when-let* ((surface (etaf-runtime-surface runtime)))
        (setf (etaf-runtime-surface runtime) nil)
        (etaf--dispose surface nil))
      (when-let* ((overlays (etaf-runtime-overlay-entries runtime)))
        (setf (etaf-runtime-overlay-entries runtime) nil)
        (dolist (entry overlays)
          (etaf--dispose (cdr entry) nil)))
      (when-let* ((mscope (etaf-runtime-meta-scope runtime)))
        (setf (etaf-runtime-meta-scope runtime) nil)
        (etaf-scope-stop mscope))
      (setf (etaf-runtime-meta-spec runtime) nil
            (etaf-runtime-meta-snapshot runtime) nil
            (etaf-runtime-key-layers runtime) nil)
      (when root (etaf--dispose root nil))
      (setq etaf--dirty-runtimes (delq runtime etaf--dirty-runtimes))
      (setf (etaf-runtime-dirty runtime) nil)
      (dolist (inst (etaf-runtime-retired-instances runtime))
        (dolist (hook (reverse (etaf--instance-unmounted-hooks inst)))
          (condition-case err
              (let ((etaf--current-runtime runtime)) (funcall hook))
            ((error quit) (push err (etaf-runtime-errors runtime))))))
      (setf (etaf-runtime-retired-instances runtime) nil
            (etaf-runtime-new-instances runtime) nil
            (etaf-runtime-updated-instances runtime) nil)
      (clrhash (etaf-runtime-hosts runtime))
      (clrhash (etaf-runtime-nodes runtime))
      (when (etaf-runtime-host-ids runtime)
        (clrhash (etaf-runtime-host-ids runtime)))
      (when (etaf-runtime-presentations runtime)
        (clrhash (etaf-runtime-presentations runtime)))
      (setf (etaf-runtime-sticky runtime) nil)
      (when (buffer-live-p buffer)
        (with-current-buffer buffer
          (etaf--sticky-clear)
          (remove-hook 'kill-buffer-hook #'etaf--runtime-buffer-killed t)
          (remove-hook 'pre-command-hook #'etaf--cursor-input-modality t)
          (setq etaf--cursor-hidden nil)
          (when etaf--mount-cursor
            (if (car etaf--mount-cursor)
                (setq-local cursor-type (cdr etaf--mount-cursor))
              (kill-local-variable 'cursor-type))
            (setq etaf--mount-cursor nil))
          (when etaf--mount-text-selection
            (if (car etaf--mount-text-selection)
                (setq-local ebox-allow-text-selection (cdr etaf--mount-text-selection))
              (kill-local-variable 'ebox-allow-text-selection))
            (setq etaf--mount-text-selection nil))
          (etaf--keys-uninstall runtime)
          (when (etaf-runtime-observer runtime)
            (ebox-buffer-set-observer buffer nil))
          (ebox-unmount-buffer buffer)))))
  runtime)

;;;###autoload
(defun etaf-runtime-unmount (&optional runtime)
  "Unmount RUNTIME, defaulting to the active or current-buffer Runtime."
  (etaf--assert-not-rendering 'unmount-runtime)
  (etaf--runtime-unmount-now (etaf-runtime-require-mounted runtime)))

;;;###autoload
(defun etaf-unmount (&optional runtime)
  "Unmount RUNTIME, defaulting to the active or current-buffer Runtime."
  (etaf-runtime-unmount runtime))

;;;###autoload
(defun etaf-render (view)
  "Render VIEW without a Runtime and return a detached Ebox root node.
Stateless Components are supported; stateful Components need `etaf-mount'."
  (let* ((root (etaf--seg-make :kind 'root :src view :ctx (etaf--root-ctx nil)))
         (etaf--render-phase-p t))
    (etaf--root-init root)
    (let ((nodes (etaf--kids-nodes root)))
      (if (and nodes (null (cdr nodes)))
          (car nodes)
        (ebox-node-create 'column nil nodes)))))

;;;; Runtime lookup

;;;###autoload
(defun etaf-runtime-for-buffer (buffer-or-name)
  "Return the live Runtime mounted in BUFFER-OR-NAME, or nil."
  (let* ((buffer (and buffer-or-name (get-buffer buffer-or-name)))
         (runtime (and buffer (gethash buffer etaf--runtimes))))
    (and runtime (etaf-runtime-mounted-p runtime) runtime)))

;;;###autoload
(defun etaf-runtime-require-mounted (&optional runtime)
  "Return mounted RUNTIME, the active Runtime or the current buffer's Runtime.
Signal `etaf-runtime-error' when none is mounted."
  (let ((runtime (or runtime etaf--current-runtime
                     (etaf-runtime-for-buffer (current-buffer)))))
    (unless (and (etaf-runtime-p runtime) (etaf-runtime-mounted-p runtime))
      (signal 'etaf-runtime-error (list "ETAF runtime is not mounted")))
    runtime))

;;;###autoload
(defun etaf-runtime-flush (&optional runtime)
  "Settle mounted RUNTIME's pending work and return its revision."
  (let ((runtime (etaf-runtime-require-mounted runtime)))
    (unless (or etaf--draining (> etaf--batch-depth 0) etaf--render-phase-p)
      (let ((etaf--retry-parked t))
        (etaf--drain)))
    (etaf-runtime-rev runtime)))

;;;###autoload
(defun etaf-runtime-update-report (&optional runtime)
  "Return the last buffer update report of mounted RUNTIME, or nil.
The plist is the engine's flush report for the last commit: its strategy,
the edited range count, the line count, the ranges and the flush counter.
RUNTIME defaults to the Runtime of the current buffer; a non-mounted
Runtime signals `etaf-runtime-error'."
  (let* ((runtime (etaf-runtime-require-mounted runtime)))
    (ebox-buffer-update-report (etaf-runtime-buffer runtime))))

;;;; Sticky Host
;;
;; A `:sticky top' Host mirrors its first row into a displaying window's header
;; line once the window scrolls completely past the Host's rows, without ever
;; calling `set-window-start'.  Because the mirror shows only once
;; `window-start' reaches the line after the Host, the original row and the
;; mirror never appear simultaneously.  Header clicks run the mirrored cell's
;; primary binding at its buffer position.

(defvar-local etaf--sticky-span nil
  "(START . NEXT) of the sticky Host's lines, or nil.")

(defvar-local etaf--sticky-string nil
  "Header line string mirroring the sticky Host's first row.")
(put 'etaf--sticky-string 'risky-local-variable t)

(defvar-local etaf--sticky-remap nil
  "Face remapping cookie of the sticky header line, or nil.")

(defconst etaf--sticky-header-format
  '(:eval (and etaf--sticky-span
               (>= (window-start) (cdr etaf--sticky-span))
               'etaf--sticky-string))
  "Zero-allocation header line construct showing the sticky mirror once off-screen.")

(defun etaf--sticky-span-of (runtime)
  "Return (START . NEXT) of RUNTIME's sticky Host lines, or nil."
  (when-let* ((ref (etaf-runtime-sticky runtime))
              (seg (gethash ref (etaf-runtime-hosts runtime)))
              ((plist-get (etaf--host-props (etaf--seg-data seg)) :sticky))
              (node (etaf--seg-node seg))
              (bounds (ebox-node-bounds node t)))
    (save-excursion
      (goto-char (car bounds))
      (let ((start (line-beginning-position)))
        (goto-char (cdr bounds))
        (forward-line 1)
        (cons start (point))))))

(defun etaf--sticky-click (buffer position map)
  "Return a header keymap running MAP's primary binding at POSITION in BUFFER."
  (let ((header (make-sparse-keymap)))
    (define-key header [header-line down-mouse-1] #'ignore)
    (define-key header [header-line mouse-1]
                (lambda ()
                  (interactive)
                  (when (buffer-live-p buffer)
                    (with-current-buffer buffer
                      (when-let* ((command (lookup-key map [mouse-1]))
                                  ((commandp command)))
                        (save-excursion
                          (goto-char position)
                          (funcall command)))))))
    header))

(defun etaf--sticky-header (span)
  "Return the header string mirroring the first row of SPAN."
  (let* ((start (car span))
         (end (save-excursion (goto-char start) (line-end-position)))
         (text (buffer-substring start end))
         (position 0))
    (while (< position (length text))
      (let ((next (next-single-property-change position 'keymap text (length text)))
            (map (get-text-property position 'keymap text)))
        (when (and (keymapp map) (lookup-key map [mouse-1]))
          (put-text-property position next 'keymap
                             (etaf--sticky-click (current-buffer)
                                                 (+ start position) map)
                             text))
        (setq position next)))
    text))

(defun etaf--sticky-window-update (window &optional start)
  "Show or hide WINDOW's sticky header line without moving `window-start'."
  (when (window-live-p window)
    (with-current-buffer (window-buffer window)
      (let* ((span etaf--sticky-span)
             (pos (or start (window-start window)))
             (shown (and span (>= pos (cdr span))))
             (hidden (eq (window-parameter window 'header-line-format) 'none)))
        (unless (eq (not shown) hidden)
          (set-window-parameter window 'header-line-format (unless shown 'none))
          (force-mode-line-update))))))

(defun etaf--sticky-scroll (window start)
  "Update WINDOW's sticky header visibility after scrolling to START."
  (etaf--sticky-window-update window start))

(defun etaf--sticky-windows ()
  "Update every window showing the current buffer."
  (dolist (window (get-buffer-window-list nil nil t))
    (etaf--sticky-window-update window)))

(defun etaf--sticky-clear ()
  "Remove sticky header state, face remap and hooks from the current buffer."
  (when (or etaf--sticky-remap etaf--sticky-span etaf--sticky-string
            (and (local-variable-p 'header-line-format)
                 (eq header-line-format etaf--sticky-header-format)))
    (when etaf--sticky-remap
      (face-remap-remove-relative etaf--sticky-remap)
      (setq etaf--sticky-remap nil))
    (when (local-variable-p 'header-line-format)
      (kill-local-variable 'header-line-format))
    (remove-hook 'window-scroll-functions #'etaf--sticky-scroll t)
    (remove-hook 'window-configuration-change-hook #'etaf--sticky-windows t)
    (setq etaf--sticky-span nil
          etaf--sticky-string nil)
    (dolist (window (get-buffer-window-list nil nil t))
      (when (eq (window-parameter window 'header-line-format) 'none)
        (set-window-parameter window 'header-line-format nil)))))

(defun etaf--sticky-refresh (runtime)
  "Mirror RUNTIME's sticky Host into its buffer's header line."
  (let ((buffer (etaf-runtime-buffer runtime)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (let ((span (etaf--sticky-span-of runtime)))
          (cond
           (span
            (unless etaf--sticky-remap
              (setq etaf--sticky-remap
                    (face-remap-add-relative
                     'header-line '(:inherit default :box nil :underline nil
                                    :overline nil :inverse-video nil)))
              (setq-local header-line-format etaf--sticky-header-format)
              (add-hook 'window-scroll-functions #'etaf--sticky-scroll nil t)
              (add-hook 'window-configuration-change-hook
                        #'etaf--sticky-windows nil t))
            (setq etaf--sticky-span span
                  etaf--sticky-string (etaf--sticky-header span))
            (etaf--sticky-windows))
           (t
            (setf (etaf-runtime-sticky runtime) nil)
            (etaf--sticky-clear))))))))

;;;; Observation and operations

;;;###autoload
(defun etaf-runtime-set-observer (runtime observer)
  "Set mounted RUNTIME's report OBSERVER, a function or nil; return it."
  (setq runtime (etaf-runtime-require-mounted runtime))
  (unless (or (null observer) (functionp observer))
    (signal 'wrong-type-argument (list 'functionp observer)))
  (unless (eq observer (etaf-runtime-observer runtime))
    (when (and etaf--observer-context
               (eql (etaf-runtime-mount-id runtime)
                    (etaf--observer-context-runtime-id etaf--observer-context)))
      (error "ETAF observer cannot change during an active operation"))
    (ebox-buffer-set-observer (etaf-runtime-buffer runtime)
                              (and observer #'etaf--runtime-forward-ebox-report))
    (setf (etaf-runtime-observer runtime) observer))
  observer)

;;;###autoload
(defun etaf-runtime-compare-and-set-observer (runtime expected replacement)
  "Replace RUNTIME's observer EXPECTED with REPLACEMENT; return non-nil on success."
  (setq runtime (etaf-runtime-require-mounted runtime))
  (dolist (observer (list expected replacement))
    (unless (or (null observer) (functionp observer))
      (signal 'wrong-type-argument (list 'functionp observer))))
  (when (eq expected (etaf-runtime-observer runtime))
    (etaf-runtime-set-observer runtime replacement)
    t))

(defun etaf--runtime-run-operation (runtime kind label function)
  "Call FUNCTION as RUNTIME operation KIND and LABEL, reporting when observed."
  (let ((observer (etaf-runtime-observer runtime))
        (current etaf--observer-context))
    (if (or (null observer)
            (and current (eql (etaf-runtime-mount-id runtime)
                              (etaf--observer-context-runtime-id current))))
        (funcall function)
      (let* ((operation-id (cl-incf (etaf-runtime-next-operation-id runtime)))
             (revision (etaf-runtime-rev runtime))
             (started (float-time))
             (gc-count gcs-done)
             (gc-time gc-elapsed)
             (status 'error)
             (context (etaf--observer-context-create
                       :sink observer :operation-id operation-id
                       :runtime-id (etaf-runtime-mount-id runtime)
                       :buffer-name (buffer-name (etaf-runtime-buffer runtime))
                       :diagnostic (lambda (diagnostic)
                                     (push diagnostic (etaf-runtime-errors runtime))))))
        (unwind-protect
            (etaf--observer-call-with-context
             context
             (lambda ()
               (condition-case err
                   (prog1 (funcall function) (setq status 'success))
                 (quit (setq status 'quit) (signal (car err) (cdr err))))))
          (etaf--observer-call-with-context
           context
           (lambda ()
             (etaf-observer-emit
              (list :provider 'etaf :stage 'runtime-operation
                    :kind kind :label (copy-sequence label) :status status
                    :revision-before revision
                    :revision-after (etaf-runtime-rev runtime)
                    :duration-ms (max 0.0 (* 1000.0 (- (float-time) started)))
                    :gc-count (- gcs-done gc-count)
                    :gc-duration-ms (max 0.0 (* 1000.0 (- gc-elapsed gc-time))))))))))))

;;;###autoload
(defun etaf-runtime-call-operation (runtime kind label function)
  "Call FUNCTION as one observed RUNTIME operation KIND with string LABEL.
Nested calls for one Runtime join the active operation.  Return FUNCTION's
result and re-signal its error."
  (unless (and (etaf-runtime-p runtime) (etaf-runtime-mounted-p runtime))
    (signal 'etaf-runtime-error (list "ETAF runtime is not mounted")))
  (unless (and (symbolp kind) kind)
    (signal 'wrong-type-argument (list 'symbolp kind)))
  (unless (stringp label)
    (signal 'wrong-type-argument (list 'stringp label)))
  (unless (functionp function)
    (signal 'wrong-type-argument (list 'functionp function)))
  (etaf--runtime-run-operation runtime kind label function))

;;;###autoload
(defun etaf-runtime-event-begin (runtime)
  "Enter one logical event batch for mounted RUNTIME."
  (setq runtime (etaf-runtime-require-mounted runtime))
  (cl-incf (etaf-runtime-event-depth runtime))
  runtime)

;;;###autoload
(defun etaf-runtime-event-end (runtime)
  "Leave RUNTIME's logical event batch."
  (when (etaf-runtime-p runtime)
    (setf (etaf-runtime-event-depth runtime)
          (max 0 (1- (etaf-runtime-event-depth runtime)))))
  runtime)

;;;###autoload
(defun etaf-runtime-set-input-finisher (runtime finisher)
  "Set mounted RUNTIME's native input session FINISHER, a function or nil.
FINISHER receives RUNTIME and runs before a press on another Host."
  (setq runtime (etaf-runtime-require-mounted runtime))
  (unless (or (null finisher) (functionp finisher))
    (signal 'wrong-type-argument (list 'functionp finisher)))
  (setf (etaf-runtime-input-finisher runtime) finisher))

;;;; Viewport

;;;###autoload
(defun etaf-runtime-viewport (&optional runtime)
  "Return mounted RUNTIME's viewport as (WIDTH . HEIGHT) in pixels and lines.
A reactive reader, such as a render or computed, depends on the viewport and
reruns after it changes."
  (let* ((runtime (etaf-runtime-require-mounted runtime))
         (buffer (etaf-runtime-buffer runtime))
         ;; The first render runs before its tree is mounted, so it reads
         ;; the viewport the mount is about to take.
         (viewport (or (ebox-mount-viewport buffer)
                       (let ((fixed (etaf-runtime-fixed-viewport runtime)))
                         (ebox-viewport-measure buffer (car fixed) (cdr fixed)))))
         (cell (or (etaf-runtime-viewport-ref runtime)
                   (setf (etaf-runtime-viewport-ref runtime)
                         (etaf--ref-create :value viewport :test #'equal
                                           :name "viewport")))))
    (etaf-value cell)
    viewport))

;;;###autoload
(defun etaf-runtime-window-viewport (&optional runtime)
  "Return RUNTIME's display-window viewport as (WIDTH . HEIGHT).
WIDTH is the width the window offers to a mounted tree: pixels on a
graphical frame, character cells on a text terminal.  HEIGHT is its body
height in lines.  RUNTIME defaults to the Runtime in the current buffer.
Nil when no window displays RUNTIME's buffer; read
`etaf-runtime-viewport' for the canvas size instead.  A non-mounted
Runtime signals `etaf-runtime-error'."
  (let* ((runtime (etaf-runtime-require-mounted runtime))
         (window (get-buffer-window (etaf-runtime-buffer runtime) t)))
    (when (window-live-p window)
      (cons (ebox-viewport-window-width window)
            (window-body-height window)))))

(defun etaf--runtime-viewport-changed (buffer)
  "Publish BUFFER's new viewport to readers of its Runtime's viewport."
  (when-let* ((runtime (etaf-runtime-for-buffer buffer))
              (cell (etaf-runtime-viewport-ref runtime)))
    (let ((etaf--in-viewport-prepare t))
      (etaf-set-value cell (ebox-mount-viewport buffer)))))

(add-hook 'ebox-viewport-prepare-functions #'etaf--runtime-viewport-changed)

;;;###autoload
(defun etaf-image-kitty-available-p (&optional frame)
  "Return a capability plist when FRAME supports Kitty terminal graphics.
FRAME defaults to the selected frame.  Return nil in batch sessions, on
graphical frames, or when FRAME's terminal does not support Kitty Unicode
placeholder graphics.  When non-nil, the plist contains `:cell-width',
`:cell-height' (pixel dimensions of one terminal cell) and `:local'."
  (ebox-image-kitty-available-p frame))

(defun etaf-display-metrics (&optional runtime)
  "Return RUNTIME's effective default-face metrics as a fresh plist.
The keys :char-width and :line-height are positive pixel sizes and :ascent
is an image ascent percentage.  RUNTIME defaults to the current Component
or buffer Runtime; an unmounted Runtime signals `etaf-runtime-error'.
A reactive read reruns after settled buffer text scaling, even with a fixed
viewport.  Image producers can repartition rows without remounting state."
  (let* ((runtime (etaf-runtime-require-mounted runtime))
         (metrics (ebox-display-metrics (etaf-runtime-buffer runtime)))
         (cell (or (etaf-runtime-display-ref runtime)
                   (setf (etaf-runtime-display-ref runtime)
                         (etaf--ref-create :value metrics :test #'equal
                                           :name "display-metrics")))))
    (etaf-value cell)
    (copy-sequence metrics)))

(defun etaf--runtime-display-changed (buffer)
  "Publish BUFFER's settled display metrics and viewport in one batch."
  (when-let* ((runtime (etaf-runtime-for-buffer buffer)))
    (etaf-batch
      (when-let* ((cell (etaf-runtime-display-ref runtime)))
        (etaf-set-value cell (ebox-display-metrics buffer)))
      (etaf--runtime-viewport-changed buffer))))

(add-hook 'ebox-display-change-functions #'etaf--runtime-display-changed)

;;;###autoload
(defun etaf-runtime-refit (runtime viewport-width &optional viewport-height)
  "Fix RUNTIME's viewport to VIEWPORT-WIDTH pixels and VIEWPORT-HEIGHT lines.
A nil dimension follows the displaying window.  Return non-nil when the
layout changed.  A native input session does not delay the refit; it applies
immediately like any other refit."
  (let ((runtime (etaf-runtime-require-mounted runtime)))
    (when (and viewport-width
               (not (and (numberp viewport-width) (> viewport-width 0))))
      (signal 'wrong-type-argument (list 'numberp viewport-width)))
    (when (and viewport-height
               (not (and (numberp viewport-height) (> viewport-height 0))))
      (signal 'wrong-type-argument (list 'numberp viewport-height)))
    (etaf--assert-not-rendering 'runtime-refit)
    (setf (etaf-runtime-fixed-viewport runtime) (cons viewport-width viewport-height))
    (etaf--runtime-relayout runtime viewport-width viewport-height)))

(defun etaf--runtime-relayout (runtime width height)
  "Relayout RUNTIME for viewport WIDTH and HEIGHT as an observed operation.
Nil WIDTH and HEIGHT follow the displaying window.  Return non-nil when the
layout changed, which advances the revision."
  (etaf--runtime-run-operation
   runtime 'refit "refit"
   (lambda ()
     (when (ebox-mount-set-viewport (etaf-runtime-buffer runtime) width height)
       (cl-incf (etaf-runtime-rev runtime))
       (when (etaf-runtime-sticky runtime)
         (etaf--sticky-refresh runtime))
       t))))

;;;###autoload
(defun etaf-refit (&optional runtime window)
  "Relayout RUNTIME for WINDOW's current size; return the viewport or nil.
RUNTIME defaults to the current buffer's Runtime and WINDOW to a window
showing it.  Mounted Runtimes follow window resizes automatically."
  (let* ((runtime (or runtime (etaf-runtime-for-buffer (current-buffer))))
         (buffer (and (etaf-runtime-p runtime) (etaf-runtime-buffer runtime)))
         (window (or window (and (buffer-live-p buffer) (get-buffer-window buffer t)))))
    (when (and (etaf-runtime-p runtime) (etaf-runtime-mounted-p runtime)
               (window-live-p window))
      (setf (etaf-runtime-fixed-viewport runtime) (cons nil nil))
      (etaf--runtime-relayout runtime nil nil)
      (ebox-mount-viewport buffer))))

;;;###autoload
(defun etaf-transient-space-borrowed-p (window committed-rows)
  "Return non-nil when transient UI borrows lines from WINDOW.
COMMITTED-ROWS is the body height WINDOW's caller last laid out for.  The
minibuffer and the echo area keep one body line at rest; while one of them
is taller (an active completion session, a wrapped prompt or message) its
extra lines are borrowed from the display windows.  While they are and
WINDOW is shorter than COMMITTED-ROWS, a caller that laid out for
COMMITTED-ROWS keeps that layout instead of recomputing one for the
borrowed height.  Growth, a nil commitment and a shorter window with no
transient UI are real geometry, so they return nil and the caller follows
the window."
  (and (window-live-p window)
       (integerp committed-rows)
       (< (window-body-height window) committed-rows)
       (let* ((frame (window-frame window))
              (minibuffer (and (frame-live-p frame) (minibuffer-window frame))))
         (and (window-live-p minibuffer)
              (> (window-body-height minibuffer) 1)))))

(provide 'etaf-runtime)
;;; etaf-runtime.el ends here
