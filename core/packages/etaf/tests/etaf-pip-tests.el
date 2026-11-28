;;; etaf-pip-tests.el --- Public behavior tests for etaf-pip -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Code:

(require 'ert)
(require 'etaf)

(etaf-define-component etaf-pip-tests--probe (&key pip-id)
  "Minimal View reading `etaf-pip-bounds' reactively."
  :render
  (let* ((b (etaf-pip-bounds pip-id))
         (cols (or (plist-get b :cols) 0))
         (rows (or (plist-get b :rows) 0))
         (size (or (plist-get b :size) 'none)))
    (etaf-view
     (box :width 'stretch :height '(lh 1)
       (text (expr (format "PIP %s %dx%d" size cols rows)))))))

(ert-deftest etaf-pip-lifecycle-presets-corners-and-reactive-bounds ()
  "`etaf-pip-open' mounts reactively, cycles size/corner and cleans up on close."
  (let ((id 'etaf-pip-test-host)
        (closed 0)
        (sizes nil)
        (corners nil)
        (title "Initial Title"))
    (unwind-protect
        (progn
          (let ((buf (etaf-pip-open
                      id (etaf-view (etaf-pip-tests--probe :pip-id id))
                      :title (lambda () title)
                      :size 'small
                      :corner 'bottom-right
                      :on-close (lambda () (setq closed (1+ closed)))
                      :on-size-change (lambda (s) (push s sizes))
                      :on-corner-change (lambda (c) (push c corners)))))
            (should (buffer-live-p buf))
            (should (eq buf (etaf-pip-buffer id)))
            (should (etaf-pip-active-p id))
            (let ((b0 (etaf-pip-bounds id)))
              (should (eq (plist-get b0 :size) 'small))
              (should (eq (plist-get b0 :corner) 'bottom-right))
              (should (> (plist-get b0 :width-px) 0))
              (should (> (plist-get b0 :rows) 0)))
            (should (eq (etaf-pip-cycle-size id) 'medium))
            (should (eq (plist-get (etaf-pip-bounds id) :size) 'medium))
            (should (eq (etaf-pip-cycle-size id) 'large))
            (should (eq (plist-get (etaf-pip-bounds id) :size) 'large))
            (should (eq (etaf-pip-cycle-corner id) 'bottom-left))
            (should (eq (plist-get (etaf-pip-bounds id) :corner) 'bottom-left))
            (setq title "Updated Title")
            (should (etaf-pip-refresh-chrome id))
            (with-current-buffer buf
              (should (string-match-p "Updated Title"
                                      (or (and (stringp header-line-format)
                                               header-line-format)
                                          ""))))
            (should (etaf-pip-close id))
            (should-not (etaf-pip-active-p id))
            (should (null (etaf-pip-buffer id)))
            (should (null (etaf-pip-bounds id)))
            (should (= closed 1))
            (should (equal (nreverse sizes) '(medium large)))
            (should (equal (nreverse corners) '(bottom-left)))))
      (etaf-pip-close id))))

(provide 'etaf-pip-tests)
;;; etaf-pip-tests.el ends here
