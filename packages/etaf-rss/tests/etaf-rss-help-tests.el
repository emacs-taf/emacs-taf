;;; -*- lexical-binding: t; -*-
;;; etaf-rss-help-tests.el --- In-buffer help acceptance

;; SPDX-License-Identifier: GPL-3.0-or-later

(require 'ert)
(require 'cl-lib)
(require 'etaf-rss)

(ert-deftest etaf-rss-tests-root-keys-own-the-canvas ()
  "The palette paints the canvas and `T' and `q' beat renderer bindings."
  (save-window-excursion
    (let* ((directory (make-temp-file "etaf-rss-keys-" t))
           (etaf-rss-buffer-name " *RSS keys acceptance*")
           (etaf-rss-refresh-interval nil)
           (model (etaf-rss-create
                   :client (etaf-rss-make-client
                            :data-file (expand-file-name "data.json" directory))))
           (buffer (progn (etaf-rss-set-theme model 'dark)
                          (etaf-rss-open model)))
           (canvas (lambda ()
                     (with-current-buffer buffer
                       ;; The application owns the base remap; Ebox adds
                       ;; the root's own background as a relative remap.
                       (plist-get (car (last (alist-get 'default face-remapping-alist)))
                                  :background)))))
      (unwind-protect
          (with-current-buffer buffer
            (should-not mode-line-format)
            (should (equal (funcall canvas) (etaf-rss-color :bg 'dark)))
            (execute-kbd-macro (kbd "T"))
            (should (equal (funcall canvas) (etaf-rss-color :bg 'light)))
            (execute-kbd-macro (kbd "q"))
            (should-not (buffer-live-p buffer)))
        (when (buffer-live-p buffer) (kill-buffer buffer))
        (delete-directory directory t)))))

(ert-deftest etaf-rss-tests-canvas-fills-the-window-without-overflow ()
  "The mounted canvas never needs more rows than the window shows.
A buffer one row taller than its window scrolls as a whole, so a wheel turn
or a scroll command slides the sidebar and the list along with the article."
  (save-window-excursion
    (let* ((directory (make-temp-file "etaf-rss-canvas-" t))
           (etaf-rss-buffer-name " *RSS canvas acceptance*")
           (etaf-rss-refresh-interval nil)
           (model (etaf-rss-create
                   :client (etaf-rss-make-client
                            :data-file (expand-file-name "data.json" directory))))
           (buffer (etaf-rss-open model)))
      (unwind-protect
          (with-current-buffer buffer
            (let ((window (get-buffer-window buffer t)))
              (should window)
              (should (<= (line-number-at-pos (point-max))
                          (window-body-height window)))
              (should (<= (cdr (etaf-runtime-viewport
                                (etaf-runtime-for-buffer buffer)))
                          (window-body-height window)))
              ;; Scrolling the window is what a stray wheel gesture did; the
              ;; page must stay pinned at its top.
              (should (window-start window))
              (should (= (window-start window) (point-min)))))
        (when (buffer-live-p buffer) (kill-buffer buffer))
        (delete-directory directory t)))))

(ert-deftest etaf-rss-tests-help-stays-in-reader ()
  "Both help entries share a read-only modal and restore the reader focus."
  (save-window-excursion
    (let* ((directory (make-temp-file "etaf-rss-help-" t))
           (etaf-rss-buffer-name " *RSS help acceptance*")
           (etaf-rss-refresh-interval nil)
           (model (etaf-rss-create
                   :client (etaf-rss-make-client
                            :data-file (expand-file-name "data.json" directory))))
           (buffer (etaf-rss-open model))
           (runtime (etaf-runtime-for-buffer buffer)))
      (unwind-protect
          (with-current-buffer buffer
            (etaf-focus-next runtime)
            (let ((focus (etaf-focused-host-ref runtime))
                  (windows (window-list))
                  (before (plist-get (etaf-rss-state model) :scope)))
              (dolist (key '("?" "C-c h"))
                (execute-kbd-macro (kbd key))
                (let* ((data (etaf-help-data runtime))
                       (entries (apply #'append
                                       (mapcar (lambda (group) (plist-get group :entries))
                                               (plist-get data :groups))))
                       (star (cl-find "s" entries :key (lambda (entry) (plist-get entry :key))
                                      :test #'equal))
                       (page-up (cl-find "M-v" entries :key (lambda (entry) (plist-get entry :key))
                                         :test #'equal))
                       (same-runtime (eq runtime (etaf-runtime-for-buffer buffer))))
                  (should same-runtime)
                  (should (eq (window-buffer) buffer))
                  (should (equal windows (window-list)))
                  (should (equal (plist-get star :label) "收藏／取消收藏"))
                  (should (equal (plist-get page-up :label) "阅读上一页"))
                  (should (string-match-p "快捷键 · 只读"
                                          (buffer-substring-no-properties (point-min) (point-max)))))
                (execute-kbd-macro (kbd "/"))
                (execute-kbd-macro "?")
                (let ((editing (etaf-text-input-active-p runtime)))
                  (should editing))
                (execute-kbd-macro (kbd "<escape>"))
                (let ((editing (etaf-text-input-active-p runtime)))
                  (should-not editing))
                (should (string-match-p "快捷键 · 只读"
                                        (buffer-substring-no-properties (point-min) (point-max))))
                (execute-kbd-macro (kbd "<escape>"))
                (let ((restored (equal focus (etaf-focused-host-ref runtime)))
                      (scope (plist-get (etaf-rss-state model) :scope)))
                  (should restored)
                  (should (equal before scope)))))
            (execute-kbd-macro (kbd "C-c h"))
            ;; Dispatch the native backdrop binding, not a component callback.
            (let* ((map (get-text-property (point-min) 'keymap))
                   (command (lookup-key map [mouse-1]))
                   (last-input-event (list 'mouse-1 (list (selected-window) 1 '(0 . 0) 0))))
              (call-interactively command))
            (let ((closed (etaf-help-close runtime)))
              (should-not closed)))
        (when (buffer-live-p buffer)
          (with-current-buffer buffer (etaf-rss-close)))
        (delete-directory directory t)))))

;;; etaf-rss-help-tests.el ends here
