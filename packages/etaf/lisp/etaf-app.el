;;; etaf-app.el --- Application buffers over mounted Runtimes -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; An application is one named buffer showing one mounted View.  This module
;; owns what every such buffer otherwise repeats: the canvas display
;; settings, the default face that follows the application's theme, the
;; display, fitting application state to its window after each settled
;; change, and a single teardown however the buffer goes away.
;;
;; Window changes come from Ebox's viewport task, which already settles a
;; drag before it refits mounts; `etaf-app' fits in the same settle through
;; `ebox-display-window-change-functions', so an application needs no resize
;; hook, debounce timer or borrowed-line guard of its own.  Text scaling
;; refits through `ebox-display-change-functions'.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'ebox)
(require 'etaf-reactive)
(require 'etaf-runtime)

(defvar-local etaf-app--record nil
  "Plist describing the application of this buffer, or nil.
Keys are :state, :fit, :close, :scope, :closing and :released.")

(defun etaf-app--live-record (buffer &optional closing)
  "Return BUFFER's application record while the application is open.
With CLOSING, also return it while its close function runs."
  (and (buffer-live-p buffer)
       (let ((record (buffer-local-value 'etaf-app--record buffer)))
         (and record
              (not (plist-get record :released))
              (or closing (not (plist-get record :closing)))
              record))))

(defun etaf-app--color (source)
  "Return the colour SOURCE designates, tracking reactive reads."
  (cond ((null source) nil)
        ((stringp source) source)
        ((or (etaf-ref-p source) (etaf-computed-p source)) (etaf-value source))
        ((functionp source) (funcall source))
        (t (signal 'wrong-type-argument
                   (list '(or string etaf-ref etaf-computed function) source)))))

(defun etaf-app--paint-canvas (buffer background foreground)
  "Remap BUFFER's default face to BACKGROUND and FOREGROUND sources."
  (let ((bg (etaf-app--color background))
        (fg (etaf-app--color foreground)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (if (or bg fg)
            (face-remap-set-base 'default
                                 (append (and bg (list :background bg))
                                         (and fg (list :foreground fg))))
          (face-remap-reset-base 'default))))))

(defun etaf-app--prepare-canvas (cursor mode-line)
  "Give the current buffer the display settings of a mounted canvas.
CURSOR becomes `cursor-type' unless it is `inherit'.  MODE-LINE nil hides
the mode line, t keeps it and another value replaces it."
  (setq-local truncate-lines t)
  (setq-local auto-hscroll-mode nil)
  (setq-local scroll-margin 0)
  (setq-local hscroll-margin 0)
  ;; The View owns every column it paints; a sub-cell remainder at the
  ;; window edge must not surface as Emacs's truncation glyph.  The fringe
  ;; draws the same warning as an arrow, so it goes with the glyph: the edge
  ;; of a canvas is not a truncated file.
  (setq-local buffer-display-table
              (let ((table (copy-sequence (or standard-display-table
                                              (make-display-table)))))
                (set-display-table-slot table 'truncation ?\s)
                table))
  (setq-local fringe-indicator-alist
              (mapcar (lambda (indicator)
                        (if (eq (car indicator) 'truncation)
                            (cons 'truncation nil)
                          indicator))
                      fringe-indicator-alist))
  (when (bound-and-true-p display-line-numbers-mode)
    (display-line-numbers-mode -1))
  (cond ((null mode-line) (setq-local mode-line-format nil))
        ((eq mode-line t))
        (t (setq-local mode-line-format mode-line)))
  ;; The Runtime captures the cursor at mount and restores it after each
  ;; modality change, so the application's cursor must exist before mount.
  (unless (eq cursor 'inherit)
    (setq-local cursor-type cursor)))

(defun etaf-app--refit-canvas (buffer window)
  "Refit BUFFER's Runtime to WINDOW, now and after the next redisplay.
Hiding the mode line does not resize WINDOW, so the size Emacs reports until
the next redisplay still counts the mode line row; the second fit catches the
row the canvas would otherwise overshoot by."
  (when (buffer-live-p buffer)
    (when-let* ((runtime (etaf-runtime-for-buffer buffer)))
      (etaf-refit runtime window))
    (run-at-time
     0 nil
     (lambda ()
       (when (and (buffer-live-p buffer) (window-live-p window))
         (when-let* ((runtime (etaf-runtime-for-buffer buffer)))
           (etaf-refit runtime window)))))))

(defun etaf-app--fit (buffer window)
  "Run BUFFER's application fit for WINDOW in one reactive batch."
  (when-let* ((record (etaf-app--live-record buffer))
              (on-fit (plist-get record :fit)))
    (when (window-live-p window)
      (with-current-buffer buffer
        (etaf-call-with-batch (lambda () (funcall on-fit window)))))))

(defun etaf-app--window-changed (buffer window)
  "Fit BUFFER's application after its display WINDOW settled."
  (etaf-app--fit buffer window))

(defun etaf-app--display-changed (buffer)
  "Fit BUFFER's application after its text scale settled."
  (when (etaf-app--live-record buffer)
    (etaf-app--fit buffer (get-buffer-window buffer t))))

(add-hook 'ebox-display-window-change-functions #'etaf-app--window-changed)
(add-hook 'ebox-display-change-functions #'etaf-app--display-changed)

(defun etaf-app--release (buffer)
  "Run BUFFER's application teardown once.
Return the condition the close function signaled, or nil."
  (when-let* ((record (etaf-app--live-record buffer)))
    (with-current-buffer buffer
      ;; Closing first, so the close function can read the state but a
      ;; nested kill or close does not run it again.
      (setq etaf-app--record (plist-put (copy-sequence record) :closing t))
      (let (failure)
        (when-let* ((on-close (plist-get record :close)))
          (condition-case error
              (funcall on-close)
            (error (setq failure error))))
        (setq etaf-app--record (plist-put etaf-app--record :released t))
        (when-let* ((scope (plist-get record :scope)))
          (etaf-scope-stop scope))
        failure))))

(defun etaf-app--buffer-killed ()
  "Release the application of the buffer being killed.
A close function error is reported, not signaled: signaling here would keep
the buffer alive."
  (when-let* ((failure (etaf-app--release (current-buffer))))
    (message "ETAF application %s: close failed: %s"
             (buffer-name) (error-message-string failure))))

;;;###autoload
(cl-defun etaf-app-open (name view &key state on-fit on-close background foreground
                              (cursor 'inherit) mode-line (display t) mount-options)
  "Open VIEW as the application buffer NAME and return the buffer.
An open application of the same NAME closes first, running its ON-CLOSE.
The buffer gets canvas display settings, then shows through DISPLAY: t
selects it in the selected window, a function receives the buffer, and nil
leaves it undisplayed.  ON-FIT, a function of the display window, runs in
the buffer before VIEW mounts and again in one reactive batch after each
settled change of that window or of the text scale.  ON-CLOSE, a function
of no arguments, runs once in the buffer when the buffer is killed or
`etaf-app-close' closes it, while VIEW is still mounted.

BACKGROUND and FOREGROUND, each a colour string, ref, computed or
zero-argument function, remap the default face; a reactive source repaints
when it changes.  CURSOR, unless `inherit' (the default), sets
`cursor-type' before mounting.
MODE-LINE nil (the default) hides the mode line, t keeps it, and another
value becomes `mode-line-format'.  STATE is returned by `etaf-app-state'.
MOUNT-OPTIONS, a plist or a function of the display window (nil when
undisplayed) that returns one, are passed to `etaf-mount'; a function runs
in the buffer after ON-FIT, so options such as a fixed viewport height can
come from the fitted state.  If mounting fails the application closes, the
buffer is killed and the error propagates."
  (unless (stringp name)
    (signal 'wrong-type-argument (list 'stringp name)))
  (when-let* ((existing (get-buffer name)))
    (when (etaf-app--live-record existing)
      (etaf-app-close existing)))
  (let ((buffer (get-buffer-create name))
        (opened nil))
    (unwind-protect
        (progn
          (with-current-buffer buffer
            (etaf-app--prepare-canvas cursor mode-line)
            (setq etaf-app--record (list :state state :fit on-fit
                                         :close on-close))
            (add-hook 'kill-buffer-hook #'etaf-app--buffer-killed -50 t)
            (when (or background foreground)
              (let ((scope (etaf-effect-scope :detached t :name 'etaf-app)))
                (setq etaf-app--record (plist-put etaf-app--record :scope scope))
                (etaf-scope-run
                 scope
                 (lambda ()
                   (etaf-watch-effect
                    (lambda () (etaf-app--paint-canvas buffer background foreground))
                    :name 'etaf-app-canvas))))))
          (cond ((functionp display) (funcall display buffer))
                (display
                 ;; A user's `display-buffer' rules must not split the
                 ;; frame: the application owns the window it opens in.
                 (let ((display-buffer-overriding-action
                        '((display-buffer-same-window))))
                   (pop-to-buffer buffer))))
          (let ((window (get-buffer-window buffer t)))
            (when (and window on-fit)
              (with-current-buffer buffer (funcall on-fit window)))
            (let ((options (if (functionp mount-options)
                               (with-current-buffer buffer
                                 (funcall mount-options window))
                             mount-options)))
              (etaf-mount buffer view options)
              ;; Hiding the mode line gives the window one more row, but its
              ;; cached geometry keeps the old body height until Emacs
              ;; redisplays it, so the Runtime mounted on the larger size.  A
              ;; canvas taller than its window scrolls as a whole, carrying
              ;; every pane along, so refit now and once more after that
              ;; redisplay.  A caller that pinned a viewport keeps it.
              (when (and window
                         (not (or (plist-member options :viewport-width)
                                  (plist-member options :viewport-height))))
                (with-current-buffer buffer
                  (etaf-app--refit-canvas buffer window)))))
          (setq opened t))
      (unless opened
        (when (buffer-live-p buffer)
          (etaf-app--release buffer)
          (kill-buffer buffer))))
    buffer))

;;;###autoload
(defun etaf-app-close (&optional buffer-or-name)
  "Close the application in BUFFER-OR-NAME, the current buffer by default.
Run its close function, unmount its View and kill the buffer.  Return t.
A close function error propagates after the buffer is gone."
  (interactive)
  (let ((buffer (get-buffer (or buffer-or-name (current-buffer)))))
    (unless (etaf-app--live-record buffer)
      (user-error "Not an open ETAF application buffer"))
    (let ((failure (etaf-app--release buffer)))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer)))
        (etaf-unmount runtime))
      (kill-buffer buffer)
      (when failure
        (signal (car failure) (cdr failure)))
      t)))

;;;###autoload
(defun etaf-app-state (&optional buffer-or-name)
  "Return the state of the open application in BUFFER-OR-NAME, or nil.
BUFFER-OR-NAME defaults to the current buffer.  The close function still
sees the state."
  (when-let* ((buffer (get-buffer (or buffer-or-name (current-buffer))))
              (record (etaf-app--live-record buffer t)))
    (plist-get record :state)))

;;;###autoload
(defun etaf-app-buffer (name)
  "Return the buffer of the open application NAME, or nil."
  (when-let* ((buffer (get-buffer name)))
    (and (etaf-app--live-record buffer) buffer)))

(provide 'etaf-app)
;;; etaf-app.el ends here
