;;; etaf-projection-tests.el --- Mapping painted cells back to source  -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; The projection is plain data over one paint: every run says which source
;; range a stretch of painted cells stands for, and both directions must agree.

;;; Code:

(require 'etaf-test-support)

(etaf-define-component etaf-projection-test-document (&key first second)
  "Render FIRST and SECOND in two Hosts a caller can name."
  :view
  (column
   (box :ref 'first (text (expr first)))
   (box :ref 'second (text (expr second)))))

(etaf-define-component etaf-projection-test-wrapped (&key body)
  "Render BODY in one Host, so it wraps when the viewport is narrow."
  :view
  (column
   (box :ref 'body (text (expr body)))))

(ert-deftest etaf-projection-maps-both-directions-through-public-api ()
  "A registered Host maps painted cells to its source range and back."
  (etaf-test-with-mount (runtime
                         (etaf-view (etaf-projection-test-document
                                     :first "hello" :second "world")))
    (let* ((entries '((first . (0 . 5)) (second . (6 . 11))))
           (projection (etaf-projection runtime entries))
           (first-run (aref projection 0))
           (second-run (aref projection 1)))
      (should (= 2 (length projection)))
      (should (= 0 (nth 2 first-run)))
      (should (= 5 (nth 3 first-run)))
      (should (= 0 (etaf-projection-source-offset projection (car first-run))))
      (should (= 2 (etaf-projection-source-offset projection (+ 2 (car first-run)))))
      (should (= (car first-run) (etaf-projection-position projection 0)))
      (should (= (+ 2 (car first-run)) (etaf-projection-position projection 2)))
      (should (= 6 (nth 2 second-run)))
      (should (= (car second-run) (etaf-projection-position projection 6)))
      (should (= (nth 1 second-run) (etaf-projection-position projection 11))))))

(ert-deftest etaf-projection-skips-entries-that-paint-nothing ()
  "Entries without a mounted Host or with an empty source range are ignored."
  (etaf-test-with-mount (runtime
                         (etaf-view (etaf-projection-test-document
                                     :first "hello" :second "world")))
    (should (= 0 (length (etaf-projection runtime '((missing . (0 . 5)))))))
    (should (= 0 (length (etaf-projection runtime '((first . (3 . 3)))))))
    (should (= 1 (length (etaf-projection runtime '((first . (0 . 5)))))))))

(ert-deftest etaf-projection-splits-a-wrapped-host-across-its-lines ()
  "A wrapped Host spreads its source range over the lines it painted."
  (etaf-test-with-mount (runtime
                         (etaf-view (etaf-projection-test-wrapped
                                     :body "alpha beta gamma delta epsilon"))
                         (list :viewport-width 14))
    (let* ((projection (etaf-projection runtime '((body . (0 . 30)))))
           (count (length projection))
           (last (aref projection (1- count))))
      (should (> count 1))
      (should (= 0 (nth 2 (aref projection 0))))
      (should (= 30 (nth 3 last)))
      (dotimes (index (1- count))
        (let ((run (aref projection index))
              (next (aref projection (1+ index))))
          (should (< (car run) (car next)))
          (should (<= (nth 3 run) (nth 2 next))))))))

(ert-deftest etaf-projection-reports-a-caret-past-the-last-cell ()
  "A source offset at the end of the document maps after the last cell."
  (etaf-test-with-mount (runtime
                         (etaf-view (etaf-projection-test-document
                                     :first "hello" :second "world")))
    (let* ((projection (etaf-projection runtime '((second . (6 . 11)))))
           (run (aref projection 0)))
      (should (= (nth 1 run) (etaf-projection-position projection 11))))))

(provide 'etaf-projection-tests)
;;; etaf-projection-tests.el ends here
