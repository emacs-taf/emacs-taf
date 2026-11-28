;;; etaf-devtools-picker.el --- Interactive Element Picker (GUI + TTY) -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Provides a non-invasive Element Picker over a target ETAF buffer.
;; Supports both pointer click/selection in graphical frames and pure keyboard
;; navigation in graphical or terminal frames (`[' / `]' walk up/down the
;; enclosing Host chain, `RET' or click confirms, `ESC' / `C-g' cancels).

;;; Code:

(require 'cl-lib)
(require 'etaf)
(require 'etaf-devtools-core)
(require 'etaf-devtools-overlay)
(require 'etaf-devtools-model)

(defvar etaf-devtools--picker-state nil
  "Active picker plist while picking an element, or nil.")

(defun etaf-devtools--picker-update-at (pos &optional lineage-index)
  "Update picker highlight for buffer position POS in active target."
  (when-let* ((st etaf-devtools--picker-state)
              (rt (plist-get st :runtime))
              ((etaf-runtime-mounted-p rt)))
    (let* ((chain (or (condition-case nil
                          (etaf-runtime-host-id-at rt pos)
                        (error nil))
                      (plist-get st :chain)))
           (idx (if chain
                    (max 0 (min (or lineage-index 0) (1- (length chain))))
                  0))
           (hid (and chain (nth idx chain))))
      (plist-put st :chain chain)
      (plist-put st :index idx)
      (plist-put st :host-id hid)
      (if hid
          (progn
            (etaf-devtools--overlay-highlight-host rt hid t)
            (when-let* ((info (condition-case nil
                                  (etaf-runtime-inspect-host rt hid)
                                (error nil))))
              (let ((geo (plist-get info :geometry)))
                (message "拾取 [%d/%d]: %s  %s  (点击/RET 确认 · [/] 切层级 · ESC 取消)"
                         (1+ idx) (length chain)
                         (etaf-devtools--host-label info)
                         (if geo
                             (format "%dpx × %dL"
                                     (or (plist-get geo :width) 0)
                                     (or (plist-get geo :height) 0))
                           "")))))
        (etaf-devtools--overlay-clear-selection)
        (message "拾取: 移动光标到目标元素 (点击/RET 确认 · ESC 取消)")))))

(defun etaf-devtools--picker-stop (&optional keep-highlight)
  "End active Element Picker session cleanly."
  (when-let* ((st etaf-devtools--picker-state))
    (setq etaf-devtools--picker-state nil)
    (when-let* ((exit-fn (plist-get st :exit-fn)))
      (ignore-errors (funcall exit-fn)))
    (when-let* ((session (plist-get st :session)))
      (when (etaf-devtools-session-alive-p session)
        (etaf-set-value (etaf-devtools-session-picker-active-ref session) nil)))
    (unless keep-highlight
      (etaf-devtools--overlay-clear-selection))))

(defun etaf-devtools--picker-confirm ()
  "Confirm currently hovered Host in Element Picker."
  (when-let* ((st etaf-devtools--picker-state))
    (let ((session (plist-get st :session))
          (rt (plist-get st :runtime))
          (hid (plist-get st :host-id))
          (on-pick (plist-get st :on-pick)))
      (etaf-devtools--picker-stop t)
      (when (and hid rt (etaf-runtime-mounted-p rt))
        (if (functionp on-pick)
            (funcall on-pick rt hid)
          (when (and session (etaf-devtools-session-alive-p session))
            (etaf-devtools--session-select-node session 'host hid t t)))
        (message "已选中 Host #%d" hid)))))

(defun etaf-devtools--picker-cancel ()
  "Cancel Element Picker without changing DevTools selection."
  (etaf-devtools--picker-stop nil)
  (message "已取消元素拾取"))

(defun etaf-devtools--picker-parent ()
  "Move picker preview one level outward to parent Host."
  (when-let* ((st etaf-devtools--picker-state)
              (buf (plist-get st :buffer))
              ((buffer-live-p buf)))
    (with-current-buffer buf
      (etaf-devtools--picker-update-at (point) (1+ (or (plist-get st :index) 0))))))

(defun etaf-devtools--picker-child ()
  "Move picker preview one level inward toward innermost Host."
  (when-let* ((st etaf-devtools--picker-state)
              (buf (plist-get st :buffer))
              ((buffer-live-p buf)))
    (with-current-buffer buf
      (etaf-devtools--picker-update-at (point) (max 0 (1- (or (plist-get st :index) 0)))))))

(defun etaf-devtools--picker-move (dir)
  "Move point in target buffer by DIR and refresh picker highlight."
  (when-let* ((st etaf-devtools--picker-state)
              (buf (plist-get st :buffer))
              ((buffer-live-p buf)))
    (with-current-buffer buf
      (pcase dir
        ('up (forward-line -1))
        ('down (forward-line 1))
        ('left (unless (bobp) (backward-char 1)))
        ('right (unless (eobp) (forward-char 1))))
      (etaf-devtools--picker-update-at (point) 0))))

(defun etaf-devtools--picker-mouse-click (event)
  "Pick the Host under mouse EVENT in the target buffer."
  (when-let* ((st etaf-devtools--picker-state)
              (posn (event-start event))
              (win (posn-window posn))
              (pt (posn-point posn))
              (buf (plist-get st :buffer)))
    (if (and (window-live-p win) (eq (window-buffer win) buf) (integerp pt))
        (progn
          (with-current-buffer buf
            (goto-char pt)
            (etaf-devtools--picker-update-at pt 0))
          (etaf-devtools--picker-confirm))
      (etaf-devtools--picker-cancel))))

(defun etaf-devtools--picker-start (session runtime &optional on-pick)
  "Start interactive Element Picker on RUNTIME for SESSION.
ON-PICK, when non-nil, is called with `(RUNTIME HOST-ID)' on confirmation."
  (etaf-devtools--picker-stop nil)
  (unless (and runtime (etaf-runtime-mounted-p runtime))
    (user-error "没有已挂载的 ETAF 目标可供拾取"))
  (let* ((buf (etaf-runtime-buffer runtime))
         (win (or (get-buffer-window buf t) (display-buffer buf))))
    (when (window-live-p win)
      (select-window win))
    (let ((map (make-sparse-keymap))
          (confirm (lambda () (interactive) (etaf-devtools--picker-confirm)))
          (cancel (lambda () (interactive) (etaf-devtools--picker-cancel))))
      (define-key map (kbd "RET") confirm)
      (define-key map (kbd "<return>") confirm)
      (define-key map (kbd "SPC") confirm)
      (define-key map (kbd "<escape>") cancel)
      (define-key map (kbd "C-g") cancel)
      (define-key map (kbd "q") cancel)
      (define-key map (kbd "[") (lambda () (interactive) (etaf-devtools--picker-parent)))
      (define-key map (kbd "]") (lambda () (interactive) (etaf-devtools--picker-child)))
      (define-key map (kbd "<up>") (lambda () (interactive) (etaf-devtools--picker-move 'up)))
      (define-key map (kbd "<down>") (lambda () (interactive) (etaf-devtools--picker-move 'down)))
      (define-key map (kbd "<left>") (lambda () (interactive) (etaf-devtools--picker-move 'left)))
      (define-key map (kbd "<right>") (lambda () (interactive) (etaf-devtools--picker-move 'right)))
      (define-key map (kbd "k") (lambda () (interactive) (etaf-devtools--picker-move 'up)))
      (define-key map (kbd "j") (lambda () (interactive) (etaf-devtools--picker-move 'down)))
      (define-key map (kbd "h") (lambda () (interactive) (etaf-devtools--picker-move 'left)))
      (define-key map (kbd "l") (lambda () (interactive) (etaf-devtools--picker-move 'right)))
      (define-key map (kbd "p") (lambda () (interactive) (etaf-devtools--picker-move 'up)))
      (define-key map (kbd "n") (lambda () (interactive) (etaf-devtools--picker-move 'down)))
      (define-key map (kbd "<mouse-1>")
                  (lambda (event) (interactive "e") (etaf-devtools--picker-mouse-click event)))
      (define-key map (kbd "<down-mouse-1>") #'ignore)
      (when (and session (etaf-devtools-session-alive-p session))
        (etaf-set-value (etaf-devtools-session-picker-active-ref session) t))
      (let* ((st (list :session session :runtime runtime :buffer buf
                       :on-pick on-pick :chain nil :index 0 :host-id nil :exit-fn nil))
             (exit-fn (set-transient-map
                       map
                       (lambda () (and etaf-devtools--picker-state t))
                       (lambda ()
                         (when etaf-devtools--picker-state
                           (etaf-devtools--picker-stop nil))))))
        (plist-put st :exit-fn exit-fn)
        (setq etaf-devtools--picker-state st)
        (with-current-buffer buf
          (etaf-devtools--picker-update-at (point) 0))
        t))))

(provide 'etaf-devtools-picker)
;;; etaf-devtools-picker.el ends here
