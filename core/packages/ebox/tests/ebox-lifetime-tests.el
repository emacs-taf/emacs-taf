;;; -*- lexical-binding: t; -*-
;;; ebox-lifetime-tests.el --- Rendered callback ownership through public APIs
;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Code:
(require 'ert)
(require 'ebox)

(defun ebox-lifetime-test--render (weak &optional mounted)
  "Render a callback-owned resource observed by WEAK.
Return detached text, or dispose a MOUNTED buffer and return nil."
  (let* ((resource (vector (copy-sequence "owned")))
         (node (ebox-text-create "content"
                 (list :help-echo (lambda (&rest _arguments) (aref resource 0))))))
    (puthash resource t weak)
    (if (not mounted)
        (ebox-render node)
      (let ((buffer (generate-new-buffer " *ebox-lifetime*")))
        (unwind-protect
            (progn
              (ebox-render-to-buffer buffer node :width 200 :height 4)
              (ebox-unmount-buffer buffer))
          (kill-buffer buffer)))
      nil)))

(defun ebox-lifetime-test--use-output (weak)
  "Exercise live output, then return without a reference to its callbacks."
  (let ((text (ebox-lifetime-test--render weak)))
    (garbage-collect)
    (let ((help (funcall (get-text-property 0 'help-echo text) nil nil 0))
          (retained (hash-table-count weak)))
      (should (equal help "owned"))
      (should (= retained 1))))
  nil)

(ert-deftest ebox-detached-output-owns-callbacks-only-while-retained ()
  "Rendered help stays usable, but discarded output cannot leak its callback."
  (let ((weak (make-hash-table :test 'eq :weakness 'key)))
    ;; Leave the frame that consumed the rendered value before testing GC.
    (ebox-lifetime-test--use-output weak)
    (garbage-collect) (garbage-collect)
    (let ((retained (hash-table-count weak))) (should (= retained 0)))))

(ert-deftest ebox-disposed-buffer-releases-rendered-callbacks ()
  "Unmounting and killing an owned buffer leaves no engine-held callbacks."
  (let ((weak (make-hash-table :test 'eq :weakness 'key)))
    (dotimes (_ 3) (ebox-lifetime-test--render weak t))
    (garbage-collect) (garbage-collect)
    (let ((retained (hash-table-count weak))) (should (= retained 0)))))

(defun ebox-lifetime-test--retire-help (weak)
  "Return a live hidden node after replacing its callback-owned resource."
  (let* ((resource (vector (copy-sequence "retired")))
         (node (ebox-node-create 'box
                 (list :help-echo (lambda (&rest _arguments) (aref resource 0)))
                 '("content"))))
    (puthash resource t weak)
    (ebox-render node)
    (ebox-node-set-props node '(:visibility hidden))
    (ebox-render node)
    node))

(ert-deftest ebox-hidden-node-releases-replaced-callbacks ()
  "A still-owned hidden node cannot retain a callback removed from its props."
  (let* ((weak (make-hash-table :test 'eq :weakness 'key))
         (node (ebox-lifetime-test--retire-help weak)))
    (garbage-collect) (garbage-collect)
    (let* ((rendered (ebox-render node))
           (help (get-text-property 0 'help-echo rendered))
           (retained (hash-table-count weak)))
      (should-not help)
      (should (= retained 0)))))

(provide 'ebox-lifetime-tests)
;;; ebox-lifetime-tests.el ends here
