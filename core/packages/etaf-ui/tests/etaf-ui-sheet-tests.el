;;; etaf-ui-sheet-tests.el --- Sheet component acceptance  -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Code:
(require 'ert)
(require 'etaf-ui)

(defun etaf-ui-sheet-test--lines (buffer)
  "Return the non-empty text lines BUFFER shows."
  (with-current-buffer buffer
    (seq-filter (lambda (line) (not (string-empty-p line)))
                (split-string (buffer-substring-no-properties
                               (point-min) (point-max))
                              "\n"))))

(defun etaf-ui-sheet-test--text (buffer)
  "Return all text BUFFER paints."
  (with-current-buffer buffer (buffer-substring-no-properties (point-min) (point-max))))

(defun etaf-ui-sheet-test--face-backgrounds (buffer line-number)
  "Return the backgrounds painted on BUFFER's LINE-NUMBER."
  (with-current-buffer buffer
    (save-excursion
      (goto-char (point-min))
      (forward-line (1- line-number))
      (let ((end (line-end-position))
            (position (line-beginning-position))
            found)
        (while (< position end)
          (let ((face (get-text-property position 'face)))
            (dolist (spec (cond ((null face) nil)
                                ((keywordp (car face)) (list face))
                                (t face)))
              (when-let* ((background (plist-get spec :background)))
                (cl-pushnew background found :test #'equal))))
          (setq position (or (next-single-property-change position 'face nil end) end)))
        found))))

(defun etaf-ui-sheet-test--face-at (buffer line-number needle property)
  "Return PROPERTY of the face NE ar LINE-NUMBER where NEEDLE starts."
  (with-current-buffer buffer
    (save-excursion
      (goto-char (point-min))
      (forward-line (1- line-number))
      (let ((end (line-end-position)))
        (when (search-forward needle end t)
          (let ((face (get-text-property (match-beginning 0) 'face)))
            (cl-loop for spec in (cond ((null face) nil)
                                       ((keywordp (car face)) (list face))
                                       (t face))
                     thereis (plist-get spec property))))))))

(defun etaf-ui-sheet-test--underline-colours (buffer line-number)
  "Return the rule colours painted on BUFFER's LINE-NUMBER."
  (with-current-buffer buffer
    (save-excursion
      (goto-char (point-min))
      (forward-line (1- line-number))
      (let ((end (line-end-position))
            (position (line-beginning-position))
            found)
        (while (< position end)
          (let ((face (get-text-property position 'face)))
            (dolist (spec (cond ((null face) nil)
                                ((keywordp (car face)) (list face))
                                (t face)))
              (when-let* ((rule (plist-get spec :underline)))
                (cl-pushnew (plist-get rule :color) found :test #'equal))))
          (setq position (or (next-single-property-change position 'face nil end) end)))
        found))))

(defun etaf-ui-sheet-test--mount (&rest overrides)
  "Mount a three-column sheet with OVERRIDES; return its plist of handles."
  (let* ((buffer (generate-new-buffer " *sheet under test*"))
         (version (etaf-ref 0))
         (cursor (etaf-ref (cons 0 0)))
         (region (etaf-ref nil))
         (editing (etaf-ref nil))
         (widths (vector 8 8 8))
         (heights (make-hash-table :test 'eql))
         (label (etaf-ref "c"))
         (commits nil)
         (spec (list :rows 100
                     :columns 3
                     :widths widths
                     :heights heights
                     :version version
                     :cursor cursor
                     :region region
                     :editing editing
                     :height 6
                     :header t
                     :row-head t
                     :ref 'sheet-under-test
                     :cell-text (lambda (row col)
                                  (format "%s%d.%d"
                                          (etaf-value label) row col))
                     :cell-edit-text (lambda (row col)
                                       (format "raw%d.%d" row col))
                     :on-commit (lambda (row col text)
                                  (push (list row col text) commits)))))
    (cl-loop for (key value) on overrides by #'cddr
             do (setq spec (plist-put spec key value)))
    (with-current-buffer buffer
      (etaf-mount buffer (etaf-node 'etaf-sheet spec nil)))
    (list :buffer buffer
          :runtime (etaf-runtime-for-buffer buffer)
          :version version :cursor cursor :region region :editing editing
          :widths widths :heights heights :label label
          :commits (lambda () (nreverse commits)))))

(defun etaf-ui-sheet-test--unmount (sheet)
  "Unmount SHEET and kill its buffer."
  (let ((buffer (plist-get sheet :buffer)))
    (when-let* ((runtime (etaf-runtime-for-buffer buffer)))
      (etaf-unmount runtime))
    (kill-buffer buffer)))

(ert-deftest etaf-ui-sheet-builds-only-the-viewport ()
  "A huge sheet paints its header and viewport, not one Host per row."
  (let ((sheet (etaf-ui-sheet-test--mount :rows 100000)))
    (unwind-protect
        (let ((buffer (plist-get sheet :buffer)))
          (should (<= (length (etaf-ui-sheet-test--lines buffer)) 8))
          (should (string-match-p "c0.0"
                                  (etaf-ui-sheet-test--text buffer)))
          (should-not (string-match-p "c20.0"
                                      (etaf-ui-sheet-test--text buffer)))
          (etaf-set-value (plist-get sheet :cursor) (cons 5000 1))
          (etaf-sheet-reveal (plist-get sheet :runtime) 'sheet-under-test)
          (should (string-match-p "c5000.1"
                                  (etaf-ui-sheet-test--text buffer)))
          (should-not (string-match-p "c0.0"
                                      (etaf-ui-sheet-test--text buffer)))
          (should (<= (length (etaf-ui-sheet-test--lines buffer)) 8)))
      (etaf-ui-sheet-test--unmount sheet))))

(ert-deftest etaf-ui-sheet-pages-the-viewport-without-moving-the-cursor ()
  "Scrolling by lines shows later rows and leaves the cursor where it was."
  (let ((sheet (etaf-ui-sheet-test--mount)))
    (unwind-protect
        (let ((buffer (plist-get sheet :buffer)))
          (should (string-match-p "c0\\.0" (etaf-ui-sheet-test--text buffer)))
          (etaf-sheet-scroll (plist-get sheet :runtime) 'sheet-under-test 3)
          (should (string-match-p "c3\\.0" (etaf-ui-sheet-test--text buffer)))
          (should-not (string-match-p "c0\\.0" (etaf-ui-sheet-test--text buffer)))
          (should (equal (etaf-value (plist-get sheet :cursor)) (cons 0 0)))
          (etaf-sheet-scroll (plist-get sheet :runtime) 'sheet-under-test -3)
          (should (string-match-p "c0\\.0" (etaf-ui-sheet-test--text buffer))))
      (etaf-ui-sheet-test--unmount sheet))))

(ert-deftest etaf-ui-sheet-paints-cursor-and-selection ()
  "The cursor cell keeps its outline, selected cells take the fill."
  (let ((sheet (etaf-ui-sheet-test--mount)))
    (unwind-protect
        (let ((buffer (plist-get sheet :buffer)))
          (etaf-batch
           (etaf-set-value (plist-get sheet :cursor) (cons 1 0))
           (etaf-set-value (plist-get sheet :region) (cons 2 2)))
          ;; Row 2 is the cursor row, row 3 is selected, row 5 is not.
          (should (etaf-ui-sheet-test--face-at buffer 3 "c1.0" :overline))
          (should (etaf-ui-sheet-test--face-at buffer 3 "c1.1" :background))
          (should (etaf-ui-sheet-test--face-at buffer 4 "c2.0" :background))
          (should-not (etaf-ui-sheet-test--face-at buffer 5 "c3.0" :background))
          ;; Every row keeps the horizontal rule.
          (should (= 1 (length (etaf-ui-sheet-test--underline-colours buffer 2)))))
      (etaf-ui-sheet-test--unmount sheet))))

(ert-deftest etaf-ui-sheet-repaints-when-the-caller-bumps-version ()
  "A version bump asks the caller for cell text again."
  (let ((sheet (etaf-ui-sheet-test--mount)))
    (unwind-protect
        (let ((buffer (plist-get sheet :buffer)))
          (should (string-match-p "c0.0" (etaf-ui-sheet-test--text buffer)))
          (etaf-set-value (plist-get sheet :label) "z")
          (should-not (string-match-p "z0.0" (etaf-ui-sheet-test--text buffer)))
          (etaf-set-value (plist-get sheet :version) 1)
          (should (string-match-p "z0.0" (etaf-ui-sheet-test--text buffer))))
      (etaf-ui-sheet-test--unmount sheet))))

(ert-deftest etaf-ui-sheet-adds-lines-for-a-tall-row ()
  "Extra row height paints filler lines and pushes the rows below down."
  (let ((sheet (etaf-ui-sheet-test--mount)))
    (unwind-protect
        (let ((buffer (plist-get sheet :buffer)))
          (let ((before (length (etaf-ui-sheet-test--lines buffer))))
            (puthash 0 1 (plist-get sheet :heights))
            (etaf-set-value (plist-get sheet :version) 1)
            ;; The viewport still holds the same lines, with one filler.
            (should (= (length (etaf-ui-sheet-test--lines buffer)) before))
            (let* ((lines (etaf-ui-sheet-test--lines buffer))
                   (first-row (seq-position lines (seq-find
                                                   (lambda (line) (string-match-p "c0\\.0" line))
                                                   lines)))
                   (filler (seq-position lines (seq-find
                                                (lambda (line) (not (string-match-p "c[0-9]" line)))
                                                (nthcdr (1+ first-row) lines)))))
              (should first-row)
              (should filler)
              (should (= filler (1+ first-row)))
              ;; The filler keeps the horizontal rule.
              (should (= 1 (length (etaf-ui-sheet-test--underline-colours
                                    buffer (1+ filler))))))))
      (etaf-ui-sheet-test--unmount sheet))))

(ert-deftest etaf-ui-sheet-edits-a-cell-through-the-field ()
  "Beginning an edit replaces the cell with a field and reports the result."
  (let ((sheet (etaf-ui-sheet-test--mount)))
    (unwind-protect
        (let ((buffer (plist-get sheet :buffer))
              (runtime (plist-get sheet :runtime)))
          (etaf-sheet-begin-edit runtime 'sheet-under-test
                                 (plist-get sheet :editing) (cons 1 1))
          (should (equal (etaf-value (plist-get sheet :editing)) (cons 1 1)))
          (should (etaf-text-input-active-p runtime))
          (should (string-match-p "raw1.1" (etaf-ui-sheet-test--text buffer)))
          (should-not (string-match-p "c1.1"
                                      (etaf-ui-sheet-test--text buffer)))
          (etaf-text-input-end 'blur)
          (etaf-set-value (plist-get sheet :editing) nil)
          (etaf-sheet-begin-edit runtime 'sheet-under-test
                                 (plist-get sheet :editing) (cons 1 1))
          (etaf-text-input-end)
          (should (equal (funcall (plist-get sheet :commits))
                         '((1 1 "raw1.1")))))
      (etaf-ui-sheet-test--unmount sheet))))

(ert-deftest etaf-ui-sheet-rejects-invalid-props ()
  "Shape and callback mistakes fail before anything is painted."
  (let ((buffer (generate-new-buffer " *sheet invalid*")))
    (unwind-protect
        (dolist (props (list (list :rows 0 :columns 1 :height 1 :cell-text #'ignore
                                   :cursor (etaf-ref (cons 0 0))
                                   :on-commit #'ignore)
                             (list :rows 1 :columns 1 :height 0 :cell-text #'ignore
                                   :cursor (etaf-ref (cons 0 0))
                                   :on-commit #'ignore)
                             (list :rows 1 :columns 1 :height 1 :widths 5
                                   :cell-text #'ignore
                                   :cursor (etaf-ref (cons 0 0))
                                   :on-commit #'ignore)
                             (list :rows 1 :columns 1 :height 1 :widths (vector 3)
                                   :cell-text 42 :cursor (etaf-ref (cons 0 0))
                                   :on-commit #'ignore)
                             (list :rows 1 :columns 1 :height 1 :widths (vector 3)
                                   :cell-text #'ignore :cursor nil
                                   :on-commit #'ignore)
                             (list :rows 1 :columns 1 :height 1 :widths (vector 3)
                                   :cell-text #'ignore :cursor (etaf-ref (cons 0 0))
                                   :on-commit nil)
                             (list :rows 1 :columns 1 :height 1 :widths (vector 3)
                                   :cell-text #'ignore :cursor (etaf-ref (cons 0 0))
                                   :on-commit #'ignore :header 42)))
          (should-error (etaf-mount buffer (etaf-node 'etaf-sheet props nil))
                        :type 'etaf-component-call-error))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer)))
        (etaf-unmount runtime))
      (kill-buffer buffer))))

(provide 'etaf-ui-sheet-tests)
;;; etaf-ui-sheet-tests.el ends here
