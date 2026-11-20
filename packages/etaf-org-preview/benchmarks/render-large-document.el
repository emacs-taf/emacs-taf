;;; render-large-document.el --- Batch render baseline -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; Development benchmark for etaf-org-preview.  It generates a deterministic
;; Org document with SECTIONS headlines, then prints the time to parse it,
;; mount it, fold one section and refresh it, so a change can be compared with
;; a recorded baseline.  Run it with `make benchmark'; it is not part of the
;; public API and is not a gate.

;;; Code:

(require 'cl-lib)
(require 'etaf)
(require 'etaf-org-preview)

(defconst etaf-org-preview-benchmark-sections
  (string-to-number (or (getenv "ORG_PREVIEW_BENCH_SECTIONS") "120"))
  "Number of headlines the benchmark document contains.")

(defun etaf-org-preview-benchmark--document ()
  "Return the benchmark Org document."
  (mapconcat
   (lambda (index)
     (format (concat "* 第 %d 节 Section %d :tag%d:\n"
                     "  SCHEDULED: <2026-02-%02d Wed>\n"
                     ":PROPERTIES:\n:ID: section-%d\n:END:\n\n"
                     "This paragraph mentions *bold %d* and /italic/ with "
                     "=code= and a [[https://example.com/%d][link]].\n\n"
                     "- first item\n- second item\n  - nested item\n\n"
                     "| name | value |\n|------+-------|\n| a | %d |\n\n"
                     "#+BEGIN_SRC elisp\n(defun section-%d () %d)\n#+END_SRC\n\n")
             index index index
             (1+ (mod index 28)) index
             index index index index (1+ index)))
   (number-sequence 1 etaf-org-preview-benchmark-sections)
   "\n"))

(defun etaf-org-preview-benchmark--milliseconds (function)
  "Call FUNCTION once and return its elapsed milliseconds."
  (let ((start (float-time)))
    (funcall function)
    (* 1000.0 (- (float-time) start))))

(let* ((document (etaf-org-preview-benchmark--document))
       (session nil)
       (buffer nil)
       (parse-ms (etaf-org-preview-benchmark--milliseconds
                  (lambda () (setq session (etaf-org-preview-create :text document)))))
       (mount-ms (etaf-org-preview-benchmark--milliseconds
                  (lambda ()
                    (setq buffer (etaf-mount "*etaf-org-preview-benchmark*"
                                             (etaf-org-preview-view session)
                                             '(:viewport-width 900 :viewport-height 50))))))
       (id (nth 2 (car (etaf-org-preview-outline session))))
       (fold-ms (etaf-org-preview-benchmark--milliseconds
                 (lambda ()
                   (etaf-org-preview-fold session id 'folded)
                   (etaf-runtime-flush (etaf-runtime-for-buffer buffer)))))
       (changed (replace-regexp-in-string
                 "第 60 节 Section 60" "第 60 节 Section 60 已改" document t t))
       (refresh-ms (etaf-org-preview-benchmark--milliseconds
                    (lambda ()
                      (plist-put session :text changed)
                      (etaf-org-preview-refresh session)
                      (etaf-runtime-flush (etaf-runtime-for-buffer buffer))))))
  (unwind-protect
      (with-current-buffer buffer
        (princ (format (concat "sections=%d chars=%d lines=%d "
                               "parse=%.1fms mount=%.1fms fold=%.1fms "
                               "edit+repaint=%.1fms\n")
                       etaf-org-preview-benchmark-sections (length document)
                       (line-number-at-pos (point-max))
                       parse-ms mount-ms fold-ms refresh-ms)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (when (etaf-runtime-for-buffer buffer)
          (etaf-unmount)))
      (kill-buffer buffer))))

(provide 'render-large-document)
;;; render-large-document.el ends here
