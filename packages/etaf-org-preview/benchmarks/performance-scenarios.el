;;; performance-scenarios.el --- Org preview workloads -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; Register the preview's parsing, mount, folding and refit paths with the
;; shared performance driver.  Every fixture uses public APIs and the
;; maintained sample document.  Run one scenario with:
;;
;;   python3 scripts/performance.py run --mode batch \
;;     --scenario-file etaf-org-preview/benchmarks/performance-scenarios.el \
;;     --scenario org-preview.mount --diagnose

;;; Code:

(require 'cl-lib)
(require 'etaf)
(require 'etaf-org-preview)
(declare-function taf-benchmark-register "performance-driver" (id &rest properties))

(defconst etaf-org-preview-benchmark--file
  (expand-file-name "../examples/sample.org"
                    (file-name-directory (or load-file-name buffer-file-name)))
  "The maintained sample the scenarios render.")

(defun etaf-org-preview-benchmark--text ()
  "Return the sample document as a string."
  (with-temp-buffer
    (insert-file-contents etaf-org-preview-benchmark--file)
    (buffer-string)))

(taf-benchmark-register
 "org-preview.parse" :version 1 :modes '(batch) :budget-ms 60
 :impact 'local :isolation 'series
 :description "Parse the maintained sample document headlessly"
 :setup
 (lambda (_mode)
   (let ((text (etaf-org-preview-benchmark--text)))
     (list
      :invoke (lambda (_sample)
                (etaf-org-preview-create :text text))
      :verify (lambda () t)
      :cleanup (lambda () nil)))))

(taf-benchmark-register
 "org-preview.mount" :version 1 :modes '(batch gui) :budget-ms 260
 :impact 'local :isolation 'series
 :description "Create a session and mount the sample document"
 :setup
 (lambda (_mode)
   (let* ((buffer (generate-new-buffer " *TAF org mount*")))
     (list
      :buffer buffer
      :invoke
      (lambda (_sample)
        (let ((session (etaf-org-preview-create
                        :file etaf-org-preview-benchmark--file)))
          (etaf-mount buffer (etaf-org-preview-view session)
                      '(:viewport-width 900 :viewport-height 50))))
      :verify
      (lambda ()
        (with-current-buffer buffer
          (cond
           ((not (etaf-runtime-for-buffer buffer))
            "The preview runtime is not mounted")
           ((not (string-match-p "ETAF Org 预览" (buffer-string)))
            "The document title is missing")
           (t t))))
      :cleanup
      (lambda ()
        (when (buffer-live-p buffer)
          (with-current-buffer buffer
            (when (etaf-runtime-for-buffer buffer)
              (etaf-unmount)))
          (kill-buffer buffer)))))))

(taf-benchmark-register
 "org-preview.fold" :version 1 :modes '(batch gui) :budget-ms 20
 :impact 'local :isolation 'series
 :description "Toggle one section's fold state on a mounted document"
 :setup
 (lambda (_mode)
   (let* ((buffer (generate-new-buffer " *TAF org fold*"))
          (session (etaf-org-preview-create
                    :file etaf-org-preview-benchmark--file))
          (id (nth 2 (car (etaf-org-preview-outline session)))))
     (etaf-mount buffer (etaf-org-preview-view session)
                 '(:viewport-width 900 :viewport-height 50))
     (list
      :buffer buffer
      :invoke
      (lambda (sample)
        (etaf-org-preview-fold
         session id (if (cl-evenp sample) 'folded 'open)))
      :verify
      (lambda ()
        (with-current-buffer buffer
          (cond
           ((not (etaf-runtime-for-buffer buffer))
            "The preview runtime is not mounted")
           ((not (string-match-p "标题与元数据" (buffer-string)))
            "Folding removed the document")
           (t t))))
      :cleanup
      (lambda ()
        (when (buffer-live-p buffer)
          (with-current-buffer buffer
            (when (etaf-runtime-for-buffer buffer)
              (etaf-unmount)))
          (kill-buffer buffer)))))))

(taf-benchmark-register
 "org-preview.edit" :version 1 :modes '(batch gui) :budget-ms 80
 :impact 'local :isolation 'series
 :description "Edit one paragraph and repaint the mounted document"
 :setup
 (lambda (_mode)
   (let* ((text (with-temp-buffer
                  (insert-file-contents etaf-org-preview-benchmark--file)
                  (buffer-string)))
          (session (etaf-org-preview-create :text text))
          (buffer (etaf-mount
                   (generate-new-buffer " *TAF org edit*")
                   (etaf-org-preview-view session)
                   '(:viewport-width 900 :viewport-height 50)))
          (edited 0))
     (list
      :buffer buffer
      :invoke
      (lambda (sample)
        (let ((changed (replace-regexp-in-string
                        "标题与元数据"
                        (format "标题与元数据 %d" sample)
                        text t t)))
          (plist-put session :text changed)
          (etaf-org-preview-refresh session)
          (with-current-buffer buffer
            (etaf-runtime-flush (etaf-runtime-for-buffer buffer)))
          (cl-incf edited)))
      :verify
      (lambda ()
        (with-current-buffer buffer
          (cond
           ((not (etaf-runtime-for-buffer buffer))
            "The preview runtime is not mounted")
           ((zerop edited) "No edit was published")
           (t t))))
      :cleanup
      (lambda ()
        (when (buffer-live-p buffer)
          (with-current-buffer buffer
            (when (etaf-runtime-for-buffer buffer)
              (etaf-unmount)))
          (kill-buffer buffer)))))))

(taf-benchmark-register
 "org-preview.refit" :version 1 :modes '(batch gui) :budget-ms 25
 :impact 'local :isolation 'series
 :description "Refit the sample document across reading measures"
 :setup
 (lambda (_mode)
   (let* ((widths (vector 700 1100 800 1000 750 950))
          (session (etaf-org-preview-create
                    :file etaf-org-preview-benchmark--file))
          (buffer (etaf-mount
                   (generate-new-buffer " *TAF org refit*")
                   (etaf-org-preview-view session)
                   '(:viewport-width 900 :viewport-height 50)))
          (runtime (etaf-runtime-for-buffer buffer))
          (refits 0))
     (list
      :buffer buffer
      :invoke
      (lambda (sample)
        (when (etaf-runtime-refit runtime
                                  (aref widths (% sample (length widths))) 50)
          (cl-incf refits)))
      :verify
      (lambda ()
        (with-current-buffer buffer
          (cond
           ((not (etaf-runtime-for-buffer buffer))
            "The preview runtime is not mounted")
           ((zerop refits) "No refit changed the layout")
           (t t))))
      :cleanup
      (lambda ()
        (when (buffer-live-p buffer)
          (with-current-buffer buffer
            (when (etaf-runtime-for-buffer buffer)
              (etaf-unmount)))
          (kill-buffer buffer)))))))

(provide 'performance-scenarios)
;;; performance-scenarios.el ends here
