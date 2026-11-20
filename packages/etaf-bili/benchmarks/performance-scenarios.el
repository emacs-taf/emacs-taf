;;; -*- lexical-binding: t; -*-
;;; performance-scenarios.el --- Bili appearance and scroll workloads

;; SPDX-License-Identifier: GPL-3.0-or-later

(require 'etaf-bili)
(declare-function taf-benchmark-register "performance-driver" (id &rest properties))

(defun bili-performance--rows (count)
  "Build COUNT deterministic offline video rows."
  (cl-loop for index below count
           collect (list :bvid (format "BV%d" index)
                         :title (format "视频 %d · Emacs 与创作" index)
                         :author "创作者" :duration 120
                         :views "12000" :date "2026-10-13" :cover "")))

(taf-benchmark-register
 "bili.appearance" :version 1 :modes '(batch gui) :budget-ms 150
 :impact 'global :isolation 'series
 :description "Switch the appearance of a populated twenty-video library"
 :setup
 (lambda (_mode)
   (let* ((rows (bili-performance--rows 20))
          (etaf-bili-client-factory
           (lambda () (lambda (_request callback) (funcall callback (list :ok rows)))))
          (buffer (etaf-bili-open))
          (expected etaf-bili-theme-mode))
     (list :buffer buffer
           :invoke (lambda (_sample)
                     (setq expected (if (eq expected 'dark) 'light 'dark))
                     (with-current-buffer buffer (etaf-bili-toggle-theme)))
           :verify (lambda ()
                     (and (eq expected etaf-bili-theme-mode)
                          (buffer-live-p buffer)
                          (with-current-buffer buffer
                            (and (string-match-p "创作者"
                                                (buffer-substring-no-properties
                                                 (point-min) (point-max))) t))))
           :cleanup (lambda ()
                      (when (buffer-live-p buffer)
                        (with-current-buffer buffer (etaf-bili-close))))))))

(taf-benchmark-register
 "bili.scroll" :version 1 :modes '(batch gui) :budget-ms 150
 :impact 'local :isolation 'series
 :description "Scroll a hundred-video library through virtual row boundaries"
 :setup
 (lambda (_mode)
   (let* ((rows (bili-performance--rows 100))
          (etaf-bili-client-factory
           (lambda () (lambda (_request callback) (funcall callback (list :ok rows)))))
          (buffer (etaf-bili-open))
          (runtime (etaf-runtime-for-buffer buffer))
          (direction 1)
          (expected 0))
     (list :buffer buffer
           :invoke (lambda (_sample)
                     (let ((before (etaf-scroll-offset runtime 'bili-gallery)))
                       (setq expected (etaf-scroll-by runtime 'bili-gallery (* direction 10)))
                       (when (= expected before)
                         (setq direction (- direction)
                               expected (etaf-scroll-by runtime 'bili-gallery (* direction 10))))))
           :verify (lambda ()
                     (and (= expected (etaf-scroll-offset runtime 'bili-gallery))
                          (with-current-buffer buffer
                            (and (string-match-p "创作者"
                                                (buffer-substring-no-properties
                                                 (point-min) (point-max))) t))))
           :cleanup (lambda ()
                      (when (buffer-live-p buffer)
                        (with-current-buffer buffer (etaf-bili-close))))))))

(provide 'bili-performance-scenarios)
