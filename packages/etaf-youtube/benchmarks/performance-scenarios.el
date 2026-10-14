;;; -*- lexical-binding: t; -*-
;;; performance-scenarios.el --- YouTube card interaction workload

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Offline account-shaped data exercises the public mounted application.
;; Selection alternates between two cards without network or media decoding.

;;; Code:
(require 'cl-lib)
(require 'json)
(require 'etaf)
(require 'etaf-youtube)
(declare-function taf-benchmark-register "performance-driver" (id &rest properties))

(defconst etaf-youtube-benchmark--fixture-file
  (expand-file-name "../tests/fixtures/responses.json"
                    (file-name-directory (or load-file-name buffer-file-name))))

(defun etaf-youtube-benchmark--setup (mode)
  "Mount a 36-card browsing surface for benchmark MODE."
  (let* ((fixtures (with-temp-buffer
                     (insert-file-contents etaf-youtube-benchmark--fixture-file)
                     (json-parse-buffer :object-type 'hash-table :array-type 'array
                                        :null-object nil :false-object :false)))
         (feed (gethash "feed home" fixtures))
         (sample (aref (gethash "items" feed) 0))
         (directory (make-temp-file "youtube-benchmark-" t))
         (buffer (generate-new-buffer " *YouTube benchmark*"))
         (step 0)
         (app nil))
    (puthash "items"
             (vconcat (cl-loop for i below 36 collect
                              (let ((item (copy-hash-table sample)))
                                (puthash "id" (format "bench-%d" i) item)
                                (puthash "thumbnail" "" item)
                                item))) feed)
    (setq app
          (etaf-youtube-create
           :store :none
           :images (etaf-youtube-images-create
                    :directory directory
                    :fetcher (lambda (_images _url _file callback)
                               (funcall callback "Artwork is not part of this offline workload")
                               #'ignore))
           :service (etaf-youtube-service-create
                     :runner
                     (lambda (argv callback)
                       (let* ((args (cddr argv))
                              (end (cl-position "--json" args :test #'equal))
                              (key (string-join (if end (seq-take args end) args) " "))
                              (payload (gethash key fixtures))
                              (timer (run-at-time
                                      0.001 nil callback
                                      (list :exit (if payload 0 3)
                                            :stdout (json-serialize
                                                     (or payload (list :ok :false
                                                                       :message key)))))))
                         (lambda () (cancel-timer timer)))))))
    (etaf-youtube-locate app 'home)
    (let ((until (+ (float-time) 3)))
      (while (and (< (plist-get (etaf-youtube-state app) :items) 36)
                  (< (float-time) until))
        (sleep-for 0.01)))
    (unless (= (plist-get (etaf-youtube-state app) :items) 36)
      (etaf-youtube-destroy app)
      (kill-buffer buffer)
      (delete-directory directory t)
      (error "YouTube benchmark did not load its 36-card fixture"))
    ;; Establish the selection before sampling; a fresh feed is unselected.
    (etaf-youtube-select app 0)
    (when (eq mode 'gui) (switch-to-buffer buffer))
    (etaf-mount buffer (etaf-youtube-view app)
                (when (eq mode 'batch) '(:viewport-width 1120 :viewport-height 36)))
    (list :buffer buffer
          :invoke (lambda (_sample)
                    (cl-incf step)
                    (etaf-youtube-select app (if (cl-oddp step) 1 -1))
                    (etaf-runtime-flush (etaf-runtime-for-buffer buffer)))
          :settled (lambda () t)
          :outcome (lambda () (list :selection (plist-get (etaf-youtube-state app) :selected)))
          :verify (lambda ()
                    (let* ((runtime (etaf-runtime-for-buffer buffer))
                           (banner (car (seq-find
                                         (lambda (entry) (eq (plist-get (cdr entry) :role) 'banner))
                                         (etaf-runtime-host-props-entries runtime))))
                           (height (and banner (cdr (etaf-host-ref-size runtime banner)))))
                      (if (and (equal height 5)
                               (= (plist-get (etaf-youtube-state app) :selected) (% step 2)))
                          t "Header or selection was not preserved")))
          :cleanup (lambda ()
                     (when-let* ((runtime (etaf-runtime-for-buffer buffer)))
                       (etaf-unmount runtime))
                     (etaf-youtube-destroy app)
                     (when (buffer-live-p buffer) (kill-buffer buffer))
                     (delete-directory directory t)))))

(taf-benchmark-register
 "etaf-youtube.browse.selection"
 :version 1 :modes '(batch gui) :budget-ms 50 :impact 'local
 :required-providers '(etaf-youtube etaf-ui)
 :description "Select a card in a 36-video feed while retaining the complete header"
 :setup #'etaf-youtube-benchmark--setup)

(provide 'etaf-youtube-performance-scenarios)
;;; performance-scenarios.el ends here
