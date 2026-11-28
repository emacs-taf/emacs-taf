;;; -*- lexical-binding: t; -*-
;;; pointer-scenarios.el --- YouTube pointer paint workloads

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Run with the workspace performance.py --scenario-file pointing here and
;; --scenario 'etaf-youtube.pointer.*' --mode gui.  Reuse the offline 36-card
;; fixture; dispatch parameterized events through its mouse-movement binding.
;; These scenarios measure hover entry and exit, not physical pointer latency.

;;; Code:
(require 'cl-lib)
(require 'etaf)
(require 'etaf-youtube)
(declare-function taf-benchmark-register "performance-driver" (id &rest properties))
(declare-function etaf-youtube-benchmark--setup "performance-scenarios" (mode))

(load (expand-file-name "performance-scenarios"
                        (file-name-directory (or load-file-name buffer-file-name)))
      nil t)

(defun etaf-youtube-pointer--background (face)
  "Return the background in the rendered FACE value, or nil."
  (cond ((and (listp face) (keywordp (car face)))
         (plist-get face :background))
        ((listp face)
         (seq-some #'etaf-youtube-pointer--background face))
        ((and (symbolp face) (facep face))
         (let ((color (face-attribute face :background nil t)))
           (unless (eq color 'unspecified) color)))))

(defun etaf-youtube-pointer--setup (mode target)
  "Mount the shared browsing fixture in MODE to hover TARGET."
  (let* ((fixture (etaf-youtube-benchmark--setup mode))
         (buffer (plist-get fixture :buffer))
         (verify-selection (plist-get fixture :verify))
         (prepared nil) (position nil) (enter nil) (leave nil)
         (resting nil) (hover nil) (hovered nil))
    (setq fixture
          (plist-put
           fixture :prepare
           (lambda ()
             (unless prepared
               (with-current-buffer buffer
                 (let ((window (get-buffer-window buffer)))
                   (unless (window-live-p window)
                     (error "YouTube pointer fixture is not displayed"))
                   (setq position
                         (save-excursion
                           (goto-char (point-min))
                           (if (eq target 'navigation)
                               (search-forward "Shorts")
                             ;; The first card is selected; hover its neighbour.
                             (search-forward "测试视频一")
                             (search-forward "测试视频一"))
                           (match-beginning 0)))
                   (unless (pos-visible-in-window-p position window)
                     (error "YouTube pointer target is not visible"))
                   (setq enter (list 'mouse-movement
                                     (list window position '(0 . 0) 0))
                         leave (list 'mouse-movement
                                     (list window (point-min) '(0 . 0) 0)))
                   (funcall (key-binding [mouse-movement]) leave)
                   (setq resting (etaf-youtube-pointer--background
                                  (get-char-property position 'face))
                         hover (etaf-youtube-pointer--background
                                (get-char-property position 'mouse-face)))
                   (unless (and hover (not (equal hover resting)))
                     (error "YouTube pointer target has no distinct hover fill"))
                   (setq prepared t)))))))
    (setq fixture
          (plist-put fixture :invoke
                     (lambda (sample)
                       (setq hovered (cl-evenp sample))
                       (with-current-buffer buffer
                         (funcall (key-binding [mouse-movement])
                                  (if hovered enter leave))))))
    (setq fixture
          (plist-put fixture :verify
                     (lambda ()
                       (with-current-buffer buffer
                         (if (and (eq t (funcall verify-selection))
                                  (equal (etaf-youtube-pointer--background
                                          (get-char-property position 'face))
                                         (if hovered hover resting)))
                             t "Pointer fill or selection was not preserved")))))
    (plist-put fixture :outcome
               (lambda () (list :hovered (if hovered t :false)
                                :target (symbol-name target))))))

(dolist (target '(navigation card))
  (taf-benchmark-register
   (format "etaf-youtube.pointer.%s" target)
   :version 1 :modes '(gui) :budget-ms 50 :impact 'local :isolation 'series
   :description (format "Enter and leave a %s hover target in a 36-video feed" target)
   :setup (lambda (mode) (etaf-youtube-pointer--setup mode target))))

(provide 'etaf-youtube-pointer-scenarios)
;;; pointer-scenarios.el ends here
