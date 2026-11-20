;;; -*- lexical-binding: t; -*-
;;; etaf-help.el --- In-buffer keyboard help and its presentation contract

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Snapshot the effective input scope before opening its modal help.  Core
;; owns the data and mounted lifetime; a catalog renderer can supply a View
;; without importing UI into ETAF or creating a second application Runtime.

;;; Code:
(require 'etaf-keys)

(defvar-local etaf--help-state nil
  "Open help's input scope and return location, or nil.")
(put 'etaf--help-state 'permanent-local t)

(defvar etaf-help-view-function nil
  "Function of DATA and CLOSE returning the keyboard help View, or nil.
DATA is the read-only snapshot documented by `etaf-help-data'.  CLOSE is a
zero-argument callback.  Return a root-layer modal View, not a buffer or
window.  The View inherits the opening Host's Context and is disposed with
its Runtime.  Nil uses the core fallback.  The optional etaf-ui package
installs its catalog renderer unless a custom renderer is already set.")

(defun etaf--help-copy (value)
  "Detach all mutable containers and property-free strings in snapshot VALUE."
  (cond ((stringp value) (substring-no-properties value))
        ((consp value) (cons (etaf--help-copy (car value))
                             (etaf--help-copy (cdr value))))
        ((vectorp value) (vconcat (mapcar #'etaf--help-copy value)))
        (t value)))

(defun etaf--help-command-label (command)
  "Return a readable description of COMMAND without invoking it."
  (let* ((raw (documentation command t))
         (doc (and (stringp raw) (string-trim raw))))
    (if (and doc (not (string-empty-p doc)))
        (car (split-string doc "\n"))
      (if (symbolp command) (symbol-name command) "未命名操作"))))

(defun etaf--help-map-entries (runtime seen)
  "Return effective local map entries outside RUNTIME's Host keys in SEEN."
  (let (entries)
    (cl-labels
        ((walk
          (map prefix parents)
          (unless (memq map parents)
            (map-keymap
             (lambda (event binding)
               (unless (or (eq event t)
                           (and (symbolp event)
                                (string-match-p "mouse\\|wheel\\|drag\\|menu\\|remap"
                                                (symbol-name event))))
                 (let* ((label (cond ((eq (car-safe binding) 'menu-item) (nth 1 binding))
                                     ((stringp (car-safe binding)) (car binding))))
                        (binding (cond ((eq (car-safe binding) 'menu-item) (nth 2 binding))
                                       ((stringp (car-safe binding)) (cdr binding))
                                       (t binding)))
                        (keys (vconcat prefix (vector event))))
                   (cond
                    ((keymapp binding) (walk binding keys (cons map parents)))
                    ((and (commandp binding)
                          (not (member keys seen))
                          (not (member keys etaf--keys-reserved-events))
                          (eq binding (key-binding keys t))
                          (not (memq binding '(ignore undefined self-insert-command))))
                     (push keys seen)
                     (push (list :key (key-description keys) :events keys
                                 :label (if (and (stringp label) (not (string-empty-p label)))
                                            label
                                          (etaf--help-command-label binding))
                                 :source (format "%s" major-mode))
                           entries))))))
             map))))
      (let ((active (current-active-maps t))
            (maps (list (current-local-map))))
        ;; Application emulation maps are gated by buffer-local state.
        ;; Global minor modes (Winner, etc.) are not application help.
        (dolist (source emulation-mode-map-alists)
          (let ((alist (if (and (symbolp source) (boundp source))
                           (symbol-value source) source)))
            (when (listp alist)
              (dolist (entry alist)
                (when (and (consp entry)
                           (or (and (symbolp source) (local-variable-p source))
                               (and (symbolp (car entry))
                                    (local-variable-p (car entry))))
                           (memq (cdr entry) active))
                  (push (cdr entry) maps))))))
        (dolist (entry minor-mode-overriding-map-alist)
          (when (memq (cdr entry) active) (push (cdr entry) maps)))
        (dolist (map (delete-dups maps))
          (when (and (keymapp map)
                     (not (memq map (list ebox-buffer-mode-map
                                           (etaf-runtime-keymap runtime)))))
            (walk map [] nil)))))
    (nreverse entries)))

(defun etaf-help-data (&optional runtime)
  "Return a read-only keyboard snapshot for mounted RUNTIME.
RUNTIME defaults to the active or current-buffer Runtime.  The plist has
:title and :scope strings, :groups, :notes and :controls.  Each group has
:title, :source, :kind (application, framework or regions) and :entries;
each entry has :key, :label, :source and optional :events (a key vector).
Only effective labelled Host keys and effective local keymap commands are
listed; nearer Host keys shadow outer keys even without a label.  Notes
come from the scoped Hosts' :help strings.  Controls are readable names,
not executable callbacks.  While help is open return its opening snapshot.
The returned data is a defensive copy and contains no business callbacks."
  (setq runtime (etaf-runtime-require-mounted runtime))
  (with-current-buffer (etaf-runtime-buffer runtime)
    (if etaf--help-state
        (etaf--help-copy (plist-get etaf--help-state :data))
      (let* ((chain (etaf--keys-chain runtime))
             (entries (etaf--keys-entries runtime chain))
             (regions (etaf--regions-in-scope runtime))
             (current (etaf--regions-current runtime regions))
             (title (or (etaf--keys-source-name runtime (car (last chain)))
                        (string-trim (buffer-name) "[ *]+" "[ *]+")))
             (scope (if current (etaf--regions-label current) title))
             groups seen notes controls)
        (dolist (item entries)
          (let* ((entry (cdr item))
                 (events (etaf--keys-event (car entry)))
                 (source (or (etaf--keys-source-name runtime (car item)) title))
                 (group (cl-find source groups :key (lambda (g) (plist-get g :source))
                                 :test #'equal)))
            (push events seen)
            (when (nth 2 entry)
              (unless group
                (setq group (list :title (if (eq (car item) (car (last chain)))
                                            "应用操作" "当前区域")
                                  :source source :kind 'application :entries nil))
                (setq groups (append groups (list group))))
              (setf (plist-get group :entries)
                    (append (plist-get group :entries)
                            (list (list :key (key-description events) :events events
                                        :label (nth 2 entry) :source source)))))))
        ;; Buffer maps belong to the enclosing canvas, not a nested scope.
        (unless (etaf--keys-boundary-p runtime (car (last chain)))
          (when-let* ((local (etaf--help-map-entries runtime seen)))
            (let ((group (cl-find title groups :key (lambda (g) (plist-get g :source))
                                  :test #'equal)))
              (if group
                  (setf (plist-get group :entries)
                        (append (plist-get group :entries) local))
                (setq groups (append groups
                                     (list (list :title "应用操作" :source title
                                                 :kind 'application :entries local))))))))
        (setq groups
              (append
               groups
               (list
                (list :title "通用导航" :source "ETAF" :kind 'framework
                      :entries
                      (mapcar (lambda (pair)
                                (list :key (car pair) :label (cdr pair) :source "ETAF"))
                              (append
                               '(("Tab" . "下一个控件") ("Shift+Tab" . "上一个控件")
                                 ("← ↑ ↓ →" . "方向导航"))
                               (when (eq etaf-direction-scheme 'vim)
                                 '(("h j k l" . "Vim 方向导航")))
                               '(("M-g" . "选择区域") ("RET" . "激活当前控件")
                                 ("Esc" . "退出当前一层") ("?" . "查看快捷键")
                                 ("M-x etaf-palette" . "按名称执行命令"))))))))
        (when regions
          (setq groups
                (append groups
                        (list
                         (list :title "区域入口" :source title :kind 'regions
                               :entries
                               (delq nil
                                     (mapcar
                                      (lambda (region)
                                        (when-let* ((key (plist-get region :key)))
                                          (list :key (format "M-g %c" (etaf--regions-key-char key))
                                                :label (etaf--regions-label region)
                                                :source title)))
                                      regions)))))))
        (dolist (ref chain)
          (when-let* ((help (plist-get (etaf--keys-props runtime ref) :help)))
            (setq notes (append notes (if (stringp help) (list help) help)))))
        (dolist (node (etaf--keys-scope-stops runtime))
          (when-let* ((ref (etaf-runtime-node-host-ref runtime node))
                      (label (etaf--keys-control-label runtime ref node)))
            (push label controls)))
        (etaf--help-copy (list :title title :scope scope :groups groups :notes notes
                               :controls (delete-dups (nreverse controls))))))))

(defun etaf-help (&optional runtime)
  "Open read-only key help inside mounted RUNTIME's existing buffer.
The opening scope is captured before the modal takes focus.  Repeated calls
reuse it.  No frame, window, buffer or application Runtime is created.
`etaf-help-view-function' supplies the View; Escape closes it and restores
the effective opening focus and window position.  Before a new opening,
run the nearest enabled Host's :on-help-open callback in the current key
scope.  Its errors abort opening; closing never undoes its application
state changes.  Calls inside an event or batch wait until its pending work
is published before preparing help.  Return the app buffer."
  (interactive)
  (setq runtime (etaf-runtime-require-mounted runtime))
  (etaf-next-tick (lambda () (etaf--help-open runtime)))
  (etaf-runtime-buffer runtime))

(defun etaf--help-open (runtime)
  "Prepare and publish help for mounted RUNTIME after the caller's batch."
  (setq runtime (etaf-runtime-require-mounted runtime))
  (with-current-buffer (etaf-runtime-buffer runtime)
    (unless etaf--help-state
      (when-let* ((finish (etaf-runtime-input-finisher runtime)))
        (funcall finish runtime))
      (when-let* ((prepare
                   (cl-find-if
                    (lambda (ref)
                      (let ((props (etaf--keys-props runtime ref)))
                        (and (functionp (plist-get props :on-help-open))
                             (not (plist-get props :disabled)))))
                    (etaf--keys-chain runtime))))
        (etaf-dispatch-event runtime prepare 'help-open))
      (let* ((data (etaf-help-data runtime))
             (origin (car (etaf--keys-chain runtime)))
             (renderer (or etaf-help-view-function #'etaf--help-default-view))
             (window (get-buffer-window (current-buffer) t))
             (state (list :data data :focus (etaf-focused-host-ref runtime)
                          :point (point) :window window
                          :start (and window (window-start window)))))
        ;; Guard local-map command sequences as well as plain letters.
        ;; The binders fall through again when help closes.
        (dolist (group (plist-get data :groups))
          (dolist (entry (plist-get group :entries))
            (when-let* ((events (plist-get entry :events)))
              (unless (and (> (length events) 1)
                           (member (vector (aref events 0)) etaf--keys-printing-events))
                (etaf--keys-define (etaf-runtime-keymap runtime) events)))))
        (setq etaf--help-state state)
        (condition-case err
            (progn
              ;; Root-layer geometry is relative to the canvas, not an
              ;; Emacs window's native scroll.  Present the modal from the
              ;; canvas top; its saved opener position is restored on close.
              (when window
                (set-window-start window (point-min) t)
                (set-window-point window (point-min)))
              (etaf--runtime-set-surface
               runtime
               (lambda ()
                 (funcall renderer data
                          (lambda () (etaf-help-close runtime))))
               origin))
          ((error quit)
           (setq etaf--help-state nil)
           (goto-char (min (point-max) (plist-get state :point)))
           (when (and (window-live-p window)
                      (eq (window-buffer window) (current-buffer)))
             (set-window-start window (min (point-max) (plist-get state :start)) t))
           (signal (car err) (cdr err))))))
    (current-buffer)))

(defun etaf-help-close (&optional runtime)
  "Close RUNTIME's key help, restoring its surviving focus and window start.
Return non-nil when help was open, otherwise nil.  Closing preserves input
and application state; native C-g is never repurposed as this command."
  (interactive)
  (setq runtime (etaf-runtime-require-mounted runtime))
  (with-current-buffer (etaf-runtime-buffer runtime)
    (when etaf--help-state
      (when-let* ((finish (etaf-runtime-input-finisher runtime)))
        (funcall finish runtime))
      (let ((state etaf--help-state))
        (etaf--runtime-set-surface runtime nil nil)
        (setq etaf--help-state nil)
        ;; An Escape or pointer callback is still inside the outer event
        ;; batch.  Restore only after removing the modal has been published;
        ;; otherwise focus still meets the old modal and its flush resets the
        ;; window start we just restored.
        (etaf-next-tick
         (lambda ()
           (when (etaf-runtime-mounted-p runtime)
             (with-current-buffer (etaf-runtime-buffer runtime)
               (unless etaf--help-state
                 (let ((focus (plist-get state :focus))
                       (window (plist-get state :window)))
                   (if (and focus (etaf-host-ref-position runtime focus))
                       (etaf-focus runtime focus)
                     (goto-char (min (point-max) (plist-get state :point))))
                   (when (and (window-live-p window)
                              (eq (window-buffer window) (current-buffer)))
                     (set-window-start
                      window (min (point-max) (plist-get state :start)) t))))))))
        t))))

(defun etaf--help-default-view (data close)
  "Build the core-only modal fallback for read-only DATA and CLOSE.
The optional catalog replaces this renderer with its searchable key cards."
  (let* ((runtime (etaf-current-runtime))
         (measured (or (etaf-runtime-window-viewport runtime)
                       (etaf-runtime-viewport runtime)))
         ;; The dialog is drawn on the canvas, so its cell is the canvas's
         ;; face, not the frame's: a text scale or a canvas font leaves the
         ;; frame's character width apart from the cells the panel is painted
         ;; in, and the panel would then sit off the centre it measured.
         (metrics (ignore-errors (etaf-display-metrics runtime)))
         (cell (or (plist-get metrics :char-width) (frame-char-width)))
         (viewport (cons (or (car measured) (* 80 cell))
                         (or (cdr measured) 32)))
         (width (max 1 (min 88 (- (/ (car viewport) (max 1 cell)) 4))))
         (height (max 6 (min 28 (- (cdr viewport) 4))))
         (fg (or (etaf-theme-value :ui-panel-fg)
                 (face-foreground 'default nil t)))
         (bg (or (etaf-theme-value :ui-panel-bg)
                 (face-background 'default nil t)))
         (lines (list (format "%s / %s" (plist-get data :title) (plist-get data :scope)))))
    (dolist (group (plist-get data :groups))
      (setq lines (append lines (list "" (concat (plist-get group :title) " · "
                                                  (plist-get group :source)))))
      (dolist (entry (plist-get group :entries))
        (setq lines (append lines (list (format "%s  %s" (plist-get entry :key)
                                                (plist-get entry :label)))))))
    (setq lines (append lines (plist-get data :notes) (plist-get data :controls)))
    (etaf-view
     (fragment
      (box :position 'absolute :layer 'root :left '(px 0) :top '(lh 0)
           :width '(% 100) :height '(% 100) :z-index 1001
           :backdrop-filter '(brightness 0.55) :role 'presentation :tab-index -1
           :on-press (lambda () (when (etaf-event-pointer-p) (funcall close))))
      (column :ref 'etaf-help-panel :position 'absolute :layer 'root :z-index 1001
              :left (list 'px (max 0 (/ (- (car viewport) (* width cell)) 2)))
              :top (list 'lh (max 0 (/ (- (cdr viewport) height) 2)))
              :width (list 'ch width) :height (list 'lh height)
              :role 'dialog :aria-label "快捷键" :focus-scope 'modal
              :on-dismiss close :color fg :background-color bg
              :border (list '(px 1) 'solid fg) :padding '((lh 1) (ch 2))
        (text :font-weight 'bold "快捷键 · 只读")
        (column :ref 'etaf-help-content :tab-index 0
                :height (list 'lh (max 1 (- height 5))) :overflow 'scroll
                :on-direction (lambda (direction)
                                (when (memq direction '(up down))
                                  (etaf-scroll-by runtime 'etaf-help-content
                                                  (if (eq direction 'up) -1 1)))
                                'handled)
          (expr (mapcar (lambda (line) (etaf-view (text (expr line)))) lines)))
        (box :role 'button :tab-index 0 :aria-label "关闭帮助" :on-press close
          "Esc  关闭帮助"))))))

(provide 'etaf-help)
;;; etaf-help.el ends here
