;;; etaf-hints-tests.el --- Public API acceptance tests for etaf-hints -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Acceptance tests verifying `etaf-hints' through its public API and `etaf-ext'.

;;; Code:

(require 'ert)
(require 'etaf)
(require 'etaf-ui)
(require 'etaf-ext)
(require 'etaf-hints)

(ert-deftest etaf-hints-overlays-targets-activates-press-and-cleans-up ()
  (let* ((etaf-ext-storage-file nil)
         (etaf-ext-use-posframe nil)
         (orig-mode (bound-and-true-p etaf-ext-mode))
         (buf (generate-new-buffer " *etaf-hints-test*"))
         (clicked nil)
         (rt nil))
    (unwind-protect
        (progn
          (etaf-ext-mode 1)
          (etaf-mount
           buf
           (etaf-node
            'column '(:width (ch 60) :item-gap (lh 1))
            (list
             (etaf-node 'text nil '("Hint test page"))
             (etaf-node
              'flex '(:gap ((lh 0) (ch 2)))
              (list
               (etaf-node 'box (list :tab-index 0
                                     :on-press (lambda () (push 'first clicked)))
                          (list (etaf-node 'text nil '("Button Alpha"))))
               (etaf-node 'box (list :tab-index 0
                                     :on-press (lambda () (push 'second clicked)))
                          (list (etaf-node 'text nil '("Button Beta"))))))))
           '(:viewport-width 480 :viewport-height 20
                             :meta (:app hints-demo :kind document)))
          (setq rt (etaf-runtime-for-buffer buf))
          ;; Extension key layer exposes M-f in help data
          (let* ((hdata (etaf-help-data rt))
                 (ext-group (cl-find 'extension (plist-get hdata :groups)
                                     :key (lambda (g) (plist-get g :kind)))))
            (should ext-group)
            (should (cl-some (lambda (e) (equal (plist-get e :key) "M-f"))
                             (plist-get ext-group :entries))))
          (let ((codes (etaf-hints-start rt)))
            (should (= (length codes) 2))
            (should (equal codes (etaf-hints-active-codes rt)))
            (let ((res (etaf-hints-input (car (nth 1 codes)) rt)))
              (should (eq res :activated))
              (should (equal clicked '(second)))
              (should (null (etaf-hints-active-codes rt)))))
          ;; Cancel clears overlay cleanly
          (should (= (length (etaf-hints-start rt)) 2))
          (etaf-hints-cancel rt)
          (should (null (etaf-hints-active-codes rt))))
      (etaf-ext-mode (if orig-mode 1 -1))
      (when (and rt (etaf-runtime-mounted-p rt)) (etaf-unmount rt))
      (when (buffer-live-p buf) (kill-buffer buf)))))

(provide 'etaf-hints-tests)
;;; etaf-hints-tests.el ends here
