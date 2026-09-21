;;; ecosystem.el --- Load the workspace checkout for development tools -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Every development tool in this workspace has to resolve the same child
;; checkouts, so tools must not hand-roll load paths, feature order or buffer
;; names.  Use this file as the single entry:
;;
;;   (load (expand-file-name "scripts/ecosystem" workspace-root) nil t t)
;;   (etaf-ecosystem-require 'etaf 'ebox 'etaf-ui)
;;
;; `etaf-ecosystem-root' defaults to the checkout that owns this file and can
;; be let-bound for another layout.  `etaf-ecosystem-load-path' lists every
;; child repository root and its `lisp' directory that actually exists, in the
;; dependency order recorded by `workspace.json'; `etaf-ecosystem-buffer' makes
;; per-run buffer names unique so repeated development runs never collide.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'subr-x)

(defvar etaf-ecosystem-root
  (file-name-directory
   (directory-file-name
    (file-name-directory (or load-file-name buffer-file-name))))
  "Workspace checkout that owns this file.")

(defconst etaf-ecosystem--order
  '(ecss ekp ebox etaf etaf-ui etaf-db etaf-desktop ebox-playground etaf-playground)
  "Child repositories in dependency order; unknown children load last.")

(defun etaf-ecosystem--repositories ()
  "Return the child repository names recorded in `workspace.json'."
  (let ((file (expand-file-name "workspace.json" etaf-ecosystem-root)))
    (when (file-readable-p file)
      (let ((json-object-type 'alist)
            (json-array-type 'list))
        (mapcar (lambda (name) (intern (symbol-name name)))
                (let (names)
                  (dolist (entry (alist-get 'repositories (json-read-file file)))
                    (push (car entry) names))
                  (nreverse names)))))))

(defun etaf-ecosystem-order (&optional repositories)
  "Return REPOSITORIES ordered by the recorded dependency order."
  (let ((names (or repositories (etaf-ecosystem--repositories))))
    (append (cl-remove-if-not (lambda (name) (memq name etaf-ecosystem--order))
                              etaf-ecosystem--order)
            (cl-remove-if (lambda (name) (memq name etaf-ecosystem--order)) names))))

(defun etaf-ecosystem-load-path (&optional repositories)
  "Return existing checkout directories for REPOSITORIES in load order."
  (let ((root (file-name-as-directory (expand-file-name etaf-ecosystem-root))))
    (cl-loop for name in (etaf-ecosystem-order repositories)
             for directory = (expand-file-name (symbol-name name) root)
             append (cl-loop for candidate in (list directory
                                                    (expand-file-name "lisp" directory))
                             when (file-directory-p candidate)
                             collect (file-name-as-directory candidate)))))

(defun etaf-ecosystem-setup (&optional repositories)
  "Add the workspace child checkouts to `load-path' and return them.
Early repositories win, so the caller's own checkout is never shadowed by a
stale copy elsewhere in `load-path'."
  (dolist (directory (reverse (etaf-ecosystem-load-path repositories)))
    (add-to-list 'load-path directory))
  load-path)

(defun etaf-ecosystem-require (&rest features)
  "Put the workspace child checkouts on `load-path' and require FEATURES.
Signal a loading error naming FEATURES when a module cannot be found."
  (etaf-ecosystem-setup)
  (dolist (feature features)
    ;; Runnable examples that are not on `load-path' yet are published under a
    ;; child's examples directory; add those lazily before reporting failure.
    (unless (or (require feature nil t)
                (progn
                  (dolist (directory (reverse (etaf-ecosystem--example-paths)))
                    (add-to-list 'load-path directory))
                  (require feature nil t)))
      (error "Cannot load %s from %s: check the checkout and its dependencies"
             feature etaf-ecosystem-root)))
  features)

(defun etaf-ecosystem--example-paths ()
  "Return existing runnable example directories of the child checkouts."
  (let ((root (file-name-as-directory (expand-file-name etaf-ecosystem-root))))
    (cl-loop for name in (etaf-ecosystem-order)
             for path = (expand-file-name (format "%s/examples" (symbol-name name))
                                          root)
             when (file-directory-p path)
             collect (file-name-as-directory path))))

(defun etaf-ecosystem-buffer (name)
  "Return a fresh buffer named NAME with the run counter appended.
Development tools call this instead of `generate-new-buffer-name' so the name
stays readable and two runs never share a mounted surface."
  (let ((counter 1) candidate)
    (while (get-buffer (setq candidate (format "%s %d" name counter)))
      (cl-incf counter))
    candidate))

(provide 'ecosystem)
;;; ecosystem.el ends here
