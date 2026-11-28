;;; etaf-view-tests.el --- Retained View updates through public APIs -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Code:

(require 'etaf-test-support)

(etaf-define-component etaf-view-test-label (&key label)
  "Render LABEL in one text Host."
  :view (text (expr (etaf-value label))))

(etaf-define-component etaf-view-test-counter-row (&key name)
  "Render NAME with a retained local counter."
  :bindings ((clicks (etaf-ref 0)))
  :view
  (row :ref (intern (format "row-%s" name))
       :on-press (lambda () (etaf-update-value clicks #'1+))
    (text (expr (format "%s=%d" name (etaf-value clicks))))))

(defvar etaf-view-test--mounted nil
  "Names whose `etaf-view-test-mounted-row' mount hook ran.")

(etaf-define-component etaf-view-test-mounted-row (&key name)
  "Render NAME and record it once its row is committed."
  :setup (progn (etaf-on-mounted (lambda () (push name etaf-view-test--mounted))) nil)
  :view (etaf-view-test-counter-row :name name))

(etaf-define-component etaf-view-test-frame (&key title)
  "Render TITLE above default content and a named footer slot."
  :view
  (column
    (text (expr title))
    (slot)
    (slot :name 'footer (text "no footer"))))

(etaf-define-component etaf-view-test-styled ()
  "Render one styled label."
  :view (column (box :class "title" "styled"))
  :styles ((".title" :font-weight bold)))

(etaf-define-component etaf-view-test-viewport-rows ()
  "Render one row per viewport line above three."
  :render
  (let ((lines (cdr (etaf-runtime-viewport))))
    (etaf-node 'column nil
               (cl-loop repeat (- lines 2)
                        collect (etaf-node 'text nil (list (format "r%d" lines)))))))

(ert-deftest etaf-view-mounts-static-and-expression-text ()
  "A mounted View paints static text and updates an expression in place."
  (let ((label (etaf-ref "first")))
    (etaf-test-with-mount (runtime (etaf-view (column (text "header")
                                                      (etaf-view-test-label :label label))))
      (should (equal (etaf-test-lines) '("header" "first")))
      (let ((revision (etaf-runtime-revision runtime)))
        (etaf-set-value label "second")
        (should (equal (etaf-test-lines) '("header" "second")))
        (should (> (etaf-runtime-revision runtime) revision))))))

(ert-deftest etaf-view-refit-advances-revision-only-on-layout-change ()
  "A refit that changes the viewport commits a revision; an equal one does not."
  (etaf-test-with-mount (runtime (etaf-view (row (text "left") (text "right"))))
    (let ((revision (etaf-runtime-revision runtime)))
      (should (etaf-runtime-refit runtime 400 40))
      (should (equal (etaf-runtime-viewport runtime) '(400 . 40)))
      (should (= (etaf-runtime-revision runtime) (1+ revision)))
      (should-not (etaf-runtime-refit runtime 400 40))
      (should (= (etaf-runtime-revision runtime) (1+ revision))))))

(ert-deftest etaf-view-transient-space-borrow-detection ()
  "A taller minibuffer marks the shortened window as borrowed geometry."
  (let ((config (current-window-configuration))
        (window (selected-window))
        (minibuffer (minibuffer-window (selected-frame))))
    (unwind-protect
        (let ((committed (window-body-height window)))
          (should-not (etaf-transient-space-borrowed-p window committed))
          ;; The minibuffer grows and takes real lines from the window.
          (window-resize minibuffer 4 nil t)
          (should (< (window-body-height window) committed))
          (should (etaf-transient-space-borrowed-p window committed))
          ;; A commitment to the borrowed height is not a borrow, and neither
          ;; is a missing commitment.
          (should-not (etaf-transient-space-borrowed-p window (window-body-height window)))
          (should-not (etaf-transient-space-borrowed-p window nil))
          ;; The minibuffer releases the lines when it returns to one row.
          (window-resize minibuffer -4 nil t)
          (should (= (window-body-height window) committed))
          (should-not (etaf-transient-space-borrowed-p window committed))
          ;; A shorter window with no transient UI is real geometry too.
          (let ((other (split-window window 4)))
            (unwind-protect
                (progn
                  (should (window-live-p other))
                  (should (< (window-body-height window) committed))
                  (should-not (etaf-transient-space-borrowed-p window committed)))
              (delete-window other))))
      (set-window-configuration config))))

(ert-deftest etaf-view-viewport-reads-follow-a-refit ()
  "Text and renders reading the viewport show its new size after a refit."
  (etaf-test-with-mount (runtime (etaf-view
                                  (column
                                   (text (expr (format "w%d" (car (etaf-runtime-viewport)))))
                                   (etaf-view-test-viewport-rows)))
                                 (list :viewport-width 400 :viewport-height 3))
    (should (equal (etaf-test-lines) '("w400" "r3")))
    (etaf-runtime-refit runtime 600 4)
    (should (equal (etaf-test-lines) '("w600" "r4" "r4")))))

(ert-deftest etaf-view-refit-nil-width-follows-the-display ()
  "A nil refit width returns that dimension to display tracking."
  (etaf-test-with-mount (runtime (etaf-view (row (text "left") (text "right")))
                                 (list :viewport-height 40))
    (let ((tracked (car (etaf-runtime-viewport runtime))))
      (etaf-runtime-refit runtime (+ tracked 300) 40)
      (should (equal (etaf-runtime-viewport runtime) (cons (+ tracked 300) 40)))
      (etaf-runtime-refit runtime nil 20)
      (should (equal (etaf-runtime-viewport runtime) (cons tracked 20)))
      (should-error (etaf-runtime-refit runtime 0 20) :type 'wrong-type-argument))))

(ert-deftest etaf-view-refit-reports-an-observed-operation ()
  "A refit reaches the mount observer as a refit operation with its flush."
  (let (reports)
    (etaf-test-with-mount (runtime (etaf-view (row (text "left") (text "right")))
                                   (list :viewport-width 800 :viewport-height 40
                                         :observer (lambda (report) (push report reports))))
      (setq reports nil)
      (should (etaf-runtime-refit runtime 400 40))
      (should (cl-find-if (lambda (report)
                            (and (eq (plist-get report :stage) 'runtime-operation)
                                 (eq (plist-get report :kind) 'refit)
                                 (eq (plist-get report :status) 'success)
                                 (> (plist-get report :revision-after)
                                    (plist-get report :revision-before))))
                          reports))
      (should (cl-find-if (lambda (report)
                            (and (eq (plist-get report :provider) 'ebox)
                                 (plist-get report :ranges)))
                          reports)))))

(ert-deftest etaf-view-batches-writes-into-one-commit ()
  "Writes inside one batch become visible together in one revision."
  (let ((a (etaf-ref "a")) (b (etaf-ref "b")))
    (etaf-test-with-mount (runtime (etaf-view (column (text (expr (etaf-value a)))
                                                      (text (expr (etaf-value b))))))
      (let ((revision (etaf-runtime-revision runtime)))
        (etaf-batch
          (etaf-set-value a "A")
          (etaf-set-value b "B")
          (should (equal (etaf-test-lines) '("a" "b"))))
        (should (equal (etaf-test-lines) '("A" "B")))
        (should (= (etaf-runtime-revision runtime) (1+ revision)))
        (should (eq 'lines (plist-get (etaf-runtime-update-report runtime) :strategy)))))))

(ert-deftest etaf-view-updates-reactive-paint-properties ()
  "A reactive Host property changes the painted face without changing text."
  (let ((bold (etaf-ref nil)))
    (etaf-test-with-mount (_runtime
                           (etaf-view (box :font-weight (if (etaf-value bold) 'bold 'normal)
                                           "label")))
      (should-not (eq (etaf-test-face-attribute (etaf-test-face-at "label") :weight) 'bold))
      (etaf-set-value bold t)
      (should (equal (etaf-test-lines) '("label")))
      (should (eq (etaf-test-face-attribute (etaf-test-face-at "label") :weight) 'bold)))))

(ert-deftest etaf-view-switches-branches ()
  "Branch directives mount only the selected arm and switch when inputs change."
  (let ((mode (etaf-ref 'a)))
    (etaf-test-with-mount (_runtime
                           (etaf-view (column
                                        (text :if (eq (etaf-value mode) 'a) "arm a")
                                        (text :else-if (eq (etaf-value mode) 'b) "arm b")
                                        (text :else t "arm c")
                                        (text "tail"))))
      (should (equal (etaf-test-lines) '("arm a" "tail")))
      (etaf-set-value mode 'b)
      (should (equal (etaf-test-lines) '("arm b" "tail")))
      (etaf-set-value mode 'z)
      (should (equal (etaf-test-lines) '("arm c" "tail")))
      (etaf-set-value mode 'a)
      (should (equal (etaf-test-lines) '("arm a" "tail"))))))

(ert-deftest etaf-view-keyed-list-retains-instances ()
  "Keyed rows keep Component state across insertion, reordering and removal."
  (let ((names (etaf-ref '("a" "b" "c"))))
    (etaf-test-with-mount (runtime
                           (etaf-view (column
                                        (etaf-view-test-counter-row
                                         :for (name (etaf-value names)) :key name
                                         :name name))))
      (should (equal (etaf-test-lines) '("a=0" "b=0" "c=0")))
      (etaf-dispatch-event runtime 'row-b 'press)
      (etaf-dispatch-event runtime 'row-b 'press)
      (should (equal (etaf-test-lines) '("a=0" "b=2" "c=0")))
      (etaf-set-value names '("c" "x" "b" "a"))
      (should (equal (etaf-test-lines) '("c=0" "x=0" "b=2" "a=0")))
      (etaf-set-value names '("b"))
      (should (equal (etaf-test-lines) '("b=2")))
      (should-not (etaf-runtime-host-props-for runtime 'row-a))
      (etaf-set-value names '("a" "b"))
      (should (equal (etaf-test-lines) '("a=0" "b=2"))))))

(ert-deftest etaf-view-keyed-list-appends-and-clears ()
  "Appending to and clearing a keyed list matches a fresh render."
  (let ((items (etaf-ref (number-sequence 1 3))))
    (etaf-test-with-mount (_runtime
                           (etaf-view (column
                                        (text "head")
                                        (text :for (n (etaf-value items)) :key n
                                              (expr (format "item %d" n)))
                                        (text "foot"))))
      (etaf-set-value items (number-sequence 1 5))
      (should (equal (etaf-test-lines)
                     '("head" "item 1" "item 2" "item 3" "item 4" "item 5" "foot")))
      (etaf-set-value items nil)
      (should (equal (etaf-test-lines) '("head" "foot")))
      (etaf-set-value items '(9))
      (should (equal (etaf-test-lines) '("head" "item 9" "foot"))))))

(ert-deftest etaf-view-failed-update-keeps-committed-ui-until-retry ()
  "A failing site discards its whole update; the next write retries all of it."
  (let ((label (etaf-ref "a")) (mode (etaf-ref 'a))
        (names (etaf-ref '("x"))) (broken (etaf-ref nil))
        (etaf-view-test--mounted nil))
    (etaf-test-with-mount (runtime
                           (etaf-view (column
                                        (text (expr (etaf-value label)))
                                        (text :if (eq (etaf-value mode) 'b) "arm b")
                                        (etaf-view-test-mounted-row
                                         :for (name (etaf-value names)) :key name
                                         :name name)
                                        (text (expr (if (etaf-value broken)
                                                        (error "Broken site")
                                                      "ok"))))))
      (etaf-dispatch-event runtime 'row-x 'press)
      (should (equal (etaf-test-lines) '("a" "x=1" "ok")))
      (should (equal etaf-view-test--mounted '("x")))
      (let ((revision (etaf-runtime-revision runtime)))
        (should-error (etaf-batch
                        (etaf-set-value label "A")
                        (etaf-set-value mode 'b)
                        (etaf-set-value names '("y" "x"))
                        (etaf-set-value broken t)))
        (should (equal (etaf-test-lines) '("a" "x=1" "ok")))
        (should (= (etaf-runtime-revision runtime) revision))
        (should-not (etaf-runtime-host-props-for runtime 'row-y))
        (should (equal etaf-view-test--mounted '("x")))
        ;; Later work retries the discarded update, so it waits for the fix too.
        (should-error (etaf-dispatch-event runtime 'row-x 'press))
        (should (equal (etaf-test-lines) '("a" "x=1" "ok")))
        (should (= (etaf-runtime-revision runtime) revision))
        (etaf-set-value broken nil)
        (should (equal (etaf-test-lines) '("A" "arm b" "y=0" "x=2" "ok")))
        (should (= (etaf-runtime-revision runtime) (1+ revision)))
        (should (equal etaf-view-test--mounted '("y" "x")))))))

(ert-deftest etaf-view-rejects-duplicate-list-keys ()
  "Duplicate keys signal and keep the previous committed rows."
  (let ((items (etaf-ref '(1 2))))
    (etaf-test-with-mount (_runtime
                           (etaf-view (column (text :for (n (etaf-value items)) :key n
                                                    (expr (format "n%d" n))))))
      (should-error (etaf-set-value items '(1 1)))
      (should (equal (etaf-test-lines) '("n1" "n2"))))))

(ert-deftest etaf-view-rejects-duplicate-keys-in-long-lists ()
  "A long list of keyed siblings rejects a repeated key; another tag may reuse it."
  (let ((keys (etaf-ref (number-sequence 1 40))))
    (etaf-test-with-mount (_runtime
                           (etaf-view
                             (column
                               (expr (etaf-node
                                      'column nil
                                      (append
                                       (mapcar (lambda (n)
                                                 (etaf-node 'text (list :key n)
                                                            (list (format "n%d" n))))
                                               (etaf-value keys))
                                       (list (etaf-node 'column '(:key 40)
                                                        (list (etaf-node 'text nil '("tail")))))))))))
      (should (= (length (etaf-test-lines)) 41))
      (should (equal (car (last (etaf-test-lines))) "tail"))
      (should-error (etaf-set-value keys (append (number-sequence 1 40) '(7)))
                    :type 'etaf-renderer-error)
      (should (= (length (etaf-test-lines)) 41))
      (should (equal (nth 39 (etaf-test-lines)) "n40")))))

(ert-deftest etaf-view-projects-default-and-named-slots ()
  "Default and named slots project caller content; absent slots use fallback."
  (let ((footer (etaf-ref t)))
    (etaf-test-with-mount (_runtime
                           (etaf-view (column
                                        (etaf-view-test-frame
                                         :title "Frame"
                                         (text "body")
                                         (slot :name 'footer
                                               (column
                                                 (text :if (etaf-value footer)
                                                       "custom footer")))))))
      (should (equal (etaf-test-lines) '("Frame" "body" "custom footer")))
      (etaf-set-value footer nil)
      (should (equal (etaf-test-lines) '("Frame" "body"))))
    (etaf-test-with-mount (_runtime (etaf-view (etaf-view-test-frame :title "Bare")))
      (should (equal (etaf-test-lines) '("Bare" "no footer"))))))

(ert-deftest etaf-view-component-props-update-retained-instance ()
  "A changed business prop updates the instance without resetting bindings."
  (let ((name (etaf-ref "left")))
    (etaf-test-with-mount (runtime
                           (etaf-view (column (etaf-view-test-counter-row
                                               :name (etaf-value name)))))
      (etaf-dispatch-event runtime 'row-left 'press)
      (should (equal (etaf-test-lines) '("left=1")))
      (etaf-set-value name "right")
      (should (equal (etaf-test-lines) '("right=1")))
      (etaf-dispatch-event runtime 'row-right 'press)
      (should (equal (etaf-test-lines) '("right=2"))))))

(ert-deftest etaf-view-render-returns-detached-node ()
  "Pure rendering evaluates the View once without a Runtime."
  (let* ((count (etaf-ref 3))
         (node (etaf-render (etaf-view (column (text (expr (format "n=%d" (etaf-value count)))))))))
    (should node)
    (with-temp-buffer
      (ebox-mount (current-buffer) node :width 400 :height 10)
      (should (equal (etaf-test-lines) '("n=3"))))))

(ert-deftest etaf-view-node-builds-views-programmatically ()
  "`etaf-node' constructs the same Views as the DSL."
  (let ((label (etaf-ref "dynamic")))
    (etaf-test-with-mount (_runtime
                           (etaf-node 'column nil
                                      (list (etaf-node 'text nil (list "static"))
                                            (etaf-node 'etaf-view-test-label
                                                       (list :label label) nil))))
      (should (equal (etaf-test-lines) '("static" "dynamic")))
      (etaf-set-value label "changed")
      (should (equal (etaf-test-lines) '("static" "changed"))))))

(ert-deftest etaf-view-applies-component-styles ()
  "Component rules style owned Hosts and later rule changes repaint them."
  (etaf-test-with-mount (_runtime (etaf-view (etaf-view-test-styled)))
    (should (eq (etaf-test-face-attribute (etaf-test-face-at "styled") :weight) 'bold))))

(ert-deftest etaf-view-unmount-and-kill-release-runtime ()
  "Unmounting releases the Runtime; killing a buffer unmounts it."
  (let ((buffer (generate-new-buffer " *etaf-unmount*")))
    (etaf-mount buffer (etaf-view (text "x")))
    (let ((runtime (etaf-runtime-for-buffer buffer)))
      (should (etaf-runtime-mounted-p runtime))
      (etaf-unmount runtime)
      (should-not (etaf-runtime-mounted-p runtime))
      (should-not (etaf-runtime-for-buffer buffer)))
    (etaf-mount buffer (etaf-view (text "y")))
    (let ((runtime (etaf-runtime-for-buffer buffer)))
      (kill-buffer buffer)
      (should-not (etaf-runtime-mounted-p runtime)))))

(ert-deftest etaf-string-pixel-width-measures-the-first-line ()
  "The measurement adapter measures styled text and rejects non-strings."
  (should (zerop (etaf-string-pixel-width "")))
  (should (> (etaf-string-pixel-width "abc") 0))
  ;; Only the first line is measured.
  (should (= (etaf-string-pixel-width "abc\ndefgh")
             (etaf-string-pixel-width "abc")))
  ;; A face never measures narrower than the plain string.
  (should (>= (etaf-string-pixel-width (propertize "abc" 'face 'bold))
              (etaf-string-pixel-width "abc")))
  (should-error (etaf-string-pixel-width 5) :type 'wrong-type-argument))

(provide 'etaf-view-tests)

;;; etaf-view-tests.el ends here
