;;; etaf-highlight-tests.el --- Public API acceptance tests for etaf-highlight -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Acceptance tests verifying `etaf-highlight' persistence, theme-adapted span
;; decorations, companion notes, and multi-package coexistence alongside
;; `etaf-hints' and `etaf-translate' through `etaf-ext'.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'subr-x)
(require 'etaf)
(require 'etaf-ui)
(require 'etaf-ext)
(require 'etaf-hints)
(require 'etaf-highlight)
(require 'etaf-translate)

(defun etaf-highlight-test--buf-text (rt)
  "Return plain text of RT's buffer without text properties."
  (with-current-buffer (etaf-runtime-buffer rt)
    (buffer-substring-no-properties (point-min) (point-max))))

(defun etaf-highlight-test--find-text-host (tree substr)
  "Return first text Host ID in TREE containing SUBSTR."
  (let ((found nil))
    (cl-labels ((walk (node)
                  (when (and (not found) (listp node))
                    (when (and (eq (plist-get node :tag) 'text)
                               (stringp (plist-get node :text))
                               (string-search substr (plist-get node :text)))
                      (setq found (plist-get node :id)))
                    (dolist (c (plist-get node :children)) (walk c)))))
      (dolist (r tree) (walk r)))
    found))

(ert-deftest etaf-highlight-decorates-notes-and-persists-across-remount ()
  (let* ((db (make-temp-file "etaf-hl-test-" nil ".sqlite3"))
         (etaf-ext-storage-file db)
         (etaf-ext-use-posframe nil)
         (orig-mode (bound-and-true-p etaf-ext-mode))
         (buf1 (generate-new-buffer " *etaf-hl-1*"))
         (buf2 (generate-new-buffer " *etaf-hl-2*"))
         (uri "https://example.org/hl-42")
         (para "ETAF renders declarative text interfaces with crisp layout.")
         (rt1 nil)
         (rt2 nil))
    (unwind-protect
        (progn
          (etaf-ext-mode 1)
          (etaf-mount buf1
                      (etaf-node 'column '(:width (ch 64))
                                 (list (etaf-node 'text nil (list para))))
                      (list :viewport-width 520 :viewport-height 20
                            :meta (list :app 'reader-demo :kind 'document :uri uri)))
          (setq rt1 (etaf-runtime-for-buffer buf1))
          (let* ((hid (etaf-highlight-test--find-text-host (etaf-runtime-host-tree rt1) "declarative"))
                 (rec (etaf-highlight-apply rt1 hid 13 39 :color 'green :note "核心特性记录")))
            (should rec)
            (should (equal (plist-get rec :anchor) "declarative text interface"))
            (let ((txt1 (etaf-highlight-test--buf-text rt1)))
              (should (string-search "declarative text interface" txt1))
              (should (string-search "核心特性记录" txt1)))
            (let ((has-face nil))
              (with-current-buffer buf1
                (goto-char (point-min))
                (when (search-forward "declarative" nil t)
                  (setq has-face (not (null (get-text-property (match-beginning 0) 'face))))))
              (should has-face))
            (should (etaf-highlight-list rt1))
            (etaf-unmount rt1)
            (setq rt1 nil)
            ;; Remount fresh Runtime for same URI -> auto-restores by anchor!
            (etaf-mount buf2
                        (etaf-node 'column '(:width (ch 64))
                                   (list (etaf-node 'text nil '("Header line"))
                                         (etaf-node 'text nil (list para))))
                        (list :viewport-width 520 :viewport-height 20
                              :meta (list :app 'reader-demo :kind 'document :uri uri)))
            (setq rt2 (etaf-runtime-for-buffer buf2))
            (should (= (length (etaf-highlight-entries rt2)) 1))
            (should (string-search "核心特性记录" (etaf-highlight-test--buf-text rt2)))
            (etaf-highlight-remove (plist-get rec :id) rt2)
            (should (null (etaf-highlight-entries rt2)))
            (should-not (string-search "核心特性记录" (etaf-highlight-test--buf-text rt2)))))
      (etaf-ext-mode (if orig-mode 1 -1))
      (when (and rt1 (etaf-runtime-mounted-p rt1)) (etaf-unmount rt1))
      (when (and rt2 (etaf-runtime-mounted-p rt2)) (etaf-unmount rt2))
      (when (buffer-live-p buf1) (kill-buffer buf1))
      (when (buffer-live-p buf2) (kill-buffer buf2))
      (dolist (f (list db (concat db "-wal") (concat db "-shm")))
        (when (file-exists-p f) (ignore-errors (delete-file f)))))))

(ert-deftest etaf-highlight-coexists-with-translate-and-hints-packages ()
  (let* ((db (make-temp-file "etaf-hl-coex-" nil ".sqlite3"))
         (etaf-ext-storage-file db)
         (etaf-ext-use-posframe nil)
         (orig-mode (bound-and-true-p etaf-ext-mode))
         (buf (generate-new-buffer " *etaf-hl-coex*"))
         (uri "https://example.org/multi-pkg-coexist")
         (para "Independent extension packages coexist peacefully over ETAF.")
         (pressed nil)
         (rt nil)
         (etaf-translate-enable-disk-cache nil)
         (etaf-translate-state-file nil)
         (etaf-translate-use-posframe nil)
         (etaf-translate-function-backend
          (lambda (text _src _tgt _gloss)
            (format "译文: %s" text))))
    (unwind-protect
        (progn
          (etaf-ext-mode 1)
          (etaf-mount buf
                      (etaf-node
                       'column '(:width (ch 72) :padding ((lh 1) (ch 2)) :item-gap (lh 1))
                       (list
                        (etaf-node 'text '(:id "coexist-p") (list para))
                        (etaf-node 'box (list :id "action-btn" :tab-index 0
                                              :on-press (lambda () (setq pressed t)))
                                   (list (etaf-node 'text nil '("Open Details"))))))
                      (list :viewport-width 580 :viewport-height 24
                            :meta (list :app 'etaf-web :kind 'document
                                        :uri uri :title "Multi-Package Coexistence")))
          (setq rt (etaf-runtime-for-buffer buf))
          (let ((hid (etaf-highlight-test--find-text-host (etaf-runtime-host-tree rt) "Independent extension")))
            (should hid)
            (etaf-translate-enable rt :engine 'function :mode 'bilingual-stacked
                                   :style 'left-bar :source-lang "en" :target-lang "zh-CN")
            (etaf-highlight-apply rt hid 0 21 :color 'yellow :note "独立包共存批注")
            (let ((codes (etaf-hints-start rt)))
              (should (= (length codes) 1))
              (let ((pres-keys (mapcar (lambda (p) (plist-get p :key))
                                       (plist-get (etaf-runtime-inspect-host rt hid) :presentations)))
                    (txt (etaf-highlight-test--buf-text rt)))
                (should (memq 'etaf-translate pres-keys))
                (should (memq 'etaf-highlight pres-keys))
                (should (string-search "译文: Independent extension" txt))
                (should (string-search "独立包共存批注" txt)))
              ;; Hint clicks button without disturbing translate or highlight
              (should (eq (etaf-hints-input (caar codes) rt) :activated))
              (should pressed)
              (let ((txt (etaf-highlight-test--buf-text rt)))
                (should (string-search "译文: Independent extension" txt))
                (should (string-search "独立包共存批注" txt)))
              ;; One Pure Mode toggle hides BOTH translate and highlight cleanly!
              (etaf-ext-pure-mode-toggle rt)
              (let ((txt (etaf-highlight-test--buf-text rt)))
                (should-not (string-search "译文: Independent extension" txt))
                (should-not (string-search "独立包共存批注" txt)))
              (etaf-ext-pure-mode-toggle rt)
              (should (string-search "独立包共存批注" (etaf-highlight-test--buf-text rt))))))
      (etaf-ext-mode (if orig-mode 1 -1))
      (when (and rt (etaf-runtime-mounted-p rt))
        (ignore-errors (etaf-translate-disable rt))
        (etaf-unmount rt))
      (when (buffer-live-p buf) (kill-buffer buf))
      (dolist (f (list db (concat db "-wal") (concat db "-shm")))
        (when (file-exists-p f) (ignore-errors (delete-file f)))))))

(provide 'etaf-highlight-tests)
;;; etaf-highlight-tests.el ends here
