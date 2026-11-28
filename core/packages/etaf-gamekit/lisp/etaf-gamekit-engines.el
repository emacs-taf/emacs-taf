;;; -*- lexical-binding: t; -*-
;;; etaf-gamekit-engines.el --- Install the engine runtimes GameKit launches

;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Commentary:
;; Godot and OpenSpiel are system programs, so the archive cannot ship them.  It
;; does ship each pinned setup script, and this module runs those scripts from
;; the installed package, so an archive installation reaches a working runtime
;; with one command.  The scripts verify what they install and write only under
;; the user cache; nothing here edits PATH or init files.

;;; Code:
(require 'cl-lib)

(defvar etaf-gamekit--directory)
(defvar etaf-gamekit-godot-program)
(defvar etaf-gamekit-openspiel-python-program)

(defconst etaf-gamekit--engine-log-buffer "*ETAF engine install*"
  "Buffer receiving progress from an engine setup run.")

(defconst etaf-gamekit--engine-targets
  '((godot "Godot" "native/godot/install-godot.py" etaf-gamekit-godot-program)
    (openspiel "OpenSpiel" "native/openspiel/install-openspiel.py"
               etaf-gamekit-openspiel-python-program))
  "Setup script and installed program of each engine GameKit can install.")

(defvar etaf-gamekit--engine-install-process nil
  "Engine setup process that is currently running, or nil.")

(defun etaf-gamekit--engine-target (engine)
  "Return the (LABEL SCRIPT PROGRAM) record of ENGINE."
  (or (cdr (assq engine etaf-gamekit--engine-targets))
      (error "Unknown engine: %s" engine)))

(defun etaf-gamekit--engine-setup-script (relative)
  "Return this package's setup script at RELATIVE, or nil.
Candidates are the directory this package loaded from, `locate-library' and the
installed package descriptor.  Native compilation moves `load-file-name' into
the byte-compilation cache, so a candidate counts only when it really holds the
script."
  (let* ((installed (car (alist-get 'etaf-gamekit (bound-and-true-p package-alist))))
         (candidates (delq nil
                           (list (and (boundp 'etaf-gamekit--directory) etaf-gamekit--directory)
                                 (let ((library (locate-library "etaf-gamekit")))
                                   (and library (file-name-directory library)))
                                 (and installed (fboundp 'package-desc-dir)
                                      (package-desc-dir installed))))))
    (cl-loop for directory in candidates
             for script = (expand-file-name relative directory)
             when (file-readable-p script)
             return script)))

(defun etaf-gamekit--engine-failure-line ()
  "Return the setup script's failure line from the current log buffer."
  (save-excursion
    (goto-char (point-max))
    (if (re-search-backward "^Engine setup failed:.*$" nil t)
        (match-string 0)
      (when (re-search-backward "[^[:space:]]" nil t)
        (buffer-substring (line-beginning-position) (line-end-position))))))

(defun etaf-gamekit--engine-install-sentinel (process _event)
  "Report the outcome of engine setup PROCESS and clear the running marker."
  (when (memq (process-status process) '(exit signal))
    (setq etaf-gamekit--engine-install-process nil)
    (let ((label (process-get process 'engine-label))
          (program (process-get process 'engine-program))
          (status (process-exit-status process))
          (log (process-buffer process)))
      (if (and (eq (process-status process) 'exit) (zerop status))
          (message "ETAF: %s runtime ready at %s; its games can start now"
                   label (or (executable-find program) program))
        (message "ETAF: %s install failed. %s See %s"
                 label
                 (or (and (buffer-live-p log)
                          (with-current-buffer log (etaf-gamekit--engine-failure-line)))
                     "The setup script exited without a report.")
                 etaf-gamekit--engine-log-buffer)))))

(defun etaf-gamekit--engine-install (engine &optional arguments)
  "Run the packaged setup script of ENGINE with ARGUMENTS in the background."
  (when (process-live-p etaf-gamekit--engine-install-process)
    (user-error "An engine install is already running; see %s"
                etaf-gamekit--engine-log-buffer))
  (let* ((target (etaf-gamekit--engine-target engine))
         (label (nth 0 target))
         (script (etaf-gamekit--engine-setup-script (nth 1 target)))
         (program (symbol-value (nth 2 target)))
         (python (executable-find "python3")))
    (unless script
      (user-error "This installation has no %s; reinstall etaf-gamekit" (nth 1 target)))
    (unless python
      (user-error "Python 3.9 or newer is required to install %s" label))
    (let* ((command (append (list python script) arguments))
           (buffer (get-buffer-create etaf-gamekit--engine-log-buffer)))
      (with-current-buffer buffer
        (let ((inhibit-read-only t))
          (erase-buffer)
          (insert (format "Installing the %s runtime: %s\n\n"
                          label (mapconcat #'identity command " "))))
        (setq default-directory (file-name-directory script)))
      (display-buffer buffer)
      (setq etaf-gamekit--engine-install-process
            (make-process :name (format "etaf-gamekit-install-%s" engine)
                          :buffer buffer
                          :command command
                          :noquery t
                          :sentinel #'etaf-gamekit--engine-install-sentinel))
      (process-put etaf-gamekit--engine-install-process 'engine-label label)
      (process-put etaf-gamekit--engine-install-process 'engine-program program)
      (message "ETAF: installing the %s runtime; progress in %s"
               label etaf-gamekit--engine-log-buffer))))

;;;###autoload
(defun etaf-gamekit-install-godot (&optional godot)
  "Install the pinned Godot runtime that GameKit games run.
GODOT registers an existing Godot 4.7 or newer executable instead of
downloading the pinned release.  The packaged setup script verifies the
release's SHA-256 before unpacking and writes only under
`~/.cache/emacs-taf/game-engines', honouring XDG_CACHE_HOME; it starts no
package manager and leaves PATH and init files alone.  Installation runs in the
background: progress goes to `etaf-gamekit--engine-log-buffer' and the echo
area reports the result.  One run happens at a time, and a failure keeps an
already working runtime in place."
  (interactive
   (list (and current-prefix-arg
              (expand-file-name (read-file-name "Godot 4.7 or newer: " nil nil t)))))
  (etaf-gamekit--engine-install 'godot (when godot (list "--godot" godot))))

;;;###autoload
(defun etaf-gamekit-install-openspiel (&optional python)
  "Install the pinned OpenSpiel environment that GameKit games run.
PYTHON selects the interpreter of the private cache environment instead of the
newest 3.11+ interpreter on PATH.  The packaged setup script creates
`~/.cache/emacs-taf/game-engines/openspiel', honouring XDG_CACHE_HOME, installs
the pinned release from `native/openspiel/requirements.txt', imports it to
verify the result, and replaces an older environment only after the new one
works.  Installation runs in the background: progress goes to
`etaf-gamekit--engine-log-buffer' and the echo area reports the result.  One
run happens at a time, and a failure keeps an already working environment in
place."
  (interactive
   (list (and current-prefix-arg
              (expand-file-name (read-file-name "Python 3.11 or newer: " nil nil t)))))
  (etaf-gamekit--engine-install 'openspiel (when python (list "--python" python))))

(provide 'etaf-gamekit-engines)
;;; etaf-gamekit-engines.el ends here
