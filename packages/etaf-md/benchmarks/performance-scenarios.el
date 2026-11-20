;;; performance-scenarios.el --- Independent preview workloads -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; Register the preview's window-resize and mount paths with the shared
;; performance driver.  The fixtures mount the maintained user manual and
;; refit it across widths; every operation uses public APIs.  Run it with:
;;
;;   python3 scripts/performance.py run --mode batch \
;;     --scenario-file etaf-md/benchmarks/performance-scenarios.el \
;;     --scenario md-preview.refit.width --diagnose
;;
;; `md-preview.republish.diagrams` guards the picture path: a page's generated
;; mermaid configuration is a per-page constant, and building it once per
;; diagram cost every republish five seconds.

;;; Code:

(require 'cl-lib)
(require 'etaf)
(require 'etaf-md)
(declare-function taf-benchmark-register "performance-driver" (id &rest properties))

(defconst etaf-md-benchmark--file
  (expand-file-name "../examples/sample.markdown"
                    (file-name-directory (or load-file-name buffer-file-name)))
  "The maintained manual the resize scenario refits.")

(defconst etaf-md-benchmark--widths
  (vector 700 1100 800 1000 750 950)
  "Widths the resize scenario cycles through, in pixels.")

(taf-benchmark-register
 "md-preview.refit.width" :version 1 :modes '(batch gui) :budget-ms 10
 :impact 'local :isolation 'series
 :description "User manual width refit through the retained Ebox tree"
 :setup
 (lambda (_mode)
   (let* ((session (etaf-md-create :file etaf-md-benchmark--file))
          (sink nil)
          (refits 0)
          (buffer (etaf-mount "*TAF md-preview refit*"
                              (etaf-md-view session)
                              (list :viewport-width 900 :viewport-height 50
                                    :observer (lambda (report)
                                                (when sink (funcall sink report))))))
          (runtime (etaf-runtime-for-buffer buffer)))
     (list
      :buffer buffer
      :invoke
      (lambda (sample)
        (when (etaf-runtime-refit
               runtime
               (aref etaf-md-benchmark--widths
                     (% sample (length etaf-md-benchmark--widths)))
               50)
          (cl-incf refits)))
      :verify
      (lambda ()
        (with-current-buffer buffer
          (cond
           ((not (etaf-runtime-for-buffer buffer))
            "The preview runtime is not mounted")
           ((not (string-match-p "ETAF Markdown Preview 用户手册" (buffer-string)))
            "The manual's title is missing after a refit")
           ((zerop refits) "No refit changed the layout")
           (t t))))
      :observe
      (lambda (observer)
        (setq sink observer)
        (lambda () (setq sink nil)))
      :cleanup
      (lambda ()
        (when (buffer-live-p buffer) (kill-buffer buffer)))))))

(taf-benchmark-register
 "md-preview.mount.manual" :version 1 :modes '(batch gui) :budget-ms 100
 :impact 'local
 :description "Parse and mount the complete manual into a fresh buffer"
 :setup
 (lambda (mode)
   (let ((buffer (generate-new-buffer " *TAF md-preview mount*"))
         sink)
     (list
      :buffer buffer
      :invoke
      (lambda (_sample)
        (let ((session (etaf-md-create :file etaf-md-benchmark--file)))
          (etaf-mount
           buffer (etaf-md-view session)
           (append
            (when (eq mode 'batch) '(:viewport-width 900 :viewport-height 50))
            (list :observer
                  (lambda (observed-report)
                    (when sink (funcall sink buffer observed-report))))))))
      :verify
      (lambda ()
        (with-current-buffer buffer
          (cond
           ((not (etaf-runtime-for-buffer buffer)) "The manual did not mount")
           ((not (string-match-p "ETAF Markdown Preview 用户手册"
                                (buffer-substring-no-properties (point-min) (point-max))))
            "The mounted manual has no title")
           (t t))))
      :observe (lambda (observer)
                 (setq sink observer)
                 (lambda () (setq sink nil)))
      :cleanup (lambda ()
                 (when (buffer-live-p buffer) (kill-buffer buffer)))))))

(defconst etaf-md-benchmark--diagram-file
  (expand-file-name "../examples/all-syntax.markdown"
                    (file-name-directory (or load-file-name buffer-file-name)))
  "The page that writes every diagram kind, used by the picture workload.")

(taf-benchmark-register
 "md-preview.republish.diagrams" :version 1 :modes '(batch gui) :budget-ms 500
 :impact 'local
 :description "Republish the page that holds thirty-four diagrams after an edit"
 :setup
 (lambda (mode)
   ;; The page is mounted once, the way a reader opens it; the samples are the
   ;; republish a keystroke in the source costs.  Drawing is answered as
   ;; unavailable so the run never starts a browser: reading the cache and
   ;; keying every picture block is the part that regressed, and it is what
   ;; stays measured.
   (let* ((buffer (generate-new-buffer " *TAF md-preview diagrams*"))
          (session (cl-letf (((symbol-function 'etaf-md-typeset-available-p)
                              (lambda () nil)))
                     (etaf-md-create :file etaf-md-benchmark--diagram-file)))
          (sink nil))
     (etaf-mount
      buffer (etaf-md-view session)
      (append
       (when (eq mode 'batch) '(:viewport-width 900 :viewport-height 50))
       (list :observer
             (lambda (observed-report)
               (when sink (funcall sink buffer observed-report))))))
     (list
      :buffer buffer
      :invoke
      (lambda (_sample)
        (cl-letf (((symbol-function 'etaf-md-typeset-available-p)
                   (lambda () nil)))
          (etaf-md-refresh session)))
      :verify
      (lambda ()
        (with-current-buffer buffer
          (cond
           ((not (etaf-runtime-for-buffer buffer)) "The diagram page did not mount")
           ((not (string-match-p "Markdown 语法总览"
                                 (buffer-substring-no-properties (point-min) (point-max))))
            "The mounted page has no title")
           (t t))))
      :observe (lambda (observer)
                 (setq sink observer)
                 (lambda () (setq sink nil)))
      :cleanup (lambda ()
                 (when (buffer-live-p buffer) (kill-buffer buffer)))))))

(provide 'performance-scenarios)
;;; performance-scenarios.el ends here
