;;; etaf-devtools-ui.el --- Docked & floating DevTools host and commands -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Manages the active `etaf-devtools' host window (right side window, bottom
;; side window or floating `etaf-posframe'), preserves the user's native Emacs
;; mode-line, isolates DevTools' own buffers from self-inspection, and exposes
;; the public interactive commands.

;;; Code:

(require 'cl-lib)
(require 'etaf)
(require 'etaf-ui)
(require 'etaf-devtools-core)
(require 'etaf-devtools-overlay)
(require 'etaf-devtools-target)
(require 'etaf-devtools-model)
(require 'etaf-devtools-picker)
(require 'etaf-devtools-view)

(declare-function etaf-posframe-show "etaf-posframe" (view &rest options))
(declare-function etaf-posframe-hide "etaf-posframe" (&optional panel))
(declare-function etaf-posframe-live-p "etaf-posframe" (panel))
(declare-function etaf-posframe-panel-frame "etaf-posframe" (panel))

(defvar etaf-devtools--active-session nil
  "Active interactive `etaf-devtools-session', or nil.")

(defvar etaf-devtools--active-posframe nil
  "Active floating `etaf-posframe' panel handle when docked as `posframe'.")

(defvar etaf-devtools--remounting nil
  "Non-nil while switching dock placement so `:on-close' preserves session.")

(defun etaf-devtools--close-host-only ()
  "Close current docked window or floating posframe without disposing session."
  (let ((etaf-devtools--remounting t))
    (when (and etaf-devtools--active-posframe
               (fboundp 'etaf-posframe-hide))
      (ignore-errors (etaf-posframe-hide etaf-devtools--active-posframe)))
    (setq etaf-devtools--active-posframe nil)
    (when-let* ((buf (get-buffer etaf-devtools--buffer-name)))
      (dolist (win (get-buffer-window-list buf nil t))
        (when (window-live-p win)
          (ignore-errors (delete-window win))))
      (ignore-errors (etaf-app-close buf))
      (when (buffer-live-p buf)
        (kill-buffer buf)))))

(defun etaf-devtools--mount-docked (session side)
  "Mount SESSION into a docked Emacs side window on SIDE (`right' or `bottom')."
  (etaf-devtools--close-host-only)
  (let* ((fw (max 40 (frame-width)))
         (fh (max 16 (frame-height)))
         (rw (min etaf-devtools-right-width (max 28 (- fw 24))))
         (bh (min etaf-devtools-bottom-height (max 8 (/ fh 2))))
         (params (if (eq side 'bottom)
                     `((side . bottom)
                       (slot . 0)
                       (window-height . ,bh))
                   `((side . right)
                     (slot . 0)
                     (window-width . ,rw))))
         (buf (etaf-app-open
               etaf-devtools--buffer-name
               (etaf-devtools--root-view session)
               :state session
               :mode-line t
               :display (lambda (b)
                          (etaf-devtools--register-own-buffer b)
                          (let ((win (or (ignore-errors
                                           (display-buffer-in-side-window b params))
                                         (display-buffer b))))
                            (when (window-live-p win)
                              (select-window win))
                            win))
               :on-close (lambda ()
                           (when (and (not etaf-devtools--remounting)
                                      (eq etaf-devtools--active-session session))
                             (setq etaf-devtools--active-session nil)
                             (etaf-devtools--session-dispose session))))))
    (etaf-devtools--register-own-buffer buf)
    (when-let* ((win (get-buffer-window buf t))
                (rt (etaf-runtime-for-buffer buf)))
      (ignore-errors (etaf-refit rt win)))
    buf))

(defun etaf-devtools--mount-posframe (session)
  "Mount SESSION into a draggable floating `etaf-posframe' panel."
  (if (not (etaf-devtools--posframe-ready-p))
      (progn
        (etaf-set-value (etaf-devtools-session-dock-ref session) 'right)
        (etaf-devtools--mount-docked session 'right))
    (etaf-devtools--close-host-only)
    (let* ((etaf-devtools--creating-own-surface t)
           (panel (etaf-posframe-show
                   (etaf-devtools--root-view session)
                   :key 'etaf-devtools
                   :title "ETAF DevTools"
                   :at 'frame-center
                   :width '(fraction 0.78)
                   :height '(fraction 0.72)
                   :fill-height t
                   :focusable t
                   :focus-on-open t
                   :draggable t
                   :auto-hide nil
                   :theme 'auto)))
      (setq etaf-devtools--active-posframe panel)
      (when-let* ((pfr (and (fboundp 'etaf-posframe-panel-frame)
                            (etaf-posframe-panel-frame panel)))
                  ((frame-live-p pfr))
                  (win (frame-root-window pfr))
                  (pbuf (window-buffer win)))
        (etaf-devtools--register-own-buffer pbuf))
      panel)))

(defun etaf-devtools--mount-session (session)
  "Display SESSION using its configured dock placement."
  (let ((dock (etaf-value (etaf-devtools-session-dock-ref session))))
    (pcase dock
      ('posframe (etaf-devtools--mount-posframe session))
      ('bottom (etaf-devtools--mount-docked session 'bottom))
      (_ (etaf-devtools--mount-docked session 'right)))))

;;;###autoload
(defun etaf-devtools-create (&optional target)
  "Create a standalone headless `etaf-devtools-session' for TARGET Runtime.
Intended for embedding or `etaf-posframe-register-app'."
  (etaf-devtools--session-create
   (or target (etaf-runtime-for-buffer (current-buffer)))))

;;;###autoload
(defun etaf-devtools-view (session)
  "Return the root ETAF View for `etaf-devtools' SESSION."
  (unless (etaf-devtools-session-p session)
    (signal 'wrong-type-argument (list 'etaf-devtools-session-p session)))
  (etaf-devtools--root-view session))

;;;###autoload
(defun etaf-devtools-dispose (session)
  "Dispose standalone `etaf-devtools' SESSION and clear its overlays."
  (when (etaf-devtools-session-p session)
    (etaf-devtools--session-dispose session)))

;;;###autoload
(defun etaf-devtools-open (&optional target)
  "Open or focus `etaf-devtools' attached to TARGET (or current ETAF buffer)."
  (interactive)
  (let* ((rt (or (and target (etaf-runtime-mounted-p target) target)
                 (let ((cur (etaf-runtime-for-buffer (current-buffer))))
                   (and cur (not (etaf-devtools--own-runtime-p cur)) cur))))
         (session etaf-devtools--active-session))
    (if (and session (etaf-devtools-session-alive-p session))
        (progn
          (when rt (etaf-devtools--session-set-target session rt))
          (let ((dock (etaf-value (etaf-devtools-session-dock-ref session))))
            (if (eq dock 'posframe)
                (unless (and etaf-devtools--active-posframe
                             (fboundp 'etaf-posframe-live-p)
                             (etaf-posframe-live-p etaf-devtools--active-posframe))
                  (etaf-devtools--mount-posframe session))
              (if-let* ((buf (get-buffer etaf-devtools--buffer-name))
                        (win (get-buffer-window buf t)))
                  (select-window win)
                (etaf-devtools--mount-session session)))))
      (setq session (etaf-devtools--session-create rt etaf-devtools-default-dock)
            etaf-devtools--active-session session)
      (etaf-devtools--mount-session session))
    session))

;;;###autoload
(defalias 'etaf-devtools #'etaf-devtools-open)

;;;###autoload
(defun etaf-devtools-close ()
  "Close `etaf-devtools' and release all overlays, hooks and timers."
  (interactive)
  (etaf-devtools--picker-stop nil)
  (let ((session etaf-devtools--active-session))
    (setq etaf-devtools--active-session nil)
    (etaf-devtools--close-host-only)
    (when session
      (etaf-devtools--session-dispose session))
    (etaf-devtools--overlay-clear-all)))

;;;###autoload
(defun etaf-devtools-toggle-dock ()
  "Cycle `etaf-devtools' placement between right, bottom and floating posframe."
  (interactive)
  (let ((session (or (and etaf-devtools--active-session
                          (etaf-devtools-session-alive-p etaf-devtools--active-session)
                          etaf-devtools--active-session)
                     (etaf-devtools-open))))
    (let* ((cur (etaf-value (etaf-devtools-session-dock-ref session)))
           (next (pcase cur
                   ('right 'bottom)
                   ('bottom (if (etaf-devtools--posframe-ready-p) 'posframe 'right))
                   (_ 'right))))
      (etaf-set-value (etaf-devtools-session-dock-ref session) next)
      (etaf-devtools--mount-session session)
      next)))

;;;###autoload
(defun etaf-devtools-inspect (&optional runtime)
  "Start interactive Element Picker on RUNTIME (or current ETAF buffer)."
  (interactive)
  (let* ((rt (or (and runtime (etaf-runtime-mounted-p runtime) runtime)
                 (let ((cur (etaf-runtime-for-buffer (current-buffer))))
                   (and cur (not (etaf-devtools--own-runtime-p cur)) cur))
                 (and etaf-devtools--active-session
                      (etaf-devtools-session-alive-p etaf-devtools--active-session)
                      (etaf-value (etaf-devtools-session-target-ref etaf-devtools--active-session)))
                 (car (etaf-devtools--candidate-runtimes)))))
    (unless (and rt (etaf-runtime-mounted-p rt))
      (user-error "没有已挂载的 ETAF 应用可供拾取"))
    (let ((session (or (and etaf-devtools--active-session
                            (etaf-devtools-session-alive-p etaf-devtools--active-session)
                            etaf-devtools--active-session)
                       (etaf-devtools-open rt))))
      (etaf-devtools--picker-start
       session rt
       (lambda (picked-rt host-id)
         (etaf-devtools--session-set-target session picked-rt t)
         (etaf-set-value (etaf-devtools-session-tab-ref session) 'tree)
         (etaf-devtools--session-select-node session 'host host-id t t)
         (when-let* ((buf (get-buffer etaf-devtools--buffer-name))
                     (win (get-buffer-window buf t)))
           (select-window win)))))))

;;;###autoload
(defun etaf-devtools-highlight-updates (&optional arg runtime)
  "Toggle Highlight Updates flash overlays on RUNTIME (or current ETAF buffer).
With positive ARG enable, non-positive disable, nil toggle."
  (interactive "P")
  (let* ((rt (or (and runtime (etaf-runtime-mounted-p runtime) runtime)
                 (let ((cur (etaf-runtime-for-buffer (current-buffer))))
                   (and cur (not (etaf-devtools--own-runtime-p cur)) cur))
                 (and etaf-devtools--active-session
                      (etaf-devtools-session-alive-p etaf-devtools--active-session)
                      (etaf-value (etaf-devtools-session-target-ref etaf-devtools--active-session)))
                 (car (etaf-devtools--candidate-runtimes)))))
    (unless (and rt (etaf-runtime-mounted-p rt))
      (user-error "当前没有已挂载的 ETAF 应用"))
    (let* ((cur (etaf-devtools--highlight-enabled-p rt))
           (next (cond ((null arg) (not cur))
                       ((> (prefix-numeric-value arg) 0) t)
                       (t nil))))
      (etaf-devtools--set-highlight-updates rt next)
      (when (and etaf-devtools--active-session
                 (etaf-devtools-session-alive-p etaf-devtools--active-session)
                 (eq rt (etaf-value (etaf-devtools-session-target-ref etaf-devtools--active-session))))
        (etaf-set-value (etaf-devtools-session-highlight-ref etaf-devtools--active-session) next))
      (when (called-interactively-p 'interactive)
        (message "%s 重绘热区闪框: %s"
                 (etaf-devtools--runtime-label rt)
                 (if next "已开启" "已关闭")))
      next)))

;;;###autoload
(defun etaf-devtools-doctor ()
  "Report runtime prerequisites and optional capabilities for `etaf-devtools'."
  (let ((has-posframe (and (ignore-errors (require 'etaf-posframe nil t))
                           (fboundp 'etaf-posframe-show))))
    (list :required
          (list (list :name "ETAF Runtime introspection"
                      :ok (and (fboundp 'etaf-runtime-inspect-tree)
                               (fboundp 'etaf-runtime-inspect-host)
                               t)
                      :detail "etaf >= 0.3.6 with etaf-inspect"))
          :optional
          (list (list :name "Floating panels (etaf-posframe)"
                      :ok (and has-posframe t)
                      :detail (if has-posframe
                                  "posframe ready for floating mode & picker badges"
                                "Install `etaf-posframe' for floating panel mode"))))))

(provide 'etaf-devtools-ui)
;;; etaf-devtools-ui.el ends here
