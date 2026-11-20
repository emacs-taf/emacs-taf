;;; etaf-desktop-resize-lock-tests.el --- Controlled locked resize -*- lexical-binding: t; -*-

;;; Commentary:
;; Use public Desktop settings and the mounted native keymaps.  Synthetic
;; coordinates cover controlled geometry and cancellation, not hardware latency.

;;; Code:
(require 'ert)
(require 'cl-lib)
(require 'etaf)
(require 'ebox)
(require 'etaf-desktop)

(defun etaf-desktop-resize-lock-test--run (ending)
  "Verify every enabled Desktop resize edge with ENDING, confirm or cancel."
  (let* ((last-input-event nil) (last-command-event nil)
         (buffer (generate-new-buffer " *desktop-resize-lock*"))
         (desktop (etaf-desktop-create :name (buffer-name buffer)
                                       :canvas-width 800 :canvas-height 40)))
    (unwind-protect
        (save-window-excursion
          (set-window-buffer (selected-window) buffer)
          (etaf-desktop-set-setting desktop :drag-lock-modifier 'super)
          (etaf-desktop-open-window desktop 'notes :x 20 :y 4
                                    :width 240 :height 12 :min-width 80 :min-height 4
                                    :title "Locked resize" :view (etaf-view (box :width 'stretch :height 'stretch
                                                    :padding '((lh 0) (ch 2) (lh 1) (ch 2))
                                             (text "Kept content"))))
          (etaf-desktop-mount desktop buffer)
          (with-current-buffer buffer
            (let ((runtime (etaf-runtime-for-buffer buffer))
                  (window (selected-window))
                  (lh (frame-char-height)))
              (dolist (edge '(left right top bottom top-left top-right
                                  bottom-left bottom-right))
                (etaf-desktop-move-window desktop 'notes 20 4)
                (etaf-desktop-resize-window desktop 'notes 240 12)
                (etaf-runtime-flush runtime)
                (let* ((ref (intern (format "etaf-desktop-resize-notes-%s" edge)))
                       (position (etaf-host-ref-position runtime ref))
                       (start (list window position '(2 . 2) 0))
                       (motion (list window position (cons 6 (+ 2 lh)) 1))
                       (finish (list window position (cons 10 (+ 2 (* 2 lh))) 2))
                       (late (list window position (cons 14 (+ 2 (* 3 lh))) 3))
                       (press (list 's-down-mouse-1 start))
                       (command (key-binding (vector press) nil nil position))
                       (unread-command-events
                        (append (list (list 's-mouse-1 start)
                                      (list 'mouse-movement motion))
                                (if (eq ending 'cancel) (list 27)
                                  (list (list 'down-mouse-1 finish)
                                        (list 'mouse-movement late)
                                        (list 'mouse-1 late)))
                                (list ?x))))
                  (should position)
                  (should (commandp command))
                  (funcall command press)
                  (etaf-runtime-flush runtime)
                  (should (equal unread-command-events '(?x)))
                  (let* ((state (etaf-desktop-window-state desktop 'notes))
                         (left (memq edge '(left top-left bottom-left)))
                         (right (memq edge '(right top-right bottom-right)))
                         (top (memq edge '(top top-left top-right)))
                         (bottom (memq edge '(bottom bottom-left bottom-right)))
                         (expected (if (eq ending 'cancel) '(20 4 240 12)
                                     (list (+ 20 (if left 8 0))
                                           (+ 4 (if top 2 0))
                                           (+ 240 (cond (left -8) (right 8) (t 0)))
                                           (+ 12 (cond (top -2) (bottom 2) (t 0)))))))
                    (should (equal expected
                                   (mapcar (lambda (key) (plist-get state key))
                                           '(:x :y :width :height)))))
                  (should (equal 'notes (etaf-desktop-active-window desktop)))
                  (should (etaf-host-ref-position runtime ref))
                  (should (string-match-p "Kept content" (buffer-string)))
                  ;; The engine's derived active state has no ETAF reader; this
                  ;; public Ebox query is the test's diagnostic for a stale gesture.
                  (should-not (ebox-selector-query-buffer buffer ":active")))))))
      (etaf-desktop-close desktop)
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(ert-deftest etaf-desktop-locked-resize-confirms-controlled-geometry ()
  "The Super setting applies to every handle and confirms the second press."
  (etaf-desktop-resize-lock-test--run 'confirm))

(ert-deftest etaf-desktop-locked-resize-cancel-restores-controlled-geometry ()
  "Escape restores every edge's original rectangle without losing content."
  (etaf-desktop-resize-lock-test--run 'cancel))

;;; etaf-desktop-resize-lock-tests.el ends here
