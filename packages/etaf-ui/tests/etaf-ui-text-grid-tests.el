;;; -*- lexical-binding: t; -*-
;;; etaf-ui-text-grid-tests.el --- Fixed-width text surface acceptance

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Code:
(require 'ert)
(require 'etaf-ui)

(defun etaf-ui-text-grid-test--lines (buffer)
  "Return the text lines BUFFER shows."
  (with-current-buffer buffer
    (split-string (buffer-substring-no-properties (point-min) (point-max)) "\n")))

(defun etaf-ui-text-grid-test--rows (first prefix)
  "Return four seven-column rows from FIRST, each named with PREFIX."
  (mapcar (lambda (row) (format "%s%-6d" prefix row))
          (number-sequence first (+ first 3))))

(ert-deftest etaf-ui-text-grid-updates-rows-with-stable-extents ()
  "Rows retain width, neighbors and text when the caller changes one value."
  (let ((buffer (generate-new-buffer " *text-grid*"))
        (rows (vector (etaf-ref "@...") (etaf-ref "中"))))
    (unwind-protect
        (progn
          (etaf-mount buffer
                      (etaf-view
                       (etaf-text-grid
                        :rows 2 :columns 4 :label "Map"
                        :row-ref (lambda (row) (if (zerop row) 'first 'second))
                        :row-text (lambda (row) (etaf-value (aref rows row))))))
          (let* ((runtime (etaf-runtime-for-buffer buffer))
                 (neighbor (etaf-host-ref-bounds runtime 'second)))
            (should-not (etaf-runtime-handler-entries runtime))
            (setf (etaf-value (aref rows 0)) ".@..")
            (should (equal neighbor (etaf-host-ref-bounds runtime 'second)))
            (dolist (pair '((first . ".@..") (second . "中  ")))
              (let ((bounds (etaf-host-ref-bounds runtime (car pair))))
                (should (equal (with-current-buffer buffer
                                 (buffer-substring-no-properties (car bounds) (cdr bounds)))
                               (cdr pair)))))))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer))) (etaf-unmount runtime))
      (kill-buffer buffer))))

(ert-deftest etaf-ui-text-grid-rejects-invalid-shapes-and-text ()
  "Invalid shapes and text fail before publication."
  (let ((buffer (generate-new-buffer " *text-grid-invalid*")))
    (unwind-protect
        (progn
          (dolist (props '((:rows 0 :columns 2) (:rows 1 :columns 0)
                          (:rows 1 :columns 2 :row-text 42)
                          (:rows 1 :columns 2 :row-text identity :height 0)
                          (:rows 1 :columns 2 :row-text identity :height 1.5)
                          (:rows 1 :columns 2 :row-text identity :height 1
                           :on-scroll 42)))
            (should-error (etaf-mount buffer (etaf-node 'etaf-text-grid props nil))
                          :type 'etaf-component-call-error))
          (dolist (content '("wide" "a\nb" "a\rb" "a\tb" 42))
            (should-error
             (etaf-mount buffer
                         (etaf-view
                          (etaf-text-grid :rows 1 :columns 2
                                          :row-text (lambda (_row) content))))
             :type 'etaf-component-call-error)))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer))) (etaf-unmount runtime))
      (kill-buffer buffer))))

(ert-deftest etaf-ui-text-grid-scrolls-a-million-rows-through-its-viewport ()
  "A scrolling grid shows its viewport and builds only the rows near it."
  (let ((buffer (generate-new-buffer " *text-grid-scroll*"))
        (prefix (etaf-ref "r")) (calls 0) (offsets nil))
    (unwind-protect
        (progn
          (etaf-mount buffer
                      (etaf-view
                       (etaf-text-grid
                        :rows 1000000 :columns 7 :height 4 :ref 'sheet
                        :on-scroll (lambda (row) (push row offsets))
                        :row-text (lambda (row)
                                    (setq calls (1+ calls))
                                    (format "%s%d" (etaf-value prefix) row)))))
          (let ((runtime (etaf-runtime-for-buffer buffer)))
            (should (equal (etaf-ui-text-grid-test--lines buffer)
                           (etaf-ui-text-grid-test--rows 0 "r")))
            (etaf-scroll-to runtime 'sheet 500000)
            (etaf-scroll-by runtime 'sheet 1)
            (should (= (etaf-scroll-offset runtime 'sheet) 500001))
            (should (equal offsets '(500001 500000)))
            (should (equal (etaf-ui-text-grid-test--lines buffer)
                           (etaf-ui-text-grid-test--rows 500001 "r")))
            ;; Rows read the caller's refs, so a change repaints the viewport.
            (setf (etaf-value prefix) "c")
            (should (equal (etaf-ui-text-grid-test--lines buffer)
                           (etaf-ui-text-grid-test--rows 500001 "c")))
            (save-window-excursion
              (switch-to-buffer buffer)
              (goto-char (point-min))
              (execute-kbd-macro (kbd "n")))
            (let ((offset (etaf-scroll-offset runtime 'sheet)))
              (should (> offset 500001))
              (should (equal (car offsets) offset))
              (should (equal (etaf-ui-text-grid-test--lines buffer)
                             (etaf-ui-text-grid-test--rows offset "c"))))
            (etaf-scroll-to runtime 'sheet 2000000)
            (should (= (etaf-scroll-offset runtime 'sheet) 999996))
            (should (equal (etaf-ui-text-grid-test--lines buffer)
                           (etaf-ui-text-grid-test--rows 999996 "c")))
            (should (< calls 300))))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer))) (etaf-unmount runtime))
      (kill-buffer buffer))))

(ert-deftest etaf-ui-text-grid-keeps-its-viewport-within-changing-rows ()
  "Shrinking and growing ROWS keeps the scrolled viewport on existing rows."
  (let ((buffer (generate-new-buffer " *text-grid-rows*"))
        (count (etaf-ref 100)))
    (unwind-protect
        (progn
          (etaf-mount buffer
                      (etaf-view
                       (etaf-text-grid :rows (etaf-value count) :columns 7 :height 4
                                       :ref 'sheet
                                       :row-text (lambda (row) (format "r%d" row)))))
          (let ((runtime (etaf-runtime-for-buffer buffer)))
            (etaf-scroll-to runtime 'sheet 90)
            (setf (etaf-value count) 50)
            (should (= (etaf-scroll-offset runtime 'sheet) 46))
            (should (equal (etaf-ui-text-grid-test--lines buffer)
                           (etaf-ui-text-grid-test--rows 46 "r")))
            (setf (etaf-value count) 3000)
            (etaf-scroll-to runtime 'sheet 2500)
            (should (equal (etaf-ui-text-grid-test--lines buffer)
                           (etaf-ui-text-grid-test--rows 2500 "r")))))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer))) (etaf-unmount runtime))
      (kill-buffer buffer))))

(provide 'etaf-ui-text-grid-tests)
;;; etaf-ui-text-grid-tests.el ends here
