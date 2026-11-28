;;; etaf-image-tests.el --- Image Host acceptance -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; Public behaviour of the core `image' Host: its fixed cell grid, the media
;; placeholder fallback and its input errors.  The scenarios render through
;; `etaf-render' and the public Ebox publication surface, so no fixture file
;; and no graphical frame is required.

;;; Code:

(require 'ert)
(require 'etaf)

(ert-deftest etaf-image-test-placeholder-grid-has-exact-cell-size ()
  "A placeholder image occupies exactly its COLUMNS by ROWS character cells."
  (let ((text (substring-no-properties
               (ebox-render
                (etaf-render
                 (etaf-view
                  (image :src "/nonexistent/etaf-image-tests.png"
                         :columns 5 :rows 3 :adapter 'placeholder)))))))
    (should (equal ".....\n.....\n....." text))))

(ert-deftest etaf-image-test-missing-file-falls-back-to-placeholder ()
  "An unreadable source becomes a placeholder instead of failing the render."
  (let ((text (substring-no-properties
               (ebox-render
                (etaf-render
                 (etaf-view
                  (image :src "/nonexistent/etaf-image-tests.png"
                         :columns 2 :rows 2)))))))
    (should (equal "..\n.." text))))

(ert-deftest etaf-image-test-accepts-image-descriptors ()
  "An image descriptor is a source; undecodable data becomes a placeholder."
  (let ((text (substring-no-properties
               (ebox-render
                (etaf-render
                 (etaf-view
                  (image :src '(image :type png :data "not a png")
                         :columns 3 :rows 2)))))))
    (should (equal "...\n..." text))))

(ert-deftest etaf-image-test-inside-layout-keeps-its-grid ()
  "An image inside a Row keeps its own cell size next to ordinary text."
  (let ((text (substring-no-properties
               (ebox-render
                (etaf-render
                 (etaf-view
                  (row
                   (text "left ")
                   (image :src "/nonexistent/etaf-image-tests.png"
                          :columns 3 :rows 2 :adapter 'placeholder))))))))
    (should (string-prefix-p "left ..." text))))

(ert-deftest etaf-image-test-rejects-invalid-input ()
  "Invalid source, size, adapter and children are reported before publication."
  (should-error
   (etaf-render (etaf-view (image :src 42 :columns 4 :rows 2)))
   :type 'etaf-renderer-error)
  (should-error
   (etaf-render (etaf-view (image :src '(image :type png) :columns 4 :rows 2)))
   :type 'etaf-renderer-error)
  (should-error
   (etaf-render (etaf-view (image :src "/tmp/x.png" :columns 0 :rows 2)))
   :type 'etaf-renderer-error)
  (should-error
   (etaf-render (etaf-view (image :src "/tmp/x.png" :columns 4)))
   :type 'etaf-renderer-error)
  (should-error
   (etaf-render (etaf-view (image :src "/tmp/x.png" :columns 4 :rows 2
                                  :adapter 'bogus)))
   :type 'etaf-renderer-error)
  (should-error
   (etaf-render (etaf-view (image :src "/tmp/x.png" :columns 4 :rows 2 "child")))
   :type 'etaf-renderer-error))

(provide 'etaf-image-tests)
;;; etaf-image-tests.el ends here
