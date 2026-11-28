;;; etaf-regions-tests.el --- Region selection, entries and adjacency -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Acceptance scenarios for `etaf-region-select' and `etaf-region-focus'.
;; Keys go through the command loop after the Runtime buffer is selected,
;; because key dispatch resolves Host bindings in the selected window's
;; buffer.

;;; Code:

(require 'etaf-test-support)

(defun etaf-regions-test-select (runtime keys)
  "Type KEYS through the command loop in RUNTIME's buffer."
  (with-current-buffer (etaf-runtime-buffer runtime)
    (switch-to-buffer (current-buffer))
    (execute-kbd-macro (kbd keys))))

(ert-deftest etaf-regions-select-focuses-hint-key-and-remembers-entry ()
  "`M-g' plus a hint key focuses a region and later restores its entry."
  (etaf-test-with-mount (runtime (etaf-view
                                  (row
                                   (column :region '(:id sidebar :label "Sidebar" :key "s")
                                           (box :ref 'side-a :tab-index 0 "A")
                                           (box :ref 'side-b :tab-index 0 "B"))
                                   (column :region '(:id main :label "Main" :key "m")
                                           (box :ref 'main-a :tab-index 0 "M")))))
    (should (eq (key-binding (kbd "M-g") t) 'etaf-region-select))
    (etaf-focus runtime 'main-a)
    (etaf-regions-test-select runtime "M-g s")
    (should (eq (etaf-focused-host-ref runtime) 'side-a))
    (etaf-focus runtime 'side-b)
    (etaf-focus runtime 'main-a)
    (etaf-regions-test-select runtime "M-g s")
    (should (eq (etaf-focused-host-ref runtime) 'side-b))
    (should (eq (etaf-region-focus 'sidebar runtime) 'side-b))))

(ert-deftest etaf-regions-arrows-cross-siblings-and-climb-parent-exits ()
  "Arrow selection crosses regions and leaves nested regions upward."
  (etaf-test-with-mount (runtime (etaf-view
                                  (column
                                   (row
                                    (column :region '(:id sidebar :key "s")
                                            (box :ref 'side :tab-index 0 "S"))
                                    (column :region '(:id main :key "m")
                                            (column :region '(:id list :key "l")
                                                    (box :ref 'item :tab-index 0 "I"))
                                            (box :ref 'editor :tab-index 0 "E")))
                                   (column :region '(:id composer :key "c")
                                           (box :ref 'input :tab-index 0 ">")))))
    (etaf-focus runtime 'item)
    (etaf-regions-test-select runtime "M-g <left>")
    (should (eq (etaf-focused-host-ref runtime) 'side))
    (etaf-regions-test-select runtime "M-g <right>")
    (should (eq (etaf-focused-host-ref runtime) 'item))
    (etaf-focus runtime 'editor)
    (etaf-regions-test-select runtime "M-g <down>")
    (should (eq (etaf-focused-host-ref runtime) 'input))
    (etaf-regions-test-select runtime "M-g <up>")
    (should (eq (etaf-focused-host-ref runtime) 'editor))))

(ert-deftest etaf-regions-declared-neighbor-overrides-geometry ()
  "A `:neighbors' declaration picks its target even against geometry."
  (etaf-test-with-mount (runtime (etaf-view
                                  (column
                                   (column :region '(:id second :key "s")
                                           (box :ref 'b :tab-index 0 "B"))
                                   (column :region '(:id first :key "f"
                                                           :neighbors (:right second))
                                           (box :ref 'a :tab-index 0 "A")))))
    (etaf-focus runtime 'a)
    ;; `second' sits to the left, so only the declaration reaches it.
    (etaf-regions-test-select runtime "M-g <right>")
    (should (eq (etaf-focused-host-ref runtime) 'b))))

(ert-deftest etaf-regions-unknown-keys-keep-state-and-c-g-quits ()
  "Unknown keys change nothing; Escape cancels and C-g quits natively."
  (etaf-test-with-mount (runtime (etaf-view
                                  (row
                                   (column :region '(:id sidebar :key "s")
                                           (box :ref 'side :tab-index 0 "S"))
                                   (column :region '(:id main :key "m")
                                           (box :ref 'main :tab-index 0 "M")))))
    (etaf-focus runtime 'side)
    (etaf-regions-test-select runtime "M-g z <escape>")
    (should (eq (etaf-focused-host-ref runtime) 'side))
    (etaf-regions-test-select runtime "M-g z m")
    (should (eq (etaf-focused-host-ref runtime) 'main))
    (should (eq 'quit
                (condition-case nil
                    (progn (etaf-regions-test-select runtime "M-g C-g") nil)
                  (quit 'quit))))))

(ert-deftest etaf-regions-modal-scope-confines-the-selector ()
  "An open modal scope reaches only its own regions."
  (etaf-test-with-mount (runtime (etaf-view
                                  (row
                                   (column :region '(:id outside :key "o")
                                           (box :ref 'out :tab-index 0 "O"))
                                   (column :focus-scope 'modal
                                           :region '(:id dialog :key "d")
                                           (box :ref 'in-a :tab-index 0 "A")
                                           (box :ref 'in-b :tab-index 0 "B")))))
    (etaf-focus runtime 'in-b)
    (etaf-regions-test-select runtime "M-g o <escape>")
    (should (eq (etaf-focused-host-ref runtime) 'in-b))
    (etaf-regions-test-select runtime "M-g d")
    (should (eq (etaf-focused-host-ref runtime) 'in-b))))

(ert-deftest etaf-regions-disabled-entry-falls-back-to-declared-and-first-stop ()
  "A disabled remembered entry falls back to `:enter', then the first stop."
  (let ((disabled (etaf-ref nil)))
    (etaf-test-with-mount (runtime (etaf-view
                                    (row
                                     (column :region '(:id side :key "s" :enter first)
                                             (box :ref 'first :tab-index 0 "1")
                                             (box :ref 'second :tab-index 0
                                                  :disabled (etaf-value disabled) "2"))
                                     (box :ref 'other :tab-index 0 "O"))))
      (etaf-focus runtime 'second)
      (etaf-set-value disabled t)
      (etaf-runtime-flush runtime)
      (etaf-focus runtime 'other)
      (should (eq (etaf-region-focus 'side runtime) 'first))))
  (let ((disabled (etaf-ref nil)))
    (etaf-test-with-mount (runtime (etaf-view
                                    (row
                                     (column :region '(:id plain :key "p")
                                             (box :ref 'first :tab-index 0 "1")
                                             (box :ref 'second :tab-index 0
                                                  :disabled (etaf-value disabled) "2"))
                                     (box :ref 'other :tab-index 0 "O"))))
      (etaf-focus runtime 'second)
      (etaf-set-value disabled t)
      (etaf-runtime-flush runtime)
      (etaf-focus runtime 'other)
      (should (eq (etaf-region-focus 'plain runtime) 'first)))))

(ert-deftest etaf-regions-reject-invalid-declarations-and-duplicates ()
  "Malformed `:region' plists and ambiguous ids or keys are errors."
  (dolist (region (list '(:label "x")
                        '(:id x :key "ab")
                        '(:id x :bogus 1)
                        '(:id x :key "?")
                        '(:id x :neighbors (:diagonal y))))
    (should-error (etaf-test-with-mount
                       (_runtime (etaf-node 'box (list :region region) (list "x"))))
                  :type 'etaf-renderer-error))
  (etaf-test-with-mount (runtime (etaf-view
                                  (row (box :region '(:id a :key "x") :tab-index 0 "A")
                                       (box :region '(:id b :key "x") :tab-index 0 "B"))))
    (should-error (etaf-region-select runtime) :type 'etaf-renderer-error))
  (etaf-test-with-mount (runtime (etaf-view
                                  (row (box :region '(:id a) :tab-index 0 "A")
                                       (box :region '(:id a) :tab-index 0 "B"))))
    (should-error (etaf-region-select runtime) :type 'etaf-renderer-error))
  (etaf-test-with-mount (runtime (etaf-view (column :region '(:id empty)
                                                    (box :ref 'plain "P"))))
    (should-error (etaf-region-focus 'missing runtime) :type 'etaf-event-error)
    (should-error (etaf-region-focus 'empty runtime) :type 'etaf-event-error)))

;;; etaf-regions-tests.el ends here
