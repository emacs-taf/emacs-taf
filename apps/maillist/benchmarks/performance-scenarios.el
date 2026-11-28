;;; performance-scenarios.el --- Mailing-list client workloads -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Performance workloads for the client, registered with the workspace driver
;; (`scripts/performance.py').  Each scenario seeds a store through the public
;; store API and mounts the client over it with `maillist-open', so the samples
;; measure the client's own work: reading stored rows, opening a thread's
;; cached bodies and scanning them for a local search.

;;; Code:
(require 'cl-lib)
(require 'maillist)
(declare-function taf-benchmark-register "performance-driver" (id &rest properties))

(defun maillist-benchmarks--threads (count)
  "Return COUNT thread rows, each with three messages."
  (cl-loop for index below count
           collect (list :id (format "bench-%04d@example.com" index)
                         :subject (format "Thread %d: a patch under discussion" index)
                         :date (format "2026-10-%02d" (1+ (% index 28)))
                         :count 3
                         :depth 0
                         :author (format "Sender %d" (% index 7))
                         :participants 3)))

(defun maillist-benchmarks--messages (thread)
  "Return the three cached messages of THREAD."
  (cl-loop for position below 3
           collect (list :id (format "%s.%d" (plist-get thread :id) position)
                         :author (plist-get thread :author)
                         :email "sender@example.org"
                         :date (plist-get thread :date)
                         :depth position
                         :subject (plist-get thread :subject)
                         :text (concat (make-string 60 ?a)
                                       "\n\nA paragraph the reader wraps while "
                                       "rendering, repeated so the body has a "
                                       "realistic width.\n"))))

(defun maillist-benchmarks--seed (count bodies)
  "Write COUNT threads to a fresh store, their messages when BODIES is non-nil.
The store file is installed through `maillist-store-file' and the temp
directory it lives in is returned with it, for the fixture to delete."
  (let* ((directory (make-temp-file "maillist-bench-" t))
         (file (expand-file-name "cache.sqlite" directory))
         (maillist-store-file file)
         (rows (maillist-benchmarks--threads count))
         (store (maillist-store-open)))
    (maillist-store-save-threads store "bench" rows)
    (when bodies
      (dolist (row rows)
        (maillist-store-save-thread-messages
         store (plist-get row :id) (maillist-benchmarks--messages row))))
    (maillist-store-close store)
    (list directory file rows)))

(defun maillist-benchmarks--mount (file)
  "Open the client over the store at FILE from its cache and return it.
The buffer is returned with the session the mounted views read; no archive is
contacted, so a sample never waits on the network."
  (let* ((maillist-store-file file)
         (maillist-sources (list '(:name "bench"
                                   :base "http://127.0.0.1/"
                                   :address "bench@example.org")))
         (maillist-prefetch-threads 0)
         (maillist-auto-refresh nil)
         (buffer (maillist-open :sync nil :list "bench"))
         (session (plist-get (etaf-app-state (buffer-name buffer)) :session)))
    (list buffer session)))

(defun maillist-benchmarks--first-id (session)
  "Return the id of SESSION's first row."
  (plist-get (car (maillist-rows session)) :id))

(defun maillist-benchmarks--finish (buffer directory)
  "Close BUFFER and delete the fixture at DIRECTORY."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (ignore-errors (maillist-close))))
  (when (and directory (file-directory-p directory))
    (ignore-errors (delete-directory directory t))))

(taf-benchmark-register
 "maillist.scroll" :version 1 :modes '(batch gui) :budget-ms 150
 :impact 'local :isolation 'series
 :description "Move the selection through a three-hundred-thread list"
 :setup
 (lambda (_mode)
   (pcase-let* ((`(,directory ,file ,_rows) (maillist-benchmarks--seed 300 t))
                (`(,buffer ,session) (maillist-benchmarks--mount file))
                (direction 1)
                (expected (maillist-benchmarks--first-id session)))
     (list
      :buffer buffer
      :invoke
      (lambda (_sample)
        (let ((before (etaf-value (plist-get session :selected))))
          (maillist-move session direction)
          (setq expected (etaf-value (plist-get session :selected)))
          ;; The selection stops at an end; turn around and move once more so
          ;; every sample does the work it names.
          (when (equal before expected)
            (setq direction (- direction))
            (maillist-move session direction)
            (setq expected (etaf-value (plist-get session :selected))))))
      :verify
      (lambda ()
        (and (equal expected (etaf-value (plist-get session :selected)))
             (= 300 (length (maillist-rows session)))
             (= 3 (length (plist-get session :open-messages)))
             (with-current-buffer buffer
               (not (null (string-match-p "300 个线程"
                                          (buffer-substring-no-properties
                                           (point-min) (point-max))))))))
      :cleanup (lambda () (maillist-benchmarks--finish buffer directory))))))

(taf-benchmark-register
 "maillist.open-thread" :version 1 :modes '(batch gui) :budget-ms 200
 :impact 'local :isolation 'series
 :description "Open one thread after another from a three-hundred-thread list"
 :setup
 (lambda (_mode)
   (pcase-let* ((`(,directory ,file ,rows) (maillist-benchmarks--seed 300 t))
                (`(,buffer ,session) (maillist-benchmarks--mount file))
                (expected nil)
                (index 0))
     (list
      :buffer buffer
      :invoke
      (lambda (_sample)
        (setq index (% (1+ index) 300)
              expected (plist-get (nth index rows) :id))
        (maillist-select session expected))
      :verify
      (lambda ()
        (and (equal expected
                    (plist-get (etaf-value (plist-get session :open)) :id))
             (= 3 (length (plist-get session :open-messages)))))
      :cleanup (lambda () (maillist-benchmarks--finish buffer directory))))))

(taf-benchmark-register
 "maillist.search" :version 1 :modes '(batch gui) :budget-ms 200
 :impact 'local :isolation 'series
 :description "Search nine hundred cached bodies for a word they all carry"
 :setup
 (lambda (_mode)
   (pcase-let* ((`(,directory ,file ,_rows) (maillist-benchmarks--seed 300 t))
                (`(,buffer ,session) (maillist-benchmarks--mount file))
                (store (plist-get session :store))
                (hits 0))
     (list
      :buffer buffer
      :invoke
      (lambda (_sample)
        (setq hits (length (maillist-store-search-bodies store "paragraph" 40))))
      :verify (lambda () (= 40 hits))
      :cleanup (lambda () (maillist-benchmarks--finish buffer directory))))))

(provide 'maillist-performance-scenarios)
;;; performance-scenarios.el ends here
