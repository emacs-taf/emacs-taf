;;; etaf-org-preview-demo.el --- Open the sample document -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; Open the maintained sample document in the Org preview.  It is the hand
;; check every surface of the previewer should still show after a change:
;; keywords, planning, tags, properties, nested lists, checkboxes, a table,
;; code, quotes, callouts, verse, centering, fixed-width text, formulas,
;; footnotes and all eight headline levels.
;;
;;   emacs -Q -L . -L lisp -L ../etaf -L ../etaf-ui -L ../ebox -L ../ecss \
;;     -l examples/etaf-org-preview-demo.el
;;
;; Interactively, `etaf-org-preview-demo' opens it from a configured Emacs.

;;; Code:

(require 'etaf-org-preview)

(defun etaf-org-preview-demo-file ()
  "Return the absolute name of the sample document."
  (expand-file-name "sample.org"
                    (file-name-directory (or load-file-name
                                             buffer-file-name))))

(defun etaf-org-preview-demo ()
  "Open the sample document in the preview."
  (interactive)
  (etaf-org-preview-open (etaf-org-preview-demo-file)))

(provide 'etaf-org-preview-demo)
;;; etaf-org-preview-demo.el ends here
