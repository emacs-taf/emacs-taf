;;; etaf-test-support.el --- Public-API helpers for ETAF tests -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Helpers shared by the ETAF acceptance scenarios.  They use only the
;; package's declared interfaces.

;;; Code:

(require 'ert)
(require 'etaf)

(defmacro etaf-test-with-mount (spec &rest body)
  "Mount a View and run BODY.
SPEC is (RUNTIME VIEW [OPTIONS]).  RUNTIME is bound to the mounted Runtime
and the buffer is current while BODY runs.  The buffer is killed afterwards."
  (declare (indent 1) (debug ((symbolp form &optional form) body)))
  (let ((buffer (make-symbol "buffer")))
    `(let* ((,buffer (generate-new-buffer " *etaf-test*"))
            (,(car spec) nil))
       (unwind-protect
           (progn
             (etaf-mount ,buffer ,(nth 1 spec)
                         (or ,(nth 2 spec)
                             (list :viewport-width 800 :viewport-height 40)))
             (setq ,(car spec) (etaf-runtime-for-buffer ,buffer))
             (with-current-buffer ,buffer ,@body))
         (when (buffer-live-p ,buffer)
           (kill-buffer ,buffer))))))

(defun etaf-test-text (&optional buffer)
  "Return BUFFER's text without properties, trailing spaces removed per line."
  (with-current-buffer (or buffer (current-buffer))
    (mapconcat #'string-trim-right
               (split-string (buffer-substring-no-properties (point-min) (point-max))
                             "\n")
               "\n")))

(defun etaf-test-lines (&optional buffer)
  "Return BUFFER's non-blank trimmed lines."
  (delq nil (mapcar (lambda (line)
                      (let ((trimmed (string-trim line)))
                        (unless (string-empty-p trimmed) trimmed)))
                    (split-string (etaf-test-text buffer) "\n"))))

(defun etaf-test-face-at (string)
  "Return the face property at the first occurrence of STRING."
  (save-excursion
    (goto-char (point-min))
    (when (search-forward string nil t)
      (get-text-property (match-beginning 0) 'face))))

(defun etaf-test-face-attribute (face attribute)
  "Return ATTRIBUTE from FACE, a face plist or list of face plists."
  (cond
   ((and (consp face) (keywordp (car face))) (plist-get face attribute))
   ((consp face) (cl-some (lambda (f) (etaf-test-face-attribute f attribute)) face))
   (t nil)))

(provide 'etaf-test-support)

;;; etaf-test-support.el ends here
