;;; etaf-posframe-app.el --- Floating panel input forwarding and app registry -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; Key forwarding into floating panels, panel focus cycling, and registered
;; floating application sessions (including `etaf-app' manifest binding).

;;; Code:

(require 'cl-lib)
(require 'etaf)
(require 'etaf-ui)
(require 'posframe)
(require 'etaf-posframe-pool)
(require 'etaf-posframe-panel)
(require 'etaf-posframe-layout)

;;; Panel input

(defun etaf-posframe--app-target ()
  "Return the panel the app prefix commands act on.
The panel of the selected frame comes first, then the most recent panel, so a
prefix command can nudge a panel while the keyboard sits in an ordinary buffer:
a text terminal cannot give a child frame the keyboard or the mouse."
  (or (etaf-posframe--panel-for-frame (selected-frame))
      (car (etaf-posframe-panels))))

(defun etaf-posframe--pin-position (panel x y)
  "Make (X . Y) PANEL's anchor, so a later refresh keeps that place."
  (let ((options (copy-sequence (etaf-posframe--panel-options panel))))
    (setq options (plist-put options :at (cons 'pixels (cons x y)))
          options (plist-put options :stack nil))
    (setf (etaf-posframe--panel-options panel) options
          (etaf-posframe--panel-position panel) (cons x y))))

(defun etaf-posframe--pin-size (panel width height)
  "Record WIDTH by HEIGHT as PANEL's size, so later refreshes keep it.
The height becomes the panel's row budget, which is why it is kept through
`:fill-height'."
  (setf (etaf-posframe--panel-options panel)
        (plist-put (plist-put (plist-put (copy-sequence (etaf-posframe--panel-options panel))
                                         :width width)
                              :height height)
                   :fill-height t)))

