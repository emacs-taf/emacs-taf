;;; performance-scenarios.el --- Video studio interaction latency -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Mounted keyboard interactions of the video studio: selecting a clip and
;; switching a details pane, each publishing the shell once.  The fixture
;; CLI is the repository's own acceptance fake and no decoder, network or
;; real project library is touched.  The workspace driver owns timing,
;; redisplay, sampling and evidence.

;;; Code:

(require 'cl-lib)
(require 'etaf-video-studio)
(declare-function taf-benchmark-register "performance-driver" (id &rest properties))

(defconst etaf-video-studio-benchmark--cli
  (expand-file-name "../tests/fixtures/fake-pi-skill"
                    (file-name-directory (or load-file-name buffer-file-name)))
  "Fixture executable resolved while this adapter is loaded.")

(defconst etaf-video-studio-benchmark--status
  "{\"ok\":true,\"id\":\"video-1\",\"title\":\"基准项目\",\"revision\":0,
    \"updated\":\"2026-10-13T00:00:00Z\",
    \"plan\":{\"version\":1,
              \"clips\":[{\"id\":\"clip-1\",\"file\":\"/tmp/bench-1.mp4\",\"in\":0,\"out\":5,\"speed\":1,\"gain\":1},
                        {\"id\":\"clip-2\",\"file\":\"/tmp/bench-2.mp4\",\"in\":1,\"out\":6,\"speed\":1,\"gain\":1},
                        {\"id\":\"clip-3\",\"file\":\"/tmp/bench-3.mp4\",\"in\":0,\"out\":4,\"speed\":1,\"gain\":1}],
              \"captions\":[{\"id\":\"caption-1\",\"start\":0,\"end\":2,\"text\":\"基准说明\"}]},
    \"timeline\":[],\"duration\":13,\"undo\":true,\"redo\":false,\"history\":[],
    \"tasks\":[]}"
  "Fixture project the benchmark CLI answers with.
The directory field is injected by the fixture writer so the project paths
stay inside the temporary library.")

(defun etaf-video-studio-benchmark--write (root)
  "Write the benchmark fixtures under ROOT and return ROOT."
  (let ((directory (expand-file-name "video-1" root)))
    (with-temp-file (expand-file-name "status.json" root)
      (insert (replace-regexp-in-string "\"revision\""
                                        (format "\"directory\":%s,\"revision\""
                                                (json-encode directory))
                                        etaf-video-studio-benchmark--status
                                        t t)))
    (with-temp-file (expand-file-name "list.json" root)
      (insert (format "{\"ok\":true,\"projects\":[{\"id\":\"video-1\",\"title\":\"基准项目\",\"directory\":%s,\"updated\":\"2026-10-13T00:00:00Z\",\"revision\":0}],\"root\":%s}"
                      (json-encode directory) (json-encode root)))))
  root)

(defun etaf-video-studio-benchmark--wait (buffer)
  "Wait until BUFFER's studio finished its CLI queries."
  (with-current-buffer buffer
    (let ((end (+ (float-time) 20)))
      (while (and (< (float-time) end)
                  (> (plist-get (etaf-video-studio-state) :pending) 0))
        (accept-process-output nil 0.05)))))

(defun etaf-video-studio-benchmark--fixture (kind)
  "Mount the studio with three clips and return a driver fixture of KIND.
KIND is `clip' to select clips or `pane' to switch details panes."
  (let* ((root (etaf-video-studio-benchmark--write
                (make-temp-file "video-studio-benchmark-" t)))
         (etaf-video-studio-executable etaf-video-studio-benchmark--cli)
         (etaf-video-studio-root root)
         (_ (setenv "FAKE_PI_SKILL_ROOT" root))
         (_ (setenv "FAKE_PI_SKILL_LOG" (expand-file-name "calls.jsonl" root)))
         (buffer (etaf-video-studio-open "video-1"))
         (expected 'preview)
         (sample 0))
    (with-current-buffer buffer
      (setq-local etaf-video-studio-executable etaf-video-studio-benchmark--cli))
    (etaf-video-studio-benchmark--wait buffer)
    (setq sample 0)
    (list
     :buffer buffer
     :environment (lambda () (list :mode (symbol-name kind) :clips 3 :offline t))
     :ready (lambda () t)
     :invoke
     (lambda (index)
       (setq sample index)
       (with-current-buffer buffer
         (if (eq kind 'clip)
             (etaf-video-studio-select-clip (if (cl-evenp index) 0 1))
           (let ((pane (if (cl-evenp index) 'properties 'captions)))
             (setq expected pane)
             (etaf-video-studio-select-pane pane)))))
     :verify
     (lambda ()
       (with-current-buffer buffer
         (let ((state (etaf-video-studio-state)))
           (if (eq kind 'clip)
               (or (= (if (cl-evenp sample) 0 1) (plist-get state :clip-index))
                   (format "clip index %S" (plist-get state :clip-index)))
             (or (eq expected (plist-get state :pane))
                 (format "pane %S" (plist-get state :pane)))))))
     :outcome
     (lambda ()
       (with-current-buffer buffer
         (let ((state (etaf-video-studio-state)))
           (list :pane (symbol-name (plist-get state :pane))
                 :clip-index (plist-get state :clip-index)))))
     :cleanup
     (lambda ()
       (when (buffer-live-p buffer)
         (with-current-buffer buffer (ignore-errors (etaf-video-studio-close))))
       (ignore-errors (delete-directory root t))))))

(taf-benchmark-register
 "video-studio.clip.select" :version 1 :modes '(batch gui) :isolation 'series
 :required-providers '(etaf) :budget-ms 150 :impact 'local
 :description "Select a clip and publish the studio shell"
 :setup (lambda (_mode) (etaf-video-studio-benchmark--fixture 'clip)))

(taf-benchmark-register
 "video-studio.pane.switch" :version 1 :modes '(batch gui) :isolation 'series
 :required-providers '(etaf) :budget-ms 150 :impact 'local
 :description "Switch the details pane and publish the studio shell"
 :setup (lambda (_mode) (etaf-video-studio-benchmark--fixture 'pane)))

;;; performance-scenarios.el ends here
