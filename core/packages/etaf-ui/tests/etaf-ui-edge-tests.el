;;; -*- lexical-binding: t; -*-
;;; etaf-ui-edge-tests.el --- Public behavior of panels, edge tabs and fields

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Every scenario drives the catalog through its public Component calls and
;; the Runtime's public target interface.  The three components share one idea:
;; a rule already present in the layout carries a label instead of owning a
;; row for it.

;;; Code:

(require 'ert)
(require 'etaf-ui)

(defun etaf-ui-edge-test--activate (runtime label)
  "Activate the visible control LABEL through RUNTIME's public targets."
  (let ((target
         (car (cl-find-if
               (lambda (entry)
                 (and (equal label (plist-get (cdr entry) :aria-label))
                      (etaf-host-ref-position runtime (car entry))))
               (etaf-runtime-host-props-entries runtime)))))
    (should target)
    (etaf-focus runtime target)
    (etaf-activate runtime)))

(ert-deftest etaf-ui-edge-panel-keeps-its-title-on-the-rule ()
  "A panel paints its title, its status and its body in that order."
  (with-temp-buffer
    (unwind-protect
        (progn
          (etaf-mount
           (current-buffer)
           (etaf-view
            (etaf-edge-panel :title "读取设置" :status "12.3.0"
              (expr (etaf-node 'text nil (list "正文一行")))))
           '(:viewport-width 700 :viewport-height 100))
          (let* ((text (buffer-string))
                 (title (string-match-p "读取设置" text))
                 (status (string-match-p "12.3.0" text))
                 (body (string-match-p "正文一行" text)))
            (should title)
            (should status)
            (should body)
            (should (< title body))
            (should (< title status))))
      (when-let* ((runtime (etaf-runtime-for-buffer (current-buffer))))
        (etaf-unmount runtime)))))

(ert-deftest etaf-ui-edge-tabs-dispatch-the-pressed-tab ()
  "Pressing a tab reports its key and marks it as the chosen one."
  (with-temp-buffer
    (let (selected)
      (unwind-protect
          (progn
            (etaf-mount
             (current-buffer)
             (etaf-view
              (etaf-edge-tabs
               :items '((:key notes :label "notes.md")
                        (:key todo :label "todo.md"))
               :active 'notes
               :on-change (lambda (key) (setq selected key))
               (expr (etaf-node 'text nil (list "正文")))))
             '(:viewport-width 700 :viewport-height 100))
            (should (string-match-p "notes.md" (buffer-string)))
            (should (string-match-p "todo.md" (buffer-string)))
            (etaf-ui-edge-test--activate
             (etaf-runtime-for-buffer (current-buffer)) "todo.md")
            (should (eq selected 'todo)))
        (when-let* ((runtime (etaf-runtime-for-buffer (current-buffer))))
          (etaf-unmount runtime))))))

(ert-deftest etaf-ui-underline-field-shows-placeholder-until-it-has-a-value ()
  "An empty field paints its placeholder; a filled one paints the value."
  (with-temp-buffer
    (unwind-protect
        (progn
          (etaf-mount
           (current-buffer)
           (etaf-view
            (column :width '(ch 40)
              (etaf-underline-field :label "仓库地址" :value ""
                                    :placeholder "还没有填")
              (etaf-underline-field :label "渲染器" :value "Ebox")))
           '(:viewport-width 700 :viewport-height 100))
          (let ((text (buffer-string)))
            (should (string-match-p "仓库地址" text))
            (should (string-match-p "还没有填" text))
            (should (string-match-p "渲染器" text))
            (should (string-match-p "Ebox" text))
            (should-not (string-match-p "还没有填[[:space:]]*Ebox" text))))
      (when-let* ((runtime (etaf-runtime-for-buffer (current-buffer))))
        (etaf-unmount runtime)))))

(provide 'etaf-ui-edge-tests)
;;; etaf-ui-edge-tests.el ends here
