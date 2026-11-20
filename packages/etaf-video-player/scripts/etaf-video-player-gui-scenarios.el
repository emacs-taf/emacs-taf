;;; etaf-video-player-gui-scenarios.el --- Real-media controls acceptance -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Load ETAF's scripts/emacs-gui-verifier.el, then call
;; (etaf-video-player-gui-run DIRECTORY SOURCE).  Native ETAF focus/RET and
;; public drag dispatch exercise the rendered controls without OS click
;; synthesis.  The supplied real clip remains muted until sound is tested.

;;; Code:
(require 'cl-lib)
(require 'etaf-video-player)
(require 'emacs-gui-verifier)

(defun etaf-video-player-gui--state ()
  "Read the displayed player's public state."
  (with-current-buffer "*Video Player*" (etaf-video-player-state)))

(defun etaf-video-player-gui--press (ref)
  "Activate displayed control REF through native focus and RET."
  (let ((runtime (etaf-runtime-for-buffer "*Video Player*")))
    (unless (etaf-focus runtime ref) (error "Cannot focus %s" ref))
    (execute-kbd-macro (kbd "RET"))))

(defun etaf-video-player-gui--range (ref ratio phase)
  "Dispatch a pointer gesture to REF at RATIO across its live track.
The track's committed width comes from `etaf-host-ref-size': a graphic
track is one slice of a viewport-wide rule image, so the glyph's own
object width is the whole rule rather than the track."
  (let* ((buffer (get-buffer "*Video Player*"))
         (runtime (etaf-runtime-for-buffer buffer))
         (window (get-buffer-window buffer t))
         (bounds (etaf-host-ref-bounds runtime ref))
         (size (etaf-host-ref-size runtime ref))
         (first (and bounds (posn-at-point (car bounds) window))))
    (unless (and first size) (error "Range %s is not visible" ref))
    (let* ((left (car (posn-x-y first)))
           (x (+ left (* ratio (car size))))
           (y (cdr (posn-x-y first))))
      (etaf-dispatch-event runtime ref (if phase 'drag 'press)
                          (list :phase phase :window window :buffer buffer
                                :position (cons x y)) t))))

(defun etaf-video-player-gui--check (name predicate)
  "Return a named assertion for PREDICATE's current public observation."
  (list (etaf-gui-verifier-assert name (funcall predicate))))

(defun etaf-video-player-gui-run (directory source)
  "Verify real SOURCE and save window evidence to DIRECTORY."
  (let ((actions nil))
    (cl-labels
        ((step (name execute predicate &optional screenshot)
           (push (etaf-gui-verifier-action-create
                  :id name :execute (lambda (_context) (funcall execute))
                  :settled-p (lambda (_context) (funcall predicate))
                  :assertions (lambda (_context)
                                (etaf-video-player-gui--check name predicate))
                  :screenshot screenshot) actions))
         (state (key) (plist-get (etaf-video-player-gui--state) key))
         (press (ref) (etaf-video-player-gui--press ref)))
      (step "ready" #'ignore (lambda () (> (state :presented) 0)))
      (step "pause" (lambda () (press 'video-play))
            (lambda () (not (state :playing))) t)
      (step "volume-click" (lambda () (etaf-video-player-gui--range 'etaf-video-player-volume 0.4 nil))
            (lambda () (<= 38 (state :volume) 42)) t)
      (step "volume-drag" (lambda ()
                            (etaf-video-player-gui--range 'etaf-video-player-volume 0.4 'start)
                            (etaf-video-player-gui--range 'etaf-video-player-volume 0.6 'move)
                            (etaf-video-player-gui--range 'etaf-video-player-volume 0.7 'end))
            (lambda () (<= 68 (state :volume) 72)))
      (step "sound-on" (lambda () (press 'video-audio)) (lambda () (state :audio)))
      (step "sound-off" (lambda () (press 'video-audio)) (lambda () (not (state :audio))))
      (step "speed" (lambda () (press 'video-speed)) (lambda () (/= 1 (state :speed))))
      (step "loop" (lambda () (press 'video-loop)) (lambda () (not (eq 'none (state :loop)))))
      (step "shuffle" (lambda () (press 'video-shuffle)) (lambda () (state :shuffle)))
      (step "seek-click" (lambda () (etaf-video-player-gui--range 'etaf-video-player-progress 0.2 nil))
            (lambda () (< (abs (- (state :position) (* 0.2 (state :duration)))) 2)))
      (step "seek-drag" (lambda ()
                          (etaf-video-player-gui--range 'etaf-video-player-progress 0.2 'start)
                          (etaf-video-player-gui--range 'etaf-video-player-progress 0.3 'move)
                          (etaf-video-player-gui--range 'etaf-video-player-progress 0.5 'end))
            (lambda () (< (abs (- (state :position) (* 0.5 (state :duration)))) 2)))
      (step "forward" (lambda () (press 'video-forward))
            (lambda () (> (state :position) (* 0.5 (state :duration)))))
      (step "backward" (lambda () (press 'video-backward))
            (lambda () (< (abs (- (state :position) (* 0.5 (state :duration)))) 2)))
      (step "next" (lambda () (press 'video-next)) (lambda () (= 1 (state :index))))
      (step "previous" (lambda () (press 'video-previous)) (lambda () (= 0 (state :index))))
      (step "keyboard-pause" (lambda () (execute-kbd-macro (kbd "SPC")))
            (lambda () (not (state :playing))))
      (step "keyboard-fit" (lambda () (execute-kbd-macro (kbd "F")))
            (lambda () (> (state :columns) 0)))
      (step "ascii-mode" (lambda () (execute-kbd-macro (kbd "C")))
            (lambda () (and (eq 'ascii (state :mode))
                            (eq 'ascii (state :render-mode)))))
      (step "color-mode" (lambda () (execute-kbd-macro (kbd "C")))
            (lambda () (and (eq 'color (state :mode))
                            (eq 'color (state :render-mode)) t)))
      (step "image-mode" (lambda () (execute-kbd-macro (kbd "C")))
            (lambda () (and (eq 'image (state :mode))
                            (eq 'image (state :render-mode)))))
      (step "light-theme" (lambda () (execute-kbd-macro (kbd "T")))
            (lambda () (eq etaf-video-player-theme-mode 'light)) t)
      (step "dark-theme" (lambda () (execute-kbd-macro (kbd "T")))
            (lambda () (eq etaf-video-player-theme-mode 'dark)) t)
      (etaf-gui-verifier-run
       (etaf-gui-verifier-scenario-create
        :name "video-player-controls" :claim "Real media, native control activation, seek/volume drag and stable canvas"
        :initialize (lambda (context)
                      (let ((buffer (etaf-video-player-open
                                     (list :playlist (list source source) :audio nil))))
                        (setf (etaf-gui-verifier-context-target-buffer context) buffer)))
        :actions (nreverse actions)
        :invariants (lambda (_context)
                      (append
                       (etaf-gui-verifier-line-height-assertions (get-buffer "*Video Player*"))
                       (list (etaf-gui-verifier-assert
                              "footer is visible"
                              (with-current-buffer "*Video Player*"
                                (pos-visible-in-window-p (1- (point-max)) (selected-window)))))))
        :completion (lambda (_context) t))
       directory))))

(provide 'etaf-video-player-gui-scenarios)
;;; etaf-video-player-gui-scenarios.el ends here
