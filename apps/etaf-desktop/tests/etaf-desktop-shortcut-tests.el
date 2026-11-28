;;; etaf-desktop-shortcut-tests.el --- Desktop keyboard layout scenarios -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

(require 'ert)

(defun desktop-test-ref (desktop name)
  "Return DESKTOP's Host reference for NAME."
  (intern (concat (plist-get (etaf-desktop-state desktop) :token) "-" name)))
(require 'etaf-desktop)

(defun etaf-desktop-shortcut-test--press (buffer key)
  "Invoke KEY through the mounted BUFFER's active native keymap."
  (with-current-buffer buffer
    (goto-char (point-min))
    (let ((command (key-binding (kbd key))))
      (should (commandp command))
      (call-interactively command))))

(defun etaf-desktop-shortcut-test--rect (desktop id)
  "Return ID's public rectangle in DESKTOP."
  (let ((window (etaf-desktop-window-state desktop id)))
    (mapcar (lambda (key) (plist-get window key)) '(:x :y :width :height))))

(ert-deftest etaf-desktop-shortcuts-traverse-visible-windows-both-directions ()
  "Repeated next/previous visits every visible member, independent of raises."
  (let ((desktop (etaf-desktop-create :name " *desktop-traverse*"
                                     :canvas-width 400 :canvas-height 40
                                     :workspaces '(main other))))
    (unwind-protect
        (progn
          (dolist (id '(one hidden two three))
            (etaf-desktop-open-window desktop id :min-width 10))
          (etaf-desktop-open-window desktop 'elsewhere :workspace 'other)
          (etaf-desktop-minimize-window desktop 'hidden)
          (etaf-desktop-focus-window desktop 'one)
          (let ((buffer (etaf-desktop-mount desktop)))
            (dolist (id '(two three one))
              (etaf-desktop-shortcut-test--press buffer "n")
              (should (eq id (etaf-desktop-active-window desktop))))
            (dolist (id '(three two one))
              (etaf-desktop-shortcut-test--press buffer "p")
              (should (eq id (etaf-desktop-active-window desktop))))))
      (etaf-desktop-close desktop))))

(ert-deftest etaf-desktop-shortcuts-split-skips-hidden-windows ()
  "Split selects the next visible same-workspace window without restoring others."
  (let ((desktop (etaf-desktop-create :name " *desktop-split-shortcut*"
                                     :canvas-width 400 :canvas-height 40
                                     :workspaces '(main other))))
    (unwind-protect
        (progn
          (dolist (id '(one two hidden))
            (etaf-desktop-open-window desktop id :min-width 10))
          (etaf-desktop-open-window desktop 'elsewhere :workspace 'other)
          (etaf-desktop-minimize-window desktop 'hidden)
          (etaf-desktop-focus-window desktop 'one)
          (let* ((buffer (etaf-desktop-mount desktop))
                 (hidden (etaf-desktop-window-state desktop 'hidden))
                 (elsewhere (etaf-desktop-window-state desktop 'elsewhere)))
            (etaf-desktop-shortcut-test--press buffer "s")
            (should (eq 'tiling (etaf-desktop-layout-mode desktop)))
            (should (equal '(:split horizontal 0.5 (:leaf one) (:leaf two))
                           (etaf-desktop-layout-tree desktop)))
            (should (equal hidden (etaf-desktop-window-state desktop 'hidden)))
            (should (equal elsewhere
                           (etaf-desktop-window-state desktop 'elsewhere)))))
      (etaf-desktop-close desktop))))

(ert-deftest etaf-desktop-shortcuts-swap-tiled-leaves-retains-policy ()
  "Swap moves tiled content across retained splits and skips floating members."
  (let ((desktop (etaf-desktop-create :name " *desktop-swap-shortcut*"
                                     :canvas-width 500 :canvas-height 40)))
    (unwind-protect
        (progn
          (dolist (id '(one overlay two three hidden))
            (etaf-desktop-open-window desktop id :min-width 10 :min-height 2))
          (etaf-desktop-minimize-window desktop 'hidden)
          (etaf-desktop-set-layout-mode desktop 'tiling)
          (etaf-desktop-layout-set-tree
           desktop '(:split horizontal 0.6 (:leaf one)
                            (:split vertical 0.3 (:leaf two) (:leaf three))))
          (etaf-desktop-focus-window desktop 'one)
          (let* ((buffer (etaf-desktop-mount desktop))
                 (one (etaf-desktop-shortcut-test--rect desktop 'one))
                 (two (etaf-desktop-shortcut-test--rect desktop 'two))
                 (overlay (etaf-desktop-window-state desktop 'overlay))
                 (hidden (etaf-desktop-window-state desktop 'hidden))
                 (expected '(:split horizontal 0.6 (:leaf two)
                                    (:split vertical 0.3 (:leaf one) (:leaf three)))))
            (etaf-desktop-shortcut-test--press buffer "x")
            (should (equal expected (etaf-desktop-layout-tree desktop)))
            (should (equal two (etaf-desktop-shortcut-test--rect desktop 'one)))
            (should (equal one (etaf-desktop-shortcut-test--rect desktop 'two)))
            (should (eq 'one (etaf-desktop-active-window desktop)))
            (etaf-desktop-layout-refresh desktop)
            (should (equal expected (etaf-desktop-layout-tree desktop)))
            (should (equal overlay (etaf-desktop-window-state desktop 'overlay)))
            (should (equal hidden (etaf-desktop-window-state desktop 'hidden)))
            (etaf-desktop-restore-window desktop 'hidden)
            (let ((leaves (flatten-tree (etaf-desktop-layout-tree desktop))))
              (dolist (id '(one two three hidden))
                (should (= 1 (cl-count id leaves))))
              (should-not (memq 'overlay leaves)))
            (should (equal overlay (etaf-desktop-window-state desktop 'overlay)))))
      (etaf-desktop-close desktop))))

(ert-deftest etaf-desktop-shortcuts-swap-floating-visible-rectangles ()
  "Floating swap exchanges rectangles without changing minimized windows."
  (let ((desktop (etaf-desktop-create :name " *desktop-floating-swap*"
                                     :canvas-width 500 :canvas-height 40)))
    (unwind-protect
        (progn
          (etaf-desktop-open-window desktop 'one :x 20 :y 2 :width 200 :height 8)
          (etaf-desktop-open-window desktop 'two :x 80 :y 6 :width 300 :height 14)
          (etaf-desktop-open-window desktop 'hidden)
          (etaf-desktop-minimize-window desktop 'hidden)
          (etaf-desktop-focus-window desktop 'one)
          (let* ((buffer (etaf-desktop-mount desktop))
                 (one (etaf-desktop-shortcut-test--rect desktop 'one))
                 (two (etaf-desktop-shortcut-test--rect desktop 'two))
                 (hidden (etaf-desktop-window-state desktop 'hidden)))
            (etaf-desktop-shortcut-test--press buffer "x")
            (should (equal two (etaf-desktop-shortcut-test--rect desktop 'one)))
            (should (equal one (etaf-desktop-shortcut-test--rect desktop 'two)))
            (should (equal hidden (etaf-desktop-window-state desktop 'hidden)))))
      (etaf-desktop-close desktop))))

(ert-deftest etaf-desktop-master-stack-keeps-user-split-ratios ()
  "Both axis ratios survive focus, workspace switches and normal refreshes."
  (let ((desktop (etaf-desktop-create :name " *desktop-master-ratios*"
                                     :canvas-width 500 :canvas-height 40
                                     :workspaces '(main other))))
    (unwind-protect
        (progn
          (dolist (id '(one two three))
            (etaf-desktop-open-window desktop id :min-width 10 :min-height 2))
          (etaf-desktop-set-layout-mode desktop 'master-stack)
          (etaf-desktop-layout-resize-split desktop nil 0.7)
          (etaf-desktop-layout-resize-split desktop '(1) 0.3)
          (etaf-desktop-focus-window desktop 'one)
          (let* ((buffer (etaf-desktop-mount desktop))
                 (tree (etaf-desktop-layout-tree desktop)))
            (should (= 0.7 (nth 2 tree)))
            (should (= 0.3 (nth 2 (nth 4 tree))))
            (etaf-desktop-shortcut-test--press buffer "n")
            (etaf-desktop-layout-refresh desktop)
            (etaf-desktop-switch-workspace desktop 'other)
            (etaf-desktop-switch-workspace desktop 'main)
            (should (equal tree (etaf-desktop-layout-tree desktop)))
            (etaf-desktop-open-window desktop 'four :min-width 10 :min-height 2)
            (should (= 0.7 (nth 2 (etaf-desktop-layout-tree desktop))))))
      (etaf-desktop-close desktop))))

(ert-deftest etaf-desktop-shortcuts-close-observes-confirmation ()
  "The mounted close key uses the same confirmation policy as window chrome."
  (let ((desktop (etaf-desktop-create :name " *desktop-close-shortcut*"
                                     :canvas-width 400 :canvas-height 30)))
    (unwind-protect
        (progn
          (etaf-desktop-open-window desktop 'one)
          (etaf-desktop-set-setting desktop :confirm-close t)
          (let* ((buffer (etaf-desktop-mount desktop))
                 (runtime (etaf-runtime-for-buffer buffer)))
            (etaf-desktop-shortcut-test--press buffer "q")
            (should (etaf-desktop-window-state desktop 'one))
            (with-current-buffer buffer
              (should (string-match-p "Close window"
                                      (buffer-substring-no-properties
                                       (point-min) (point-max)))))
            (etaf-dispatch-event runtime (desktop-test-ref desktop "etaf-desktop-close-cancel") 'press)
            (should (etaf-desktop-window-state desktop 'one))
            (etaf-desktop-shortcut-test--press buffer "q")
            (etaf-dispatch-event runtime (desktop-test-ref desktop "etaf-desktop-close-confirm") 'press)
            (should-not (etaf-desktop-windows desktop))))
      (etaf-desktop-close desktop))))

(ert-deftest etaf-desktop-dividers-drag-from-constrained-edges-on-both-axes ()
  "A new drag begins at the actual edge after minimum or maximum allocation."
  (dolist (axis '(horizontal vertical))
    (let ((desktop (etaf-desktop-create :name " *desktop-constrained-divider*"
                                       :canvas-width 400 :canvas-height 40)))
      (unwind-protect
          (progn
            (etaf-desktop-open-window desktop 'one
                                      :width 120 :height 12
                                      :min-width 120 :min-height 12
                                      :max-width 200 :max-height 20)
            (etaf-desktop-open-window desktop 'two :min-width 10 :min-height 2)
            (etaf-desktop-set-setting desktop :tile-outer-gap 0)
            (etaf-desktop-set-layout-mode desktop 'tiling)
            (etaf-desktop-layout-set-tree
             desktop (list :split axis 0.1 '(:leaf one) '(:leaf two)))
            (let* ((buffer (etaf-desktop-mount desktop))
                   (runtime (etaf-runtime-for-buffer buffer))
                   (divider (cl-loop for (ref . props)
                                     in (etaf-runtime-host-props-entries runtime)
                                     when (equal "etaf-splitter-divider"
                                                 (plist-get props :class))
                                     return ref))
                   (dimension (if (eq axis 'horizontal) :width :height)))
              (should divider)
              (dolist (case '((0.1 . 2) (0.9 . -2)))
                (etaf-desktop-layout-resize-split desktop nil (car case))
                (let* ((before (plist-get (etaf-desktop-window-state desktop 'one)
                                          dimension))
                       (offset (cdr case))
                       (delta (if (eq axis 'horizontal) (cons offset 0)
                                (cons 0 offset))))
                  (etaf-dispatch-event runtime divider 'drag
                                       '(:phase start :delta (0 . 0)) t)
                  (etaf-dispatch-event runtime divider 'drag
                                       (list :phase 'move :delta delta) t)
                  (etaf-dispatch-event runtime divider 'drag
                                       (list :phase 'end :delta delta) t)
                  (should (= (+ before offset)
                             (plist-get (etaf-desktop-window-state desktop 'one)
                                        dimension)))
                  (let ((ratio (nth 2 (etaf-desktop-layout-tree desktop))))
                    (etaf-dispatch-event runtime divider 'drag
                                         '(:phase start :delta (0 . 0)) t)
                    (etaf-dispatch-event runtime divider 'drag
                                         (list :phase 'move :delta delta) t)
                    (etaf-dispatch-event runtime divider 'drag
                                         (list :phase 'cancel :delta delta) t)
                    (should (= ratio (nth 2 (etaf-desktop-layout-tree desktop)))))))))
        (etaf-desktop-close desktop)))))

;; Keyboard focus resolves Host keys from the focused node, so these
;; scenarios press keys where Tab or a shortcut left focus.
(defun etaf-desktop-shortcut-test--key (buffer key)
  "Run KEY's current binding in BUFFER without moving point."
  (with-current-buffer buffer
    (let ((command (key-binding (kbd key))))
      (should (commandp command))
      (call-interactively command))))

(ert-deftest etaf-desktop-keyboard-cycling-focuses-the-activated-window ()
  "Window cycling moves keyboard focus so window keys act on the new window."
  (let ((desktop (etaf-desktop-create :name " *desktop-cycle-focus*"
                                     :canvas-width 400 :canvas-height 40)))
    (unwind-protect
        (progn
          (etaf-desktop-open-window desktop 'one :x 0 :y 0 :width 160 :height 10)
          (etaf-desktop-open-window desktop 'two :x 0 :y 0 :width 160 :height 10)
          (let ((buffer (etaf-desktop-mount desktop)))
            (etaf-desktop-shortcut-test--press buffer "n")
            (should (eq 'one (etaf-desktop-active-window desktop)))
            (etaf-desktop-shortcut-test--key buffer "M-<right>")
            (should (< 0 (plist-get (etaf-desktop-window-state desktop 'one) :x)))
            (should (= 0 (plist-get (etaf-desktop-window-state desktop 'two) :x)))))
      (etaf-desktop-close desktop))))

(ert-deftest etaf-desktop-keyboard-tab-activates-tiled-windows ()
  "Tab traversal into a tiled window activates that window."
  (let ((desktop (etaf-desktop-create :name " *desktop-tab-activate*"
                                     :canvas-width 400 :canvas-height 40))
        seen)
    (unwind-protect
        (progn
          (etaf-desktop-open-window desktop 'one)
          (etaf-desktop-open-window desktop 'two)
          (etaf-desktop-set-layout-mode desktop 'tiling)
          (let ((runtime (etaf-runtime-for-buffer (etaf-desktop-mount desktop))))
            (should (eq 'two (etaf-desktop-active-window desktop)))
            (dotimes (_ 12)
              (etaf-focus-next runtime)
              (cl-pushnew (etaf-desktop-active-window desktop) seen))
            (should (memq 'one seen))
            (should (memq 'two seen))))
      (etaf-desktop-close desktop))))

(ert-deftest etaf-desktop-keyboard-steps-tiling-divider ()
  "A focused tiling divider moves its split with the arrow keys."
  (let ((desktop (etaf-desktop-create :name " *desktop-divider-keys*"
                                     :canvas-width 400 :canvas-height 40)))
    (unwind-protect
        (progn
          (etaf-desktop-open-window desktop 'one)
          (etaf-desktop-open-window desktop 'two)
          (etaf-desktop-set-layout-mode desktop 'tiling)
          (etaf-desktop-layout-set-tree
           desktop '(:split vertical 0.5 (:leaf one) (:leaf two)))
          (let* ((buffer (etaf-desktop-mount desktop))
                 (runtime (etaf-runtime-for-buffer buffer)))
            (dotimes (_ 12)
              (unless (equal "separator"
                             (format "%s" (plist-get (etaf-runtime-host-props-for
                                                      runtime (etaf-focused-host-ref runtime))
                                                     :role)))
                (etaf-focus-next runtime)))
            (etaf-desktop-shortcut-test--key buffer "<down>")
            (should (< 0.5 (nth 2 (etaf-desktop-layout-tree desktop))))
            (etaf-desktop-shortcut-test--key buffer "<up>")
            (should (< (abs (- 0.5 (nth 2 (etaf-desktop-layout-tree desktop))))
                       0.001))))
      (etaf-desktop-close desktop))))

(ert-deftest etaf-desktop-native-title-click-only-focuses ()
  "A title press/release without displacement preserves normal/maximized geometry."
  (let ((desktop (etaf-desktop-create :name " *desktop-title-click*"
                                     :canvas-width 600 :canvas-height 30)))
    (unwind-protect
        (save-window-excursion
          (etaf-desktop-open-window desktop 'target :title "Target"
                                    :x 20 :y 2 :width 240 :height 12)
          (etaf-desktop-open-window desktop 'other :title "Other"
                                    :x 320 :y 14 :width 200 :height 10)
          (let* ((buffer (etaf-desktop-mount desktop))
                 (runtime (etaf-runtime-for-buffer buffer)))
            (set-window-buffer (selected-window) buffer)
            (dolist (maximized '(nil t))
              (when maximized (etaf-desktop-maximize-window desktop 'target))
              (etaf-desktop-focus-window desktop 'other)
              (let ((before (etaf-desktop-shortcut-test--rect desktop 'target)))
                (with-current-buffer buffer
                  (let* ((position (etaf-host-ref-position
                                    runtime 'etaf-desktop-chrome-target))
                         (start (list (selected-window) position '(2 . 2) 0))
                         (press (list 'down-mouse-1 start))
                         (command (key-binding (vector press) nil nil position))
                         (unread-command-events (list (list 'mouse-1 start)))
                         (last-input-event nil)
                         (last-command-event nil))
                    (should position)
                    (should (commandp command))
                    (funcall command press)
                    (should-not unread-command-events)))
                (etaf-runtime-flush runtime)
                (should (eq 'target (etaf-desktop-active-window desktop)))
                (should (equal before
                               (etaf-desktop-shortcut-test--rect desktop 'target)))
                (should (eq maximized
                            (plist-get (etaf-desktop-window-state desktop 'target)
                                       :maximized)))))))
      (etaf-desktop-close desktop))))

(provide 'etaf-desktop-shortcut-tests)
;;; etaf-desktop-shortcut-tests.el ends here
