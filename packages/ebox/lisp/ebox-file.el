;;; ebox-file.el --- Ebox file loading and preview -*- lexical-binding: t; -*-

;;; Commentary:

;; The core owns the file contract.  Playground may provide a richer view,
;; but loading an `.ebox' file must not require Playground.

;;; Code:

(require 'cl-lib)
(require 'elisp-mode)
(require 'subr-x)
(require 'ebox-node)
(declare-function ebox-render-to-buffer "ebox-buffer" (buffer-or-name input &rest options))
(defvar read-eval)

(defconst ebox-file--header "Ebox DSL  |  C-c C-c  Render preview")

(defun ebox-file-read-form (source)
  "Read exactly one Elisp expression from SOURCE."
  (when (string-empty-p (string-trim source))
    (user-error "The Ebox DSL source is empty"))
  (with-temp-buffer
    (set-syntax-table emacs-lisp-mode-syntax-table)
    (insert source)
    (goto-char (point-min))
    (let* ((read-eval nil)
          (form (read (current-buffer))))
      (forward-comment (point-max))
      (unless (eobp)
        (user-error "The Ebox source must contain one Elisp expression"))
      form)))

(defun ebox-file-load-companion (&optional file)
  "Load FILE's same-basename `.el' companion when it exists.
A compiled companion is used only when it is newer than the source."
  (when (and file (string= (file-name-extension file) "ebox"))
    (let ((base (file-name-sans-extension (expand-file-name file))))
      (when (file-readable-p (concat base ".el"))
        (let ((load-prefer-newer t))
          (load base nil t))))))

(defun ebox-file-read-file (file)
  "Read one Ebox expression from FILE without evaluating it."
  (unless (file-readable-p file)
    (user-error "Ebox DSL file is not readable: %s" file))
  (with-temp-buffer
    (insert-file-contents file)
    (ebox-file-read-form
     (buffer-substring-no-properties (point-min) (point-max)))))

(defun ebox-file--resolve-styles (dsl &optional companion-rules)
  "Snapshot file styles in DSL, adding COMPANION-RULES at its root.
File rules precede inline rules on the same Box.  No DSL data is evaluated."
  (if (not (and (consp dsl) (memq (car dsl) ebox--box-tags)))
      (if companion-rules
          (user-error "An ECSS companion requires a Box root")
        dsl)
    (let* ((split (ebox--dsl-split (cdr dsl)))
           (properties (car split))
           (file (plist-get properties :ecss-file))
           (rules (append companion-rules
                          (when file
                            (unless (stringp file)
                              (user-error ":ecss-file requires a file name"))
                            (ecss-file-read (expand-file-name file)))
                          (plist-get properties :ecss)))
           kept)
      (while properties
        (let ((key (pop properties)) (value (pop properties)))
          (unless (memq key '(:ecss :ecss-file))
            (setq kept (append kept (list key (list 'quote value)))))))
      (cons (car dsl)
            (append kept
                    (when rules (list :ecss (list 'quote rules)))
                    (mapcar #'ebox-file--resolve-styles (cdr split)))))))

(defun ebox-file-evaluate-form (form &optional source-file)
  "Evaluate FORM once, loading SOURCE-FILE companions and local styles.
Relative paths use SOURCE-FILE's directory.  The result is inert DSL data;
file styles are snapshots consumed by the ordinary local scope pipeline."
  (let* ((source-file (and source-file (expand-file-name source-file)))
         (default-directory (if source-file (file-name-directory source-file)
                              default-directory))
         (stylesheet (and source-file
                          (concat (file-name-sans-extension source-file) ".ecss"))))
    (ebox-file-load-companion source-file)
    (ebox-file--resolve-styles
     (eval form t)
     (when (and stylesheet (file-exists-p stylesheet))
       (ecss-file-read stylesheet)))))

(defun ebox-file-evaluate-buffer (&optional buffer)
  "Evaluate the Ebox expression in BUFFER through the core file contract."
  (with-current-buffer (or buffer (current-buffer))
    (ebox-file-evaluate-form
     (ebox-file-read-form
      (buffer-substring-no-properties (point-min) (point-max)))
     buffer-file-name)))

;;;###autoload
(defun ebox-file-preview (&optional buffer)
  "Render the `.ebox' source in BUFFER into a dedicated preview buffer."
  (interactive)
  (let* ((source (or buffer (current-buffer)))
         (file (buffer-file-name source))
         (name (format "*Ebox Preview: %s*" (or file (buffer-name source))))
         (node (ebox-build (ebox-file-evaluate-buffer source)))
         (preview (ebox-render-to-buffer name node)))
    (pop-to-buffer preview)
    preview))

(defvar ebox-dsl-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map emacs-lisp-mode-map)
    (define-key map (kbd "C-c C-c") #'ebox-file-preview)
    map))

;;;###autoload
(define-derived-mode ebox-dsl-mode emacs-lisp-mode "EboxDSL"
  "Major mode for Ebox DSL files."
  (setq-local header-line-format ebox-file--header)
  (setq-local truncate-lines nil)
  (setq-local bidi-display-reordering nil)
  (setq-local bidi-paragraph-direction 'left-to-right))

;;;###autoload
(add-to-list 'auto-mode-alist '("\\.ebox\\'" . ebox-dsl-mode))

;;;; Byte compilation

(defconst ebox--directory
  (file-name-directory
   (directory-file-name
    (file-name-directory (or load-file-name buffer-file-name))))
  "Root directory of the Ebox checkout.")

(defun ebox-byte-compile ()
  "Recompile every Ebox Lisp source into a neighboring `.elc' file.
Compiler output is written to `*Ebox Byte Compile*'.  Restart Emacs after a
successful build so the current process loads the new bytecode."
  (interactive)
  (require 'bytecomp)
  (let* ((sources (cons (expand-file-name "ebox.el" ebox--directory)
                        (directory-files (expand-file-name "lisp" ebox--directory)
                                         t "\\`ebox-.*\\.el\\'")))
         (byte-compile-log-buffer "*Ebox Byte Compile*")
         (load-prefer-newer t)
         failures)
    (dolist (source sources)
      (condition-case err
          (unless (byte-compile-file source)
            (push (file-name-nondirectory source) failures))
        (error
         (push (file-name-nondirectory source) failures)
         (message "[%s] %s" (file-name-nondirectory source) (error-message-string err)))))
    (if failures
        (error "Ebox byte compilation failed: %s"
               (mapconcat #'identity (nreverse failures) ", "))
      (message "Ebox byte compilation finished: %d files" (length sources)))))

(provide 'ebox-file)
;;; ebox-file.el ends here
