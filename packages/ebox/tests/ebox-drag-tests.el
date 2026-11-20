;;; ebox-drag-tests.el --- Native drag tracking tests -*- lexical-binding: t; -*-

(require 'ebox-test-support)

(defun ebox-drag-test-play (command press events)
  "Invoke COMMAND with PRESS, feeding EVENTS through `read-event'.
EVENTS is a list of (TIME . EVENT); idle reads advance a fake clock by 0.05
seconds until an event's TIME arrives, so edge timing is deterministic."
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

(defun ebox-drag-test-edge-point (side width height)
  "Return the pixel point on SIDE of a WIDTH by HEIGHT window."
  (pcase side
    ('bottom (cons (/ width 2) (1- height)))
    ('top (cons (/ width 2) 0))
    ('left (cons 0 (/ height 2)))
    ('right (cons (1- width) (/ height 2)))))

(defmacro ebox-drag-test-with-target (keymap &rest body)
  "Mount a TARGET with KEYMAP and run BODY with window, width and height.
BODY can call `ebox-drag-test-press' and `ebox-drag-test-release'."
  (declare (indent 1))
  `(let ((buffer (generate-new-buffer " *ebox-drag-test*")))
     (unwind-protect
         (save-window-excursion
           (switch-to-buffer buffer)
           (ebox-mount buffer
                       (list 'column
                             (list 'box :id "target" :keymap ,keymap "TARGET")))
           (let* ((window (selected-window))
                  (window-edges (window-inside-pixel-edges window))
                  (width (- (nth 2 window-edges) (nth 0 window-edges)))
                  (height (- (nth 3 window-edges) (nth 1 window-edges)))
                  (position (ebox-node-position
                             (car (ebox-selector-query-buffer buffer "#target"))))
                  (command (lookup-key (get-text-property position 'keymap)
                                       [down-mouse-1]))
                  (press (list 'down-mouse-1 (list window position '(4 . 4) 0)))
                  (move (lambda (point)
                          (list 'mouse-movement (list window position point 1))))
                  (release (lambda (point)
                             (list 'mouse-1 (list window position point 2)))))
             (ignore command)
             ,@body))
       (when (buffer-live-p buffer) (kill-buffer buffer)))))

(ert-deftest ebox-drag-escape-cancels-and-is-consumed ()
  "Escape ends a plain drag with quit and does not survive as a Meta prefix."
  (let (phases)
    (ebox-drag-test-with-target
        (ebox-keymap-create
         :drag (lambda (gesture) (push (plist-get gesture :phase) phases)))
      (let ((unread-command-events
             (list (funcall move '(5 . 5)) 27 (funcall release '(5 . 5)) ?x)))
        (funcall command press)
        (should (equal (nreverse phases) '(start move cancel)))
        (should (equal unread-command-events
                       (list (funcall release '(5 . 5)) ?x)))))))

(ert-deftest ebox-drag-other-input-cancels-and-is-preserved ()
  "An unrelated key cancels the drag and stays available to Emacs."
  (let (phases reasons)
    (ebox-drag-test-with-target
        (ebox-keymap-create
         :drag (lambda (gesture)
                 (push (plist-get gesture :phase) phases)
                 (push (plist-get gesture :reason) reasons)))
      (let ((unread-command-events (list (funcall move '(5 . 5)) ?a)))
        (funcall command press)
        (should (equal (nreverse phases) '(start move cancel)))
        (should (eq (car reasons) 'input))
        (should (equal unread-command-events '(?a)))))))

(ert-deftest ebox-drag-new-press-ends-a-drag-that-lost-its-release ()
  "A new press ends the drag at its last position and starts its own gesture."
  (let (gestures)
    (ebox-drag-test-with-target
        (ebox-keymap-create
         :drag (lambda (gesture)
                 (push (list (plist-get gesture :phase)
                             (plist-get gesture :position)
                             (plist-get gesture :reason))
                       gestures)))
      (let* ((again (list 'down-mouse-1 (list window position '(9 . 6) 3)))
             (unread-command-events
              (list (funcall move '(8 . 5)) again ?x)))
        (funcall command press)
        (should (equal (nreverse gestures)
                       '((start (4 . 4) nil) (move (8 . 5) nil)
                         (end (8 . 5) nil))))
        (should (equal unread-command-events (list again ?x)))))))

(ert-deftest ebox-drag-hides-tooltips-and-help-while-tracking ()
  "A drag hides a shown or pending tooltip and shows no help until it ends."
  (let ((shown '("earlier")) seen)
    (ebox-drag-test-with-target
        (ebox-keymap-create
         :drag (lambda (gesture)
                 (when (eq (plist-get gesture :phase) 'move)
                   (funcall show-help-function "during"))
                 (push (plist-get gesture :phase) seen)))
      (let ((show-help-function (lambda (message) (push message shown)))
            (unread-command-events
             (list (funcall move '(5 . 5)) (funcall release '(5 . 5)))))
        (cl-letf (((symbol-function 'display-graphic-p) #'always))
          (funcall command press))
        (should (equal (nreverse seen) '(start move end)))
        (should (equal shown '(nil "earlier")))
        (funcall show-help-function "after")
        (should (equal (car shown) "after"))))))

(ert-deftest ebox-drag-follows-the-pointer-past-the-window ()
  "A drag past the text area keeps going, clamps :position and ends on release."
  (let (gestures)
    (ebox-drag-test-with-target
        (ebox-keymap-create
         :drag (lambda (gesture)
                 (push (list (plist-get gesture :phase)
                             (plist-get gesture :position)
                             (plist-get gesture :overshoot)
                             (plist-get gesture :reason))
                       gestures)))
      (let* ((frame (window-frame window))
             (outer (window-pixel-edges window))
             (bottom (1- height))
             ;; Three pixels below the text area, over the mode line, whose
             ;; coordinates count from the window corner.
             (mode-line (list window 'mode-line
                              (cons (+ (- (nth 0 window-edges) (nth 0 outer)) 6)
                                    (+ (- (nth 3 window-edges) (nth 1 outer)) 2))
                              2))
             ;; Thirty pixels below the text area, past every window, in
             ;; frame coordinates.
             (beyond (list frame nil
                           (cons (+ (nth 0 window-edges) 6)
                                 (+ (nth 3 window-edges) 29))
                           3)))
        (ebox-drag-test-play
         command press
         (list (cons 0.0 (funcall move '(5 . 5)))
               (cons 0.1 (list 'mouse-movement mode-line))
               (cons 0.2 (list 'mouse-movement beyond))
               (cons 0.3 (list 'drag-mouse-1 (list window position '(4 . 4) 0)
                               beyond))))
        (should (equal (nreverse gestures)
                       `((start (4 . 4) (0 . 0) nil)
                         (move (5 . 5) (0 . 0) nil)
                         (move (6 . ,bottom) (0 . 3) nil)
                         (end (6 . ,bottom) (0 . 30) nil))))))))

(ert-deftest ebox-drag-edge-reports-overshoot-and-elapsed-past-the-window ()
  "Edge phases continue past the window with the distance and the time between."
  (let (edges)
    (ebox-drag-test-with-target
        (ebox-keymap-create
         :drag-edge t
         :drag (lambda (gesture)
                 (when (eq (plist-get gesture :phase) 'edge)
                   (push (list (plist-get gesture :edges)
                               (plist-get gesture :position)
                               (plist-get gesture :overshoot)
                               (plist-get gesture :elapsed))
                         edges))))
      (let* ((middle (/ width 2))
             (beyond (list (window-frame window) nil
                           (cons (+ (nth 0 window-edges) middle)
                                 (+ (nth 3 window-edges) 39))
                           2)))
        (ebox-drag-test-play
         command press
         (list (cons 0.0 (funcall move '(5 . 5)))
               (cons 0.05 (list 'mouse-movement beyond))
               (cons 0.6 (list 'drag-mouse-1 (list window position '(4 . 4) 0)
                               beyond))))
        (should (>= (length edges) 2))
        (dolist (edge edges)
          (should (equal (nth 0 edge) '(bottom)))
          (should (equal (nth 1 edge) (cons middle (1- height))))
          (should (equal (nth 2 edge) '(0 . 40)))
          (should (numberp (nth 3 edge)))
          (should (>= (nth 3 edge) ebox-drag-edge-interval)))))))

(ert-deftest ebox-drag-edge-reports-intent-on-each-window-edge ()
  "An opted-in drag reports the bottom, top, left and right edge in turn."
  (dolist (side '(bottom top left right))
    (let (edges)
      (ebox-drag-test-with-target
          (ebox-keymap-create
           :drag-edge t
           :drag (lambda (gesture)
                   (when (eq (plist-get gesture :phase) 'edge)
                     (push (plist-get gesture :edges) edges))))
        (let ((point (ebox-drag-test-edge-point side width height)))
          (ebox-drag-test-play
           command press
           (list (cons 0.0 (funcall move point))
                 (cons 0.5 (funcall release point))))
          (should edges)
          (should (cl-every (lambda (value) (equal value (list side))) edges)))))))

(ert-deftest ebox-drag-edge-waits-for-motion ()
  "A press resting at the edge reports no intent until the pointer moves."
  (let (phases)
    (ebox-drag-test-with-target
        (ebox-keymap-create
         :drag-edge t
         :drag (lambda (gesture) (push (plist-get gesture :phase) phases)))
      (let ((point (ebox-drag-test-edge-point 'bottom width height)))
        (ebox-drag-test-play
         command press
         (list (cons 0.5 (funcall release point))))
        (should (equal (nreverse phases) '(start end)))))))

(ert-deftest ebox-drag-edge-requires-the-keymap-option ()
  "Without :drag-edge a drag keeps its old phases at the window edge."
  (let (phases)
    (ebox-drag-test-with-target
        (ebox-keymap-create
         :drag (lambda (gesture) (push (plist-get gesture :phase) phases)))
      (let ((point (ebox-drag-test-edge-point 'bottom width height)))
        (ebox-drag-test-play
         command press
         (list (cons 0.0 (funcall move point))
               (cons 0.5 (funcall release point))))
        (should (equal (nreverse phases) '(start move end)))))))

;;; ebox-drag-tests.el ends here
