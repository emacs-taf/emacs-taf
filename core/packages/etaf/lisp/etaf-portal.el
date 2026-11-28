;;; etaf-portal.el --- Unified declarative Portal layer for ETAF -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Engine-level declarative `<Portal>' projecting slot content into one of
;; three standard targets:
;; - `in-buffer': root-layer overlay via `etaf-runtime-set-overlay' (escapes
;;   ancestor `overflow: hidden' / scroll containers);
;; - `child-frame': graphical child-frame host registered via
;;   `etaf-portal-register-host' (installed by `etaf-posframe'), falling back
;;   cleanly to `in-buffer' on terminals, batch, or when no host is registered;
;; - `header-line': buffer-local `header-line-format' projection with automatic
;;   save/restore on close or unmount.

;;; Code:

(require 'cl-lib)
(require 'etaf-reactive)
(require 'etaf-view)
(require 'etaf-component)
(require 'etaf-context)
(require 'etaf-runtime)
(require 'etaf-presentation)
(require 'etaf-measure)

(defvar etaf-portal--hosts (make-hash-table :test #'eq)
  "Registry mapping Portal target symbols to host adapter functions.")

(defvar etaf-portal--key-counter 0
  "Monotonic counter for unnamed Portal overlay keys.")

;;;###autoload
(defun etaf-portal-register-host (target host-function)
  "Register HOST-FUNCTION as the Portal host adapter for symbol TARGET.
When HOST-FUNCTION is nil, remove any registered host for TARGET.
HOST-FUNCTION receives a spec plist (:key :parent-buffer :parent-window :title
:width-px :height-rows :max-height-rows :theme :appearance :view :on-close) and
returns a handle plist (:update FN :close FN :frame FRAME :runtime-fn FN) or
nil to fall back to `in-buffer'.  Return HOST-FUNCTION."
  (unless (and (symbolp target) target (not (keywordp target)))
    (signal 'wrong-type-argument (list 'symbolp target)))
  (when (and host-function (not (functionp host-function)))
    (signal 'wrong-type-argument (list 'functionp host-function)))
  (if host-function
      (puthash target host-function etaf-portal--hosts)
    (remhash target etaf-portal--hosts))
  host-function)

;;;###autoload
(defun etaf-portal-host (target)
  "Return the registered Portal host function for symbol TARGET, or nil."
  (and (symbolp target) (gethash target etaf-portal--hosts)))

(defun etaf-portal--resolve-bool (value)
  "Read boolean/reactive VALUE."
  (cond
   ((or (etaf-ref-p value) (etaf-computed-p value)) (etaf-value value))
   ((functionp value) (funcall value))
   (t value)))

(defun etaf-portal--extract-text (nodes)
  "Extract plain inline text from View NODES for `header-line' projection."
  (let (parts)
    (cl-labels
        ((walk (node)
           (cond
            ((null node) nil)
            ((stringp node) (push node parts))
            ((etaf--expr-p node)
             (when-let* ((fn (etaf--expr-thunk node)))
               (walk (ignore-errors (funcall fn)))))
            ((etaf--slot-projection-p node)
             (let ((content (etaf--slot-projection-content node)))
               (walk (if (etaf--slot-content-p content)
                         (etaf--slot-content-children content)
                       content))))
            ((etaf--slot-content-p node)
             (walk (etaf--slot-content-children node)))
            ((etaf--view-node-p node)
             (dolist (kid (etaf--view-node-children node))
               (walk kid)))
            ((listp node)
             (dolist (kid node) (walk kid))))))
      (walk nodes))
    (mapconcat #'identity (nreverse parts) "")))

(defun etaf-portal--positioned-child-p (node)
  "Return non-nil when NODE (or slot projection) has `:position \\='absolute'."
  (cond
   ((etaf--slot-projection-p node)
    (let* ((content (etaf--slot-projection-content node))
           (kids (delq nil (copy-sequence
                            (if (etaf--slot-content-p content)
                                (etaf--slot-content-children content)
                              (and (listp content) content))))))
      (and kids (cl-every #'etaf-portal--positioned-child-p kids))))
   ((etaf--view-node-p node)
    (eq (plist-get (etaf--view-node-props node) :position) 'absolute))))

(defun etaf-portal--wrap-in-buffer (children z-index backdrop on-close &optional width height)
  "Wrap CHILDREN into a root-layer overlay View at Z-INDEX."
  (let* ((non-nil (delq nil (copy-sequence children)))
         (all-positioned (and non-nil
                              (cl-every #'etaf-portal--positioned-child-p non-nil)))
         (body (if all-positioned
                   (etaf-node 'fragment nil non-nil)
                 (etaf-node 'column
                            (append (list :position 'absolute :layer 'root
                                          :z-index z-index)
                                    (when width (list :width width))
                                    (when height (list :height height)))
                            children))))
    (if backdrop
        (etaf-node
         'fragment nil
         (list
          (etaf-node 'box
                     (append (list :position 'absolute :layer 'root
                                   :left '(px 0) :top '(lh 0)
                                   :width '(% 100) :height '(% 100)
                                   :z-index (max 1 (1- z-index))
                                   :backdrop-filter '(brightness 0.55)
                                   :role 'presentation)
                             (when (functionp on-close)
                               (list :on-dismiss on-close
                                     :on-press (lambda () (funcall on-close)))))
                     nil)
          body))
      body)))

(defun etaf-portal--child-frame-view (children-ref)
  "Return a zero-argument View builder reading portal slot CHILDREN-REF."
  (lambda ()
    (etaf-node 'column (list :width 'stretch) (etaf-value children-ref))))

(defun etaf-portal--length-to-px (length char-w)
  "Convert Ebox LENGTH `(px N)' or `(ch N)' to pixels using CHAR-W, or nil."
  (pcase length
    (`(px ,(and n (pred numberp))) (round n))
    (`(ch ,(and n (pred numberp))) (round (* n char-w)))
    ((pred integerp) length)))

(defun etaf-portal--length-to-rows (length)
  "Convert Ebox LENGTH `(lh N)' or integer N to rows, or nil."
  (pcase length
    (`(lh ,(and n (pred integerp))) n)
    ((pred integerp) length)))

(etaf-define-component etaf-portal
    (&key (target 'in-buffer) (open t) name title width height max-height
          (z-index 1000) backdrop on-close header-format)
  "Project slot children into TARGET (`in-buffer', `child-frame', `header-line').
`in-buffer' mounts into the owning Runtime's root overlay layer so content
escapes ancestor clipping; `child-frame' delegates to the host registered via
`etaf-portal-register-host' (falling back to `in-buffer' when unavailable or
non-graphical); `header-line' projects into buffer-local `header-line-format'
and restores the previous header line on close or unmount."
  :validate
  (progn
    (etaf-check-prop :target target
                     (and (symbolp target) target (not (keywordp target))
                          (or (memq target '(in-buffer child-frame header-line))
                              (functionp (etaf-portal-host target))))
                     "in-buffer, child-frame, header-line, or a registered portal target")
    (etaf-check-prop :name name (or (null name) (and (symbolp name) (not (keywordp name))))
                     "nil or a non-keyword symbol")
    (etaf-check-prop :z-index z-index (integerp z-index) "an integer")
    (etaf-check-prop :on-close on-close (or (null on-close) (functionp on-close))
                     "nil or a function"))
  :bindings
  ((overlay-key (or (and (symbolp name) name)
                    (intern (format "etaf-portal-%d"
                                    (cl-incf etaf-portal--key-counter)))))
   (owner-buffer (if-let* ((rt (etaf-current-runtime)))
                     (etaf-runtime-buffer rt)
                   (current-buffer)))
   (spec-box (list nil))
   (portal-children (etaf-ref nil :name 'etaf-portal-children))
   (portal-theme (etaf-ref nil :name 'etaf-portal-theme))
   (portal-appearance (etaf-ref 'light :name 'etaf-portal-appearance)))
  :setup
  (let ((mounted-p nil)
        (overlay-active-p nil)
        (frame-handle nil)
        (saved-header-p nil)
        (saved-header nil))
    (letrec
        ((teardown-targets
          (lambda ()
            (when overlay-active-p
              (setq overlay-active-p nil)
              (when-let* ((rt (and (buffer-live-p owner-buffer)
                                   (etaf-runtime-for-buffer owner-buffer)))
                          ((etaf-runtime-mounted-p rt)))
                (ignore-errors (etaf-runtime-set-overlay rt overlay-key nil))))
            (when frame-handle
              (let ((close-fn (plist-get frame-handle :close)))
                (setq frame-handle nil)
                (when (functionp close-fn)
                  (ignore-errors (funcall close-fn)))))
            (when saved-header-p
              (setq saved-header-p nil)
              (when (buffer-live-p owner-buffer)
                (with-current-buffer owner-buffer
                  (setq-local header-line-format saved-header))))))
         (sync-portal
          (lambda ()
            (when mounted-p
              (let* ((spec (car spec-box))
                     (is-open (plist-get spec :open))
                     (tgt (plist-get spec :target))
                     (kids (plist-get spec :children)))
                (if (not is-open)
                    (funcall teardown-targets)
                  (pcase tgt
                    ('header-line
                     (when (or overlay-active-p frame-handle)
                       (funcall teardown-targets))
                     (when (buffer-live-p owner-buffer)
                       (with-current-buffer owner-buffer
                         (unless saved-header-p
                           (setq saved-header header-line-format
                                 saved-header-p t))
                         (setq-local header-line-format
                                     (plist-get spec :header-value)))))
                    (_
                     (let* ((host-fn (and (not (eq tgt 'in-buffer))
                                          (not noninteractive)
                                          (display-graphic-p)
                                          (etaf-portal-host tgt)))
                            (win (and host-fn (buffer-live-p owner-buffer)
                                      (get-buffer-window owner-buffer t))))
                       (if (and host-fn (window-live-p win))
                           (progn
                             (when (or overlay-active-p saved-header-p)
                               (funcall teardown-targets))
                             (setf (etaf-value portal-children) kids)
                             (when (plist-get spec :theme)
                               (setf (etaf-value portal-theme) (plist-get spec :theme)))
                             (when (memq (plist-get spec :appearance) '(light dark))
                               (setf (etaf-value portal-appearance)
                                     (plist-get spec :appearance)))
                             (if frame-handle
                                 (when-let* ((upd (plist-get frame-handle :update)))
                                   (ignore-errors (funcall upd spec)))
                               (let ((handle
                                      (funcall
                                       host-fn
                                       (list :key (cons owner-buffer overlay-key)
                                             :parent-buffer owner-buffer
                                             :parent-window win
                                             :panel overlay-key
                                             :title (plist-get spec :title)
                                             :width-px (plist-get spec :width-px)
                                             :height-rows (plist-get spec :height-rows)
                                             :max-height-rows (plist-get spec :max-height-rows)
                                             :theme portal-theme
                                             :appearance portal-appearance
                                             :view (etaf-portal--child-frame-view
                                                    portal-children)
                                             :on-close (plist-get spec :on-close)))))
                                 (if handle
                                     (setq frame-handle handle)
                                   ;; Host declined: fall back cleanly to in-buffer overlay.
                                   (when-let* ((rt (etaf-runtime-for-buffer owner-buffer))
                                               ((etaf-runtime-mounted-p rt)))
                                     (etaf-runtime-set-overlay
                                      rt overlay-key
                                      (etaf-portal--wrap-in-buffer
                                       kids (plist-get spec :z-index)
                                       (plist-get spec :backdrop)
                                       (plist-get spec :on-close)
                                       (plist-get spec :width)
                                       (plist-get spec :height)))
                                     (setq overlay-active-p t))))))
                         ;; Default / fallback: mount in owning Runtime root overlay.
                         (when (or frame-handle saved-header-p)
                           (funcall teardown-targets))
                         (when-let* ((rt (and (buffer-live-p owner-buffer)
                                              (etaf-runtime-for-buffer owner-buffer)))
                                     ((etaf-runtime-mounted-p rt)))
                           (etaf-runtime-set-overlay
                            rt overlay-key
                            (etaf-portal--wrap-in-buffer
                             kids (plist-get spec :z-index)
                             (plist-get spec :backdrop)
                             (plist-get spec :on-close)
                             (plist-get spec :width)
                             (plist-get spec :height)))
                           (setq overlay-active-p t))))))))))))
      (etaf-on-mounted
       (lambda ()
         (setq mounted-p t)
         (etaf-next-tick sync-portal)))
      (etaf-on-updated
       (lambda ()
         (etaf-next-tick sync-portal)))
      (etaf-on-unmounted
       (lambda ()
         (setq mounted-p nil)
         (funcall teardown-targets)))))
  :render
  (let* ((is-open (and (etaf-portal--resolve-bool open) t))
         (kids (when is-open (etaf-current-slot 'default)))
         (metrics (ignore-errors (etaf-display-metrics)))
         (char-w (max 1 (or (plist-get metrics :char-width) 8)))
         (theme-raw (etaf-inject 'theme nil))
         (theme-val (cond ((or (etaf-ref-p theme-raw) (etaf-computed-p theme-raw))
                           (etaf-value theme-raw))
                          (t theme-raw)))
         (app-mode (ignore-errors (etaf-appearance)))
         (header-val
          (when (and is-open (eq target 'header-line))
            (cond
             ((or (etaf-ref-p header-format) (etaf-computed-p header-format))
              (etaf-value header-format))
             ((functionp header-format) (funcall header-format))
             (header-format header-format)
             (t (etaf-portal--extract-text kids))))))
    (setcar spec-box
            (list :open is-open
                  :target target
                  :title title
                  :width width
                  :height height
                  :width-px (etaf-portal--length-to-px width char-w)
                  :height-rows (etaf-portal--length-to-rows height)
                  :max-height-rows (etaf-portal--length-to-rows max-height)
                  :z-index z-index
                  :backdrop backdrop
                  :on-close on-close
                  :header-value header-val
                  :theme (and (proper-list-p theme-val) theme-val)
                  :appearance app-mode
                  :children kids))
    nil))

(provide 'etaf-portal)
;;; etaf-portal.el ends here
