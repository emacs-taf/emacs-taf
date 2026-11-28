;;; etaf-devtools-target.el --- Target Runtime tracking and hooks -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Discovers live mounted ETAF Runtimes while strictly excluding DevTools' own
;; buffers and floating badges to prevent self-inspection loops.  Manages
;; lifecycle/flush hooks, Highlight Updates state and `etaf-performance'
;; recording attachment.

;;; Code:

(require 'cl-lib)
(require 'etaf)
(require 'etaf-devtools-core)
(require 'etaf-devtools-overlay)

(defconst etaf-devtools--buffer-name "*etaf-devtools*"
  "Buffer name of the docked `etaf-devtools' panel.")

(defvar etaf-devtools--own-buffers (make-hash-table :test #'eq :weakness 'key)
  "Weak set of buffers owned by `etaf-devtools' itself (never inspected).")

(defvar etaf-devtools--creating-own-surface nil
  "Dynamically non-nil while `etaf-devtools' mounts its own posframe or badge.")

(defvar etaf-devtools--highlight-buffers (make-hash-table :test #'eq :weakness 'key)
  "Buffers with Highlight Updates currently enabled.")

(defvar etaf-devtools--listeners nil
  "Active DevTools listener callbacks invoked on target Runtime events.")

(defvar etaf-devtools--hooks-installed nil
  "Non-nil while global ETAF Runtime observation hooks are installed.")

(defun etaf-devtools--register-own-buffer (buffer)
  "Mark BUFFER as owned by `etaf-devtools' so it is never inspected."
  (when (buffer-live-p buffer)
    (puthash buffer t etaf-devtools--own-buffers)))

(defun etaf-devtools--own-buffer-p (buffer)
  "Return non-nil when BUFFER belongs to `etaf-devtools' itself."
  (and (bufferp buffer)
       (or (gethash buffer etaf-devtools--own-buffers)
           (let ((name (buffer-name buffer)))
             (and name
                  (or (string= name etaf-devtools--buffer-name)
                      (string-prefix-p " *etaf-posframe:etaf-devtools" name)))))))

(defun etaf-devtools--own-runtime-p (runtime)
  "Return non-nil when RUNTIME belongs to `etaf-devtools'."
  (and runtime
       (etaf-devtools--own-buffer-p (etaf-runtime-buffer runtime))))

(defun etaf-devtools--candidate-runtimes ()
  "Return all live mounted ETAF Runtimes excluding DevTools' own."
  (cl-remove-if #'etaf-devtools--own-runtime-p (etaf-runtime-list)))

(defun etaf-devtools--runtime-label (runtime)
  "Return concise display label for RUNTIME."
  (let ((buf (and runtime (etaf-runtime-buffer runtime))))
    (if (buffer-live-p buf)
        (buffer-name buf)
      "<unmounted>")))

(defun etaf-devtools--highlight-enabled-p (runtime)
  "Return non-nil when Highlight Updates is active for RUNTIME."
  (let ((buf (and runtime (etaf-runtime-buffer runtime))))
    (and (buffer-live-p buf)
         (gethash buf etaf-devtools--highlight-buffers))))

(defun etaf-devtools--set-highlight-updates (runtime enabled)
  "Enable or disable Highlight Updates for RUNTIME."
  (let ((buf (and runtime (etaf-runtime-buffer runtime))))
    (when (buffer-live-p buf)
      (if enabled
          (puthash buf t etaf-devtools--highlight-buffers)
        (remhash buf etaf-devtools--highlight-buffers)
        (etaf-devtools--overlay-clear-flashes buf))
      (etaf-devtools--sync-hooks)
      (and enabled t))))

(defun etaf-devtools--notify (event runtime &optional data)
  "Dispatch EVENT for RUNTIME with optional DATA to registered listeners."
  (dolist (fn (copy-sequence etaf-devtools--listeners))
    (condition-case nil
        (funcall fn event runtime data)
      (error nil))))

(defun etaf-devtools--on-mount (runtime)
  "Handle `etaf-runtime-mount-functions' for RUNTIME."
  (when etaf-devtools--creating-own-surface
    (etaf-devtools--register-own-buffer (etaf-runtime-buffer runtime)))
  (unless (etaf-devtools--own-runtime-p runtime)
    (etaf-devtools--notify 'mount runtime)))

(defun etaf-devtools--on-commit (runtime)
  "Handle `etaf-runtime-after-commit-functions' for RUNTIME."
  (unless (etaf-devtools--own-runtime-p runtime)
    (let ((summary (condition-case nil
                       (etaf-runtime-commit-summary runtime)
                     (error nil))))
      (etaf-devtools--notify 'commit runtime summary))))

(defun etaf-devtools--on-flush (runtime)
  "Handle `etaf-runtime-after-flush-functions' for RUNTIME."
  (unless (etaf-devtools--own-runtime-p runtime)
    (let ((report (condition-case nil
                      (etaf-runtime-update-report runtime)
                    (error nil))))
      (when (and report (etaf-devtools--highlight-enabled-p runtime))
        (etaf-devtools--overlay-flash-report runtime report))
      (etaf-devtools--notify 'flush runtime report))))

(defun etaf-devtools--on-unmount (runtime)
  "Handle `etaf-runtime-unmount-functions' for RUNTIME."
  (unless (etaf-devtools--own-runtime-p runtime)
    (let ((buf (etaf-runtime-buffer runtime)))
      (when (bufferp buf)
        (remhash buf etaf-devtools--highlight-buffers)
        (etaf-devtools--overlay-clear-flashes buf)))
    (etaf-devtools--notify 'unmount runtime)
    (etaf-devtools--sync-hooks)))

(defun etaf-devtools--sync-hooks ()
  "Install Runtime hooks only when listeners or Highlight Updates are active."
  (let ((need (or etaf-devtools--listeners
                  (> (hash-table-count etaf-devtools--highlight-buffers) 0))))
    (cond
     ((and need (not etaf-devtools--hooks-installed))
      (add-hook 'etaf-runtime-mount-functions #'etaf-devtools--on-mount)
      (add-hook 'etaf-runtime-after-commit-functions #'etaf-devtools--on-commit)
      (add-hook 'etaf-runtime-after-flush-functions #'etaf-devtools--on-flush)
      (add-hook 'etaf-runtime-unmount-functions #'etaf-devtools--on-unmount)
      (setq etaf-devtools--hooks-installed t))
     ((and (not need) etaf-devtools--hooks-installed)
      (remove-hook 'etaf-runtime-mount-functions #'etaf-devtools--on-mount)
      (remove-hook 'etaf-runtime-after-commit-functions #'etaf-devtools--on-commit)
      (remove-hook 'etaf-runtime-after-flush-functions #'etaf-devtools--on-flush)
      (remove-hook 'etaf-runtime-unmount-functions #'etaf-devtools--on-unmount)
      (setq etaf-devtools--hooks-installed nil)))))

(defun etaf-devtools--add-listener (fn)
  "Register FN as a DevTools Runtime observer."
  (unless (memq fn etaf-devtools--listeners)
    (push fn etaf-devtools--listeners))
  (etaf-devtools--sync-hooks))

(defun etaf-devtools--remove-listener (fn)
  "Unregister FN and remove global hooks when idle."
  (setq etaf-devtools--listeners (delq fn etaf-devtools--listeners))
  (etaf-devtools--sync-hooks))

(provide 'etaf-devtools-target)
;;; etaf-devtools-target.el ends here
