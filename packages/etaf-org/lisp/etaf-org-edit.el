;;; etaf-org-edit.el --- Optional minor mode for authoring ETAF Org documents -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; `etaf-org-edit-mode' is a strictly non-destructive optional minor mode for
;; Org source buffers that assists authoring `etaf-org' containers and
;; `#+attr_etaf:' attributes:
;; - Soft font-lock on `#+attr_etaf:' and `#+begin_<ext> :key val' lines
;; - `completion-at-point' driven live from `etaf-org-node-definitions'
;; - Bounded pair highlight between matching `#+begin_...' and `#+end_...'
;; - `etaf-org-insert-block' interactive skeleton helper
;;
;; Disabling `etaf-org-edit-mode' removes all overlays, hooks, CAPF entries
;; and font-lock keywords cleanly while leaving `buffer-string' untouched.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'etaf-org-node)

(defconst etaf-org-edit--font-lock-keywords
  '(("^[ \t]*\\(#\\+attr_etaf:\\)\\(.*\\)$"
     (1 font-lock-keyword-face t)
     (2 font-lock-variable-name-face keep))
    ("^[ \t]*\\(#\\+\\(?:begin\\|end\\)_[A-Za-z][A-Za-z0-9_-]*\\)\\([ \t]+.*\\)?$"
     (1 font-lock-keyword-face keep))
    ("\\(:[a-z][a-z0-9-]*\\)\\(?:[ \t]+\\|$\\)"
     (1 font-lock-builtin-face keep))
    ("\\[\\[\\(kbd\\|badge\\|sym\\|color\\|spoiler\\|icon\\|abbr\\|roam\\|denote\\):\\([^]]+\\)\\]\\]"
     (1 font-lock-keyword-face prepend)
     (2 font-lock-string-face prepend)))
  "Soft font-lock rules installed by `etaf-org-edit-mode'.")

(defvar-local etaf-org-edit--pair-overlays nil
  "Active overlays highlighting matching `#+begin_' / `#+end_' lines.")

