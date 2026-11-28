;;; etaf-key-scope-tests.el --- Local keyboard boundaries -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Exercise non-modal keyboard ownership through mounted public interfaces.

;;; Code:

(require 'etaf-test-support)

(defun etaf-key-scope-test-press (key)
  "Run KEY through its effective binding without retaining the command."
  (let ((command (key-binding (kbd key) t)))
    (unless (commandp command) (error "No command for %s" key))
    (call-interactively command))
  nil)

(ert-deftest etaf-key-scope-isolates-siblings-and-unbound-letters ()
  "Local Hosts own letters without stealing focus from sibling Hosts."
  (let (log)
    (etaf-test-with-mount (runtime
                          (etaf-view
                           (column :keys (list (list "a" (lambda () (push 'outer log)))
                                               (list "q" (lambda () (push 'quit log))))
                                   (box :ref 'outside :tab-index 0 "Outside")
                                   (column :key-scope 'local
                                           :keys (list (list "a" (lambda () (push 'one log))))
                                           (box :ref 'one :tab-index 0 "One"))
                                   (column :key-scope 'local
                                           :keys (list (list "a" (lambda () (push 'two log))))
                                           (box :ref 'two :tab-index 0 "Two")))))
      (etaf-focus runtime 'one)
      (etaf-key-scope-test-press "a")
      (etaf-key-scope-test-press "q")
      ;; Moving raw point never transfers ownership out of a focused app.
      (goto-char (etaf-host-ref-position runtime 'outside))
      (etaf-key-scope-test-press "q")
      (should (eq (key-binding "n" t) 'ignore))
      (etaf-focus runtime 'two)
      (etaf-key-scope-test-press "a")
      (etaf-key-scope-test-press "q")
      (etaf-focus runtime 'outside)
      (etaf-key-scope-test-press "a")
      (etaf-key-scope-test-press "q")
      (should (equal (reverse log) '(one two outer quit))))))

(ert-deftest etaf-key-scope-confines-tab-directions-and-region-exits ()
  "Tab, arrows and declared neighbors cannot escape a local boundary."
  (let (outer-directions)
    (etaf-test-with-mount (runtime
                          (etaf-view
                           (column :on-direction (lambda (direction)
                                                   (push direction outer-directions)
                                                   'hold)
                                   (box :ref 'before :tab-index 0 "Before")
                                   (column :key-scope 'local
                                           :region '(:id app :label "App")
                                           (column :region '(:id first :key ?f :neighbors (:down second))
                                                   (box :ref 'first :tab-index 0 "First"))
                                           (column :region '(:id second :key ?s :neighbors (:down outside))
                                                   (box :ref 'second :tab-index 0 "Second")))
                                   (column :region '(:id outside :key ?o)
                                           (box :ref 'after :tab-index 0 "After")))))
      (etaf-focus runtime 'first)
      (etaf-key-scope-test-press "<down>")
      (should (eq (etaf-focused-host-ref runtime) 'second))
      (etaf-key-scope-test-press "<down>")
      (should (eq (etaf-focused-host-ref runtime) 'second))
      (etaf-key-scope-test-press "TAB")
      (should (eq (etaf-focused-host-ref runtime) 'first))
      (etaf-key-scope-test-press "<backtab>")
      (should (eq (etaf-focused-host-ref runtime) 'second))
      (should-not outer-directions)
      (dolist (key '("<home>" "M-<"))
        (etaf-key-scope-test-press key)
        (should (eq (etaf-focused-host-ref runtime) 'first))
        (etaf-key-scope-test-press "C-n")
        (should (eq (etaf-focused-host-ref runtime) 'second)))
      (dolist (key '("<end>" "M->"))
        (etaf-focus runtime 'first)
        (etaf-key-scope-test-press key)
        (should (eq (etaf-focused-host-ref runtime) 'second)))
      (etaf-key-scope-test-press "C-n")
      (should (eq (etaf-focused-host-ref runtime) 'second))
      (save-window-excursion
        (switch-to-buffer (current-buffer))
        (execute-kbd-macro (kbd "M-g o <escape>")))
      (should (eq (etaf-focused-host-ref runtime) 'second))
      (etaf-focus runtime 'before)
      (etaf-key-scope-test-press "<down>")
      (should (equal outer-directions '(down))))))

(ert-deftest etaf-key-scope-confines-spatial-navigation-without-regions ()
  "A local subtree needs no region declaration to contain focus movement."
  (etaf-test-with-mount (runtime
                        (etaf-view
                         (column (column :key-scope 'local
                                         (box :ref 'inside :tab-index 0 "Inside"))
                                 (box :ref 'outside :tab-index 0 "Outside"))))
    (etaf-focus runtime 'inside)
    (etaf-key-scope-test-press "<down>")
    (should (eq (etaf-focused-host-ref runtime) 'inside))
    ;; Explicit navigation is allowed: this is not a modal focus trap.
    (etaf-focus runtime 'outside)
    (should (eq (etaf-focused-host-ref runtime) 'outside))))

(ert-deftest etaf-key-scope-help-and-palette-expose-only-local-controls ()
  "Help and execution use the same boundary as keyboard dispatch."
  (let (offered)
    (etaf-test-with-mount (runtime
                          (etaf-view
                           (column :aria-label "Outer"
                                   :help "Outer notes"
                                   :keys (list (list "q" #'ignore "Outer quit"))
                                   (box :ref 'outside :tab-index 0 "Outside control")
                                   (column :key-scope 'local :aria-label "Inner"
                                           :help "Inner notes"
                                           :keys (list (list "a" #'ignore "Inner action"))
                                           (box :ref 'inside :tab-index 0 "Inside control")))))
      (etaf-focus runtime 'inside)
      (let ((data (etaf-help-data runtime)))
        (should (equal (plist-get data :title) "Inner"))
        (should (equal (plist-get data :notes) '("Inner notes")))
        (should (equal (plist-get data :controls) '("Inside control")))
        (should-not (string-match-p "Outer quit" (prin1-to-string data))))
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (_prompt collection &rest _)
                   (setq offered (all-completions "" collection))
                   "Inside control")))
        (etaf-palette runtime))
      (should (equal offered '("Inner action" "Inside control")))
      (etaf-help runtime)
      (etaf-key-scope-test-press "<escape>")
      (should (eq (etaf-focused-host-ref runtime) 'inside)))))

(ert-deftest etaf-key-scope-dismisses-one-layer-and-restores-region-entry ()
  "Inner selection, modal, local return and remembered entry stay distinct."
  (let ((selection (etaf-ref t)) (dialog (etaf-ref nil)) log)
    (etaf-test-with-mount (runtime
                          (etaf-view
                           (column :on-dismiss (lambda () (push 'outer log))
                                   (box :ref 'outside :tab-index 0 "Outside")
                                   (column :key-scope 'local :region '(:id app)
                                           :on-dismiss (lambda ()
                                                         (push 'return log)
                                                         (etaf-focus runtime 'outside))
                                           (box :ref 'first :tab-index 0 "First")
                                           (box :ref 'second :tab-index 0
                                                :on-dismiss (and (etaf-value selection)
                                                                 (lambda ()
                                                                   (push 'selection log)
                                                                   (etaf-set-value selection nil)))
                                                "Second")
                                           (column :if (etaf-value dialog)
                                                   :focus-scope 'modal
                                                   :on-dismiss (lambda ()
                                                                 (push 'dialog log)
                                                                 (etaf-set-value dialog nil))
                                                   (box :ref 'dialog :tab-index 0 "Dialog"))))))
      (etaf-focus runtime 'second)
      (etaf-key-scope-test-press "<escape>")
      (should (equal log '(selection)))
      (should (eq (etaf-focused-host-ref runtime) 'second))
      (etaf-key-scope-test-press "<escape>")
      (should (equal log '(return selection)))
      (should (eq (etaf-focused-host-ref runtime) 'outside))
      (let ((entry (etaf-region-focus 'app runtime)))
        (should (eq entry 'second)))
      (etaf-set-value dialog t)
      (etaf-focus runtime 'dialog)
      (etaf-key-scope-test-press "<escape>")
      (should (equal log '(dialog return selection)))
      (etaf-focus runtime 'second)
      (etaf-key-scope-test-press "<escape>")
      (should (equal log '(return dialog return selection))))))

(ert-deftest etaf-key-scope-reactive-boundaries-and-lifetime ()
  "Changing or removing a boundary updates ownership with no mode flag."
  (let ((scope (etaf-ref 'local)) (present (etaf-ref t)) log)
    (etaf-test-with-mount (runtime
                          (etaf-view
                           (column :keys (list (list "q" (lambda () (push 'outer log))))
                                   (box :ref 'outside :tab-index 0 "Outside")
                                   (column :if (etaf-value present)
                                           :key-scope (etaf-value scope)
                                           (box :ref 'inside :tab-index 0 "Inside")))))
      (etaf-focus runtime 'inside)
      (etaf-key-scope-test-press "q")
      (should-not log)
      (etaf-set-value scope nil)
      (etaf-key-scope-test-press "q")
      (should (equal log '(outer)))
      (etaf-set-value scope 'local)
      (etaf-key-scope-test-press "q")
      (should (equal log '(outer)))
      (etaf-set-value present nil)
      (etaf-focus runtime 'outside)
      (etaf-key-scope-test-press "q")
      (should (equal log '(outer outer)))
      (etaf-unmount runtime)
      (should-not (eq (key-binding "q" t) 'ignore)))))

(ert-deftest etaf-key-scope-native-editing-keeps-draft-before-dismissal ()
  "Editing owns the first Escape and the next one dismisses the local layer."
  (let ((draft (etaf-ref "seed")) session dismissed)
    (etaf-test-with-mount (runtime
                          (etaf-view
                           (column :key-scope 'local
                                   :on-dismiss (lambda () (setq dismissed t))
                                   (text :ref 'field :tab-index 0 (expr (etaf-value draft))))))
      (save-window-excursion
        (switch-to-buffer (current-buffer))
        (etaf-focus runtime 'field)
        (let ((map (make-sparse-keymap)))
          (define-key map [escape]
                      (lambda ()
                        (interactive)
                        (etaf-input-end session)
                        (etaf-focus runtime 'field)))
          (setq session (etaf-input-begin runtime 'field
                                          :keymap map
                                          :on-change (lambda (value)
                                                       (etaf-set-value draft value)))))
        (execute-kbd-macro (kbd "C-a C-k draft <escape>"))
        (should-not (etaf-input-active-p runtime))
        (should (equal (etaf-value draft) "draft"))
        (should-not dismissed)
        (execute-kbd-macro (kbd "<escape>"))
        (should dismissed)))))

(ert-deftest etaf-key-scope-nearest-boundary-stops-unhandled-dismissal ()
  "An inner local boundary cannot invoke an enclosing dismiss or help hook."
  (let (outer-help outer-dismiss)
    (etaf-test-with-mount (runtime
                          (etaf-view
                           (column :key-scope 'local
                                   :on-help-open (lambda () (setq outer-help t))
                                   :on-dismiss (lambda () (setq outer-dismiss t))
                                   (column :key-scope 'local
                                           (box :ref 'inside :tab-index 0 "Inside")))))
      (etaf-focus runtime 'inside)
      (etaf-key-scope-test-press "<escape>")
      (should-not outer-dismiss)
      (etaf-help runtime)
      (should-not outer-help)
      (etaf-help-close runtime)
      (should (eq (etaf-focused-host-ref runtime) 'inside)))))

(ert-deftest etaf-key-scope-rejects-unsupported-values ()
  "Only nil and local are valid non-modal keyboard boundary values."
  (dolist (value '(t modal global))
    (should-error
     (etaf-test-with-mount (runtime (etaf-node 'box (list :key-scope value) '("X")))
       (ignore runtime))
     :type 'etaf-renderer-error)))

;;; etaf-key-scope-tests.el ends here
