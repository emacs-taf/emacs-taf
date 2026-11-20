;;; etaf-drag-edge-tests.el --- Host drag edge intent tests -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Exercise the :drag-edge Host property through a native primary-button
;; gesture on a mounted Runtime.  read-event and float-time are replaced so
;; idle time and the edge cadence are deterministic.

;;; Code:

(require 'cl-lib)
(require 'etaf-test-support)

(defun etaf-drag-edge-test-play (command press events)
  "Invoke COMMAND with PRESS, feeding EVENTS through `read-event'.
EVENTS is a list of (TIME . EVENT); idle reads advance a fake clock by 0.05
seconds until an event's TIME arrives."
  (let ((clock 0.0) (queue (copy-sequence events)))
    (cl-letf (((symbol-function 'read-event)
               (lambda (&optional _prompt _inherit timeout)
                 (cond
                  ((and queue (<= (car (car queue)) clock))
                   (cdr (pop queue)))
                  ((and timeout (> timeout 0))
                   (setq clock (+ clock 0.05))
                   nil)
                  (t nil))))
              ((symbol-function 'float-time)
               (lambda (&optional time) (or time clock))))
      (funcall command press))))

(defun etaf-drag-edge-test-bottom (width height)
  "Return a point inside the bottom edge band of WIDTH by HEIGHT pixels."
  (cons (/ width 2) (1- height)))

(ert-deftest etaf-drag-edge-reaches-the-drag-handler ()
  "A Host with :drag-edge receives an edge gesture naming the window edge."
  (let (edges)
    (etaf-test-with-mount
        (runtime (etaf-view (box :ref 'handle :drag-edge t
                                 :on-drag (lambda (gesture)
                                            (when (eq (plist-get gesture :phase) 'edge)
                                              (push (plist-get gesture :edges) edges)))
                                 "drag")))
      (save-window-excursion
        (switch-to-buffer (current-buffer))
        (let* ((window (selected-window))
               (window-edges (window-inside-pixel-edges window))
               (width (- (nth 2 window-edges) (nth 0 window-edges)))
               (height (- (nth 3 window-edges) (nth 1 window-edges)))
               (position (etaf-host-ref-position runtime 'handle))
               (point (etaf-drag-edge-test-bottom width height))
               (press (list 'down-mouse-1 (list window position '(4 . 4) 0)))
               (move (list 'mouse-movement (list window position point 1)))
               (release (list 'mouse-1 (list window position point 2)))
               (command (key-binding (vector press) nil nil position)))
          (should (commandp command))
          (etaf-drag-edge-test-play
           command press
           (list (cons 0.0 move) (cons 0.5 release)))
          (should edges)
          (should (cl-every (lambda (value) (equal value '(bottom))) edges)))))))

(ert-deftest etaf-drag-edge-without-the-property-keeps-old-phases ()
  "A Host without :drag-edge receives no edge gesture at the same edge."
  (let (phases)
    (etaf-test-with-mount
        (runtime (etaf-view (box :ref 'handle
                                 :on-drag (lambda (gesture)
                                            (push (plist-get gesture :phase) phases))
                                 "drag")))
      (save-window-excursion
        (switch-to-buffer (current-buffer))
        (let* ((window (selected-window))
               (window-edges (window-inside-pixel-edges window))
               (width (- (nth 2 window-edges) (nth 0 window-edges)))
               (height (- (nth 3 window-edges) (nth 1 window-edges)))
               (position (etaf-host-ref-position runtime 'handle))
               (point (etaf-drag-edge-test-bottom width height))
               (press (list 'down-mouse-1 (list window position '(4 . 4) 0)))
               (move (list 'mouse-movement (list window position point 1)))
               (release (list 'mouse-1 (list window position point 2)))
               (command (key-binding (vector press) nil nil position)))
          (should (commandp command))
          (etaf-drag-edge-test-play
           command press
           (list (cons 0.0 move) (cons 0.5 release)))
          (should (equal (nreverse phases) '(start move end))))))))

;;; etaf-drag-edge-tests.el ends here
