;;; ebox-release-smoke.el --- Isolated package installation smoke -*- lexical-binding: t; -*-

;;; Commentary:
;; Invoked by scripts/ebox-release.py verify in a disposable user directory.
;; No source checkout or sibling package may enter this process's load-path.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'package)
(require 'bytecomp)

(let* ((archive (getenv "EBOX_RELEASE_ARCHIVE"))
       (profile (getenv "EBOX_RELEASE_PROFILE"))
       (manifest (with-temp-buffer
                   (insert-file-contents (expand-file-name "manifest.json" archive))
                   (json-parse-buffer :object-type 'alist :array-type 'list)))
       (packages (alist-get 'packages manifest)))
  (unless (and archive profile)
    (error "Run through the release verification entry point"))
  (setq user-emacs-directory (file-name-as-directory profile)
        package-user-dir (expand-file-name "elpa" profile)
        package-archives (list (cons "ebox-release" (file-name-as-directory archive)))
        package-check-signature nil
        package-directory-list nil
        native-comp-jit-compilation nil)
  (package-initialize)
  (package-refresh-contents)
  (let* (compile-issues
         (capture-warning
          (lambda (message &rest _)
            (when (and byte-compile-current-file
                       (string-match-p "\\`ebox.*\\.el\\'"
                                       (file-name-nondirectory byte-compile-current-file))
                       ;; package.el owns generated descriptor/autoload compilation.
                       (not (string-match-p "-\\(?:pkg\\|autoloads\\)\\.el\\'"
                                            byte-compile-current-file)))
              (push (format "%s: %s" (file-name-nondirectory byte-compile-current-file)
                            message) compile-issues)))))
    (unwind-protect
        (progn
          (advice-add 'byte-compile-log-warning :before capture-warning)
          (package-install 'ebox)
          (when (seq-some (lambda (entry) (equal (alist-get 'name entry) "ekp")) packages)
            (package-install 'ekp)))
      (advice-remove 'byte-compile-log-warning capture-warning))
    (when compile-issues
      (error "Installed Ebox compilation diagnostics:\n%s"
             (mapconcat #'identity (nreverse compile-issues) "\n"))))
  (dolist (command '(ebox-build ebox-render ebox-next-interaction ebox-previous-interaction))
    (unless (fboundp command)
      (error "Installed autoload registry omitted %s" command)))
  (require 'ebox)
  (dolist (feature '(ecss ebox))
    (let ((library (locate-library (symbol-name feature))))
      (unless (and (featurep feature) library
                   (file-in-directory-p library package-user-dir))
        (error "Package escaped the clean installation: %s" feature))))
  (when (featurep 'etaf)
    (error "Standalone installation unexpectedly loaded ETAF"))
  (let ((buffer (generate-new-buffer " *ebox-release-smoke*")))
    (unwind-protect
        (let* ((root (ebox-mount buffer '(column
                                          (box :id "counter" :class "value" "before")
                                          (box "unchanged"))
                                 :width 400 :height 10))
               (counter (car (ebox-selector-query root "#counter"))))
          (dotimes (index 30)
            (ebox-node-set-text (ebox-node-child counter 0) (format "after %02d" index)))
          (with-current-buffer buffer
            (unless (and (string-match-p "after 29" (buffer-string))
                         (string-match-p "unchanged" (buffer-string))
                         (not (string-match-p "before" (buffer-string)))
                         (= 1 (length (ebox-selector-query-buffer buffer ".value"))))
              (error "Installed render/update/selector smoke failed"))))
      (kill-buffer buffer)))
  (unless (string-match-p "first" (ebox-render '(box :width (ch 10) "first")))
    (error "Installed string rendering failed"))
  (if (assoc "ekp" (mapcar (lambda (entry) (cons (alist-get 'name entry) entry)) packages))
      (let ((calls 0))
        (require 'ekp)
        (let ((probe (lambda (&rest _) (cl-incf calls))))
          (unwind-protect
              (progn
                (advice-add 'ekp-pixel-justify :before probe)
                (ebox-render (ebox-build '(box :width (ch 12) :wrap-mode kp
                                              "one two three four five six seven")))
                (unless (> calls 0)
                  (error "KP installation did not invoke the real EKP provider")))
            (advice-remove 'ekp-pixel-justify probe))))
    (when (locate-library "ekp")
      (error "Default installation unexpectedly found optional EKP")))
  (princ (format "Clean installation OK: Emacs %s; render, update, selector; EKP %s\n"
                 emacs-version (if (featurep 'ekp) "verified" "absent"))))

;;; ebox-release-smoke.el ends here
