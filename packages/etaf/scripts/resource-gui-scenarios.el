;;; resource-gui-scenarios.el --- Resource example GUI acceptance -*- lexical-binding: t; -*-

;;; Commentary:
;; Drive the shipped asynchronous example through Emacs-local RET and the
;; shared verifier. Timings cover request initiation, not async completion.

;;; Code:
(require 'etaf)
(require 'emacs-gui-verifier)

(defun etaf-resource-gui--shows (context text)
  "Return non-nil when CONTEXT's example currently displays TEXT."
  (with-current-buffer (etaf-gui-verifier-context-target-buffer context)
    (string-match-p (regexp-quote text) (buffer-string))))

(defun etaf-resource-gui--press (context ref)
  "Activate REF through the example's native RET binding in CONTEXT."
  (let* ((buffer (etaf-gui-verifier-context-target-buffer context))
         (runtime (etaf-runtime-for-buffer buffer)))
    (with-current-buffer buffer
      (etaf-focus runtime ref)
      (execute-kbd-macro (kbd "RET")))))

(defun etaf-resource-gui-run (directory &optional screenshots)
  "Verify the Resource example in DIRECTORY, optionally taking SCREENSHOTS.
Use the existing Emacs frame and leave the example visible without activating
the application. DIRECTORY must be fresh. This records functional acceptance;
screenshots require review and timings do not certify async completion latency."
  (etaf-gui-verifier-run
   (etaf-gui-verifier-scenario-create
    :name "resource-lifecycle"
    :claim "Native asynchronous Resource loading, refresh, cancellation and cleanup"
    :initialize (lambda (context)
                  (etaf-resource-example-close)
                  (etaf-gui-verifier-context-select-buffer context (etaf-resource-example-open)))
    :invariants
    (lambda (context)
      (list (etaf-gui-verifier-assert
             "mounted example"
             (not (null (etaf-runtime-for-buffer
                         (etaf-gui-verifier-context-target-buffer context)))))))
    :actions
    (mapcar
     (lambda (spec)
       (let ((id (nth 0 spec)) (execute (nth 1 spec)) (expected (nth 2 spec)))
         (etaf-gui-verifier-action-create
          :id id :execute execute :screenshot screenshots
          :settled-p (lambda (context) (etaf-resource-gui--shows context expected))
          :assertions (lambda (context)
                        (list (etaf-gui-verifier-assert
                               expected (etaf-resource-gui--shows context expected)))))))
     (list
      (list "first-load" #'ignore "Generation 1 is healthy.")
      (list "refresh"
            (lambda (context)
              (etaf-resource-gui--press context 'resource-reload)
              (unless (and (etaf-resource-gui--shows context "REFRESHING")
                           (etaf-resource-gui--shows context "Generation 1 is healthy."))
                (error "Refresh did not retain the last successful value")))
            "Generation 2 is healthy.")
      (list "cancel"
            (lambda (context)
              (etaf-resource-gui--press context 'resource-reload)
              (etaf-resource-gui--press context 'resource-cancel))
            "CANCELLED")
      (list "retry"
            (lambda (context) (etaf-resource-gui--press context 'resource-reload))
            "Generation 4 is healthy.")
      (list "failure"
            (lambda (context) (etaf-resource-gui--press context 'resource-fail))
            "Synthetic service failure 5")
      (list "recover"
            (lambda (context) (etaf-resource-gui--press context 'resource-reload))
            "Generation 6 is healthy.")
      (list "replace-pending-owner"
            (lambda (context)
              (etaf-resource-gui--press context 'resource-reload)
              (etaf-resource-example-close)
              (etaf-gui-verifier-context-select-buffer context (etaf-resource-example-open)))
            "Generation 1 is healthy."))))
   directory))

(provide 'resource-gui-scenarios)
;;; resource-gui-scenarios.el ends here
