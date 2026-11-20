;;; etaf-events-tests.el --- Events, focus, input and Host queries -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Code:

(require 'etaf-test-support)

(etaf-action-define etaf-events-test-add (runtime count amount)
  "Add AMOUNT to COUNT inside RUNTIME."
  (ignore runtime)
  (etaf-update-value count #'+ amount))

(etaf-define-component etaf-events-test-toggle (&key on)
  "Render a toggle bound to ref ON."
  :bindings ((behavior (etaf-toggleable :value on
                                        :on-change (lambda (next) (etaf-set-value on next)))))
  :view (box :ref 'toggle :use (list behavior)
             (text (expr (if (etaf-value on) "[x]" "[ ]")))))

(etaf-define-component etaf-events-test-drag (&key x)
  "Render a draggable box moving ref X."
  :bindings ((behavior (etaf-draggable :x x :axis 'x)))
  :view (box :ref 'handle :use (list behavior) (text (expr (format "x=%s" (etaf-value x))))))

(ert-deftest etaf-events-press-runs-callback-in-one-batch ()
  "A press callback runs in a batch and publishes its writes once."
  (let ((count (etaf-ref 0)) seen)
    (etaf-test-with-mount (runtime (etaf-view (column
                                                (text (expr (format "count %d" (etaf-value count))))
                                                (box :ref 'add
                                                     :on-press (lambda (&optional payload)
                                                                 (setq seen payload)
                                                                 (etaf-update-value count #'1+)
                                                                 (etaf-update-value count #'1+))
                                                     "add"))))
      (let ((revision (etaf-runtime-revision runtime)))
        (etaf-dispatch-event runtime 'add 'press)
        (should (equal (etaf-test-lines) '("count 2" "add")))
        (should (= (etaf-runtime-revision runtime) (1+ revision)))
        (etaf-dispatch-event runtime 'add :on-press 'data t)
        (should (eq seen 'data))
        (should (equal (etaf-test-lines) '("count 4" "add")))))))

(defvar etaf-events-test-pressed nil
  "Item reported by `etaf-events-test-row'.")

(etaf-define-component etaf-events-test-row (&key item)
  "Render a row reporting ITEM when pressed."
  :render (etaf-node 'box (list :ref 'row
                                :on-press (lambda () (setq etaf-events-test-pressed item)))
                     (list "row")))

(ert-deftest etaf-events-press-uses-callback-over-equal-new-item ()
  "A new prop object replaces the committed callback even when `equal'."
  (let* ((item (etaf-ref (list :id 1 :name "Row")))
         (replacement (copy-sequence (etaf-value item)))
         (etaf-events-test-pressed nil))
    (etaf-test-with-mount (runtime (etaf-view (etaf-events-test-row :item (etaf-value item))))
      (etaf-set-value item replacement)
      (etaf-dispatch-event runtime 'row 'press)
      (should (eq etaf-events-test-pressed replacement)))))

(ert-deftest etaf-events-rejects-disabled-and-missing-handlers ()
  "Disabled Hosts and Hosts without a handler signal `etaf-event-error'."
  (let ((disabled (etaf-ref t)) (presses 0))
    (etaf-test-with-mount (runtime (etaf-view (column
                                                (box :ref 'button :disabled (etaf-value disabled)
                                                     :on-press (lambda () (cl-incf presses))
                                                     "button")
                                                (box :ref 'plain "plain"))))
      (should-error (etaf-dispatch-event runtime 'button 'press) :type 'etaf-event-error)
      (should-error (etaf-dispatch-event runtime 'plain 'press) :type 'etaf-event-error)
      (etaf-set-value disabled nil)
      (etaf-dispatch-event runtime 'button 'press)
      (should (= presses 1)))))

(ert-deftest etaf-events-press-capture-sees-target ()
  "Ancestor press-capture callbacks run after the target and see it."
  (let (log)
    (etaf-test-with-mount (runtime
                           (etaf-view (column :ref 'shell
                                              :on-press-capture
                                              (lambda ()
                                                (push (list 'capture
                                                            (etaf-event-target-within-p 'panel)
                                                            (etaf-event-target-within-p 'leaf))
                                                      log))
                                        (box :ref 'panel
                                             (box :ref 'leaf
                                                  :on-press (lambda () (push 'leaf log))
                                                  "leaf")))))
      (etaf-dispatch-event runtime 'leaf 'press)
      (should (equal (reverse log) '(leaf (capture t t))))
      (should (equal (gethash 'leaf (etaf-runtime-host-ancestries runtime '(leaf)))
                     '(leaf panel shell))))))

(ert-deftest etaf-events-pointer-p-separates-clicks-from-keys ()
  "A press reports a pointer source only for a mouse click."
  (let (log)
    (etaf-test-with-mount (runtime (etaf-view (box :ref 'surface
                                                   :on-press (lambda ()
                                                               (push (etaf-event-pointer-p) log))
                                                   "surface")))
      (let ((last-input-event ?\r))
        (etaf-dispatch-event runtime 'surface 'press))
      (let ((last-input-event (list 'mouse-1 (list (selected-window) 1 '(0 . 0) 0))))
        (etaf-dispatch-event runtime 'surface 'press))
      (should (equal (reverse log) '(nil t)))
      (should-error (etaf-event-pointer-p) :type 'etaf-event-error))))

(ert-deftest etaf-events-actions-dispatch-through-runtime ()
  "Named Actions receive the Runtime and run in an event batch."
  (let ((count (etaf-ref 1)))
    (etaf-test-with-mount (runtime (etaf-view (column
                                                (text (expr (format "n=%d" (etaf-value count))))
                                                (box :ref 'go
                                                     :on-press (lambda ()
                                                                 (etaf-dispatch 'etaf-events-test-add
                                                                                count 2))
                                                     "go"))))
      (etaf-dispatch-event runtime 'go 'press)
      (should (equal (car (etaf-test-lines)) "n=3"))
      (etaf-dispatch runtime 'etaf-events-test-add count 10)
      (should (equal (car (etaf-test-lines)) "n=13"))
      (should-error (etaf-dispatch runtime 'etaf-events-test-unknown) :type 'etaf-action-error))))

(ert-deftest etaf-events-focus-navigation ()
  "Focus moves among tab stops and reports committed Host references."
  (etaf-test-with-mount (runtime (etaf-view (column
                                              (box :ref 'one :tab-index 0 "one")
                                              (box :ref 'two :use (list (etaf-focusable)) "two")
                                              (box :ref 'group
                                                   (box :ref 'three :tab-index 0 "three")))))
    (etaf-focus runtime)
    (should (eq (etaf-focused-host-ref runtime) 'one))
    (etaf-focus-next runtime)
    (should (eq (etaf-focused-host-ref runtime) 'two))
    (etaf-focus-previous runtime)
    (should (eq (etaf-focused-host-ref runtime) 'one))
    (etaf-focus runtime 'three)
    (should (eq (etaf-focused-host-ref runtime) 'three))
    (should (= (point) (etaf-host-ref-position runtime 'three)))
    (etaf-focus runtime 'one)
    (etaf-focus-within runtime 'group)
    (should (eq (etaf-focused-host-ref runtime) 'three))
    (should-error (etaf-focus runtime 'missing) :type 'etaf-event-error)))

(ert-deftest etaf-events-activate-dispatches-press-at-point ()
  "Activation at point dispatches the enclosing Host's press callback."
  (let ((pressed nil))
    (etaf-test-with-mount (runtime (etaf-view (column
                                                (text "header")
                                                (box :ref 'button :on-press (lambda () (setq pressed t))
                                                     "button"))))
      (goto-char (etaf-host-ref-position runtime 'button))
      (etaf-activate runtime)
      (should pressed))))

(ert-deftest etaf-events-host-ref-at-maps-positions-to-rows ()
  "A position resolves to the explicit ref of its innermost enclosing Host."
  (etaf-test-with-mount (runtime (etaf-view (column
                                              (text "header")
                                              (row :ref 'row-1 (box :ref 'cell "one") (text " a"))
                                              (row :ref 'row-2 (text "two")))))
    (let ((cell (etaf-host-ref-position runtime 'cell))
          (two (etaf-host-ref-position runtime 'row-2)))
      (should (eq (etaf-host-ref-at runtime cell) 'cell))
      (should (eq (etaf-host-ref-at runtime cell
                                    (lambda (ref) (memq ref '(row-1 row-2))))
                  'row-1))
      (goto-char two)
      (should (eq (etaf-host-ref-at runtime) 'row-2))
      (should-not (etaf-host-ref-at runtime (point-min))))))

(ert-deftest etaf-events-scroll-api-anchors-and-reveals-hosts ()
  "Scroll queries, end anchoring and reveal operate on explicit Hosts."
  (let ((items (etaf-ref (number-sequence 1 4))))
    (etaf-test-with-mount (runtime
                           (etaf-view (column
                                        (text "head")
                                        (box :ref 'log :height '(lh 2) :overflow 'scroll
                                             :scroll-anchor 'end
                                             (column
                                              (text :for (n (etaf-value items)) :key n
                                                    :ref (intern (format "item-%d" n))
                                                    (expr (format "item %d" n)))))
                                        (text "foot"))))
      (should (equal (etaf-test-lines) '("head" "item 3" "item 4" "foot")))
      (should (= (etaf-scroll-offset runtime 'log) 2))
      (etaf-set-value items (number-sequence 1 5))
      (should (equal (etaf-test-lines) '("head" "item 4" "item 5" "foot")))
      (should (= (etaf-scroll-to runtime 'log 'start) 0))
      (should (= (etaf-scroll-by runtime 'log 1) 1))
      (etaf-set-value items (number-sequence 1 6))
      (should (equal (etaf-test-lines) '("head" "item 2" "item 3" "foot")))
      (should (eq (etaf-scroll-into-view runtime 'item-5) 'item-5))
      (should (equal (etaf-test-lines) '("head" "item 4" "item 5" "foot")))
      (should (= (etaf-scroll-to runtime 'log 'end) 4))
      (etaf-set-value items (number-sequence 1 7))
      (should (equal (etaf-test-lines) '("head" "item 6" "item 7" "foot")))
      (should-error (etaf-scroll-to runtime 'log 'middle) :type 'wrong-type-argument)
      (should-error (etaf-scroll-offset runtime 'missing)))))

(ert-deftest etaf-events-on-scroll-loads-older-rows-in-place ()
  "A history Host loads older rows at offset 0 and keeps its reading position."
  (let* ((items (etaf-ref (number-sequence 5 8)))
         (offsets nil)
         (load-older (lambda ()
                       (let ((first (car (etaf-value items))))
                         (when (> first 1)
                           (etaf-set-value items
                                           (append (number-sequence (- first 2) (1- first))
                                                   (etaf-value items)))
                           (let ((runtime (etaf-current-runtime)))
                             (etaf-next-tick
                              (lambda ()
                                (etaf-scroll-into-view
                                 runtime (intern (format "item-%d" first)) 'start)))))))))
    (etaf-test-with-mount (runtime
                           (etaf-view (column
                                        (box :ref 'log :height '(lh 2) :overflow 'scroll
                                             :scroll-anchor 'end
                                             :on-scroll (lambda (offset)
                                                          (push offset offsets)
                                                          (when (zerop offset)
                                                            (funcall load-older)))
                                             (column
                                              (text :for (n (etaf-value items)) :key n
                                                    :ref (intern (format "item-%d" n))
                                                    (expr (format "item %d" n))))))))
      (should (equal (etaf-test-lines) '("item 7" "item 8")))
      (should-not offsets)
      (etaf-scroll-by runtime 'log -1)
      (should (equal offsets '(1)))
      (etaf-scroll-to runtime 'log 'start)
      (should (equal (etaf-test-lines) '("item 5" "item 6")))
      (should (equal (etaf-value items) (number-sequence 3 8)))
      (should (= (etaf-scroll-offset runtime 'log) 2))
      (should (equal offsets '(2 0 1)))
      (etaf-scroll-into-view runtime 'item-7 'end)
      (should (equal (etaf-test-lines) '("item 6" "item 7")))
      (should-error (etaf-scroll-into-view runtime 'item-3 'middle)
                    :type 'wrong-type-argument))))

(ert-deftest etaf-events-swipe-reaches-the-nearest-handler-once ()
  "A horizontal trackpad gesture calls the nearest Host's :on-swipe once."
  (let ((swipes nil) (ebox-swipe-quiet 0.05) (mouse-wheel-flip-direction nil)
        (outer-calls 0))
    (etaf-test-with-mount (runtime
                           (etaf-view
                            (column :ref 'shell
                                    :on-swipe (lambda (dir)
                                                (cl-incf outer-calls)
                                                (push (list 'shell dir) swipes))
                                    (text :ref 'title "Chats")
                                    (box :ref 'pane
                                         :on-swipe (lambda (dir) (push (list 'pane dir) swipes))
                                         (text :ref 'body "hello")))))
      (switch-to-buffer (current-buffer))
      (cl-flet ((swipe (ref type dx)
                  (let* ((pos (car (etaf-host-ref-bounds runtime ref)))
                         (event (list type (list (selected-window) pos '(0 . 0) 0)
                                      1 1 (cons (float dx) 0.0))))
                    (funcall (key-binding (vector type)) event)))
                (pause () (sleep-for 0.1)))
        (pause)
        (swipe 'title 'wheel-left 80)
        (swipe 'title 'wheel-left 300)
        (should (equal swipes '((shell right))))
        (pause)
        (swipe 'body 'wheel-right 80)
        (should (equal swipes '((pane left) (shell right))))
        (should (= outer-calls 1))
        (should-not (get-text-property (car (etaf-host-ref-bounds runtime 'title))
                                       'pointer))))))

(ert-deftest etaf-events-behaviors-toggle-and-drag ()
  "Toggleable and draggable Behaviors update caller-owned refs."
  (let ((on (etaf-ref nil)) (x (etaf-ref 10)))
    (etaf-test-with-mount (runtime (etaf-view (column (etaf-events-test-toggle :on on)
                                                      (etaf-events-test-drag :x x))))
      (should (equal (etaf-test-lines) '("[ ]" "x=10")))
      (etaf-dispatch-event runtime 'toggle 'press)
      (should (equal (etaf-test-lines) '("[x]" "x=10")))
      (etaf-dispatch-event runtime 'handle 'drag '(:phase start :delta (0 . 0)) t)
      (etaf-dispatch-event runtime 'handle 'drag '(:phase move :delta (5 . 0)) t)
      (etaf-dispatch-event runtime 'handle 'drag '(:phase end :delta (7 . 0)) t)
      (should (= (etaf-value x) 17))
      (should (equal (etaf-test-lines) '("[x]" "x=17"))))))

(ert-deftest etaf-events-native-input-session ()
  "An input session edits a Host's value while state echoes it back."
  (let ((value (etaf-ref "value")) (seen nil))
    (etaf-test-with-mount (runtime (etaf-view (column (text :ref 'field (expr (etaf-value value)))
                                                      (text (expr (format "len=%d" (length (etaf-value value))))))))
      (let ((session (etaf-input-begin runtime 'field
                                       :on-change (lambda (text)
                                                    (push text seen)
                                                    (etaf-set-value value text)))))
        (should (eq (etaf-input-active-p runtime) session))
        (switch-to-buffer (etaf-runtime-buffer runtime))
        (execute-kbd-macro (kbd "s"))
        (should (equal (etaf-input-text session) "values"))
        (should (equal seen '("values")))
        (should (equal (etaf-test-lines) '("values" "len=6")))
        (etaf-set-value value "reset")
        (should (equal (etaf-input-text session) "reset"))
        (should (equal (etaf-input-end session) "reset"))
        (should-not (etaf-input-active-p runtime))
        (should (equal (etaf-test-lines) '("reset" "len=5")))))))

(ert-deftest etaf-events-host-queries ()
  "Host queries report committed props, handlers, bounds and size."
  (let ((label (etaf-ref "abc")))
    (etaf-test-with-mount (runtime (etaf-view (column
                                                (box :ref 'target :class "c" :tab-index 0
                                                     :on-press #'ignore
                                                     (text (expr (etaf-value label)))))))
      (should (equal (plist-get (etaf-runtime-host-props-for runtime 'target) :class) "c"))
      (should (assq 'target (etaf-runtime-host-props-entries runtime)))
      (should (assq 'target (etaf-runtime-handler-entries runtime)))
      (let ((bounds (etaf-host-ref-bounds runtime 'target))
            (size (etaf-host-ref-size runtime 'target)))
        (should (consp bounds))
        (should (< (car bounds) (cdr bounds)))
        (should (= (cdr size) 1))
        (should (> (car size) 0)))
      (should-not (etaf-host-ref-bounds runtime 'missing)))))

(ert-deftest etaf-events-sticky-host-mirrors-header-line ()
  "A `:sticky top' Host owns the header line and forwards header clicks."
  (let ((sticky (etaf-ref 'top)) (presses 0))
    (etaf-test-with-mount (runtime (etaf-view
                                    (column
                                     (row :sticky (etaf-value sticky)
                                          (box :on-press (lambda () (cl-incf presses))
                                               "Back")
                                          " Title")
                                     "Body")))
      (ignore runtime)
      ;; Batch Emacs formats no mode lines; read the construct's value.
      (should (symbolp header-line-format))
      (let* ((header (symbol-value header-line-format))
             (map (get-text-property 0 'keymap header)))
        (should (equal (string-trim header) "Back Title"))
        (funcall (lookup-key map [header-line mouse-1]))
        (should (= presses 1)))
      (etaf-set-value sticky nil)
      (should-not (local-variable-p 'header-line-format))
      (should-error (etaf-render (etaf-view (box :sticky 'bottom "x")))
                    :type 'etaf-renderer-error))))

(ert-deftest etaf-events-retained-host-updates ()
  "Retained content and geometry updates change one Host and bump the revision."
  (etaf-test-with-mount (runtime (etaf-view (column (text :ref 'frame "frame 0")
                                                    (box :ref 'panel :width '(px 100) "panel"))))
    (let ((revision (etaf-runtime-revision runtime)))
      (should (eq t (etaf-runtime-update-host-content runtime 'frame "frame 1")))
      (should (equal (etaf-test-lines) '("frame 1" "panel")))
      (should (> (etaf-runtime-revision runtime) revision))
      (should (eq t (etaf-runtime-update-host-contents runtime '((frame . "frame 2")))))
      (should (equal (etaf-test-lines) '("frame 2" "panel")))
      (should (eq t (etaf-runtime-update-host-geometry runtime 'panel :width '(px 200))))
      (should (= (car (etaf-host-ref-size runtime 'panel)) 200))
      (should-error (etaf-runtime-update-host-content runtime 'missing "x")
                    :type 'etaf-runtime-error))))

(ert-deftest etaf-events-invalid-host-content-preserves-the-whole-batch ()
  "Invalid content signals the public error, with no text or revision changes."
  (etaf-test-with-mount
      (runtime (etaf-view (column (text :ref 'first "first")
                                 (text :ref 'second "second"))))
    (let ((revision (etaf-runtime-revision runtime)))
      (let ((failure
             (condition-case problem
                 (progn
                   (etaf-runtime-update-host-contents
                    runtime '((first . "must not publish") (second . 42)))
                   nil)
               (error (car problem)))))
        (should (eq failure 'etaf-runtime-error)))
      (should (equal (etaf-test-lines) '("first" "second")))
      (should (= (etaf-runtime-revision runtime) revision))
      (let ((updated (etaf-runtime-update-host-content runtime 'first "retry")))
        (should updated))
      (should (equal (etaf-test-lines) '("retry" "second"))))))

(ert-deftest etaf-events-performance-records-operations ()
  "The performance recorder captures observed event operations."
  (etaf-test-with-mount (runtime (etaf-view (box :ref 'b :on-press #'ignore "b")))
    (etaf-performance-clear)
    (etaf-performance-start runtime)
    (unwind-protect
        (etaf-dispatch-event runtime 'b 'press)
      (etaf-performance-stop runtime))
    (let ((records (etaf-performance-records)))
      (should records)
      (should (eq (etaf-performance-operation-kind (car records)) 'event))
      (should (eq (etaf-performance-operation-status (car records)) 'success))
      (let ((runtime-id (etaf-performance-operation-runtime-id (car records))))
        (should (integerp runtime-id))
        (should (= 1 (length (etaf-performance-records runtime-id))))))))

(ert-deftest etaf-input-edit-commands-add-and-remove ()
  "The session text-editing commands change only through the public API."
  (let ((command 'forward-char))
    (unwind-protect
        (progn
          (should (memq command (etaf-input-edit-command-add command)))
          (should (memq command (etaf-input-edit-command-add command)))
          (should-not (memq command (etaf-input-edit-command-remove command)))
          (should-not (memq command (etaf-input-edit-command-remove command)))
          (should-error (etaf-input-edit-command-add "forward-char")
                        :type 'wrong-type-argument)
          (should-error (etaf-input-edit-command-remove 7)
                        :type 'wrong-type-argument))
      (etaf-input-edit-command-remove command))))

(provide 'etaf-events-tests)

;;; etaf-events-tests.el ends here
