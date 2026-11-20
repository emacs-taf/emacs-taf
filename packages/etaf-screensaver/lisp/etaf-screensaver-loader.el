;;; etaf-screensaver-loader.el --- Loading scene spec files -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; Scenes and reels are data files.  Every *.esc file in
;; `etaf-screensaver-scene-directories' is read as one `(etaf-scene ...)'
;; form and registered by the DSL, and every *.esr file as one
;; `(etaf-reel ...)' form registered through its recording provider, so
;; adding a screensaver means dropping a file in a directory, never adding
;; Lisp.  Bundled scenes ship under lisp/scenes; the user directory overrides
;; a bundled scene with the same id.  Loading is tolerant: a broken file
;; reports and the rest load.

;;; Code:

(require 'cl-lib)
(require 'etaf-screensaver-model)
(require 'etaf-screensaver-dsl)
(require 'etaf-screensaver-reel)

(defun etaf-screensaver--bundled-scene-directories ()
  "Return the bundled reel and scene spec directories, in order."
  (when-let* ((library (locate-library "etaf-screensaver-loader")))
    (let ((directory (file-name-directory library)))
      (list (expand-file-name "reels" directory)
            (expand-file-name "scenes" directory)))))

(defcustom etaf-screensaver-scene-directories
  (append (etaf-screensaver--bundled-scene-directories)
          (list (locate-user-emacs-file "etaf-screensaver/scenes")))
  "Directories scanned for scene and reel spec files, in order.
Every *.esc file holds one `(etaf-scene ...)' form and every *.esr file one
`(etaf-reel ...)' form.  A later directory replaces a scene whose :id
already exists, so the user directory overrides a bundled scene of the same
id.  Bundled reels reference recorded animations shipped with the package."
  :type '(repeat directory)
  :group 'etaf-screensaver)

(defun etaf-screensaver--read-scene-file (file)
  "Read FILE as exactly one scene spec form and return it."
  (with-temp-buffer
    (insert-file-contents file)
    (goto-char (point-min))
    (let ((form (condition-case nil
                    (read (current-buffer))
                  (end-of-file
                   (etaf-screensaver--fail "Scene file is empty: %s" file))
                  (error
                   (etaf-screensaver--fail "Scene file is not readable: %s" file)))))
      (skip-chars-forward " \t\n")
      (unless (eobp)
        (etaf-screensaver--fail "Scene file holds more than one form: %s" file))
      form)))

(defun etaf-screensaver-load-scenes (&optional directories)
  "Load every scene and reel spec file in DIRECTORIES and return how many loaded.
DIRECTORIES defaults to `etaf-screensaver-scene-directories'.  Files load in
name order per directory and later directories replace earlier scenes whose
:id matches, so a user scene can override a bundled one.  A file that fails
to read or validate reports and is skipped; the other files still load."
  (interactive)
  (let ((directories (or directories etaf-screensaver-scene-directories))
        (count 0))
    (dolist (directory directories)
      (when (and directory (file-directory-p directory))
        (dolist (file (directory-files directory t "\\`[^.#].*\\.\\(?:esc\\|esr\\)\\'"))
          (condition-case problem
              (progn
                (if (equal (file-name-extension file) "esr")
                    (let ((etaf-screensaver--reel-directory
                           (file-name-directory file)))
                      (etaf-screensaver-register-reel
                       (etaf-screensaver--read-scene-file file)))
                  (etaf-screensaver-register-scene
                   (etaf-screensaver--read-scene-file file)))
                (cl-incf count))
            (error
             (message "etaf-screensaver: skipping %s: %s"
                      file (error-message-string problem)))))))
    count))

(provide 'etaf-screensaver-loader)
;;; etaf-screensaver-loader.el ends here
