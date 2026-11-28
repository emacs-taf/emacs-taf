;;; etaf-ui-label-tests.el --- Composable text layout -*- lexical-binding: t; -*-

;;; Commentary:
;; Label layout and updates are observed through mounted output and public APIs.

;;; Code:
(require 'ert)
(require 'etaf-ui)

(defun etaf-ui-label-test--face-value (string position property)
  "Read PROPERTY from native face plists at POSITION in STRING."
  (let ((face (get-text-property position 'face string)))
    (or (plist-get face property)
        (cl-some (lambda (attributes)
                   (and (listp attributes) (plist-get attributes property)))
                 face))))

(ert-deftest etaf-ui-label-supports-box-geometry-and-text-presentation ()
  "Label accepts geometry and wraps complete text inside its content width."
  (let* ((text "alpha beta gamma")
         (props '(:width (ch 10) :padding ((lh 1) (ch 1))
                  :border ((px 1) solid "#123456") :color "#234567"
                  :font-weight bold :wrap-mode word))
         (actual (ebox-render (etaf-render (etaf-node 'etaf-label (append (list :text text) props) nil))))
         (expected (ebox-render (ebox-build (append (list 'box) props (list text))))))
    (should (equal (substring-no-properties actual) (substring-no-properties expected)))
    (dolist (word '("alpha" "beta" "gamma"))
      (let ((position (string-match word actual)))
        (should position)
        (should (equal "#234567" (etaf-ui-label-test--face-value actual position :foreground)))
        (should (eq 'bold (etaf-ui-label-test--face-value actual position :weight)))))
    (should (> (length (split-string actual "\n")) 3))))

(ert-deftest etaf-ui-label-reflows-reactive-text-and-preserves-following-content ()
  "A constrained Label reflows on content and viewport changes and keeps its ref."
  (let* ((value (etaf-ref "alpha beta gamma"))
         (buffer (generate-new-buffer " *etaf-ui-label-layout*")))
    (unwind-protect
        (progn
          (etaf-mount
           buffer
           (etaf-view
            (column :width 'stretch
                    (etaf-label :text value :width 'stretch :ref 'paragraph
                                :wrap-mode 'word :color "#234567")
                    (text "After"))))
          (let ((runtime (etaf-runtime-for-buffer buffer)))
            (etaf-runtime-refit (etaf-runtime-for-buffer buffer) 8 30)
            (let ((narrow (with-current-buffer buffer (buffer-substring-no-properties (point-min) (point-max)))))
              (should (string-match-p "alpha *\nbeta *\ngamma *\nAfter" narrow))
              (should (etaf-host-ref-bounds runtime 'paragraph)))
            (setf (etaf-value value) "中文内容测试")
            (etaf-runtime-flush runtime)
            (with-current-buffer buffer
              (should (string-match-p "中文内容 *\n测试 *\nAfter" (buffer-substring-no-properties (point-min) (point-max)))))
            (etaf-runtime-refit (etaf-runtime-for-buffer buffer) 20 30)
            (with-current-buffer buffer
              (should (string-match-p "中文内容测试 *\nAfter" (buffer-substring-no-properties (point-min) (point-max)))))
            (should (etaf-host-ref-bounds runtime 'paragraph))))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer))) (etaf-unmount runtime))
      (kill-buffer buffer))))

(provide 'etaf-ui-label-tests)
;;; etaf-ui-label-tests.el ends here
