;;; etaf-slides-app.el --- Buffer, keys and lifecycle for etaf-slides -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; The application boundary: it owns the buffer, the root keys, the display
;; window and the presentation clock.  It is the only module that reads the
;; session to decide what to show; the views receive values and return nodes.
;;
;; A presentation is one buffer with one mounted Runtime.  Opening the same deck
;; again selects the existing buffer instead of mounting a second copy, because
;; two mounts of one session would keep two owners of the same state.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'etaf)
(require 'etaf-slides-theme)
(require 'etaf-slides-model)
(require 'etaf-slides-views)

(etaf-define-component etaf-slides-frame (&key session)
  "Render the slide application of SESSION and own its theme.
Every displayed value is read from SESSION's reactive cells, so a slide change,
a mode switch or a theme switch repaints the mounted view without a remount."
  :bindings ((theme (plist-get session :theme))
             (tokens (etaf-computed
                      (lambda ()
                        (etaf-slides-theme-tokens
                         (etaf-slides-resolve-theme (etaf-value theme))))
                      :name 'etaf-slides-theme-tokens)))
  :setup (etaf-theme-provide tokens)
  :render (etaf-slides--frame
           session
           (etaf-slides-palette
            (etaf-slides-resolve-theme (etaf-value theme)))))

;;; Session lookup

(defun etaf-slides--session ()
  "Return the session of the current slides buffer."
  (or (etaf-app-state)
      (user-error "Not in an ETAF slides buffer")))

(defun etaf-slides-view (&optional session)
  "Return the View for SESSION, or for an empty deck when SESSION is nil.
Pass a session from `etaf-slides-create' to mount a deck yourself with
`etaf-mount', for example inside another layout or a test."
  (etaf-view (etaf-slides-frame
              :session (or session (etaf-slides-create :text "# 空白")))))

;;; Clock

(defconst etaf-slides--clock-interval 1
  "Seconds between presentation clock updates.")

(defun etaf-slides--format-clock (seconds)
  "Return SECONDS as a presentation clock string."
  (format "%02d:%02d" (floor (/ seconds 60))
          (mod (round seconds) 60)))

(defun etaf-slides--clock-start (session)
  "Start SESSION's presentation clock."
  (etaf-slides--clock-stop session)
  (let ((started (float-time)))
    (etaf-slides-set-clock
     session (etaf-slides--format-clock 0))
    (plist-put session :timer
               (run-at-time 0 etaf-slides--clock-interval
                            (lambda ()
                              (when (buffer-live-p (plist-get session :buffer))
                                (etaf-slides-set-clock
                                 session
                                 (etaf-slides--format-clock
                                  (- (float-time) started)))))))))

(defun etaf-slides--clock-stop (session)
  "Stop SESSION's presentation clock, if any."
  (when-let* ((timer (plist-get session :timer)))
    (cancel-timer timer))
  (plist-put session :timer nil))

;;; Opening

(defun etaf-slides--buffer-name (session)
  "Return the application buffer name of SESSION."
  (format "*ETAF Slides: %s*" (plist-get session :title)))

(defun etaf-slides--palette (session)
  "Return SESSION's palette for its current theme."
  (etaf-slides-palette
   (etaf-slides-resolve-theme (etaf-slides--read session :theme))))

(defun etaf-slides--background (session)
  "Return SESSION's canvas background color."
  (etaf-slides--c (etaf-slides--palette session) :bg))

(defun etaf-slides--foreground (session)
  "Return SESSION's canvas foreground color."
  (etaf-slides--c (etaf-slides--palette session) :ink))

(defun etaf-slides--fit (session window)
  "Record SESSION's viewport from WINDOW."
  (when (and window (window-live-p window))
    (setf (etaf-value (plist-get session :viewport))
          (cons (window-body-width window t) (window-body-height window)))))

(defconst etaf-slides-present-scale 4
  "Text scale of a presentation: four steps, about twice the body size.
A slide is read from across a room, so the deck opens at presentation size
instead of the frame's body size.  `+' and `-' change it, `0' returns here.")

(defconst etaf-slides-window-scale 2
  "Text scale of a deck opened in an ordinary window.")

(defun etaf-slides-zoom-in ()
  "Enlarge the deck by one text scale step."
  (interactive)
  (text-scale-increase 1))

(defun etaf-slides-zoom-out ()
  "Shrink the deck by one text scale step."
  (interactive)
  (text-scale-decrease 1))

(defun etaf-slides-zoom-reset ()
  "Return the deck to the size it opened at."
  (interactive)
  (text-scale-set (if (plist-get (etaf-slides--session) :presenting)
                      etaf-slides-present-scale
                    etaf-slides-window-scale)))

(defun etaf-slides--install (session &optional present)
  "Mount SESSION in its application buffer and return the buffer.
PRESENT gives the deck the whole frame and the larger opening text scale."
  (let* ((name (etaf-slides--buffer-name session))
         (existing (etaf-app-buffer name)))
    (if (and existing (buffer-live-p existing))
        (progn (pop-to-buffer existing) existing)
      (let ((buffer
             (etaf-app-open
              name
              (etaf-slides-view session)
              :state session
              :display (if present #'switch-to-buffer t)
              :mode-line nil
              :cursor nil
              :background (lambda () (etaf-slides--background session))
              :foreground (lambda () (etaf-slides--foreground session))
              :on-fit (lambda (window) (etaf-slides--fit session window))
              :on-close (lambda ()
                          (etaf-slides--clock-stop session)
                          (plist-put session :buffer nil)))))
        (plist-put session :buffer buffer)
        (plist-put session :presenting (and present t))
        ;; A slide is read from a distance: the deck opens at presentation
        ;; size.  Text scaling is Emacs' own mechanism, and an ETAF Runtime
        ;; republishes its metrics after it, so the stage re-fits around the
        ;; bigger cells instead of clipping them.
        (with-current-buffer buffer
          (text-scale-set (if present
                              etaf-slides-present-scale
                            etaf-slides-window-scale)))
        (when present
          (delete-other-windows)
          (set-window-margins nil 0 0)
          (set-window-fringes nil 0 0)
          (etaf-slides--clock-start session))
        buffer))))

;;;###autoload
(defun etaf-slides-open (deck &optional slide)
  "Open DECK in an ETAF slides buffer and return it.
DECK is a markdown deck file, a session from `etaf-slides-create', or nil to
ask for a file.  SLIDE is a one-based slide number.  An already open deck is
selected instead of mounted twice."
  (interactive
   (list (read-file-name "Deck: " nil nil t nil
                         (lambda (name)
                           (string-match-p "\\.\\(md\\|markdown\\|mdown\\)\\'" name)))
         nil))
  (let* ((session (pcase deck
                    ((pred stringp) (etaf-slides-create :file deck))
                    ((pred listp) deck)
                    (_ (etaf-slides-create
                        :file (read-file-name "Deck: " nil nil t)))))
         (buffer (etaf-slides--install session)))
    (when slide
      (etaf-slides-goto session (1- slide)))
    (pop-to-buffer buffer)
    buffer))

;;;###autoload
(defun etaf-slides-present (deck &optional slide)
  "Present DECK in the whole frame and start its clock.
DECK and SLIDE are as in `etaf-slides-open'.  The buffer keeps the frame until
it is closed or another buffer takes the window."
  (interactive
   (list (read-file-name "Deck: " nil nil t nil
                         (lambda (name)
                           (string-match-p "\\.\\(md\\|markdown\\|mdown\\)\\'" name)))
         nil))
  (let* ((session (pcase deck
                    ((pred stringp) (etaf-slides-create :file deck))
                    ((pred listp) deck)
                    (_ (etaf-slides-create
                        :file (read-file-name "Deck: " nil nil t)))))
         (buffer (etaf-slides--install session t)))
    (when slide
      (etaf-slides-goto session (1- slide)))
    (pop-to-buffer buffer)
    buffer))

;;;###autoload
(defun etaf-slides-close ()
  "Close the current slides buffer and stop its clock."
  (interactive)
  (let ((session (etaf-app-state)))
    (when session (etaf-slides--clock-stop session))
    (etaf-app-close)))

;;; Commands

(defun etaf-slides-next-slide ()
  "Show the next slide."
  (interactive)
  (let ((session (etaf-slides--session)))
    (etaf-slides-show session (1+ (etaf-slides--read session :index)))))

(defun etaf-slides-previous-slide ()
  "Show the previous slide."
  (interactive)
  (let ((session (etaf-slides--session)))
    (etaf-slides-show session (1- (etaf-slides--read session :index)))))

(defun etaf-slides-first-slide ()
  "Show the first slide."
  (interactive)
  (etaf-slides-goto (etaf-slides--session) 0))

(defun etaf-slides-last-slide ()
  "Show the last slide."
  (interactive)
  (let ((session (etaf-slides--session)))
    (etaf-slides-goto session (1- (length (plist-get session :slides))))))

(defun etaf-slides-goto-slide (number)
  "Show slide NUMBER, counting from one."
  (interactive
   (list (read-number "幻灯片编号: "
                      (1+ (etaf-slides--read (etaf-slides--session) :index)))))
  (etaf-slides-goto (etaf-slides--session) (1- number)))

(defun etaf-slides-toggle-overview ()
  "Switch between the stage and the slide overview."
  (interactive)
  (let ((session (etaf-slides--session)))
    (etaf-slides-set-mode
     session
     (if (eq (etaf-slides--read session :mode) 'overview) 'stage 'overview))))

(defun etaf-slides-toggle-notes ()
  "Show or hide the speaker notes band."
  (interactive)
  (let ((session (etaf-slides--session)))
    (etaf-slides-set-notes session (not (etaf-slides--read session :notes)))))

(defun etaf-slides-next-theme ()
  "Advance the deck theme: light, dark, then follow the frame."
  (interactive)
  (etaf-slides-cycle-theme (etaf-slides--session)))

(defun etaf-slides-toggle-clock ()
  "Start or stop the presentation clock."
  (interactive)
  (let ((session (etaf-slides--session)))
    (if (plist-get session :timer)
        (progn (etaf-slides--clock-stop session)
               (etaf-slides-set-clock session nil))
      (etaf-slides--clock-start session))))

(defun etaf-slides-toggle-fullscreen ()
  "Toggle the frame's fullscreen state."
  (interactive)
  (toggle-frame-fullscreen))

(defun etaf-slides-edit-source ()
  "Open the deck's markdown source in another window."
  (interactive)
  (let ((file (plist-get (etaf-slides--session) :file)))
    (if (and file (file-readable-p file))
        (find-file-other-window file)
      (user-error "This deck was created from text and has no source file"))))

(provide 'etaf-slides-app)
;;; etaf-slides-app.el ends here
