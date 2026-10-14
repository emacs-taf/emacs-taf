;;; etaf-youtube-app.el --- Application shell of etaf-youtube -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; The application layer owns the buffer, the keymap and the mount lifecycle.
;; Closing the buffer releases the Runtime and the model, so reopening starts
;; clean and no request, timer or store connection leaks.  The renderer's
;; minor-mode map owns RET, q, Escape, Tab, `?', the arrows and M-g; this map
;; only adds keys the application really owns.

;;; Code:

(require 'etaf)
(require 'etaf-ui)
(require 'etaf-youtube-model)
(require 'etaf-youtube-views)

(defcustom etaf-youtube-buffer-name "*YouTube*"
  "Buffer name of a mounted application."
  :type 'string
  :group 'etaf-youtube)

(defcustom etaf-youtube-resize-delay 0.15
  "Seconds of quiet after a window change before the layout refits."
  :type 'number
  :group 'etaf-youtube)

(defvar-local etaf-youtube--model nil
  "Model shown by the current buffer's runtime.")

(defvar etaf-youtube--resize-timer nil
  "Pending debounced refit of the application's window.")

(defun etaf-youtube--refit-windows ()
  "Refit every mounted YouTube runtime to its showing window."
  (setq etaf-youtube--resize-timer nil)
  (dolist (frame (frame-list))
    (when (frame-live-p frame)
      (dolist (window (window-list frame t))
        (with-current-buffer (window-buffer window)
          (when (and (bound-and-true-p etaf-youtube--model)
                     (etaf-runtime-for-buffer (current-buffer)))
            (etaf-runtime-refit (etaf-runtime-for-buffer (current-buffer))
                                (window-body-width window t)
                                (window-body-height window))
            ;; A focused right-hand control can leave Emacs horizontally
            ;; scrolled after a resize, even when the new layout fits.
            (set-window-hscroll window 0)))))))

(defun etaf-youtube--window-size-change (frame)
  "Schedule a refit after FRAME's windows changed size."
  (when (frame-live-p frame)
    (when etaf-youtube--resize-timer
      (cancel-timer etaf-youtube--resize-timer))
    (setq etaf-youtube--resize-timer
          (run-at-time etaf-youtube-resize-delay nil
                       #'etaf-youtube--refit-windows))))

(add-hook 'window-size-change-functions #'etaf-youtube--window-size-change)

(defun etaf-youtube--current-model ()
  "Return the model of the current buffer, or signal `user-error'."
  (or etaf-youtube--model
      (user-error "Current buffer is not an etaf-youtube session")))

(defun etaf-youtube-focus-search ()
  "Begin editing the search field of the current session."
  (interactive)
  (let* ((model (etaf-youtube--current-model))
         (buffer (plist-get model :buffer))
         (runtime (and buffer (get-buffer buffer)
                       (etaf-runtime-for-buffer buffer))))
    (if runtime
        (etaf-text-input-begin runtime etaf-youtube-search-ref)
      (user-error "The YouTube session is not mounted"))))

(defun etaf-youtube-toggle-playback-command ()
  "Toggle playback of the current session."
  (interactive)
  (etaf-youtube-toggle-playback (etaf-youtube--current-model)))

(defun etaf-youtube-seek-forward-command ()
  "Seek five seconds forward."
  (interactive)
  (etaf-youtube-seek-by (etaf-youtube--current-model) 5))

(defun etaf-youtube-seek-backward-command ()
  "Seek five seconds backward."
  (interactive)
  (etaf-youtube-seek-by (etaf-youtube--current-model) -5))

(defun etaf-youtube-volume-up-command ()
  "Raise the volume by five."
  (interactive)
  (let ((model (etaf-youtube--current-model)))
    (etaf-youtube-set-volume model (+ (or (plist-get (etaf-youtube-state model)
                                                     :volume)
                                          100)
                                      5))))

(defun etaf-youtube-volume-down-command ()
  "Lower the volume by five."
  (interactive)
  (let ((model (etaf-youtube--current-model)))
    (etaf-youtube-set-volume model (- (or (plist-get (etaf-youtube-state model)
                                                     :volume)
                                          100)
                                      5))))

