;;; etaf-org-derive.el --- Document-wide derivation pass for etaf-org -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; Runs once per document publish (and on style-rule changes, without
;; re-parsing) to compute document-wide derived facts:
;; - Stable section IDs (`CUSTOM_ID' > `ID' > positional `s1.1')
;; - Outline list `(LEVEL TITLE ID TODO TAGS PRIORITY LINE-START)'
;; - Section numbering (`decimal', `lower-roman', `upper-alpha') honoring
;;   `#+OPTIONS: num:' and `(headline)' style `:numbering'
;; - Inherited tags (`#+FILETAGS:' + ancestor tags -> `:effective-tags')
;; - Named-block table (`#+NAME:' -> block plist) for `chart :from' & jumps
;; - Table numbering (`1', `2', ...) and display equation numbering (`(1)', ...)
;; - Real deadline overdue / due-soon calculation against `:today'
;; - Aggregate counts (`:todo', `:done', `:deadline', `:overdue', `:clock-minutes')

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'etaf-org-node)
(require 'etaf-org-parse)

(defun etaf-org-derive--to-roman (n)
  "Format positive integer N as lowercase Roman numerals."
  (let ((table '((1000 . "m") (900 . "cm") (500 . "d") (400 . "cd")
                 (100 . "c") (90 . "xc") (50 . "l") (40 . "xl")
                 (10 . "x") (9 . "ix") (5 . "v") (4 . "iv") (1 . "i")))
        (rem (max 1 n))
        (out nil))
    (dolist (pair table)
      (while (>= rem (car pair))
        (push (cdr pair) out)
        (setq rem (- rem (car pair)))))
    (apply #'concat (nreverse out))))

(defun etaf-org-derive--to-alpha (n)
  "Format positive integer N as uppercase letter(s) A..Z."
  (let ((idx (mod (max 0 (1- n)) 26)))
    (char-to-string (+ ?A idx))))

(defun etaf-org-derive--format-number (counters style)
  "Format COUNTERS (outermost first) in numbering STYLE."
  (pcase style
    ('lower-roman (mapconcat #'etaf-org-derive--to-roman counters "."))
    ('upper-alpha (mapconcat #'etaf-org-derive--to-alpha counters "."))
    ('decimal (mapconcat #'number-to-string counters "."))
    (_ nil)))

(defun etaf-org-derive--today-days (&optional today)
  "Return absolute day count for TODAY (`(Y M D)' or `YYYY-MM-DD' or nil)."
  (let* ((ymd
          (cond
           ((and (listp today) (= (length today) 3)) today)
           ((and (stringp today)
                 (string-match "\\`\\([0-9]\\{4\\}\\)-\\([0-9]\\{2\\}\\)-\\([0-9]\\{2\\}\\)\\'"
                               today))
            (list (string-to-number (match-string 1 today))
                  (string-to-number (match-string 2 today))
                  (string-to-number (match-string 3 today))))
           (t
            (let ((decoded (decode-time (current-time))))
              (list (nth 5 decoded) (nth 4 decoded) (nth 3 decoded)))))))
    (time-to-days (encode-time 0 0 12 (nth 2 ymd) (nth 1 ymd) (nth 0 ymd)))))

(defun etaf-org-derive--stamp-days (stamp)
  "Return absolute day count of parsed Org timestamp STAMP, or nil."
  (when-let* ((start (plist-get stamp :start))
              (y (plist-get start :y))
              (m (plist-get start :m))
              (d (plist-get start :d)))
    (ignore-errors (time-to-days (encode-time 0 0 12 d m y)))))

(defun etaf-org-derive--deadline-delta (planning todo-state today-days)
  "Return integer days until deadline (negative means overdue), or nil.
Completed (`done') sections are never overdue."
  (when (and planning (not (eq todo-state 'done)))
    (when-let* ((deadline (plist-get planning :deadline))
                (ddays (etaf-org-derive--stamp-days deadline)))
      (- ddays today-days))))

(defun etaf-org-derive--heading-numbering-style (document)
  "Return effective heading numbering style for DOCUMENT, or nil."
  (let* ((opts (plist-get document :options))
         (opt-num (plist-get opts :num))
         (dummy (etaf-org-node-create :type 'headline :derived '(:level 1)))
         (style-num (etaf-org--resolve-attr dummy :numbering)))
    (cond
     ((and style-num (not (eq style-num 'none))) style-num)
     ((or (eq opt-num t) (and (integerp opt-num) (> opt-num 0))) 'decimal)
     (t nil))))

(defun etaf-org-derive (document &optional today)
  "Run the document-wide derivation pass over DOCUMENT for date TODAY.
Populates `:outline', `:named-blocks', `:counts', `:tables-index',
`:listings-index', section IDs, section numbers, inherited tags, overdue
flags, and table/equation numbers.  Returns DOCUMENT."
  (let* ((sections (plist-get document :sections))
         (preamble (plist-get document :preamble))
         (filetags (plist-get document :filetags))
         (opts (plist-get document :options))
         (num-limit (let ((n (plist-get opts :num)))
                      (if (integerp n) n 8)))
         (num-style (etaf-org-derive--heading-numbering-style document))
         (today-days (etaf-org-derive--today-days today))
         (named-blocks (make-hash-table :test #'equal))
         (section-by-id (make-hash-table :test #'equal))
         (outline nil)
         (tables-index nil)
         (listings-index nil)
         (table-seq 0)
         (eq-seq 0)
         (todo-count 0)
         (done-count 0)
         (deadline-count 0)
         (overdue-count 0)
         (clock-minutes 0))
    (cl-labels
        ((walk-blocks (blocks section-id)
           (dolist (block blocks)
             (when-let* ((bname (plist-get block :block-name)))
               (puthash bname block named-blocks))
             (when-let* ((aid (plist-get (plist-get block :attrs) :id)))
               (puthash aid block named-blocks))
             (pcase (plist-get block :type)
               ('table
                (cl-incf table-seq)
                (plist-put block :derived-number (number-to-string table-seq))
                (push (list :number table-seq
                            :caption (or (plist-get block :caption)
                                         (plist-get block :block-name)
                                         (format "表格 %d" table-seq))
                            :section-id section-id
                            :line-start (plist-get block :line-start))
                      tables-index))
               ('src-block
                (when (or (plist-get block :caption) (plist-get block :block-name))
                  (push (list :caption (or (plist-get block :caption)
                                           (plist-get block :block-name))
                              :lang (plist-get block :lang)
                              :section-id section-id
                              :line-start (plist-get block :line-start))
                        listings-index)))
               ((or 'display-math 'latex-environment)
                (when (or (plist-get block :block-name)
                          (and (eq (plist-get block :type) 'latex-environment)
                               (member (plist-get block :name)
                                       '("equation" "align" "gather"))))
                  (cl-incf eq-seq)
                  (plist-put block :derived-number (format "(%d)" eq-seq)))))
             (when-let* ((kids (plist-get block :blocks)))
               (walk-blocks kids section-id))
             (dolist (item (plist-get block :items))
               (walk-blocks (plist-get item :blocks) section-id))))
         (walk-section (section path ancestor-tags counters)
           (let* ((props (etaf-org-section-properties section))
                  (custom (or (cdr (assoc "CUSTOM_ID" props))
                              (cdr (assoc "ID" props))))
                  (id (or custom path))
                  (level (etaf-org-section-level section))
                  (own-tags (etaf-org-section-tags section))
                  (eff-tags (delete-dups (append ancestor-tags own-tags)))
                  (todo (etaf-org-section-todo section))
                  (todo-state (etaf-org-section-todo-state section))
                  (planning (etaf-org-section-planning section))
                  (delta (etaf-org-derive--deadline-delta planning todo-state today-days))
                  (number (when (and num-style
                                     (not (etaf-org-section-commented section))
                                     (<= level num-limit))
                            (etaf-org-derive--format-number counters num-style))))
             (setf (etaf-org-section-id section) id
                   (etaf-org-section-effective-tags section) eff-tags
                   (etaf-org-section-number section) number)
             (when planning
               (setq planning (plist-put (copy-sequence planning)
                                         :deadline-delta delta))
               (setq planning (plist-put planning :overdue (and delta (< delta 0))))
               (setq planning (plist-put planning :due-soon (and delta (>= delta 0) (<= delta 3))))
               (setf (etaf-org-section-planning section) planning))
             (puthash id section section-by-id)
             (when todo
               (if (eq todo-state 'done)
                   (cl-incf done-count)
                 (cl-incf todo-count)))
             (when (plist-get planning :deadline)
               (cl-incf deadline-count)
               (when (and delta (< delta 0))
                 (cl-incf overdue-count)))
             (dolist (entry (etaf-org-section-logbook section))
               (cl-incf clock-minutes (or (plist-get entry :minutes) 0)))
             ;; Keep exact 5-element prefix `(LEVEL TITLE ID TODO TAGS)' for
             ;; public `etaf-org-outline' compatibility.
             (push (list level
                         (etaf-org-section-title-plain section)
                         id
                         todo
                         own-tags)
                   outline)
             (walk-blocks (etaf-org-section-body section) id)
             (let ((idx 0))
               (dolist (child (etaf-org-section-children section))
                 (cl-incf idx)
                 (walk-section child
                               (format "%s.%d" path idx)
                               eff-tags
                               (append counters (list idx))))))))
      (walk-blocks preamble nil)
      (let ((idx 0))
        (dolist (section sections)
          (cl-incf idx)
          (walk-section section (format "s%d" idx) filetags (list idx)))))
    (setq document (plist-put document :outline (nreverse outline)))
    (setq document (plist-put document :named-blocks named-blocks))
    (setq document (plist-put document :section-by-id section-by-id))
    (setq document (plist-put document :tables-index (nreverse tables-index)))
    (setq document (plist-put document :listings-index (nreverse listings-index)))
    (setq document (plist-put document :counts
                              (list :todo todo-count
                                    :done done-count
                                    :deadline deadline-count
                                    :overdue overdue-count
                                    :clock-minutes clock-minutes)))
    document))

(provide 'etaf-org-derive)
;;; etaf-org-derive.el ends here
