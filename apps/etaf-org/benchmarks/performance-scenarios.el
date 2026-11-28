;;; performance-scenarios.el --- Org preview workloads -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; Register the preview's parsing, mount, folding and refit paths with the
;; shared performance driver.  Every fixture uses public APIs and the
;; maintained sample document.  Run one scenario with:
;;
;;   python3 scripts/performance.py run --mode batch \
;;     --scenario-file etaf-org/benchmarks/performance-scenarios.el \
;;     --scenario org.mount --diagnose

;;; Code:

(require 'cl-lib)
(require 'etaf)
(require 'etaf-org)
(declare-function taf-benchmark-register "performance-driver" (id &rest properties))

(defconst etaf-org-benchmark--file
  (expand-file-name "../examples/complete-gallery.org"
                    (file-name-directory (or load-file-name buffer-file-name)))
  "The maintained gallery document the scenarios render.")

(defun etaf-org-benchmark--text ()
  "Return the sample document as a string."
  (with-temp-buffer
    (insert-file-contents etaf-org-benchmark--file)
    (buffer-string)))

(taf-benchmark-register
 "org.parse" :version 1 :modes '(batch) :budget-ms 60
 :impact 'local :isolation 'series
 :description "Parse the maintained sample document headlessly"
 :setup
 (lambda (_mode)
   (let ((text (etaf-org-benchmark--text)))
     (list
      :invoke (lambda (_sample)
                (etaf-org-create :text text))
      :verify (lambda () t)
      :cleanup (lambda () nil)))))

(taf-benchmark-register
 "org.mount" :version 1 :modes '(batch gui) :budget-ms 260
 :impact 'local :isolation 'series
 :description "Create a session and mount the sample document"
 :setup
 (lambda (_mode)
   (let* ((buffer (generate-new-buffer " *TAF org mount*")))
     (list
      :buffer buffer
      :invoke
      (lambda (_sample)
        (let ((session (etaf-org-create
                        :file etaf-org-benchmark--file)))
          (etaf-mount buffer (etaf-org-view session)
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
 "org.fold" :version 1 :modes '(batch gui) :budget-ms 20
 :impact 'local :isolation 'series
 :description "Toggle one section's fold state on a mounted document"
 :setup
 (lambda (_mode)
   (let* ((buffer (generate-new-buffer " *TAF org fold*"))
          (session (etaf-org-create
                    :file etaf-org-benchmark--file))
          (id (nth 2 (car (etaf-org-outline session)))))
     (etaf-mount buffer (etaf-org-view session)
                 '(:viewport-width 900 :viewport-height 50))
     (list
      :buffer buffer
      :invoke
      (lambda (sample)
        (etaf-org-fold
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
 "org.edit" :version 1 :modes '(batch gui) :budget-ms 80
 :impact 'local :isolation 'series
 :description "Edit one paragraph and repaint the mounted document"
 :setup
 (lambda (_mode)
   (let* ((text (with-temp-buffer
                  (insert-file-contents etaf-org-benchmark--file)
                  (buffer-string)))
          (session (etaf-org-create :text text))
          (buffer (etaf-mount
                   (generate-new-buffer " *TAF org edit*")
                   (etaf-org-view session)
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
          (etaf-org-refresh session)
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
 "org.refit" :version 1 :modes '(batch gui) :budget-ms 25
 :impact 'local :isolation 'series
 :description "Refit the sample document across reading measures"
 :setup
 (lambda (_mode)
   (let* ((widths (vector 700 1100 800 1000 750 950))
          (session (etaf-org-create
                    :file etaf-org-benchmark--file))
          (buffer (etaf-mount
                   (generate-new-buffer " *TAF org refit*")
                   (etaf-org-view session)
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

(taf-benchmark-register
 "org.live-edit.paragraph" :version 1 :modes '(batch gui) :budget-ms 40
 :impact 'local :isolation 'series
 :description "Edit a single paragraph in a live source buffer and flush preview"
 :setup
 (lambda (_mode)
   (let* ((file (make-temp-file "etaf-org-bench-" nil ".org"
                                (etaf-org-benchmark--text)))
          (src (find-file-noselect file))
          (preview (etaf-org-open file))
          (edits 0))
     (list
      :buffer preview
      :invoke
      (lambda (sample)
        (with-current-buffer src
          (save-excursion
            (goto-char (point-min))
            (when (search-forward "标题与元数据" nil t)
              (forward-line 2)
              (delete-region (line-beginning-position) (line-end-position))
              (insert (format "实时段落更新第 %d 次。" sample)))))
        (with-current-buffer preview
          (etaf-org-reload))
        (cl-incf edits))
      :verify
      (lambda ()
        (cond
         ((not (buffer-live-p preview)) "Preview buffer died")
         ((zerop edits) "No live edits executed")
         (t t)))
      :cleanup
      (lambda ()
        (when (buffer-live-p preview)
          (with-current-buffer preview (etaf-org-close)))
        (when (buffer-live-p src)
          (with-current-buffer src (set-buffer-modified-p nil))
          (kill-buffer src))
        (when (file-exists-p file) (delete-file file)))))))

(provide 'performance-scenarios)
;;; performance-scenarios.el ends here
