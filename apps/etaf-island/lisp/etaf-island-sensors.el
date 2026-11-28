;;; etaf-island-sensors.el --- Optional native Emacs sensors for ETAF protocol -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Bridges built-in Emacs events (`compilation' and `org-clock') into ETAF's
;; generic `etaf-activity-*' and `etaf-notify' protocol so they appear natively
;; in `etaf-island' and any other shell without custom view code.

;;; Code:

(require 'subr-x)
(require 'etaf)

(declare-function org-clock-clocking-in "org-clock" ())
(declare-function org-clock-out "org-clock" (&optional switch-to-state fail-quietly at-time))
(declare-function org-clock-goto "org-clock" (&optional select))
(declare-function org-clock-get-clocked-time "org-clock" ())
(defvar org-clock-heading)

(defgroup etaf-island nil
  "Dynamic Island shell for ETAF's cross-application activity protocol."
  :group 'etaf
  :prefix "etaf-island-")

(defcustom etaf-island-auto-hide-idle nil
  "When non-nil, hide the floating capsule when no active activity or alert exists."
  :type 'boolean
  :group 'etaf-island)

(defcustom etaf-island-sense-compilation t
  "When non-nil, publish Emacs compilation progress and results to ETAF protocol."
  :type 'boolean
  :group 'etaf-island)

(defcustom etaf-island-sense-org-clock t
  "When non-nil, publish active `org-clock' tasks as live `timer' activities."
  :type 'boolean
  :group 'etaf-island)

(defvar etaf-island--sensors-active nil
  "Non-nil when Emacs native sensor hooks are installed.")

(defvar etaf-island--org-clock-timer nil
  "Lightweight minute-level refresh timer while an `org-clock' task runs.")

;;;; Compilation sensor

(defun etaf-island--on-compile-start (proc)
  "Publish a live `task' activity when compilation PROC starts."
  (when (and etaf-island-sense-compilation (processp proc))
    (let* ((buf (process-buffer proc))
           (bname (if (buffer-live-p buf) (buffer-name buf) "*compilation*"))
           (cmd (mapconcat #'identity (process-command proc) " "))
           (short-cmd (truncate-string-to-width (string-trim cmd) 40 nil nil "…")))
      (etaf-activity-publish
       'emacs-compile
       (list :app 'compile
             :kind 'task
             :state 'active
             :priority 72
             :icon "⟳"
             :tone 'info
             :title (format "编译运行中 · %s" bname)
             :subtitle short-cmd
             :compact "编译中"
             :progress '(:indeterminate t :label "编译中")
             :open (lambda ()
                     (when (buffer-live-p buf)
                       (pop-to-buffer buf)))
             :actions (list (list :id 'open :label "查看日志" :primary t
                                  :fn (lambda ()
                                        (when (buffer-live-p buf)
                                          (pop-to-buffer buf))))))))))

(defun etaf-island--on-compile-finish (buf status)
  "Remove live compile activity and emit an `etaf-notify' pulse on finish."
  (when etaf-island-sense-compilation
    (etaf-activity-remove 'emacs-compile)
    (let* ((msg (string-trim (or status "")))
           (ok (string-prefix-p "finished" msg))
           (bname (if (buffer-live-p buf) (buffer-name buf) "*compilation*")))
      (etaf-notify
       (if ok (format "编译通过 · %s" bname) (format "编译失败 · %s" bname))
       :app 'compile
       :detail msg
       :variant (if ok 'success 'danger)
       :group 'compile
       :ttl (if ok 5.0 8.0)
       :actions (list (list :id 'open
                            :label (format "查看 %s" bname)
                            :primary t
                            :fn (lambda ()
                                  (when (buffer-live-p buf)
                                    (pop-to-buffer buf)))))))))

;;;; Org-Clock sensor

(defun etaf-island--sync-org-clock ()
  "Publish or clear the live `org-clock' timer activity."
  (if (and etaf-island-sense-org-clock
           (fboundp 'org-clocking-p)
           (org-clocking-p))
      (let* ((heading (or (and (boundp 'org-clock-heading) org-clock-heading)
                          "Org 计时任务"))
             (mins (if (fboundp 'org-clock-get-clocked-time)
                       (or (ignore-errors (org-clock-get-clocked-time)) 0)
                     0))
             (clock-str (format "%02d:%02d" (/ mins 60) (% mins 60))))
        (etaf-activity-publish
         'org-clock
         (list :app 'org-clock
               :kind 'timer
               :state 'active
               :priority 75
               :icon "●"
               :tone 'success
               :title (substring-no-properties heading)
               :subtitle (format "Org Clock 已计时 %s" clock-str)
               :compact (format "计时 %s" clock-str)
               :open (lambda ()
                       (when (fboundp 'org-clock-goto)
                         (org-clock-goto)))
               :actions (list (list :id 'goto :label "跳转任务" :primary t
                                    :fn (lambda ()
                                          (when (fboundp 'org-clock-goto)
                                            (org-clock-goto))))
                              (list :id 'out :label "结束计时"
                                    :fn (lambda ()
                                          (when (fboundp 'org-clock-out)
                                            (org-clock-out))))))))
    (etaf-activity-remove 'org-clock)
    (when (timerp etaf-island--org-clock-timer)
      (cancel-timer etaf-island--org-clock-timer)
      (setq etaf-island--org-clock-timer nil))))

(defun etaf-island--on-org-clock-in ()
  "Start mirroring active `org-clock' into `etaf-activity'."
  (etaf-island--sync-org-clock)
  (when (and etaf-island-sense-org-clock (not noninteractive))
    (when (timerp etaf-island--org-clock-timer)
      (cancel-timer etaf-island--org-clock-timer))
    (setq etaf-island--org-clock-timer
          (run-with-timer 30 30 #'etaf-island--sync-org-clock))))

(defun etaf-island--on-org-clock-out ()
  "Stop mirroring `org-clock' when clocked out or cancelled."
  (etaf-island--sync-org-clock))

;;;; Lifecycle

(defun etaf-island--sensors-enable ()
  "Install native Emacs sensor hooks into the ETAF protocol."
  (unless etaf-island--sensors-active
    (add-hook 'compilation-start-hook #'etaf-island--on-compile-start)
    (add-hook 'compilation-finish-functions #'etaf-island--on-compile-finish)
    (add-hook 'org-clock-in-hook #'etaf-island--on-org-clock-in)
    (add-hook 'org-clock-out-hook #'etaf-island--on-org-clock-out)
    (add-hook 'org-clock-cancel-hook #'etaf-island--on-org-clock-out)
    (setq etaf-island--sensors-active t))
  (etaf-island--sync-org-clock))

(defun etaf-island--sensors-disable ()
  "Remove native Emacs sensor hooks and clean up their activities."
  (when etaf-island--sensors-active
    (remove-hook 'compilation-start-hook #'etaf-island--on-compile-start)
    (remove-hook 'compilation-finish-functions #'etaf-island--on-compile-finish)
    (remove-hook 'org-clock-in-hook #'etaf-island--on-org-clock-in)
    (remove-hook 'org-clock-out-hook #'etaf-island--on-org-clock-out)
    (remove-hook 'org-clock-cancel-hook #'etaf-island--on-org-clock-out)
    (setq etaf-island--sensors-active nil))
  (when (timerp etaf-island--org-clock-timer)
    (cancel-timer etaf-island--org-clock-timer)
    (setq etaf-island--org-clock-timer nil))
  (etaf-activity-remove 'emacs-compile)
  (etaf-activity-remove 'org-clock))

(provide 'etaf-island-sensors)
;;; etaf-island-sensors.el ends here