;;;###autoload
(defun etaf-posframe-move (direction &optional steps panel)
  "Move PANEL STEPS character cells in DIRECTION.
DIRECTION is `left', `right', `up' or `down'.  STEPS defaults to
`etaf-posframe-move-step'; one step is one character, so a graphical frame
moves by its character width and height and a terminal by its single cell.
The panel keeps the new place through later refreshes.  A text terminal
reaches this from the app prefix map, because a child frame there takes
neither the keyboard nor the mouse."
  (interactive
   (list (intern (completing-read "方向: " '("left" "right" "up" "down") nil t))
         (and current-prefix-arg (prefix-numeric-value current-prefix-arg))))
  (let* ((panel (or panel (etaf-posframe--app-target)))
         (frame (and panel (etaf-posframe-panel-frame panel))))
    (unless (frame-live-p frame)
      (signal 'etaf-posframe-error (list "No live ETAF panel to move")))
    (let* ((steps (or steps etaf-posframe-move-step))
           (cell-width (max 1 (frame-char-width frame)))
           (cell-height (max 1 (frame-char-height frame)))
           (dx (* cell-width (pcase direction ('left (- steps)) ('right steps) (_ 0))))
           (dy (* cell-height (pcase direction ('up (- steps)) ('down steps) (_ 0))))
           (position (frame-position frame))
           (parent (etaf-posframe--panel-parent-frame panel))
           (parent-width (if (frame-live-p parent) (frame-pixel-width parent) 0))
           (parent-height (if (frame-live-p parent) (frame-pixel-height parent) 0))
           ;; A panel stays inside its parent frame, so a run of moves cannot
           ;; push it off screen where only part of it would be reachable.
           (x (max 0 (min (+ (or (car-safe position) 0) dx)
                          (max 0 (- parent-width (frame-pixel-width frame))))))
           (y (max 0 (min (+ (or (cdr-safe position) 0) dy)
                          (max 0 (- parent-height (frame-pixel-height frame)))))))
      (let ((etaf-posframe--positioning t))
        (set-frame-position frame x y))
      (etaf-posframe--pin-position panel x y)
      panel)))

;;;###autoload
(defun etaf-posframe-resize (axis &optional steps panel)
  "Change PANEL's size by STEPS cells along AXIS.
AXIS is `wider', `narrower', `taller' or `shorter'.  STEPS defaults to
`etaf-posframe-resize-step'.  The panel keeps its new width and row budget
through later refreshes."
  (interactive
   (list (intern (completing-read "方向: " '("wider" "narrower" "taller" "shorter") nil t))
         (and current-prefix-arg (prefix-numeric-value current-prefix-arg))))
  (let* ((panel (or panel (etaf-posframe--app-target)))
         (frame (and panel (etaf-posframe-panel-frame panel))))
    (unless (frame-live-p frame)
      (signal 'etaf-posframe-error (list "No live ETAF panel to resize")))
    (let* ((permitted (etaf-posframe--resize-permitted panel))
           (steps (or steps etaf-posframe-resize-step))
           (dw (if (car permitted)
                   (pcase axis ('wider steps) ('narrower (- steps)) (_ 0))
                 0))
           (dh (if (cdr permitted)
                   (pcase axis ('taller steps) ('shorter (- steps)) (_ 0))
                 0))
           (width (max 4 (+ (frame-width frame) dw)))
           (height (max 2 (+ (frame-height frame) dh))))
      (when (or (/= dw 0) (/= dh 0))
        ;; Record the size first: the frame's own size change runs a refresh
        ;; that would otherwise put the old width back.
        (etaf-posframe--pin-size panel width height)
        (set-frame-size frame width height)
        (etaf-posframe-refresh panel))
      panel)))

;;;###autoload
(defun etaf-posframe-send-key (&optional panel)
  "Read one key sequence and run it in PANEL's View.
A text terminal cannot give a child frame the keyboard, so this is how the
panel's own keys are reached: the key runs with the panel's buffer current.
A key the View declares runs there; a control that needs the keyboard focus on
a particular row, such as a button reached through Tab, still needs a
graphical frame.  Return the key sequence that ran."
  (interactive)
  (let* ((panel (or panel (etaf-posframe--app-target)))
         (buffer (and panel (etaf-posframe--panel-buffer panel))))
    (unless (buffer-live-p buffer)
      (signal 'etaf-posframe-error (list "No live ETAF panel to send a key to")))
    (let ((keys (read-key-sequence-vector "面板按键: ")))
      (with-current-buffer buffer
        (execute-kbd-macro keys))
      keys)))

;;; Applications

(defcustom etaf-posframe-app-repeat-delay 0.3
  "Seconds during which a repeated app toggle is ignored.
Opening a panel mounts a whole application, so key repeat would otherwise mount
it once per repeat and stall Emacs."
  :type 'number
  :group 'etaf-posframe)

(defvar etaf-posframe-apps nil
  "Registered applications, a list of (ID . PLIST) in registration order.")

(defvar etaf-posframe-app-map (make-sparse-keymap)
  "Keymap with one binding per registered application `:key'.")

(defvar etaf-posframe--app-panels (make-hash-table :test #'eq)
  "Live panel of each registered application, by ID.")

(defvar etaf-posframe--app-toggled-at (make-hash-table :test #'eq)
  "Time of each application's last real toggle, for the repeat guard.")

(defconst etaf-posframe--app-options etaf-posframe--show-keys
  "Registration keys handed to `etaf-posframe-show' unchanged.")

(defvar etaf-posframe--app-sessions (make-hash-table :test #'eq)
  "Live application sessions by registration ID, for `:keep-alive' apps.")

(defun etaf-posframe--app-show-options (record)
  "Return the `etaf-posframe-show' options RECORD carries.
Every key in `etaf-posframe--app-options' is passed through, so a registration
can use the whole panel vocabulary without the registry listing it again."
  (let (options)
    (dolist (key etaf-posframe--app-options)
      (when (plist-member record key)
        (setq options (plist-put options key (plist-get record key)))))
    options))

(defun etaf-posframe-app-record (id)
  "Return the registration plist of application ID."
  (or (cdr (assq id etaf-posframe-apps))
      (signal 'etaf-posframe-error
              (list (format "Application %s is not registered" id)))))

(defvar etaf-posframe--nudge-map nil
  "Keys that keep moving or resizing a panel while the prefix stays active.
`etaf-posframe--nudge' installs it as a transient map, so the arrow keys keep
working until a key it does not bind ends the run.")

(defun etaf-posframe--nudge (direction)
  "Move the target panel DIRECTION and keep the arrow keys nudging it.
The map stays active until a key it does not bind is pressed, so one prefix
reaches a run of moves instead of stopping after one cell."
  (etaf-posframe-move direction)
  (set-transient-map etaf-posframe--nudge-map t))

(defun etaf-posframe--nudge-resize (axis)
  "Change the target panel's size along AXIS and keep the keys nudging it."
  (etaf-posframe-resize axis)
  (set-transient-map etaf-posframe--nudge-map t))

(setq etaf-posframe--nudge-map
      (let ((map (make-sparse-keymap)))
        (define-key map [left] (lambda () (interactive) (etaf-posframe--nudge 'left)))
        (define-key map [right] (lambda () (interactive) (etaf-posframe--nudge 'right)))
        (define-key map [up] (lambda () (interactive) (etaf-posframe--nudge 'up)))
        (define-key map [down] (lambda () (interactive) (etaf-posframe--nudge 'down)))
        ;; Control plus an arrow is a desktop shortcut on macOS: the window
        ;; manager switches spaces before Emacs sees the key.  Plain `=' and
        ;; `-' size the width, `>' and '<' the height, and every terminal sends
        ;; them.
        (define-key map (kbd "=") (lambda () (interactive) (etaf-posframe--nudge-resize 'wider)))
        (define-key map (kbd "+") (lambda () (interactive) (etaf-posframe--nudge-resize 'wider)))
        (define-key map (kbd "-") (lambda () (interactive) (etaf-posframe--nudge-resize 'narrower)))
        (define-key map (kbd ">") (lambda () (interactive) (etaf-posframe--nudge-resize 'taller)))
        (define-key map (kbd "<") (lambda () (interactive) (etaf-posframe--nudge-resize 'shorter)))
        map))

(defun etaf-posframe--app-keymap ()
  "Return a keymap binding every registered application `:key'."
  (let ((map (make-sparse-keymap)))
    (dolist (entry etaf-posframe-apps)
      (let ((id (car entry))
            (shortcut (plist-get (cdr entry) :shortcut)))
        (when shortcut
          (define-key map (kbd shortcut)
                      (lambda () (interactive) (etaf-posframe-app id))))))
    ;; The panel's place and keys are reached from the buffer the user is in:
    ;; a text terminal gives a child frame neither the keyboard nor the mouse.
    ;; Each of these also installs `etaf-posframe--nudge-map', so the next
    ;; arrow presses move the same panel without the prefix again.
    (define-key map [left] (lambda () (interactive) (etaf-posframe--nudge 'left)))
    (define-key map [right] (lambda () (interactive) (etaf-posframe--nudge 'right)))
    (define-key map [up] (lambda () (interactive) (etaf-posframe--nudge 'up)))
    (define-key map [down] (lambda () (interactive) (etaf-posframe--nudge 'down)))
    (define-key map (kbd "=") (lambda () (interactive) (etaf-posframe--nudge-resize 'wider)))
    (define-key map (kbd "+") (lambda () (interactive) (etaf-posframe--nudge-resize 'wider)))
    (define-key map (kbd "-") (lambda () (interactive) (etaf-posframe--nudge-resize 'narrower)))
    (define-key map (kbd ">") (lambda () (interactive) (etaf-posframe--nudge-resize 'taller)))
    (define-key map (kbd "<") (lambda () (interactive) (etaf-posframe--nudge-resize 'shorter)))
    (define-key map (kbd "k") #'etaf-posframe-send-key)
    map))

;;;###autoload
(defun etaf-posframe-register-app (id &rest options)
  "Register application ID with OPTIONS, as described in the package Commentary."
  (unless (symbolp id)
    (signal 'etaf-posframe-error (list "Application ID must be a symbol" id)))
  (unless (plist-get options :create)
    (signal 'etaf-posframe-error
            (list (format "Application %s needs :create" id))))
  (unless (plist-get options :view)
    (signal 'etaf-posframe-error
            (list (format "Application %s needs :view" id))))
  ;; Registering again replaces the record but keeps the order.
  (setq etaf-posframe-apps
        (append (assq-delete-all id etaf-posframe-apps)
                (list (cons id options)))
        etaf-posframe-app-map (etaf-posframe--app-keymap))
  id)

(defun etaf-posframe--merge-plist (base overrides)
  "Return a new plist merging keyword plists BASE and OVERRIDES (OVERRIDES win)."
  (let ((result (copy-sequence base)))
    (cl-loop for (k v) on overrides by #'cddr
             do (setq result (plist-put result k v)))
    result))

;;;###autoload
(defun etaf-posframe-bind-app (id &optional shortcut &rest overrides)
  "Register application ID from ETAF's `etaf-app-get' registry as a floating panel.
Optional SHORTCUT binds a key in `etaf-posframe-app-map'.  Keyword OVERRIDES
replace manifest panel or lifecycle defaults."
  (let* ((spec (or (and (symbolp id) (etaf-app-get id))
                   (signal 'etaf-posframe-error
                           (list (format "Application %S is not registered in `etaf-app'" id)
                                 id))))
         (session (or (plist-get spec :session)
                      (signal 'etaf-posframe-error
                              (list (format "Application %S declares no embeddable :session" id)
                                    id))))
         (feature (plist-get spec :feature))
         (close-fn (plist-get session :close))
         (base (list :title (plist-get spec :title)
                     :create (plist-get session :create)
                     :view (plist-get session :view))))
    (when feature
      (setq base (plist-put base :require feature)))
    (when close-fn
      (setq base (plist-put base :on-stop close-fn)))
    (when (plist-member session :keep-alive)
      (setq base (plist-put base :keep-alive (plist-get session :keep-alive))))
    (when-let* ((panel-hints (plist-get spec :panel)))
      (setq base (etaf-posframe--merge-plist base panel-hints)))
    (when shortcut
      (setq base (plist-put base :shortcut shortcut)))
    (when overrides
      (setq base (etaf-posframe--merge-plist base overrides)))
    (apply #'etaf-posframe-register-app id base)))

;;;###autoload
(defun etaf-posframe-bind-apps (specs)
  "Bind multiple applications from ETAF's `etaf-app' registry.
Each element of SPECS is `ID', `(ID . SHORTCUT)' or `(ID SHORTCUT . OVERRIDES)'.
Entries not currently registered or lacking `:session' are skipped cleanly."
  (let (bound)
    (dolist (entry specs)
      (let* ((id (if (consp entry) (car entry) entry))
             (rest (and (consp entry) (cdr entry)))
             (shortcut (cond ((stringp rest) rest)
                             ((consp rest) (car rest))
                             (t nil)))
             (overrides (and (consp rest) (cdr rest)))
             (spec (and (symbolp id) (etaf-app-get id))))
        (when (and spec (plist-get spec :session))
          (apply #'etaf-posframe-bind-app id shortcut overrides)
          (push id bound))))
    (nreverse bound)))

;;;###autoload
(defun etaf-posframe-cycle ()
  "Move input focus to the next open panel, then back to its frame.
With no panel focused, focus the most recent panel.  Return the frame that now
has focus."
  (interactive)
  (let* ((panels (etaf-posframe-panels))
         (selected (selected-frame))
         (current (cl-position-if (lambda (panel)
                                    (eq (etaf-posframe--panel-frame panel) selected))
                                  panels))
         (target (cond ((null panels) (selected-frame))
                       ((null current) (etaf-posframe--panel-frame (car panels)))
                       ((< (1+ current) (length panels))
                        (etaf-posframe--panel-frame (nth (1+ current) panels)))
                       (t (or (etaf-posframe--panel-parent-frame
                               (nth current panels))
                              (selected-frame))))))
    (when (etaf-posframe--frame-active-p target)
      (etaf-posframe--restore-input-focus target)
      (when-let* ((panel (etaf-posframe--panel-for-frame target))
                  (window (get-buffer-window (etaf-posframe--panel-buffer panel) t)))
        (select-window window)
        (setf (etaf-posframe--panel-focused panel) t)))
    (etaf-posframe--paint-borders)
    target))

;;;###autoload
(defun etaf-posframe-app-prefix ()
  "Read one key and open the registered application bound to it."
  (interactive)
  (let* ((keys (read-key-sequence-vector nil t))
         (command (and keys (lookup-key etaf-posframe-app-map keys))))
    (if (commandp command)
        (call-interactively command)
      (signal 'etaf-posframe-error
              (list (format "No ETAF application on %s"
                            (if keys (key-description keys) "no key")))))))

;;;###autoload
(defun etaf-posframe-app (id)
  "Open or close the registered application ID's panel.
A `:keep-alive' application is only hidden: its session stays in the registry
and the next open resumes it.  Return the panel, or nil when it hid one."
  (interactive
   (list (intern (completing-read "ETAF 应用: "
                                  (mapcar #'car etaf-posframe-apps) nil t))))
  (let* ((record (etaf-posframe-app-record id))
         (panel (gethash id etaf-posframe--app-panels))
         (keep (plist-get record :keep-alive))
         (now (float-time)))
    (if (etaf-posframe-live-p panel)
        (progn
          (puthash id now etaf-posframe--app-toggled-at)
          (puthash id nil etaf-posframe--app-panels)
          (etaf-posframe-hide panel)
          nil)
      (unless (< (- now (or (gethash id etaf-posframe--app-toggled-at) 0))
                 etaf-posframe-app-repeat-delay)
        (puthash id now etaf-posframe--app-toggled-at)
        (when-let* ((feature (plist-get record :require)))
          (require feature nil t))
        (let* ((session (or (and keep (gethash id etaf-posframe--app-sessions))
                            (funcall (plist-get record :create))))
               (panel (apply #'etaf-posframe-show
                             (funcall (plist-get record :view) session)
                             (append
                              ;; Defaults first, then the registration, then
                              ;; the keys this registry owns.
                              (list :at 'frame-top-right
                                    :stack t
                                    :width etaf-posframe-default-width
                                    :height etaf-posframe-default-max-height
                                    :title (plist-get record :title)
                                    :focusable t)
                              (etaf-posframe--app-show-options record)
                              (list :key id)))))
          (when keep
            (puthash id session etaf-posframe--app-sessions))
          (setf (etaf-posframe--panel-close-callback panel)
                (lambda (_panel)
                  (puthash id nil etaf-posframe--app-panels)
                  (unless keep
                    (etaf-posframe--app-stop id session))))
          (puthash id panel etaf-posframe--app-panels)
          panel)))))

(defun etaf-posframe--app-stop (id session)
  "Release SESSION of application ID and forget it."
  (remhash id etaf-posframe--app-sessions)
  (when-let* ((record (ignore-errors (etaf-posframe-app-record id)))
              (stop (plist-get record :on-stop)))
    (condition-case error
        (funcall stop session)
      (error (message "ETAF application %s :on-stop failed: %s"
                      id (error-message-string error))))))

;;;###autoload
(defun etaf-posframe-app-quit (id)
  "Stop application ID, hide its panel and release its session."
  (interactive
   (list (intern (completing-read "退出 ETAF 应用: "
                                  (mapcar #'car etaf-posframe-apps) nil t))))
  (let ((panel (gethash id etaf-posframe--app-panels))
        (session (gethash id etaf-posframe--app-sessions)))
    (when (etaf-posframe-live-p panel)
      (etaf-posframe-hide panel))
    (when session
      (etaf-posframe--app-stop id session))
    (puthash id nil etaf-posframe--app-panels)
    nil))

(provide 'etaf-posframe-app)
;;; etaf-posframe-app.el ends here
