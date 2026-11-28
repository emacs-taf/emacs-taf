;;; -*- lexical-binding: t; -*-
;;; etaf-tanks-maps.el --- Map text, the stage catalog and campaign progress
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Map files are plain text owned by the user or bundled with the Godot world
;; in native/godot/stages/.  The world validates every map it plays; this file
;; only reads headers for the catalog, converts editor state to text and
;; remembers cleared stages.

;;; Code:
(require 'cl-lib)
(require 'subr-x)

(defvar etaf-tanks--directory)
(defvar etaf-tanks-map-directory)
(defvar etaf-tanks-progress-file)

(defconst etaf-tanks--map-limits '(:min-width 12 :max-width 52 :min-height 12 :max-height 40 :max-enemies 60)
  "Map dimensions and roster size accepted by the native world.")

(defconst etaf-tanks--kind-names ["普通" "快速" "重炮" "装甲"]
  "Display names of the four enemy kinds, in roster order.")

(defun etaf-tanks--map-parse (text)
  "Leniently read map TEXT into (:name :counts :rows).
Rows keep their characters; ragged rows are padded with empty ground to the
widest row, and the rectangle is padded or cut to the accepted dimensions,
so the editor always holds a map of a playable size.  Return nil when TEXT
has no map section."
  (let ((name nil) (counts nil) (rows nil) (in-map nil))
    (dolist (line (split-string text "\n"))
      (let ((line (string-trim-right line)))
        (cond
         (in-map (push line rows))
         ((or (string-empty-p (string-trim line)) (string-prefix-p ";" (string-trim-left line))))
         ((string-match "\\`[ \t]*map:[ \t]*\\'" line) (setq in-map t))
         ((string-match "\\`[ \t]*name:[ \t]*\\(.*\\)\\'" line)
          (setq name (string-trim (match-string 1 line))))
         ((string-match "\\`[ \t]*enemies:[ \t]*\\(.*\\)\\'" line)
          (let ((numbers (mapcar #'string-to-number (split-string (match-string 1 line)))))
            (when (= (length numbers) 4) (setq counts numbers)))))))
    (when in-map
      (while (and rows (string-empty-p (car rows))) (pop rows))
      (setq rows (nreverse rows))
      (let ((width (apply #'max 0 (mapcar #'length rows))))
        (when (> width 0)
          (let* ((limits etaf-tanks--map-limits)
                 (width (max (plist-get limits :min-width) (min (plist-get limits :max-width) width)))
                 (height (max (plist-get limits :min-height) (min (plist-get limits :max-height) (length rows))))
                 (blank (make-string width ?.)))
            (list :name (or name "未命名") :counts (or counts (list 20 0 0 0))
                  :rows (cl-loop for index below height
                                 for row = (or (nth index rows) blank)
                                 collect (if (> (length row) width) (substring row 0 width)
                                           (concat row (make-string (- width (length row)) ?.)))))))))))

(defun etaf-tanks--map-text (name counts rows)
  "Serialize NAME, enemy COUNTS and terrain ROWS as map text."
  (concat "name: " (string-trim name) "\n"
          "enemies: " (mapconcat #'number-to-string counts " ") "\n"
          "map:\n" (mapconcat #'identity rows "\n") "\n"))

(defun etaf-tanks--catalog-entry (file builtin number)
  "Describe map FILE for the menu; BUILTIN stages carry campaign NUMBER."
  (let* ((text (with-temp-buffer
                 (insert-file-contents file nil 0 65536)
                 (buffer-string)))
         (map (etaf-tanks--map-parse text)))
    (list :key (if builtin (format "stage-%02d" number) (concat "file:" file))
          :builtin builtin :number number :file file :text text
          :name (or (plist-get map :name) (file-name-base file))
          :counts (plist-get map :counts)
          :width (length (car (plist-get map :rows)))
          :height (length (plist-get map :rows)))))

(defun etaf-tanks--builtin-stages ()
  "Return the bundled campaign in play order."
  (let ((number 0))
    (mapcar (lambda (file) (etaf-tanks--catalog-entry file t (cl-incf number)))
            (directory-files (expand-file-name "native/godot/stages" etaf-tanks--directory) t "\\`[0-9]+\\.txt\\'"))))

(defun etaf-tanks--custom-maps ()
  "Return the user's maps from `etaf-tanks-map-directory', newest first."
  (let ((directory etaf-tanks-map-directory))
    (when (file-directory-p directory)
      (mapcar (lambda (file) (etaf-tanks--catalog-entry file nil 1))
              (sort (directory-files directory t "\\.txt\\'")
                    (lambda (a b) (time-less-p (file-attribute-modification-time (file-attributes b))
                                               (file-attribute-modification-time (file-attributes a)))))))))

(defun etaf-tanks--entry-summary (entry)
  "Describe ENTRY's size and enemy total in one line."
  (format "%d×%d 块 · 敌车 %d 辆" (plist-get entry :width) (plist-get entry :height)
          (apply #'+ (plist-get entry :counts))))

(defun etaf-tanks--entry-roster (entry)
  "Return ENTRY's present enemy kinds as (INDEX . TEXT) pairs."
  (cl-loop for count in (plist-get entry :counts) for index from 0
           when (> count 0) collect (cons index (format "%s %d" (aref etaf-tanks--kind-names index) count))))

(defun etaf-tanks--write-file (file text)
  "Write TEXT to FILE atomically, creating its directory."
  (make-directory (file-name-directory file) t)
  (let ((temporary (concat file ".tmp")))
    (let ((coding-system-for-write 'utf-8-unix))
      (write-region text nil temporary nil 'silent))
    (rename-file temporary file t)))

;;; Progress

(defun etaf-tanks--progress-read ()
  "Return the stored progress plist, or an empty record.
A missing file starts fresh; an unreadable one is reported and left intact
until the next record replaces it."
  (or (condition-case problem
          (with-temp-buffer
            (insert-file-contents etaf-tanks-progress-file)
            (let ((data (read (current-buffer))))
              (if (and (plistp data) (eq (plist-get data :version) 1)) data
                (message "坦克大战：进度文件格式不符，已从头记录：%s"
                         (abbreviate-file-name etaf-tanks-progress-file))
                nil)))
        (file-missing nil)
        ((file-error end-of-file invalid-read-syntax)
         (message "坦克大战：无法读取进度文件：%s" (error-message-string problem))
         nil))
      (list :version 1 :cleared nil :best nil)))

(defun etaf-tanks--progress-cleared (progress difficulty)
  "Return the campaign numbers cleared on DIFFICULTY in PROGRESS."
  (alist-get difficulty (plist-get progress :cleared)))

(defun etaf-tanks--progress-best (progress difficulty)
  "Return the best score reached on DIFFICULTY in PROGRESS, or 0."
  (or (alist-get difficulty (plist-get progress :best)) 0))

(defun etaf-tanks--progress-record (progress difficulty number score)
  "Return PROGRESS with stage NUMBER cleared on DIFFICULTY and SCORE kept.
NUMBER nil records only the score.  The record is written to
`etaf-tanks-progress-file'; a write failure keeps the in-memory value."
  (let* ((cleared (copy-tree (plist-get progress :cleared)))
         (best (copy-tree (plist-get progress :best)))
         (numbers (alist-get difficulty cleared)))
    (when (and number (not (memq number numbers)))
      (setf (alist-get difficulty cleared) (sort (cons number numbers) #'<)))
    (when (> score (or (alist-get difficulty best) 0))
      (setf (alist-get difficulty best) score))
    (let ((next (list :version 1 :cleared cleared :best best)))
      (unless (equal next progress)
        (condition-case problem
            (etaf-tanks--write-file etaf-tanks-progress-file
                                    (let ((print-length nil) (print-level nil)) (prin1-to-string next)))
          (file-error (message "坦克大战：无法保存进度：%s" (error-message-string problem)))))
      next)))

(provide 'etaf-tanks-maps)
;;; etaf-tanks-maps.el ends here
