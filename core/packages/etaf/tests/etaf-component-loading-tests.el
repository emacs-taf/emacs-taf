;;; -*- lexical-binding: t; -*-
;;; etaf-component-loading-tests.el --- Library loading contracts

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Code:

(require 'etaf-test-support)
(require 'bytecomp)

(defun etaf-component-loading-test-write (file name &optional suffix)
  "Write a public Component NAME into FILE with optional SUFFIX."
  (with-temp-file file
    (insert ";;; -*- lexical-binding: t; -*-\n(require 'etaf)\n")
    (prin1 `(etaf-define-component ,name (&key label on-setup)
              :bindings ((count (etaf-ref 0)))
              :setup (funcall on-setup count)
              :view (text (expr (format "%s %d%s" label (etaf-value count) ,(or suffix "")))))
           (current-buffer))
    (insert "\n")))

(ert-deftest etaf-component-library-reload-retains-live-state ()
  "Source and bytecode reloads keep the definition and its mounted state."
  (let* ((directory (make-temp-file "etaf-component-load-" t))
         (file (expand-file-name "component.el" directory))
         (name (intern (make-temp-name "etaf-loading-")))
         (setups 0)
         state)
    (unwind-protect
        (progn
          (etaf-component-loading-test-write file name)
          (load file nil t t)
          (let* ((ready (lambda (value) (setq state value) (cl-incf setups)))
                 (view (etaf-ref (etaf-node name (list :label "first" :on-setup ready) nil))))
            (etaf-test-with-mount (runtime (etaf-view (fragment (expr (etaf-value view)))))
              (ignore runtime)
              (setf (etaf-value state) 7)
              (let ((byte-compile-error-on-warn t))
                (should (byte-compile-file file)))
              (load (byte-compile-dest-file file) nil t t)
              (load file nil t t)
              (setf (etaf-value view)
                    (etaf-node name (list :label "after" :on-setup ready) nil))
              (etaf-runtime-flush)
              (should (= setups 1))
              (should (string-match-p "after 7" (buffer-substring-no-properties (point-min) (point-max)))))))
      (delete-directory directory t))))

(ert-deftest etaf-component-library-conflicts-preserve-the-definition ()
  "Other libraries and changed declarations fail; deliberate replacement works."
  (let* ((directory (make-temp-file "etaf-component-conflict-" t))
         (file (expand-file-name "component.el" directory))
         (other (expand-file-name "other.el" directory))
         (name (intern (make-temp-name "etaf-loading-"))))
    (unwind-protect
        (progn
          (etaf-component-loading-test-write file name)
          (load file nil t t)
          (copy-file file other)
          (should-error (load other nil t t) :type 'etaf-component-call-error)
          (etaf-component-loading-test-write file name " changed")
          (should-error (load file nil t t) :type 'etaf-component-call-error)
          (etaf-test-with-mount (runtime (etaf-node name (list :label "old" :on-setup #'ignore) nil))
            (ignore runtime)
            (should (string-match-p "old 0" (buffer-substring-no-properties (point-min) (point-max))))
            (should-not (string-match-p "changed" (buffer-substring-no-properties (point-min) (point-max)))))
          (etaf-component-redefine-run (lambda () (load file nil t t)))
          (etaf-test-with-mount (runtime (etaf-node name (list :label "new" :on-setup #'ignore) nil))
            (ignore runtime)
            (should (string-match-p "new 0 changed" (buffer-substring-no-properties (point-min) (point-max))))))
      (delete-directory directory t))))

(ert-deftest etaf-component-evaluated-duplicates-retain-lexical-captures ()
  "Identical evaluated declarations are not library reloads or new captures."
  (let* ((name (intern (make-temp-name "etaf-evaluated-")))
         (definition `(etaf-define-component ,name () :view (text (expr captured))))
         (define (lambda (value)
                   (eval `(let ((captured ,value)) ,definition) t))))
    (funcall define "first")
    (should-error (funcall define "second") :type 'etaf-component-call-error)
    (etaf-test-with-mount (runtime (etaf-node name nil nil))
      (ignore runtime)
      (should (string-match-p "first" (buffer-substring-no-properties (point-min) (point-max)))))
    (etaf-component-redefine-run (lambda () (funcall define "replacement")))
    (etaf-test-with-mount (runtime (etaf-node name nil nil))
      (ignore runtime)
      (should (string-match-p "replacement" (buffer-substring-no-properties (point-min) (point-max)))))))

(provide 'etaf-component-loading-tests)
;;; etaf-component-loading-tests.el ends here
