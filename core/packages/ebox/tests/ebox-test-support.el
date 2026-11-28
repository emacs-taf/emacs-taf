;;; ebox-test-support.el --- Public Ebox test helpers -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(require 'ebox)

(defun ebox-test-native-width (string buffer)
  "Return STRING's width measured by Emacs with BUFFER's face remapping.
This is the oracle for Ebox measurement on every supported Emacs version."
  (let ((remap (buffer-local-value 'face-remapping-alist buffer)))
    (with-temp-buffer
      (setq-local face-remapping-alist remap)
      (insert string)
      (car (buffer-text-pixel-size nil nil t)))))

(defun ebox-test-native-height (string buffer)
  "Return STRING's one-row height measured with BUFFER's face remapping."
  (let ((remap (buffer-local-value 'face-remapping-alist buffer)))
    (with-temp-buffer
      (setq-local face-remapping-alist remap)
      (insert string)
      (cdr (buffer-text-pixel-size nil nil t)))))

(defmacro ebox-test-with-tall-cjk (&rest body)
  "Run BODY with a CJK font taller than the Latin one, then restore.
Skips the test when the font is not installed on this machine."
  (declare (indent 0))
  `(let* ((frame (selected-frame))
          (range '(#x4e00 . #x9fff))
          (prior (fontset-font "fontset-default" #x4e00)))
     (skip-unless (find-font (font-spec :family "Noto Serif CJK SC")))
     (unwind-protect
         (progn
           (set-fontset-font "fontset-default" range
                             (font-spec :family "Noto Serif CJK SC") frame)
           ,@body)
       (set-fontset-font "fontset-default" range
                         (and prior
                              (font-spec :family (car prior)
                                         :registry (cdr prior)))
                         frame))))

(defmacro ebox-test-with-mounted (spec &rest body)
  "Mount SPEC's input in a new buffer, bind its root, run BODY, then clean up.
SPEC has the form (BUFFER ROOT INPUT &rest OPTIONS)."
  (declare (indent 1))
  (let ((buffer (nth 0 spec))
        (root (nth 1 spec))
        (input (nth 2 spec))
        (options (nthcdr 3 spec)))
    `(let ((,buffer (generate-new-buffer " *ebox-test*")))
       (unwind-protect
           (let ((,root (ebox-mount ,buffer ,input ,@options)))
             (with-current-buffer ,buffer
               ,@body))
         (when (buffer-live-p ,buffer)
           (kill-buffer ,buffer))))))

(defun ebox-test-render-text (input)
  "Return INPUT's rendered text without text properties."
  (substring-no-properties (ebox-render input)))

(defun ebox-test-buffer-text (&optional buffer)
  "Return BUFFER's text without text properties."
  (with-current-buffer (or buffer (current-buffer))
    (buffer-substring-no-properties (point-min) (point-max))))

(defun ebox-test-buffer-string (&optional buffer)
  "Return BUFFER's text with properties."
  (with-current-buffer (or buffer (current-buffer))
    (buffer-substring (point-min) (point-max))))

(defun ebox-test-buffer-matches-render-p (root &optional buffer)
  "Whether BUFFER's propertized contents equal rendering ROOT now."
  (equal (ebox-test-buffer-string buffer) (ebox-render root)))

(defun ebox-test-first-face (string)
  "Return the face property on STRING's first character, if any."
  (and (> (length string) 0)
       (get-text-property 0 'face string)))

(defun ebox-test-face-plists (value)
  "Return the face plists in VALUE, a face property value."
  (cond ((null value) nil)
        ((and (listp value) (keywordp (car value))) (list value))
        ((listp value) (apply #'append (mapcar #'ebox-test-face-plists value)))
        (t nil)))

(provide 'ebox-test-support)
;;; ebox-test-support.el ends here
