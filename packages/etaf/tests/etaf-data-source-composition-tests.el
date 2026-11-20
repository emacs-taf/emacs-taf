;;; etaf-data-source-composition-tests.el --- Public source adapters -*- lexical-binding: t; -*-

;;; Commentary:
;; An adapted source retains storage and disposal while Data owns publication.

;;; Code:
(require 'ert)
(require 'etaf)

(ert-deftest etaf-data-source-capabilities-compose-async-storage-and-disposal ()
  "A capability snapshot supports async adaptation without a second store."
  (should-error (etaf-data-source-capabilities nil) :type 'wrong-type-argument)
  (let* ((memory (etaf-data-memory-source '((:id 1 :title "Before")) :id-key :id))
         (capabilities (etaf-data-source-capabilities memory))
         (load (plist-get capabilities :load))
         (mutate (plist-get capabilities :mutate))
         disposed controller)
    (setf (plist-get capabilities :load)
          (lambda (&rest args)
            (etaf-async
             (lambda (resolve _reject)
               (let ((timer (run-at-time 0.01 nil (lambda () (funcall resolve (apply load args))))))
                 (lambda () (cancel-timer timer))))))
          (plist-get capabilities :mutate-v2)
          (lambda (operation payload)
            (list :certainty 'committed :result (funcall mutate operation payload)))
          (plist-get capabilities :dispose) (lambda () (setq disposed t)))
    (should (eq load (plist-get (etaf-data-source-capabilities memory) :load)))
    (unwind-protect
        (progn
          (setq controller (etaf-data-controller (apply #'etaf-data-source capabilities)))
          (etaf-data-mutate controller 'update '(:id 1 :title "After"))
          (should (eq 'committed (plist-get (etaf-data-mutation-outcome controller) :certainty)))
          (let ((deadline (+ (float-time) 2)))
            (while (and (memq (etaf-value (etaf-data-status controller)) '(loading refreshing))
                        (< (float-time) deadline))
              (accept-process-output nil 0.01)))
          (should (eq 'success (etaf-value (etaf-data-status controller))))
          (should (equal '((:id 1 :title "After")) (etaf-value (etaf-data-items controller))))
          (should (equal '((:id 1 :title "After"))
                         (plist-get (etaf-data-source-load-page memory) :items))))
      (when controller (etaf-data-stop controller)))
    (should disposed)))

(provide 'etaf-data-source-composition-tests)
;;; etaf-data-source-composition-tests.el ends here
