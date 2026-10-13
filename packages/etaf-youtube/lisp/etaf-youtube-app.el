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

(defvar-local etaf-youtube--model nil
  "Model shown by the current buffer's runtime.")

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

(defvar etaf-youtube-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "SPC") #'etaf-youtube-toggle-playback-command)
    (define-key map (kbd "f") #'etaf-youtube-seek-forward-command)
    (define-key map (kbd "b") #'etaf-youtube-seek-backward-command)
    (define-key map (kbd "]") #'etaf-youtube-volume-up-command)
    (define-key map (kbd "[") #'etaf-youtube-volume-down-command)
    (define-key map (kbd "m") #'etaf-youtube-mute-command)
    (define-key map (kbd "s") #'etaf-youtube-sidebar-command)
    (define-key map (kbd "t") #'etaf-youtube-theater-command)
    (define-key map (kbd "d") #'etaf-youtube-theme-command)
    (define-key map (kbd "r") #'etaf-youtube-refresh-command)
    (define-key map (kbd "u") #'etaf-youtube-back-command)
    (define-key map (kbd "RET") #'etaf-youtube-activate-command)
    (define-key map (kbd "/") #'etaf-youtube-focus-search)
    map)
  "Application bindings that do not conflict with the renderer's own keys.")

;;;###autoload
(defun etaf-youtube-open ()
  "Mount the application in its own buffer and return that buffer."
  (interactive)
  (let ((buffer (get-buffer-create etaf-youtube-buffer-name)))
    (with-current-buffer buffer
      (unless etaf-youtube--model
        (setq-local etaf-youtube--model (etaf-youtube-create)))
      (setf (plist-get etaf-youtube--model :buffer) buffer)
      (use-local-map etaf-youtube-mode-map))
    (pop-to-buffer buffer)
    (etaf-mount buffer (etaf-youtube-view (buffer-local-value 'etaf-youtube--model
                                                              buffer))
                (list :viewport-width (window-body-width nil t)
                      :viewport-height (window-body-height)))
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
