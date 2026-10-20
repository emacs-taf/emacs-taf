;;; etaf-youtube-app.el --- Application shell of etaf-youtube -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; The application opens through `etaf-app-open', which owns the buffer,
;; its canvas and the mount lifecycle; the shell View declares the keys the
;; application owns as root `:keys'.  Closing the buffer releases the Runtime
;; and the model, so reopening starts clean and no request, timer or store
;; connection leaks.

;;; Code:

(require 'etaf)
(require 'etaf-ui)
(require 'etaf-youtube-model)
(require 'etaf-youtube-views)

(defcustom etaf-youtube-buffer-name "*YouTube*"
  "Buffer name of a mounted application."
  :type 'string
  :group 'etaf-youtube)

(defun etaf-youtube--current-model ()
  "Return the model of the current buffer, or signal `user-error'."
  (or (etaf-app-state)
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
  (if-let* ((buffer (etaf-app-buffer etaf-youtube-buffer-name)))
      (progn (pop-to-buffer-same-window buffer) buffer)
    (let* ((model (etaf-youtube-create))
           (mode (plist-get model :theme-mode))
           (buffer nil))
      (setq model (plist-put model :buffer
                             (get-buffer-create etaf-youtube-buffer-name)))
      ;; The canvas outside the View follows the application's own
      ;; appearance, which is independent of the Emacs theme.  The point
      ;; caret is not the selection indicator: focused controls paint their
      ;; own cue, and native text input brings its own caret while editing.
      (setq buffer
            (etaf-app-open etaf-youtube-buffer-name (etaf-youtube-view model)
                           :state model
                           :background (lambda ()
                                         (etaf-youtube-color :bg (etaf-value mode)))
                           :foreground (lambda ()
                                         (etaf-youtube-color :ink (etaf-value mode)))
                           :cursor nil))
      (etaf-runtime-flush (etaf-runtime-for-buffer buffer))
      buffer)))

;;;###autoload
(defun etaf-youtube-close ()
  "Unmount the application buffer and kill it."
  (interactive)
  (when-let* ((buffer (etaf-app-buffer etaf-youtube-buffer-name)))
    (etaf-app-close buffer)))

(provide 'etaf-youtube-app)
;;; etaf-youtube-app.el ends here
