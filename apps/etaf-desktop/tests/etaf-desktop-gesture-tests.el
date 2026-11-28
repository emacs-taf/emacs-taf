;;; etaf-desktop-gesture-tests.el --- Retained desktop gesture scenarios -*- lexical-binding: t; -*-

;;; Commentary:
;; These scenarios exercise the public desktop mount and event APIs.  They do
;; not inspect Behavior closures or Runtime tables; the observable contract is
;; that a mounted window keeps its gesture origin across publications.

;;; Code:

(require 'ert)
(require 'etaf)
(require 'etaf-desktop)

(defun etaf-desktop-gesture-test--dispatch (runtime host-ref gestures)
  "Dispatch GESTURES to HOST-REF through mounted RUNTIME."
  (dolist (gesture gestures)
    (etaf-dispatch-event runtime host-ref 'drag gesture t)))

(ert-deftest etaf-desktop-gesture-retains-origin-through-multiple-motions ()
  "A move and resize gesture survives every publication in one gesture."
  (let ((desktop (etaf-desktop-create :name " *desktop-gesture-retained*"
                                      :canvas-width 400 :canvas-height 30)))
    (unwind-protect
        (progn
          (etaf-desktop-open-window desktop 'notes :x 4 :y 2
                                    :width 240 :height 10
                                    :min-width 20 :min-height 3)
          (let* ((buffer (etaf-desktop-mount desktop))
                 (runtime (etaf-runtime-for-buffer buffer)))
            (etaf-desktop-gesture-test--dispatch
             runtime 'etaf-desktop-chrome-notes
             '((:phase start :delta (0 . 0))
               (:phase move :delta (10 . 2))
               (:phase move :delta (21 . 4))
               (:phase end :delta (37 . 6))))
            (let ((state (etaf-desktop-window-state desktop 'notes)))
              (should (equal '(41 8)
                             (list (plist-get state :x)
                                   (plist-get state :y)))))))
      (etaf-desktop-close desktop))))

(ert-deftest etaf-desktop-gesture-repeated-sequences-reset-origin ()
  "A second gesture starts from the committed geometry of the first one."
  (let ((desktop (etaf-desktop-create :name " *desktop-gesture-repeat*")))
    (unwind-protect
        (progn
          (etaf-desktop-open-window desktop 'notes :x 2 :y 1)
          (let* ((buffer (etaf-desktop-mount desktop))
                 (runtime (etaf-runtime-for-buffer buffer)))
            (etaf-desktop-gesture-test--dispatch
             runtime 'etaf-desktop-chrome-notes
             '((:phase start :delta (0 . 0))
               (:phase move :delta (8 . 2))
               (:phase end :delta (8 . 2))))
            (garbage-collect)
            (etaf-desktop-gesture-test--dispatch
             runtime 'etaf-desktop-chrome-notes
             '((:phase start :delta (0 . 0))
               (:phase move :delta (5 . 1))
               (:phase end :delta (5 . 1))))
            (let ((state (etaf-desktop-window-state desktop 'notes)))
              (should (equal '(15 4)
                             (list (plist-get state :x)
                                   (plist-get state :y)))))))
      (etaf-desktop-close desktop))))

(ert-deftest etaf-desktop-gesture-close-and-reopen-releases-retained-component ()
  "Closing a window releases its retained gesture component before reuse."
  (let ((desktop (etaf-desktop-create :name " *desktop-gesture-reopen*")))
    (unwind-protect
        (progn
          (etaf-desktop-open-window desktop 'notes :x 1 :y 1)
          (let* ((buffer (etaf-desktop-mount desktop))
                 (runtime (etaf-runtime-for-buffer buffer)))
            (etaf-desktop-gesture-test--dispatch
             runtime 'etaf-desktop-chrome-notes
             '((:phase start :delta (0 . 0))
               (:phase end :delta (4 . 1))))
            (should (= 5 (plist-get (etaf-desktop-window-state desktop 'notes) :x)))
            (should (etaf-desktop-close-window desktop 'notes))
            (etaf-desktop-open-window desktop 'notes :x 7 :y 3)
            (etaf-desktop-gesture-test--dispatch
             runtime 'etaf-desktop-chrome-notes
             '((:phase start :delta (0 . 0))
               (:phase end :delta (2 . 1))))
            (let ((state (etaf-desktop-window-state desktop 'notes)))
              (should (equal '(9 4)
                             (list (plist-get state :x)
                                   (plist-get state :y)))))))
      (etaf-desktop-close desktop))))

(ert-deftest etaf-desktop-gesture-resizes-every-enabled-edge-and-corner ()
  "Every edge owns its pointer target and changes only its controlled axes."
  (let ((desktop (etaf-desktop-create :name " *desktop-gesture-edges*"
                                      :canvas-width 500 :canvas-height 30)))
    (unwind-protect
        (progn
          (etaf-desktop-open-window desktop 'notes :x 10 :y 4 :width 240 :height 12
                                    :min-width 20 :min-height 3
                                    :view (etaf-view (box :width 'stretch :height 'stretch
                                                    :padding '((lh 0) (ch 2) (lh 1) (ch 2))
                                             (text "Kept content"))))
          (let* ((buffer (etaf-desktop-mount desktop))
                 (runtime (etaf-runtime-for-buffer buffer)))
            (dolist (edge '(left right top bottom top-left top-right bottom-left bottom-right))
              (etaf-desktop-move-window desktop 'notes 10 4)
              (etaf-desktop-resize-window desktop 'notes 240 12)
              (etaf-runtime-flush runtime)
              (let* ((ref (intern (format "etaf-desktop-resize-notes-%s" edge)))
                     (position (etaf-host-ref-position runtime ref))
                     (left (memq edge '(left top-left bottom-left)))
                     (right (memq edge '(right top-right bottom-right)))
                     (top (memq edge '(top top-left top-right)))
                     (bottom (memq edge '(bottom bottom-left bottom-right))))
                (should position)
                (should (eq ref (etaf-host-ref-at runtime position)))
                (with-current-buffer buffer
                  (should (eq (get-text-property position 'pointer)
                              (cond ((memq edge '(left right)) 'hdrag)
                                    ((memq edge '(top bottom)) 'vdrag)
                                    (t 'nhdrag)))))
                (etaf-desktop-gesture-test--dispatch
                 runtime ref '((:phase start :delta (0 . 0))
                               (:phase move :delta (2 . 1))
                               (:phase end :delta (5 . 1))))
                (should (equal (list (+ 10 (if left 5 0)) (+ 4 (if top 1 0))
                                     (+ 240 (cond (left -5) (right 5) (t 0)))
                                     (+ 12 (cond (top -1) (bottom 1) (t 0))))
                               (let ((state (etaf-desktop-window-state desktop 'notes)))
                                 (mapcar (lambda (key) (plist-get state key))
                                         '(:x :y :width :height)))))
                (with-current-buffer buffer
                  (should (string-match-p "Kept content"
                                          (buffer-substring-no-properties (point-min) (point-max)))))))))
      (etaf-desktop-close desktop))))

(ert-deftest etaf-desktop-background-uses-arrow-and-dismisses-launcher ()
  "Background dismissal keeps the canvas pointer an arrow."
  (let ((desktop (etaf-desktop-create :name " *desktop-background-pointer*"
                                      :canvas-width 800 :canvas-height 30)))
    (unwind-protect
        (let* ((buffer (etaf-desktop-mount desktop))
               (runtime (etaf-runtime-for-buffer buffer))
               (root (car (cl-find-if
                           (lambda (entry)
                             (eq (plist-get (cdr entry) :on-press)
                                 #'etaf-ui-dismiss-outside-press))
                           (etaf-runtime-host-props-entries runtime)))))
          (with-current-buffer buffer
            (save-excursion
              (goto-char (point-min))
              (forward-line 5)
              (should (eq 'arrow (get-text-property (point) 'pointer)))))
          (should root)
          (etaf-desktop-toggle-launcher desktop t)
          (should (etaf-desktop-launcher-open-p desktop))
          (etaf-dispatch-event runtime root 'press)
          (should-not (etaf-desktop-launcher-open-p desktop)))
      (etaf-desktop-close desktop))))

(ert-deftest etaf-desktop-gesture-clamps-resize-at-desktop-origin ()
  "Dragging a left edge past the canvas overflows it; a top edge stops at zero.
Neither gesture aborts, and each preserves its opposite edge."
  (let ((desktop (etaf-desktop-create :name " *desktop-gesture-origin*"
                                      :canvas-width 400 :canvas-height 30)))
    (unwind-protect
        (progn
          (etaf-desktop-open-window desktop 'notes :x 2 :y 2
                                    :width 100 :height 12
                                    :min-width 20 :min-height 3)
          (let* ((buffer (etaf-desktop-mount desktop))
                 (runtime (etaf-runtime-for-buffer buffer)))
            (etaf-desktop-gesture-test--dispatch
             runtime 'etaf-desktop-resize-notes-top-left
             '((:phase start :delta (0 . 0)) (:phase end :delta (-20 . 0))))
            (etaf-desktop-gesture-test--dispatch
             runtime 'etaf-desktop-resize-notes-top
             '((:phase start :delta (0 . 0)) (:phase end :delta (0 . -20))))
            (let ((state (etaf-desktop-window-state desktop 'notes)))
              (should (= -18 (plist-get state :x)))
              (should (= 0 (plist-get state :y)))
              (should (= 102 (+ (plist-get state :x)
                                (plist-get state :width))))
              (should (= 14 (+ (plist-get state :y)
                               (plist-get state :height)))))))
      (etaf-desktop-close desktop))))

(ert-deftest etaf-desktop-gesture-divider-tracks-cumulative-displacement ()
  "A tiling divider follows the pointer instead of compounding each motion.
Ebox reports every motion as the displacement from the press, so the ratio
after several moves equals the start ratio plus the final displacement, and a
cancelled gesture restores the ratio it started from."
  (let ((desktop (etaf-desktop-create :name " *desktop-gesture-divider*"
                                      :canvas-width 400 :canvas-height 20)))
    (unwind-protect
        (progn
          (dolist (id '(one two))
            (etaf-desktop-open-window desktop id :title (format "%s" id)
                                      :width 100 :min-width 10 :min-height 2))
          (etaf-desktop-set-setting desktop :tile-outer-gap 0)
          (etaf-desktop-set-setting desktop :tile-inner-gap 2)
          (etaf-desktop-set-layout-mode desktop 'tiling)
          (etaf-desktop-layout-set-tree
           desktop '(:split horizontal 0.5 (:leaf one) (:leaf two)))
          (let* ((buffer (etaf-desktop-mount desktop))
                 (runtime (etaf-runtime-for-buffer buffer))
                 (divider (cl-loop for (ref . props)
                                   in (etaf-runtime-host-props-entries runtime)
                                   when (equal "etaf-splitter-divider"
                                               (plist-get props :class))
                                   return ref))
                 (span (- 400 (* 2 (frame-char-width))))
                 (ratio (lambda ()
                          (nth 2 (etaf-desktop-layout-tree desktop))))
                 (right-edge (lambda ()
                               (let ((one (etaf-desktop-window-state desktop 'one)))
                                 (+ (plist-get one :x) (plist-get one :width)))))
                 (edge (funcall right-edge)))
            (should divider)
            (etaf-desktop-gesture-test--dispatch
             runtime divider
             '((:phase start :delta (0 . 0))
               (:phase move :delta (40 . 0))
               (:phase move :delta (80 . 0))
               (:phase end :delta (80 . 0))))
            (should (< (abs (- (+ 0.5 (/ 80.0 span)) (funcall ratio)))
                       0.001))
            (should (<= (abs (- (funcall right-edge) (+ edge 80))) 1))
            (etaf-desktop-gesture-test--dispatch
             runtime divider
             '((:phase start :delta (0 . 0))
               (:phase move :delta (-40 . 0))
               (:phase cancel :delta (-40 . 0))
               (:phase start :delta (0 . 0))
               (:phase end :delta (-80 . 0))))
            (should (< (abs (- 0.5 (funcall ratio))) 0.001))))
      (etaf-desktop-close desktop))))

(provide 'etaf-desktop-gesture-tests)
;;; etaf-desktop-gesture-tests.el ends here
