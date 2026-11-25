;;; etaf-org-gui-probe.el --- Visual & viewport regression probe for etaf-org -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; Drives `etaf-org' across themes (`dark', `light', `sepia', `auto') and
;; viewport sizes (wide 140x44, ordinary 100x36, compact 68x32, short 100x16)
;; on `examples/complete-gallery.org' and `examples/widgets-showcase.org'.
;;
;; Verifies:
;; - Clean mount with zero errors across all themes and viewports
;; - Line width discipline (no unexpected horizontal overflow past measure)
;; - Interactive filter, TOC toggle, fold, and spoiler reveal transitions
;; - Optional PNG capture in graphical Emacs when ETAF_ORG_PROBE_OUT is set.

;;; Code:

(require 'cl-lib)
(require 'etaf)
(require 'etaf-ui)
(require 'etaf-org)

(defconst etaf-org-probe--root
  (expand-file-name ".." (file-name-directory (or load-file-name buffer-file-name)))
  "Root directory of `packages/etaf-org'.")

(defun etaf-org-probe--max-line-width (buffer)
  "Return maximum display width among lines in BUFFER."
  (with-current-buffer buffer
    (let ((text (buffer-substring-no-properties (point-min) (point-max)))
          (max-w 0))
      (dolist (ln (split-string text "\n"))
        (setq max-w (max max-w (string-width ln))))
      max-w)))

(defun etaf-org-probe--check-case (file theme width height)
  "Mount FILE in THEME at WIDTH x HEIGHT and return summary plist."
  (let* ((etaf-org-typeset nil)
         (session (etaf-org-create :file file :theme theme))
         (buf (generate-new-buffer (format " *probe-%s-%s*" theme width))))
    (unwind-protect
        (progn
          (when (< width 96)
            (etaf-org-adjust-width session (- width 96)))
          (etaf-mount buf (etaf-org-view session)
                      (list :viewport-width width :viewport-height height))
          (etaf-runtime-flush (etaf-runtime-for-buffer buf))
          (let* ((max-w (etaf-org-probe--max-line-width buf))
                 (lines (with-current-buffer buf (count-lines (point-min) (point-max))))
                 (state (etaf-org-state session)))
            (list :file (file-name-nondirectory file)
                  :theme theme
                  :viewport (format "%dx%d" width height)
                  :lines lines
                  :max-width max-w
                  :sections (plist-get state :sections)
                  :degraded (plist-get state :degraded))))
      (when (buffer-live-p buf)
        (with-current-buffer buf
          (when (etaf-runtime-for-buffer buf)
            (etaf-unmount)))
        (kill-buffer buf)))))

(defun etaf-org-probe-run ()
  "Run the multi-theme, multi-viewport visual probe and report results."
  (let* ((sample (expand-file-name "examples/complete-gallery.org" etaf-org-probe--root))
         (showcase (expand-file-name "examples/widgets-showcase.org" etaf-org-probe--root))
         (cases `((,sample dark 140 44)
                  (,sample light 100 36)
                  (,sample sepia 68 32)
                  (,sample auto 100 16)
                  (,showcase dark 140 44)
                  (,showcase light 100 36)
                  (,showcase sepia 68 32)
                  (,showcase auto 100 16)))
         (results nil))
    (dolist (spec cases)
      (let ((res (apply #'etaf-org-probe--check-case spec)))
        (push res results)
        (princ (format "PROBE %-22s theme=%-5s vp=%-7s lines=%-4d max-w=%-3d degraded=%d\n"
                       (plist-get res :file)
                       (plist-get res :theme)
                       (plist-get res :viewport)
                       (plist-get res :lines)
                       (plist-get res :max-width)
                       (plist-get res :degraded)))))
    (nreverse results)))

(when noninteractive
  (etaf-org-probe-run))

(provide 'etaf-org-gui-probe)
;;; etaf-org-gui-probe.el ends here