(defun etaf-org-edit--clear-overlays ()
  "Delete all pair-highlight overlays in the current buffer."
  (mapc #'delete-overlay etaf-org-edit--pair-overlays)
  (setq etaf-org-edit--pair-overlays nil))

(defun etaf-org-edit--registered-block-names ()
  "Return sorted list of container document names from `etaf-org-node-definitions'."
  (let ((names nil))
    (maphash (lambda (_type def)
               (when-let* ((name (plist-get def :name)))
                 (push name names)))
             etaf-org-node-definitions)
    (sort (delete-dups names) #'string<)))

(defun etaf-org-edit--block-attr-names (block-name)
  "Return sorted `:attr' completion candidates for BLOCK-NAME."
  (when-let* ((entry (etaf-org--definition-by-name block-name))
              (def (cdr entry)))
    (sort (mapcar (lambda (d) (symbol-name (car d)))
                  (plist-get def :attrs))
          #'string<)))

(defun etaf-org-edit--capf ()
  "Completion-at-point function for `#+begin_<name>' and `:attr' keys."
  (let ((line-beg (line-beginning-position))
        (pt (point))
        (case-fold-search t))
    (save-excursion
      (cond
       ;; Completing block name right after `#+begin_'
       ((and (looking-back "^[ \t]*#\\+begin_\\([A-Za-z0-9_-]*\\)" line-beg))
        (list (match-beginning 1) pt (etaf-org-edit--registered-block-names)
              :exclusive 'no))
       ;; Completing `:attr' on a `#+begin_<name> ...' line
       ((save-excursion
          (goto-char line-beg)
          (and (looking-at "^[ \t]*#\\+begin_\\([A-Za-z][A-Za-z0-9_-]*\\)[ \t]")
               (let ((bname (match-string-no-properties 1)))
                 (goto-char pt)
                 (when (looking-back "\\(:[A-Za-z0-9_-]*\\)" line-beg)
                   (list (match-beginning 1) pt
                         (etaf-org-edit--block-attr-names bname)
                         :exclusive 'no))))))
       ;; Completing `:attr' on a `#+attr_etaf:' line (peeks at next block)
       ((save-excursion
          (goto-char line-beg)
          (and (looking-at "^[ \t]*#\\+attr_etaf:")
               (let ((bname (save-excursion
                              (forward-line 1)
                              (cond
                               ((looking-at "^[ \t]*#\\+begin_\\([A-Za-z][A-Za-z0-9_-]*\\)")
                                (match-string-no-properties 1))
                               ((looking-at "^[ \t]*|") "table")
                               (t nil)))))
                 (goto-char pt)
                 (when (and bname (looking-back "\\(:[A-Za-z0-9_-]*\\)" line-beg))
                   (list (match-beginning 1) pt
                         (etaf-org-edit--block-attr-names bname)
                         :exclusive 'no))))))))))

(defun etaf-org-edit--highlight-pair ()
  "Highlight the matching `#+begin_<name>' / `#+end_<name>' within 400 lines."
  (etaf-org-edit--clear-overlays)
  (save-excursion
    (beginning-of-line)
    (let ((case-fold-search t))
      (cond
       ((looking-at "^[ \t]*#\\+begin_\\([A-Za-z][A-Za-z0-9_-]*\\)\\b")
        (let* ((name (downcase (match-string-no-properties 1)))
               (beg-ov-a (line-beginning-position))
               (beg-ov-b (line-end-position))
               (depth 1)
               (limit (save-excursion (forward-line 400) (point)))
               (open-re (format "^[ \t]*#\\+begin_%s\\b" (regexp-quote name)))
               (close-re (format "^[ \t]*#\\+end_%s[ \t]*$" (regexp-quote name))))
          (forward-line 1)
          (while (and (> depth 0) (< (point) limit) (not (eobp)))
            (cond
             ((looking-at open-re) (cl-incf depth))
             ((looking-at close-re)
              (cl-decf depth)
              (when (zerop depth)
                (let ((ov1 (make-overlay beg-ov-a beg-ov-b))
                      (ov2 (make-overlay (line-beginning-position) (line-end-position))))
                  (overlay-put ov1 'face 'show-paren-match)
                  (overlay-put ov2 'face 'show-paren-match)
                  (setq etaf-org-edit--pair-overlays (list ov1 ov2))))))
            (forward-line 1))))
       ((looking-at "^[ \t]*#\\+end_\\([A-Za-z][A-Za-z0-9_-]*\\)[ \t]*$")
        (let* ((name (downcase (match-string-no-properties 1)))
               (end-ov-a (line-beginning-position))
               (end-ov-b (line-end-position))
               (depth 1)
               (limit (save-excursion (forward-line -400) (point)))
               (open-re (format "^[ \t]*#\\+begin_%s\\b" (regexp-quote name)))
               (close-re (format "^[ \t]*#\\+end_%s[ \t]*$" (regexp-quote name))))
          (while (and (> depth 0) (> (point) limit) (zerop (forward-line -1)))
            (cond
             ((looking-at close-re) (cl-incf depth))
             ((looking-at open-re)
              (cl-decf depth)
              (when (zerop depth)
                (let ((ov1 (make-overlay (line-beginning-position) (line-end-position)))
                      (ov2 (make-overlay end-ov-a end-ov-b)))
                  (overlay-put ov1 'face 'show-paren-match)
                  (overlay-put ov2 'face 'show-paren-match)
                  (setq etaf-org-edit--pair-overlays (list ov1 ov2)))))))))))))

(defvar-local etaf-org-edit-mode nil
  "Non-nil when `etaf-org-edit-mode' authoring assistance is enabled.")

(add-to-list 'minor-mode-alist '(etaf-org-edit-mode " ETAF-Org"))

(defun etaf-org-insert-block (name)
  "Insert a `#+begin_NAME ... #+end_NAME' skeleton with required attributes."
  (let* ((entry (etaf-org--definition-by-name name))
         (def (cdr entry))
         (req (cl-loop for d in (plist-get def :attrs)
                       when (plist-get (cdr d) :required)
                       collect (format "%s \"\"" (symbol-name (car d)))))
         (header (if req
                     (format "#+begin_%s %s\n" name (string-join req " "))
                   (format "#+begin_%s\n" name))))
    (unless (bolp) (insert "\n"))
    (insert header)
    (let ((body-pos (point)))
      (insert "\n#+end_" name "\n")
      (goto-char body-pos))))

(defun etaf-org-edit-mode (&optional arg)
  "Toggle non-destructive authoring assistance for ETAF Org source buffers.
Not an interactive `M-x' command; call from Lisp or `org-mode-hook'.
With ARG omitted or `toggle', toggle the state; enable when ARG is positive
or non-nil, and disable when ARG is 0 or negative.  Adds soft syntax
highlighting, CAPF completion from `etaf-org-node-definitions', and bounded
`#+begin_' / `#+end_' pair matching without altering buffer text."
  (let ((enable (cond
                 ((or (null arg) (eq arg 'toggle))
                  (not etaf-org-edit-mode))
                 ((numberp arg) (> arg 0))
                 (t (not (null arg))))))
    (setq etaf-org-edit-mode enable)
    (if etaf-org-edit-mode
        (progn
          (font-lock-add-keywords nil etaf-org-edit--font-lock-keywords 'append)
          (add-hook 'completion-at-point-functions #'etaf-org-edit--capf nil t)
          (add-hook 'post-command-hook #'etaf-org-edit--highlight-pair nil t)
          (when font-lock-mode (font-lock-flush)))
      (font-lock-remove-keywords nil etaf-org-edit--font-lock-keywords)
      (remove-hook 'completion-at-point-functions #'etaf-org-edit--capf t)
      (remove-hook 'post-command-hook #'etaf-org-edit--highlight-pair t)
      (etaf-org-edit--clear-overlays)
      (when font-lock-mode (font-lock-flush)))
    etaf-org-edit-mode))

(provide 'etaf-org-edit)
;;; etaf-org-edit.el ends here
