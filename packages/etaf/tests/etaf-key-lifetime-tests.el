;;; -*- lexical-binding: t; -*-
;;; etaf-key-lifetime-tests.el --- Ownership of retained native commands
;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Code:
(require 'etaf-test-support)

(defun etaf-key-lifetime-test--commands (weak)
  "Return live-tested commands after disposing their mount observed by WEAK."
  (let ((resource (vector 0)))
    (puthash resource t weak)
    (etaf-test-with-mount
        (runtime
         (etaf-view
          (column :ref 'owner
            :keys (list (list "x" (lambda () (cl-incf (aref resource 0))) "Increment"))
            :on-dismiss (lambda () (cl-incf (aref resource 0) 10))
            (box :ref 'first :tab-index 0 "first")
            (box :ref 'second :tab-index 0 "second"))))
      (puthash runtime t weak)
      (etaf-focus runtime 'first)
      (let ((commands (mapcar (lambda (key) (key-binding (kbd key) t))
                              '("x" "TAB" "<down>" "<escape>"))))
        (garbage-collect)
        (call-interactively (nth 0 commands))
        (let ((value (aref resource 0))) (should (= value 1)))
        (call-interactively (nth 1 commands))
        (should (eq (etaf-focused-host-ref runtime) 'second))
        (etaf-focus runtime 'first)
        (call-interactively (nth 2 commands))
        (should (eq (etaf-focused-host-ref runtime) 'second))
        (call-interactively (nth 3 commands))
        (let ((value (aref resource 0))) (should (= value 11)))
        commands))))

(ert-deftest etaf-native-key-commands-do-not-retain-disposed-owners ()
  "Commands may stay in Emacs history without keeping a disposed app alive."
  (let* ((weak (make-hash-table :test 'eq :weakness 'key))
         (commands (etaf-key-lifetime-test--commands weak)))
    (garbage-collect) (garbage-collect)
    (let ((retained (hash-table-count weak))) (should (= retained 0)))
    (dolist (command commands)
      (should (commandp command))
      (should-error (call-interactively command) :type 'user-error))))

(provide 'etaf-key-lifetime-tests)
;;; etaf-key-lifetime-tests.el ends here
