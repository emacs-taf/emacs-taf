;;; etaf-screensaver-gui-scenarios.el --- Canvas and wake GUI acceptance -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Maintained GUI verification scenario for etaf-screensaver.  Drives every
;; built-in scene, full and card framing across viewport shapes, resizing and
;; native command-loop wake events.

;;; Code:
(require 'cl-lib)
(require 'etaf-screensaver)
(require 'emacs-gui-verifier)

(defun etaf-screensaver-gui--action (id execute verify &optional settle-timeout)
  "Create screenshot action ID with EXECUTE and VERIFY."
  (etaf-gui-verifier-action-create
   :id id :execute execute :screenshot t :settled-p verify
   :settle-timeout (or settle-timeout 5)
   :assertions (lambda (context)
                 (list (etaf-gui-verifier-assert id (funcall verify context))))))

(defun etaf-screensaver-gui--scenario ()
  "Return the maintained GUI lifecycle and visual scenario."
  (let (editor original-fullscreen)
    (etaf-gui-verifier-scenario-create
     :name "etaf-screensaver"
     :claim "Built-in scenes render cleanly across viewports and wake input restores the editor"
     :initialize
     (lambda (context)
       (etaf-screensaver-mode -1)
       (setq original-fullscreen (frame-parameter nil 'fullscreen))
       (when original-fullscreen
         (set-frame-parameter nil 'fullscreen nil))
       (setq editor (generate-new-buffer " *Screensaver GUI editor*"))
       (with-current-buffer editor (insert "Editor restored. No wake input is replayed."))
       (switch-to-buffer editor)
       (delete-other-windows)
       (setf (etaf-gui-verifier-context-target-buffer context) editor))
     :invariants
     (lambda (context)
       (let ((buffer (etaf-gui-verifier-context-target-buffer context)))
         (append
          (list (etaf-gui-verifier-assert "target-selected" (eq (window-buffer) buffer)))
          (when (plist-get (etaf-screensaver-status) :active)
            (with-current-buffer buffer
              (list (etaf-gui-verifier-assert "no-mode-line" (null mode-line-format)))))
          (etaf-gui-verifier-line-height-assertions buffer))))
     :actions
     (append
      (mapcar
       (lambda (scene)
         (etaf-screensaver-gui--action
          (format "scene-%s" scene)
          (lambda (context)
            (etaf-screensaver-stop)
            (setf (etaf-gui-verifier-context-target-buffer context)
                  (etaf-screensaver-open scene 42)))
          (lambda (_context)
            (let ((status (etaf-screensaver-status)))
              (and (eq (plist-get status :scene) scene)
                   (>= (or (plist-get status :ticks) 0) 2))))))
       '(matrix snow plasma donut equalizer sand poems clock))
      (cl-loop for size in '((130 . 46) (90 . 40) (64 . 28) (100 . 16))
               append
               (cl-loop for style in '(full card)
                        collect
                        (let ((size size) (style style))
                          (etaf-screensaver-gui--action
                           (format "%s-%dx%d" style (car size) (cdr size))
                           (lambda (context)
                             (etaf-screensaver-stop)
                             (set-frame-size (selected-frame) (car size) (cdr size))
                             (setf (etaf-gui-verifier-context-target-buffer context)
                                   (etaf-screensaver-open
                                    (list (if (eq style 'card) 'poems 'equalizer)
                                          :frame style :duration 60)
                                    42)))
                           (lambda (_context)
                             (let ((status (etaf-screensaver-status)))
                               (and (eq (plist-get status :frame) style)
                                    (= (frame-width) (car size))
                                    (= (frame-height) (cdr size))
                                    (>= (or (plist-get status :ticks) 0) 3)
                                    (= (or (plist-get status :columns) 0)
                                       (1- (window-body-width)))
                                    (= (or (plist-get status :rows) 0)
                                       (window-body-height)))))))))
      (mapcar
       (lambda (event)
         (etaf-screensaver-gui--action
          (format "wake-%s" event)
          (lambda (context)
            (unless (plist-get (etaf-screensaver-status) :active)
              (etaf-screensaver-open 'matrix 42))
            (if (eq event 'key)
                (execute-kbd-macro (kbd "x"))
              (let ((position (list (selected-window) 1 '(3 . 3) 0)))
                (if (eq event 'mouse-1)
                    (execute-kbd-macro (vector (list 'down-mouse-1 position)
                                               (list 'mouse-1 position)))
                  (execute-kbd-macro (vector (list event position))))))
            (setf (etaf-gui-verifier-context-target-buffer context) editor))
          (lambda (_context)
            (and (not (plist-get (etaf-screensaver-status) :active))
                 (eq (window-buffer) editor)
                 (with-current-buffer editor
                   (equal (buffer-substring-no-properties (point-min) (point-max))
                          "Editor restored. No wake input is replayed."))))))
       '(key mouse-movement mouse-1 wheel-down)))
     :completion
     (lambda (_context)
       (when original-fullscreen
         (set-frame-parameter nil 'fullscreen original-fullscreen))
       (and (not (plist-get (etaf-screensaver-status) :active))
            (eq (window-buffer) editor))))))

(defun etaf-screensaver-gui-run (directory)
  "Run the maintained GUI scenario into fresh evidence DIRECTORY."
  (unwind-protect
      (etaf-gui-verifier-run (etaf-screensaver-gui--scenario) directory)
    (etaf-screensaver-mode -1)))

(provide 'etaf-screensaver-gui-scenarios)
;;; etaf-screensaver-gui-scenarios.el ends here
