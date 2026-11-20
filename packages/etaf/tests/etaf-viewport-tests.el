;;; etaf-viewport-tests.el --- Nested viewport regions through public APIs -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Code:

(require 'etaf-test-support)

(etaf-define-component etaf-viewport-test-reader (&key seen)
  "Record the subtree's viewport into the cons cell SEEN."
  :setup
  (progn
    (etaf-watch-effect
     (lambda () (setcar seen (etaf-viewport))))
    nil)
  :view (text "reader"))

(etaf-define-component etaf-viewport-test-region (&key seen)
  "Wrap SEEN's reader in a viewport region that fills its parent."
  :view (etaf-viewport-region (etaf-viewport-test-reader :seen seen)))

(etaf-define-component etaf-viewport-test-callable-reader (&key seen)
  "Record the subtree's viewport through a callable watch source into SEEN.
A callable source is read outside the Component's dynamic environment, so
this exercises the environment `etaf-watch' must retain for its getter."
  :setup
  (progn
    (etaf-watch #'etaf-viewport
                (lambda (new _old) (setcar seen new))
                :immediate t)
    nil)
  :view (text "callable reader"))

(etaf-define-component etaf-viewport-test-callable-region (&key seen)
  "Wrap SEEN's callable reader in a viewport region that fills its parent."
  :view (etaf-viewport-region (etaf-viewport-test-callable-reader :seen seen)))

(etaf-define-component etaf-viewport-test-fixed-region (&key seen height)
  "Wrap SEEN's reader in a viewport region of HEIGHT lines."
  :view (etaf-viewport-region :height (list 'lh (etaf-value height))
          (etaf-viewport-test-reader :seen seen)))

(etaf-define-component etaf-viewport-test-computed-reader (&key source seen)
  "Record the subtree's viewport through a computed binding into SEEN.
SOURCE is read first so a plain reference change dirties the computed."
  :bindings ((viewport (etaf-computed
                        (lambda ()
                          (etaf-value source)
                          (etaf-viewport))
                        :test #'equal)))
  :setup
  (progn
    (etaf-watch viewport (lambda (new _old) (setcar seen new)))
    nil)
  :view (text "computed reader"))

(etaf-define-component etaf-viewport-test-computed-region (&key source seen height)
  "Wrap SEEN's computed reader in a viewport region of HEIGHT lines."
  :view (etaf-viewport-region :height (list 'lh (etaf-value height))
          (etaf-viewport-test-computed-reader :source source :seen seen)))

(etaf-define-component etaf-viewport-test-wrapper ()
  "Pass its default slot through a viewport region."
  :render
  (etaf-node 'etaf-viewport-region nil (etaf-current-slot 'default)))

(etaf-define-component etaf-viewport-test-toggle (&key show seen)
  "Show a four-line region around SEEN's reader only while SHOW is non-nil."
  :render
  (if (etaf-value show)
      (etaf-node 'etaf-viewport-region (list :height '(lh 4))
                 (list (etaf-node 'etaf-viewport-test-reader (list :seen seen) nil)))
    (etaf-node 'etaf-viewport-test-reader (list :seen seen) nil)))

(ert-deftest etaf-viewport-region-publishes-its-committed-size ()
  "Content below a region reads the region's committed box, not the mount."
  (let ((seen (cons nil nil)))
    (etaf-test-with-mount
        (runtime (etaf-view (etaf-viewport-test-region :seen seen))
                 (list :viewport-width 200 :viewport-height 10))
      (should (equal (car seen) (cons 200 10))))))

(ert-deftest etaf-viewport-falls-back-to-the-runtime-viewport ()
  "Without a region the subtree reads the mounted Runtime's viewport."
  (let ((seen (cons nil nil)))
    (etaf-test-with-mount
        (runtime (etaf-view (etaf-viewport-test-reader :seen seen))
                 (list :viewport-width 400 :viewport-height 12))
      (should (equal (car seen) (cons 400 12))))))

(ert-deftest etaf-viewport-region-reaches-slot-content ()
  "Content passed through a slot resolves the wrapping region."
  (let ((seen (cons nil nil)))
    (etaf-test-with-mount
        (runtime (etaf-view (etaf-viewport-test-wrapper
                             (etaf-viewport-test-reader :seen seen)))
                 (list :viewport-width 200 :viewport-height 10))
      (should (equal (car seen) (cons 200 10))))))

(ert-deftest etaf-viewport-region-republishes-after-a-region-resize ()
  "Changing a region's own size republishes it after the next flush."
  (let ((seen (cons nil nil))
        (height (etaf-ref 6)))
    (etaf-test-with-mount
        (runtime (etaf-view
                  (etaf-viewport-test-fixed-region :seen seen :height height))
                 (list :viewport-width 200 :viewport-height 10))
      (should (equal (car seen) (cons 200 6)))
      (etaf-set-value height 3)
      (should (equal (car seen) (cons 200 3))))))

(ert-deftest etaf-viewport-region-follows-the-mount-refit ()
  "A stretched region republishes after the Runtime viewport changes."
  (let ((seen (cons nil nil)))
    (etaf-test-with-mount
        (runtime (etaf-view (etaf-viewport-test-region :seen seen))
                 (list :viewport-width 200 :viewport-height 10))
      (should (equal (car seen) (cons 200 10)))
      (etaf-runtime-refit runtime 200 6)
      (etaf-runtime-flush runtime)
      (should (equal (car seen) (cons 200 6))))))

(ert-deftest etaf-viewport-nearest-region-wins ()
  "A nested region shadows the region around it."
  (let ((seen (cons nil nil)))
    (etaf-test-with-mount
        (runtime (etaf-view
                  (etaf-viewport-region :height '(lh 8)
                    (etaf-viewport-region :height '(lh 3)
                      (etaf-viewport-test-reader :seen seen))))
                 (list :viewport-width 200 :viewport-height 10))
      (should (equal (car seen) (cons 200 3))))))

(ert-deftest etaf-viewport-region-stops-publishing-when-removed ()
  "Removing a region returns its subtree to the Runtime viewport."
  (let ((seen (cons nil nil))
        (show (etaf-ref t)))
    (etaf-test-with-mount
        (runtime (etaf-view (etaf-viewport-test-toggle :show show :seen seen))
                 (list :viewport-width 200 :viewport-height 10))
      (should (equal (car seen) (cons 200 4)))
      (etaf-set-value show nil)
      (should (equal (car seen) (cons 200 10))))))

(ert-deftest etaf-viewport-callable-source-reads-its-own-region ()
  "A watcher with a callable source reads the enclosing region, not the canvas.
The source is evaluated at flush time, outside the Component's dynamic
environment; without a retained environment `etaf-viewport' answers with the
Runtime canvas and an embedded view lays out for the whole buffer."
  (let ((seen (cons nil nil)))
    (etaf-test-with-mount
        (_runtime (etaf-view (etaf-viewport-test-callable-region :seen seen))
                  (list :viewport-width 200 :viewport-height 10))
      (should (equal (car seen) (cons 200 10))))))

(ert-deftest etaf-viewport-computed-keeps-its-component-environment ()
  "A computed keeps reading its own region when later run outside rendering.
The refresh below happens in a buffer with no Runtime and no Component
render; without the retained Component environment the getter would look
up the ambient Runtime and signal."
  (let ((source (etaf-ref 1))
        (height (etaf-ref 6))
        (seen (cons nil nil)))
    (etaf-test-with-mount
        (_runtime (etaf-view (etaf-viewport-test-computed-region
                              :source source :seen seen :height height))
                  (list :viewport-width 200 :viewport-height 10))
      (should (equal (car seen) (cons 200 6)))
      ;; Refresh from a buffer without a Runtime, outside any render.
      (with-temp-buffer (etaf-set-value source 2))
      (should (equal (car seen) (cons 200 6))))))

(ert-deftest etaf-viewport-window-metrics-need-a-live-window ()
  "The window viewport follows a displaying window on any display and needs a Runtime."
  (etaf-test-with-mount (runtime (etaf-view (box "w")))
    (should-not (etaf-runtime-window-viewport runtime)))
  (should-error (etaf-runtime-window-viewport) :type 'etaf-runtime-error))

(ert-deftest etaf-viewport-window-metrics-read-a-text-window ()
  "A text frame reports the cell viewport of the window showing the Runtime.
The width is what the mount lays out against, so a terminal surface can
center and clamp itself instead of guessing a pixel width."
  (etaf-test-with-mount (runtime (etaf-view (box "w")))
    (let* ((window (selected-window))
           (original (window-buffer window)))
      (unwind-protect
          (progn
            (set-window-buffer window (current-buffer))
            (should (equal (etaf-runtime-window-viewport runtime)
                           (cons (ebox-viewport-window-width window)
                                 (window-body-height window)))))
        (set-window-buffer window original)))))

(ert-deftest etaf-viewport-canvas-columns-follow-the-canvas-cell ()
  "The canvas reports its own cells, not the frame's face.
A ten-pixel canvas in a frame whose face is twenty pixels wide holds forty
columns in 400 pixels; dividing by the frame's cell would report twenty and
lay the page out at half the width it has."
  (etaf-test-with-mount (runtime (etaf-view (box :ref 'entry "Entry")))
    (cl-letf (((symbol-function 'ebox-display-metrics)
               (lambda (&optional _buffer)
                 (list :char-width 10 :line-height 18 :ascent 100)))
              ((symbol-function 'frame-char-width) (lambda (&optional _frame) 20))
              ((symbol-function 'frame-char-height) (lambda (&optional _frame) 40)))
      (etaf-runtime-refit runtime 400 20)
      (should (equal (etaf-canvas-cell runtime) (cons 10 18)))
      (should (= (etaf-canvas-columns runtime) 40))
      ;; A hundred and ninety-three canvas cells hold four 42-cell items with
      ;; three cells between them, and leave the remainder on both sides.
      (should (equal (etaf-fit-columns 193 42 30)
                     '(:across 4 :item 42 :offset 8)))
      ;; One more column only when every item still clears its minimum.
      (should (equal (etaf-fit-columns 240 42 30)
                     '(:across 5 :item 42 :offset 9)))
      (should (equal (etaf-fit-columns 100 42 30)
                     '(:across 2 :item 42 :offset 6)))
      (should (equal (etaf-fit-columns 40 42 30)
                     '(:across 1 :item 40 :offset 0))))))

(provide 'etaf-viewport-tests)
;;; etaf-viewport-tests.el ends here
