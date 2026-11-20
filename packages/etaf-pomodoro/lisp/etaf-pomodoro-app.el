;;; etaf-pomodoro-app.el --- Application shell of the Pomodoro timer -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; The application layer binds one timer session to a View.  `etaf-pomodoro-open'
;; opens it as an ETAF application: the framework owns the buffer, the default
;; face, the fit callback and the close hook, and the View's root Host owns the
;; timer keys.  The same session and View mount in a floating panel through
;; `etaf-pomodoro-create' and `etaf-pomodoro-view'.

;;; Code:

(require 'cl-lib)
(require 'etaf)
(require 'etaf-pomodoro-theme)
(require 'etaf-pomodoro-session)
(require 'etaf-pomodoro-views)

(defconst etaf-pomodoro--buffer-name "*ETAF Pomodoro*"
  "Buffer name of the standalone timer.")

(defun etaf-pomodoro--surface-background ()
  "Return the surface colour of the appearance around the timer."
  (plist-get (etaf-pomodoro--tokens (etaf-appearance)) :ui-panel-bg))

(defun etaf-pomodoro--surface-foreground ()
  "Return the ink colour of the appearance around the timer."
  (plist-get (etaf-pomodoro--tokens (etaf-appearance)) :ui-panel-fg))

;;;###autoload
(defun etaf-pomodoro-open (&optional minutes)
  "Open a Pomodoro timer in its own buffer and return the buffer.
MINUTES is the focus length, `etaf-pomodoro-default-minutes' by default.  The
timer starts paused; `p' starts or pauses it, `r' resets it, `+' adds five
minutes, `t' switches the style and `q' closes the window.  An open timer is
selected instead of creating a second one."
  (interactive)
  (if-let* ((buffer (etaf-app-buffer etaf-pomodoro--buffer-name)))
      (progn (pop-to-buffer buffer) buffer)
    (let* ((session (etaf-pomodoro-create :minutes minutes))
           (view (etaf-pomodoro-view session t))
           (buffer (etaf-app-open etaf-pomodoro--buffer-name view
                                  :state session
                                  :background #'etaf-pomodoro--surface-background
                                  :foreground #'etaf-pomodoro--surface-foreground
                                  :on-close (lambda ()
                                              (etaf-pomodoro-stop-session session)))))
      buffer)))

;;;###autoload
(defun etaf-pomodoro-stop ()
  "Close the standalone Pomodoro timer and stop its tick.
Inside a floating panel the command does nothing: the renderer closes the
panel with its own key before this one."
  (interactive)
  (when-let* ((buffer (etaf-app-buffer etaf-pomodoro--buffer-name)))
    (etaf-app-close buffer)))

;;;###autoload
(defun etaf-pomodoro-view (&optional session quit)
  "Return SESSION's timer View for embedding.
SESSION defaults to a new paused session of `etaf-pomodoro-default-minutes'.
The View owns the session's tick only while it is mounted, so mounting it in a
floating panel starts the countdown and unmounting the panel stops it.  QUIT
adds a `q' key that closes the standalone window; leave it nil when embedding,
where the host closes its own surface with its own key."
  (let ((session (or session (etaf-pomodoro-create))))
    (etaf-view (etaf-pomodoro--root
                :session session
                :keys (etaf-pomodoro--keys session quit)))))

(provide 'etaf-pomodoro-app)
;;; etaf-pomodoro-app.el ends here
