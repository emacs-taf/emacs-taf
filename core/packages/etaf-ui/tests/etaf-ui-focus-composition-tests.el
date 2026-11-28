;;; etaf-ui-focus-composition-tests.el --- Keyboard composite focus tests -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'etaf)
(require 'etaf-ui)
(require 'ebox)

;; ---------------------------------------------------------------------------
;; Keyboard composites
;; ---------------------------------------------------------------------------

(ert-deftest etaf-ui-composites-are-one-tab-stop-entered-at-the-selection ()
  "Tabs are one Tab stop entered at the active tab; arrows move inside."
  (let ((buffer-name " *etaf-ui-composite-keys*") changes)
    (unwind-protect
        (progn
          (etaf-mount
           buffer-name
           (etaf-view
            (column
             (etaf-button :label "Before" :ref 'before :on-press #'ignore)
             (etaf-tabs :items '((:key a :label "Alpha" :ref tab-a)
                                 (:key b :label "Beta" :ref tab-b)
                                 (:key c :label "Gamma" :ref tab-c))
                        :active 'b
                        :on-change (lambda (key) (push key changes)))
             (etaf-button :label "After" :ref 'after :on-press #'ignore))))
          (with-current-buffer buffer-name
            (let ((runtime (etaf-runtime-for-buffer buffer-name)))
              (etaf-focus runtime 'before)
              (etaf-focus-next runtime)
              (should (eq (etaf-focused-host-ref runtime) 'tab-b))
              (call-interactively (key-binding (kbd "<right>") t))
              (should (eq (etaf-focused-host-ref runtime) 'tab-c))
              (call-interactively (key-binding (kbd "C-b") t))
              (should (eq (etaf-focused-host-ref runtime) 'tab-b))
              (etaf-focus-next runtime)
              (should (eq (etaf-focused-host-ref runtime) 'after))
              (etaf-focus-previous runtime)
              (should (eq (etaf-focused-host-ref runtime) 'tab-b))
              (should-not changes))))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer-name)))
        (etaf-unmount runtime))
      (when-let* ((buffer (get-buffer buffer-name)))
        (kill-buffer buffer)))))

(ert-deftest etaf-ui-tree-branches-open-right-and-close-left ()
  "A focused tree branch expands with Right and collapses with Left."
  (let ((buffer-name " *etaf-ui-tree-keys*") (expanded (etaf-ref nil)))
    (unwind-protect
        (progn
          (etaf-mount
           buffer-name
           (etaf-view
            (etaf-tree :items '((:key src :label "src"
                                 :children ((:key main :label "main.el"))))
                       :expanded expanded
                       :on-toggle (lambda (keys) (etaf-set-value expanded keys)))))
          (with-current-buffer buffer-name
            (let ((runtime (etaf-runtime-for-buffer buffer-name)))
              (etaf-focus-next runtime)
              (call-interactively (key-binding (kbd "<right>") t))
              (etaf-runtime-flush runtime)
              (should (equal (etaf-value expanded) '(src)))
              (etaf-focus-next runtime)
              (etaf-focus-previous runtime)
              (call-interactively (key-binding (kbd "<left>") t))
              (should (null (etaf-value expanded))))))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer-name)))
        (etaf-unmount runtime))
      (when-let* ((buffer (get-buffer buffer-name)))
        (kill-buffer buffer)))))

(provide 'etaf-ui-focus-composition-tests)
;;; etaf-ui-focus-composition-tests.el ends here
