;;; etaf-install-doctor.el --- Interactive capability doctor buffer -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Capability checks and the interactive `*ETAF Installation*' guide buffer.

;;; Code:

(require 'cl-lib)
(require 'package)
(require 'subr-x)
(require 'etaf-install-catalog)
(require 'etaf-install-native)

(declare-function etaf-install--manage-invalidate "etaf-install-manage" ())

;;; Interactive installation & doctor guide buffer

(defvar-local etaf-install--doctor-package nil
  "Target package currently displayed in `*ETAF Installation*'.")

(defvar-local etaf-install--doctor-copy-cmd nil
  "Combined shell command ready to copy from `*ETAF Installation*'.")

(defun etaf-install--doctor-copy-command ()
  "Copy the combined system install command in `*ETAF Installation*'."
  (unless (and (stringp etaf-install--doctor-copy-cmd)
               (not (string-empty-p etaf-install--doctor-copy-cmd)))
    (user-error "No system install command to copy for %s"
                (or etaf-install--doctor-package "this package")))
  (kill-new etaf-install--doctor-copy-cmd)
  (message "ETAF: copied install command: %s" etaf-install--doctor-copy-cmd))

(defun etaf-install--doctor-recheck ()
  "Re-run capability checks for the package shown in `*ETAF Installation*'."
  (let ((package (or etaf-install--doctor-package
                     (user-error "No ETAF package in this buffer"))))
    (let ((facts (etaf-install-doctor package)))
      (etaf-install--render-doctor-buffer package facts)
      (when-let* ((mgr (get-buffer "*ETAF Packages*"))
                  ((buffer-live-p mgr)))
        (with-current-buffer mgr
          (when (derived-mode-p 'etaf-install--manage-mode)
            (etaf-install--manage-invalidate)
            (tabulated-list-revert))))
      (if (plist-get facts :ready)
          (message "ETAF: %s is ready%s"
                   package
                   (if (and (package-installed-p package)
                            (nth 3 (etaf-install--target package)))
                       " — press `o' to open."
                     "."))
        (let ((missing (cl-remove-if #'cadr (plist-get facts :required))))
          (message "ETAF: %s still missing %s."
                   package (mapconcat #'car missing ", ")))))))

(defun etaf-install--doctor-open ()
  "Open the package shown in `*ETAF Installation*' when installed and ready."
  (let* ((package (or etaf-install--doctor-package
                      (user-error "No ETAF package in this buffer")))
         (target (etaf-install--target package))
         (open (nth 3 target)))
    (unless (package-installed-p package)
      (user-error "%s is not installed yet; run M-x etaf-install" package))
    (unless open
      (user-error "%s has no open command" package))
    (let* ((facts (etaf-install-doctor package))
           (missing (cl-remove-if #'cadr (plist-get facts :required))))
      (when missing
        (etaf-install--render-doctor-buffer package facts)
        (user-error "%s still requires %s" package (mapconcat #'car missing ", "))))
    (call-interactively open)))

(defun etaf-install--doctor-install-native ()
  "Install prebuilt native module(s) for the package in `*ETAF Installation*'."
  (let ((package (or etaf-install--doctor-package
                     (user-error "No ETAF package in this buffer"))))
    (etaf-install-native package)
    (etaf-install--render-doctor-buffer package (etaf-install-doctor package))))

(defvar etaf-install--doctor-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map special-mode-map)
    (define-key map (kbd "c")
      (lambda ()
        "Copy the combined system install command in `*ETAF Installation*'."
        (interactive)
        (etaf-install--doctor-copy-command)))
    (define-key map (kbd "r")
      (lambda ()
        "Re-run capability checks for the package in `*ETAF Installation*'."
        (interactive)
        (etaf-install--doctor-recheck)))
    (define-key map (kbd "o")
      (lambda ()
        "Open the package in `*ETAF Installation*' when installed and ready."
        (interactive)
        (etaf-install--doctor-open)))
    (define-key map (kbd "n")
      (lambda ()
        "Install prebuilt native module(s) for `*ETAF Installation*'."
        (interactive)
        (etaf-install--doctor-install-native)))
    map)
  "Keymap for `*ETAF Installation*' doctor guide buffer.")

(define-derived-mode etaf-install--doctor-mode special-mode "ETAF Doctor"
  "Major mode for the interactive `*ETAF Installation*' guide buffer."
  :interactive nil
  (setq-local truncate-lines nil))

(defun etaf-install--render-doctor-buffer (package facts)
  "Render PACKAGE's doctor FACTS into `*ETAF Installation*' and return buffer."
  (let* ((buf (get-buffer-create "*ETAF Installation*"))
         (required (plist-get facts :required))
         (optional (plist-get facts :optional))
         (missing-req (cl-remove-if #'cadr required))
         (missing-req-tools (etaf-install--missing-cli-tools-from-facts facts :required))
         (missing-opt-tools (etaf-install--missing-cli-tools-from-facts facts :optional))
         (pm (etaf-install--preferred-package-manager))
         (req-cmd (and missing-req-tools
                       (etaf-install--cli-combined-command missing-req-tools pm)))
         (opt-cmd (and (null req-cmd) missing-opt-tools
                       (etaf-install--cli-combined-command missing-opt-tools pm)))
         (copy-cmd (or req-cmd opt-cmd))
         (engine (and missing-req (etaf-install--missing-managed-engine package missing-req)))
         (installed-p (package-installed-p package))
         (open-cmd (nth 3 (etaf-install--target package)))
         (native-status (and installed-p (etaf-install--native-status package))))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (etaf-install--doctor-mode)
        (setq etaf-install--doctor-package package
              etaf-install--doctor-copy-cmd copy-cmd)
        (insert (propertize (format "ETAF installation: %s\n" package) 'face 'bold))
        (insert (propertize (format "Emacs %s on %s" emacs-version system-type) 'face 'shadow))
        (insert "   ")
        (if missing-req
            (insert (propertize
                     (format "Missing %d required item%s\n\n"
                             (length missing-req)
                             (if (= (length missing-req) 1) "" "s"))
                     'face 'warning))
          (insert (propertize
                   (if installed-p "Ready\n\n" "Prerequisites met (not installed yet)\n\n")
                   'face 'success)))
        (when (or req-cmd engine (eq native-status 'available)
                  (and installed-p (null missing-req) open-cmd))
          (insert (propertize "Quick actions\n" 'face 'bold))
          (when req-cmd
            (insert (format "  Install missing system CLI tools (%s):\n"
                            (or pm system-type)))
            (insert "    " (propertize req-cmd 'face 'font-lock-keyword-face) "\n"))
          (insert "  ")
          (when req-cmd
            (insert-text-button
             "[Copy command (c)]"
             'action (lambda (_btn) (etaf-install--doctor-copy-command))
             'follow-link t
             'help-echo "Copy the system install command to the kill ring")
            (insert "  "))
          (when (and engine (fboundp (cadr engine)))
            (let ((eng-cmd (cadr engine))
                  (eng-label (car engine)))
              (insert-text-button
               (format "[Install %s]" eng-label)
               'action (lambda (_btn) (call-interactively eng-cmd))
               'follow-link t
               'help-echo (format "Run M-x %s" eng-cmd))
              (insert "  ")))
          (when (eq native-status 'available)
            (insert-text-button
             "[Install native (n)]"
             'action (lambda (_btn) (etaf-install--doctor-install-native))
             'follow-link t
             'help-echo "Download and verify prebuilt native dynamic module(s)")
            (insert "  "))
          (insert-text-button
           "[Re-check (r)]"
           'action (lambda (_btn) (etaf-install--doctor-recheck))
           'follow-link t
           'help-echo "Re-run capability checks after installing tools")
          (when (and installed-p (null missing-req) open-cmd)
            (insert "  ")
            (insert-text-button
             (format "[Open %s (o)]" package)
             'action (lambda (_btn) (etaf-install--doctor-open))
             'follow-link t
             'help-echo (format "Run M-x %s" open-cmd)))
          (insert "\n\n"))
        (dolist (section (list (cons "Required" required) (cons "Optional" optional)))
          (insert (propertize (format "%s\n" (car section)) 'face 'bold))
          (dolist (fact (cdr section))
            (let ((avail (cadr fact)))
              (insert "  "
                      (propertize (if avail "✓" "✗")
                                  'face (if avail 'success
                                          (if (equal (car section) "Required")
                                              'warning 'shadow)))
                      (format " %s: %s\n" (car fact)
                              (if avail "available" "unavailable")))
              (unless avail
                (insert (propertize (format "    %s\n" (nth 2 fact)) 'face 'shadow)))))
          (insert "\n"))
        (when opt-cmd
          (insert (propertize "Optional system CLI install command\n" 'face 'bold))
          (insert "  " (propertize opt-cmd 'face 'font-lock-keyword-face) "  ")
          (insert-text-button
           "[Copy (c)]"
           'action (lambda (_btn) (etaf-install--doctor-copy-command))
           'follow-link t
           'help-echo "Copy the optional system CLI install command")
          (insert "\n\n"))
        (insert (propertize
                 "Keys: c copy command   r re-check   o open   n native   q quit\n"
                 'face 'shadow))
        (insert "Install: M-x etaf-install   Manage/update/remove: M-x etaf-install-manage\n")
        (insert "Restart Emacs after upgrading loaded packages.\n")
        (goto-char (point-min))))
    buf))

(defun etaf-install--display-doctor (package &optional facts)
  "Show PACKAGE's doctor FACTS in the interactive `*ETAF Installation*' buffer."
  (let* ((facts (or facts (etaf-install-doctor package)))
         (buf (etaf-install--render-doctor-buffer package facts)))
    (pop-to-buffer buf)
    buf))

(defun etaf-install-doctor (&optional package)
  "Check required and optional capabilities for PACKAGE without modifying state."
  (interactive (list (etaf-install--read-target)))
  (let* ((package (or package 'etaf-ui))
         (target (etaf-install--target package))
         (doctor-fn (intern (format "%s-doctor" package)))
         (required
          (list (list "Emacs 29.1 or newer" (not (version< emacs-version "29.1"))
                      "Use Emacs 29.1 or newer; your existing configuration is preserved.")))
         (optional
          (list (list "Native Lisp compilation"
                      (and (fboundp 'native-comp-available-p) (native-comp-available-p))
                      "Byte compilation works without it; a native-comp capable Emacs can improve speed."))))
    (if (fboundp doctor-fn)
        (let ((facts (funcall doctor-fn)))
          (setq required (append required (mapcar #'etaf-install--enrich-fact
                                                  (plist-get facts :required)))
                optional (append optional (mapcar #'etaf-install--enrich-fact
                                                  (plist-get facts :optional)))))
      ;; Before PACKAGE is installed, synthesize manual System CLI and managed
      ;; engine facts from the declarative catalog so users see prerequisites upfront.
      (when-let* ((entry (etaf-install--target-system-tools package)))
        (dolist (tool (plist-get entry :required))
          (let ((spec (cdr (assq tool etaf-install--cli-catalog))))
            (setq required
                  (append required
                          (list (list (or (plist-get spec :label) (symbol-name tool))
                                      (and (etaf-install--cli-installed-p tool) t)
                                      (etaf-install--cli-remedy tool)))))))
        (dolist (eng (plist-get entry :managed-engines))
          (setq required
                (append required
                        (list (list (car eng) nil
                                    (format "Install it once after installing %s: M-x %s"
                                            package (cadr eng)))))))
        (dolist (tool (plist-get entry :optional))
          (let ((spec (cdr (assq tool etaf-install--cli-catalog))))
            (setq optional
                  (append optional
                          (list (list (or (plist-get spec :label) (symbol-name tool))
                                      (and (etaf-install--cli-installed-p tool) t)
                                      (etaf-install--cli-remedy tool t)))))))))
    (when (memq 'sqlite (nthcdr 4 target))
      (push (list "SQLite built into Emacs"
                  (and (fboundp 'sqlite-available-p) (sqlite-available-p))
                  "Use an Emacs build with SQLite support; installing the sqlite3 executable is not sufficient.")
            required))
    (unless (eq package 'ekp)
      (push (list "Graphical display" (display-graphic-p)
                  "Terminal rendering is available, but graphical images require a graphical Emacs frame.")
            optional))
    (let ((result (list :package package
                        :ready (cl-every #'cadr required)
                        :required required :optional optional)))
      (when (called-interactively-p 'interactive)
        (etaf-install--display-doctor package result))
      result)))

(provide 'etaf-install-doctor)
;;; etaf-install-doctor.el ends here