(defun etaf-youtube-mute-command ()
  "Toggle mute on the current session."
  (interactive)
  (etaf-youtube-toggle-mute (etaf-youtube--current-model)))

(defun etaf-youtube-sidebar-command ()
  "Fold or unfold the sidebar."
  (interactive)
  (etaf-youtube-toggle-sidebar (etaf-youtube--current-model)))

(defun etaf-youtube-theater-command ()
  "Toggle theater mode."
  (interactive)
  (etaf-youtube-toggle-theater (etaf-youtube--current-model)))

(defun etaf-youtube-theme-command ()
  "Switch the appearance."
  (interactive)
  (etaf-youtube-cycle-theme (etaf-youtube--current-model)))

(defun etaf-youtube-refresh-command ()
  "Reload the current view."
  (interactive)
  (etaf-youtube-refresh (etaf-youtube--current-model)))

(defun etaf-youtube-back-command ()
  "Return to the previous view."
  (interactive)
  (etaf-youtube-back (etaf-youtube--current-model)))

(defun etaf-youtube-activate-command ()
  "Open the selected item."
  (interactive)
  (etaf-youtube-activate (etaf-youtube--current-model)))

(defun etaf-youtube--focus-region (region-id label)
  "Focus REGION-ID in the current session, reporting LABEL when absent."
  (let* ((model (etaf-youtube--current-model))
         (buffer (plist-get model :buffer))
         (runtime (and buffer (get-buffer buffer)
                       (etaf-runtime-for-buffer buffer))))
    (unless runtime
      (user-error "The YouTube session is not mounted"))
    (condition-case nil
        (etaf-region-focus region-id runtime)
      (error (user-error "当前页面没有%s" label)))))

(defun etaf-youtube-focus-sidebar-command ()
  "Move focus to the navigation sidebar."
  (interactive)
  (etaf-youtube--focus-region etaf-youtube-region-sidebar "侧栏"))

(defun etaf-youtube-focus-content-command ()
  "Move focus to the content area."
  (interactive)
  (etaf-youtube--focus-region etaf-youtube-region-content "内容区"))

(defun etaf-youtube-focus-comments-command ()
  "Move focus to the comment section of the watch page."
  (interactive)
  (etaf-youtube--focus-region etaf-youtube-region-comments "评论区"))

;;;###autoload
(defun etaf-youtube-open ()
  "Mount the application in its own buffer and return that buffer."
  (interactive)
  (let ((buffer (get-buffer-create etaf-youtube-buffer-name)))
    (with-current-buffer buffer
      (unless etaf-youtube--model
        (setq-local etaf-youtube--model (etaf-youtube-create)))
      (setf (plist-get etaf-youtube--model :buffer) buffer)
      ;; A canvas row that fills the window must not end in Emacs's
      ;; truncation glyph, which shows as a stray `$' at the right edge.
      (setq-local buffer-display-table
                  (let ((table (copy-sequence (or standard-display-table
                                                  (make-display-table)))))
                    (set-display-table-slot table 'truncation ?\s)
                    table)))
    (pop-to-buffer buffer)
    (set-window-hscroll (selected-window) 0)
    (let ((window (get-buffer-window buffer t)))
      (etaf-mount buffer (etaf-youtube-view (buffer-local-value 'etaf-youtube--model
                                                                buffer))
                  (list :viewport-width (and window (window-body-width window t))
                        :viewport-height (and window (window-body-height window)))))
    (etaf-runtime-flush (etaf-runtime-for-buffer buffer))
    buffer))

;;;###autoload
(defun etaf-youtube-close ()
  "Unmount the application buffer and kill it."
  (interactive)
  (let ((buffer (get-buffer etaf-youtube-buffer-name)))
    (when (and buffer (buffer-live-p buffer))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer)))
        (etaf-unmount runtime))
      (kill-buffer buffer))))

(provide 'etaf-youtube-app)
;;; etaf-youtube-app.el ends here
