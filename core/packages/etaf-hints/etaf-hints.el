;;; etaf-hints.el --- Vimium-style quick jump hints extension for ETAF -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later
;; Author: ETAF contributors
;; Version: 0.1.3
;; Package-Requires: ((emacs "29.1") (etaf "0.3.10") (etaf-ui "0.3.6") (etaf-ext "0.1.0"))
;; Keywords: convenience, extensions, ui
;; URL: https://github.com/emacs-taf/etaf

;;; Commentary:

;; Standalone Vimium-style quick-jump extension built strictly on `etaf-ext''s
;; public API.  Invoking `etaf-hints-start' overlays prefix-free letter badges
;; over every visible clickable or focusable Host in the current ETAF page;
;; typing a code dispatches semantic press or focus and removes the overlay
;; cleanly.
;;
;; Public API
;;
;; Load this package with (require 'etaf-hints) after adding this repository,
;; ETAF, ETAF UI, ETAF Ext, Ebox and ECSS roots to `load-path'.  Only the
;; interfaces listed below are supported for use by other packages; unlisted
;; symbols are internal even without a double hyphen.  docs/manual.md contains
;; workflows.
;;
;; Variable: etaf-hints-alphabet
;; String of characters used to generate prefix-free quick-jump hint codes.
;;
;; Function: etaf-hints-register ()
;;;###autoload (autoload 'etaf-hints-register "etaf-hints" nil nil)
;; Register or re-register the `etaf-hints' extension inside `etaf-ext'.
;;
;; Function: etaf-hints-start (&optional runtime)
;;;###autoload (autoload 'etaf-hints-start "etaf-hints" nil t)
;; Interactive command activating quick-jump hint badges on mounted RUNTIME.
;;
;; Function: etaf-hints-input (keys &optional runtime)
;;;###autoload (autoload 'etaf-hints-input "etaf-hints" nil nil)
;; Feed hint character string KEYS into the active hint session on RUNTIME.
;; Return `:activated', `:prefix' or `:cancelled'.
;;
;; Function: etaf-hints-cancel (&optional runtime)
;;;###autoload (autoload 'etaf-hints-cancel "etaf-hints" nil t)
;; Interactive command cancelling any active hint overlay on RUNTIME.
;;
;; Function: etaf-hints-active-codes (&optional runtime)
;;;###autoload (autoload 'etaf-hints-active-codes "etaf-hints" nil nil)
;; Return alist of `(CODE . HOST-ID)' currently displayed on RUNTIME, or nil.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'etaf)
(require 'etaf-ui)
(require 'etaf-ext)

(defgroup etaf-hints nil
  "Vimium-style quick-jump hints extension for ETAF."
  :group 'etaf-ext
  :prefix "etaf-hints-")

(defcustom etaf-hints-alphabet "asdfghjklqwertyuiop"
  "Characters used to generate prefix-free quick-jump hint labels."
  :type 'string
  :group 'etaf-hints)

(defun etaf-hints--generate-codes (count)
  "Generate COUNT prefix-free hint codes from `etaf-hints-alphabet'."
  (let* ((chars (cl-loop for c across etaf-hints-alphabet
                         collect (char-to-string c)))
         (n (length chars)))
    (cond
     ((<= count 0) nil)
     ((<= count n)
      (cl-subseq chars 0 count))
     (t
      (let ((out nil))
        (catch 'done
          (dolist (a chars)
            (dolist (b chars)
              (push (concat a b) out)
              (when (>= (length out) count)
                (throw 'done nil)))))
        (nreverse out))))))

(defun etaf-hints--collect-targets (tree)
  "Collect interactive Host plists from read-only Host TREE."
  (let ((acc nil))
    (cl-labels ((walk (node)
                  (when (listp node)
                    (let* ((props (plist-get node :props))
                           (disabled (plist-get props :disabled))
                           (has-press (plist-get props :has-on-press))
                           (tab (plist-get props :tab-index))
                           (focusable (and (integerp tab) (>= tab 0))))
                      (when (and (not disabled) (or has-press focusable))
                        (push (list :id (plist-get node :id)
                                    :tag (plist-get node :tag)
                                    :press has-press
                                    :focusable focusable)
                              acc)))
                    (dolist (child (plist-get node :children))
                      (walk child)))))
      (dolist (root tree) (walk root)))
    (nreverse acc)))

(defun etaf-hints--render-overlay (ctx state)
  "Render floating root-layer hint badges for STATE on CTX."
  (let* ((prefix (or (plist-get state :prefix) ""))
         (items (plist-get state :items))
         (matched (cl-remove-if-not
                   (lambda (it)
                     (string-prefix-p prefix (plist-get it :code)))
                   items))
         (theme (etaf-ext-theme))
         (dark (eq (plist-get theme :ext-mode) 'dark))
         (badge-bg (if dark "#EAB308" "#FACC15"))
         (badge-fg "#111827")
         (badge-dim (etaf-ui-color-mix badge-fg badge-bg 0.55))
         (badge-border (if dark "#FEF08A" "#A16207"))
         (children
          (mapcar
           (lambda (it)
             (let* ((code (plist-get it :code))
                    (x (max 0 (or (plist-get it :x) 0)))
                    (y (max 0 (or (plist-get it :y) 0)))
                    (rest (substring code (length prefix))))
               (etaf-node
                'box
                (list :key (plist-get it :id)
                      :layer 'root
                      :position 'absolute
                      :left (list 'px x)
                      :top (list 'lh y)
                      :z-index 900
                      :background-color badge-bg
                      :border (list '(px 1) 'solid badge-border)
                      :padding '((lh 0) (ch 0)))
                (list
                 (etaf-node
                  'flex (list :align-items 'center :gap '((lh 0) (ch 0)))
                  (delq
                   nil
                   (list
                    (unless (string-empty-p prefix)
                      (etaf-node 'text (list :color badge-dim :font-weight 'bold)
                                 (list (upcase prefix))))
                    (etaf-node 'text (list :color badge-fg :font-weight 'bold)
                               (list (format " %s " (upcase rest)))))))))))
           matched)))
    (if children
        (etaf-ext-set-overlay ctx (etaf-node 'fragment nil children))
      (etaf-ext-clear-overlay ctx))))

(defun etaf-hints--stop (ctx)
  "Clear hint overlay and transient state for CTX."
  (when-let* ((st (etaf-ext-ctx-state ctx))
              (exit-fn (plist-get st :exit-map)))
    (when (functionp exit-fn)
      (ignore-errors (funcall exit-fn))))
  (etaf-ext-ctx-set-state ctx nil)
  (ignore-errors (etaf-ext-clear-overlay ctx))
  nil)

(defun etaf-hints--handle-char (ctx ch)
  "Feed single hint character CH into CTX's active hint session.
Return `:activated', `:prefix', or `:cancelled'."
  (let* ((st (etaf-ext-ctx-state ctx))
         (items (plist-get st :items))
         (prefix (concat (or (plist-get st :prefix) "") (downcase ch)))
         (matches (cl-remove-if-not
                   (lambda (it)
                     (string-prefix-p prefix (plist-get it :code)))
                   items)))
    (cond
     ((null matches)
      (etaf-hints--stop ctx)
      :cancelled)
     ((and (= (length matches) 1)
           (string= (plist-get (car matches) :code) prefix))
      (let* ((target (car matches))
             (hid (plist-get target :id))
             (has-press (plist-get target :press)))
        (etaf-hints--stop ctx)
        (if has-press
            (etaf-ext-press ctx hid)
          (etaf-ext-focus ctx hid))
        :activated))
     (t
      (let ((next-st (plist-put (copy-sequence st) :prefix prefix)))
        (etaf-ext-ctx-set-state ctx next-st)
        (etaf-hints--render-overlay ctx next-st)
        :prefix)))))

(defun etaf-hints--install-transient (ctx)
  "Install transient keymap capturing hint letters while hints are active."
  (unless noninteractive
    (let ((map (make-sparse-keymap)))
      (cl-loop for c across etaf-hints-alphabet
               for s = (char-to-string c)
               do (let ((key s))
                    (define-key map key
                      (lambda ()
                        (interactive)
                        (etaf-hints--handle-char ctx key)))
                    (define-key map (upcase key)
                      (lambda ()
                        (interactive)
                        (etaf-hints--handle-char ctx key)))))
      (define-key map (kbd "C-g")
        (lambda () (interactive) (etaf-hints--stop ctx)))
      (define-key map [escape]
        (lambda () (interactive) (etaf-hints--stop ctx)))
      (let ((exit-fn
             (set-transient-map
              map
              (lambda () (and (etaf-ext-ctx-state ctx) t))
              (lambda ()
                (when (etaf-ext-ctx-state ctx)
                  (etaf-ext-ctx-set-state ctx nil)
                  (ignore-errors (etaf-ext-clear-overlay ctx)))))))
        (etaf-ext-ctx-set-state
         ctx
         (plist-put (copy-sequence (etaf-ext-ctx-state ctx))
                    :exit-map exit-fn))))))

(defun etaf-hints--cmd-jump (ctx)
  "Command entry point activating quick-jump hints on CTX."
  (if (etaf-ext-ctx-state ctx)
      (progn
        (etaf-hints--stop ctx)
        nil)
    (let* ((tree (etaf-ext-tree ctx))
           (targets (etaf-hints--collect-targets tree))
           (geos (etaf-ext-geometries ctx (mapcar (lambda (x) (plist-get x :id)) targets)))
           (visible nil))
      (dolist (tgt targets)
        (when-let* ((geo (cdr (assq (plist-get tgt :id) geos)))
                    ((plist-get geo :visible-p))
                    (w (plist-get geo :width))
                    (h (plist-get geo :height))
                    ((and (numberp w) (> w 0) (numberp h) (> h 0))))
          (push (append tgt (list :x (plist-get geo :x)
                                  :y (plist-get geo :y)
                                  :width w :height h))
                visible)))
      (setq visible (nreverse visible))
      (if (null visible)
          (progn
            (etaf-ext-notify ctx "快捷跳转" :detail "当前视口内没有可点击或可聚焦元素")
            nil)
        (let* ((codes (etaf-hints--generate-codes (length visible)))
               (items (cl-mapcar (lambda (tgt code)
                                   (plist-put (copy-sequence tgt) :code code))
                                 visible codes))
               (state (list :prefix "" :items items)))
          (etaf-ext-ctx-set-state ctx state)
          (etaf-hints--render-overlay ctx state)
          (etaf-hints--install-transient ctx)
          (mapcar (lambda (it) (cons (plist-get it :code) (plist-get it :id)))
                  items))))))

(defun etaf-hints--badge (ctx)
  "Return compact mode-line badge text while hints are active on CTX."
  (when-let* ((st (etaf-ext-ctx-state ctx))
              (items (plist-get st :items)))
    (list :text (format "跳%d" (length items)) :variant 'warning)))

(defun etaf-hints--on-detach (ctx)
  "Cleanly exit any active hint session on detach."
  (etaf-hints--stop ctx))

;;;; Public API

;;;###autoload
(defun etaf-hints-start (&optional runtime)
  "Activate Vimium-style quick-jump hints on mounted RUNTIME."
  (interactive)
  (etaf-ext-run-command 'etaf-hints 'jump runtime))

(defun etaf-hints-input (keys &optional runtime)
  "Feed hint letter string KEYS into the active hint session on RUNTIME.
Return `:activated', `:prefix', or `:cancelled'."
  (let* ((rt (or runtime (etaf-current-runtime)
                 (etaf-runtime-for-buffer (current-buffer))))
         (ctx (and rt (etaf-ext-attach 'etaf-hints rt)))
         (result :cancelled))
    (when (and ctx (stringp keys))
      (cl-loop for ch across keys
               while (etaf-ext-ctx-state ctx)
               do (setq result (etaf-hints--handle-char ctx (char-to-string ch)))))
    result))

;;;###autoload
(defun etaf-hints-cancel (&optional runtime)
  "Cancel active quick-jump hints on RUNTIME."
  (interactive)
  (when-let* ((ctx (etaf-ext-context 'etaf-hints runtime)))
    (etaf-hints--stop ctx))
  t)

(defun etaf-hints-active-codes (&optional runtime)
  "Return alist of `(CODE . HOST-ID)' currently displayed by `etaf-hints'."
  (when-let* ((ctx (etaf-ext-context 'etaf-hints runtime))
              (st (etaf-ext-ctx-state ctx)))
    (mapcar (lambda (it) (cons (plist-get it :code) (plist-get it :id)))
            (plist-get st :items))))

(defun etaf-hints-register ()
  "Register the standalone `etaf-hints' extension inside `etaf-ext'."
  (etaf-ext-define etaf-hints
    :name "快捷跳转 (Hints)"
    :version "0.1.1"
    :icon "跳"
    :tone 'warning
    :prefix-hint "f"
    :description "在当前 ETAF 页面所有可见可交互元素旁浮现无前缀冲突的字母标签，键入字母直达点击或聚焦。"
    :activation 'on-command
    :matches '(:apps t)
    :priority 20
    :debounce 0.05
    :permissions '(read-tree overlay interact keys notify)
    :commands '((jump :subkey "f" :suggested-key "M-f" :label "显示快捷跳转标签" :fn etaf-hints--cmd-jump))
    :badge #'etaf-hints--badge
    :on-detach #'etaf-hints--on-detach))

(etaf-hints-register)

(provide 'etaf-hints)
;;; etaf-hints.el ends here
