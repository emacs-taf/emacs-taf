;;; etaf-ui-font-tests.el --- Window typography contracts -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'etaf-ui)

(defun etaf-ui-test-font-property (buffer text property)
  "Read explicit rendered face PROPERTY on TEXT in BUFFER."
  (with-current-buffer buffer
    (save-excursion
      (goto-char (point-min))
      (should (search-forward text nil t))
      (cl-labels ((lookup (face)
                    (cond ((and (listp face) (keywordp (car face)))
                           (plist-get face property))
                          ((listp face) (cl-some #'lookup face))
                          ((and (symbolp face) (facep face))
                           (let ((value (face-attribute face property nil)))
                             (unless (eq value 'unspecified) value))))))
        (lookup (get-text-property (1- (point)) 'face))))))

(ert-deftest etaf-ui-window-fonts-inherit-and-override-independently ()
  "Window text and controls inherit unless their own region overrides it."
  (dolist (sizes '((nil nil) (1.0 nil) (nil 0.8) (1.0 0.8)))
    (let ((buffer (generate-new-buffer " *etaf-ui-font-window*")))
      (unwind-protect
          (progn
            (etaf-mount
             buffer
             (etaf-node
              'box '(:position relative :width (ch 100) :height (lh 25)
                      :font-size 1.5 :font-family "Monospace")
              (list
               (etaf-node
                'etaf-window
                (list :title "WindowTitle" :width '(ch 70) :height '(lh 18)
                      :title-font-size (nth 0 sizes) :content-font-size (nth 1 sizes))
                (list (etaf-view
                       (column
                        (etaf-label :text "BodyLabel")
                        (text :font-size 1.0 "BodyRef")
                        (etaf-label :text "BodyHeading" :variant 'heading)
                        (etaf-button :label "BodyButton")
                        (etaf-text-input :value "BodyInput" :hide-label t))))
                (list (cons 'footer (list (etaf-view (text "BodyFooter")))))))))
            (let* ((unit (etaf-ui-test-font-property buffer "BodyRef" :height))
                  (closes (lambda (ratio height)
                            (< (abs (- height (* ratio unit))) 1.5))))
              (should (funcall closes (or (nth 0 sizes) 1.5)
                               (etaf-ui-test-font-property buffer "WindowTitle" :height)))
              (should (funcall closes (or (nth 0 sizes) 1.5)
                               (etaf-ui-test-font-property
                                buffer (if (and (display-graphic-p)
                                                (image-type-available-p 'svg)) "⬤" "o")
                                :height)))
              (dolist (text '("BodyLabel" "BodyHeading" "BodyButton" "BodyInput" "BodyFooter"))
                (should (funcall closes (or (nth 1 sizes) 1.5)
                                 (etaf-ui-test-font-property buffer text :height)))
                (should (equal "Monospace"
                               (etaf-ui-test-font-property buffer text :family))))))
        (when-let* ((runtime (etaf-runtime-for-buffer buffer)))
          (etaf-unmount runtime))
        (kill-buffer buffer)))))

(ert-deftest etaf-ui-panel-font-default-follows-buffer-face ()
  "An unspecified panel font adds no smaller size over the Emacs default."
  (let ((buffer (generate-new-buffer " *etaf-ui-font-default*")))
    (unwind-protect
        (progn
          (etaf-mount
           buffer
           (etaf-view
            (etaf-resizable-panel :width '(ch 60) :height '(lh 10)
                                  :font-family "Monospace"
              (etaf-label :text "Inherited"))))
          (should-not (etaf-ui-test-font-property buffer "Inherited" :height))
          (should (equal "Monospace"
                         (etaf-ui-test-font-property buffer "Inherited" :family))))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer)))
        (etaf-unmount runtime))
      (kill-buffer buffer))))

(ert-deftest etaf-ui-control-markers-keep-native-selection-behavior ()
  "ASCII control marks track state through native Return without losing labels."
  (let ((buffer (generate-new-buffer " *etaf-ui-font-markers*"))
        (checked (etaf-ref nil)) (enabled (etaf-ref nil))
        (choice (etaf-ref 'one)))
    (unwind-protect
        (progn
          (etaf-mount
           buffer
           (etaf-view
            (column :width '(ch 60)
              (etaf-checkbox :bind checked :label "Checkbox")
              (etaf-switch :bind enabled :label "Switch")
              (etaf-radio :bind choice :label "Radio"
                          :options '((one . "One") (two . "Two"))))))
          (let ((runtime (etaf-runtime-for-buffer buffer)))
            (cl-labels
                ((text (expected)
                   (with-current-buffer buffer
                     (should (string-match-p
                              (regexp-quote expected)
                              (buffer-substring-no-properties (point-min) (point-max))))))
                 (press (label)
                   (let ((ref (car (cl-find-if
                                    (lambda (entry)
                                      (equal label (plist-get (cdr entry) :aria-label)))
                                    (etaf-runtime-host-props-entries runtime)))))
                     (should ref)
                     (save-window-excursion
                       (switch-to-buffer buffer)
                       (etaf-focus runtime ref)
                       (let ((command (key-binding (kbd "RET"))))
                         (should (commandp command))
                         (call-interactively command))))))
              (text "[ ] Checkbox")
              (text "[ ] Switch")
              (text "(o) One")
              (text "( ) Two")
              (press "Checkbox") (should (etaf-value checked))
              (text "[x] Checkbox")
              (press "Checkbox") (should-not (etaf-value checked))
              (text "[ ] Checkbox")
              (press "Switch") (should (etaf-value enabled))
              (text "[x] Switch")
              (press "Two") (should (eq (etaf-value choice) 'two))
              (text "( ) One") (text "(o) Two"))))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer)))
        (etaf-unmount runtime))
      (kill-buffer buffer))))

(ert-deftest etaf-ui-traffic-lights-use-one-cell-ascii-without-svg ()
  "No-SVG traffic lights retain inherited typography and controlled actions."
  (let ((buffer (generate-new-buffer " *etaf-ui-ascii-lights*"))
        (mode (etaf-ref 'normal)) actions)
    (unwind-protect
        (cl-letf (((symbol-function 'image-type-available-p) (lambda (_type) nil)))
          (etaf-mount
           buffer
           (etaf-view
            (box :font-size 1.5
              (column
               (text "UnitRef")
               (etaf-window-controls
                :mode mode
                :on-close (lambda () (push 'close actions))
                :on-minimize (lambda () (push 'minimize actions))
                :on-maximize (lambda () (push 'maximize actions))
                :on-restore (lambda () (push 'restore actions)))))))
          (should (= (etaf-ui-test-font-property buffer "UnitRef" :height)
                     (etaf-ui-test-font-property buffer "o" :height)))
          (let* ((runtime (etaf-runtime-for-buffer buffer))
                 (controls
                  (mapcar
                   (lambda (label)
                     (cl-find-if
                      (lambda (entry) (equal label (plist-get (cdr entry) :aria-label)))
                      (etaf-runtime-host-props-entries runtime)))
                   '("Close" "Minimize" "Zoom"))))
            (cl-loop for entry in controls for mark in '("x" "-" "+") do
                     (let ((hover (plist-get (cdr entry) :hover-content)))
                       (should (equal mark hover))
                       (should (= 1 (string-width hover)))
                       (should-not (get-text-property 0 'display hover)))
                     (etaf-dispatch-event runtime (car entry) 'press))
            (should (equal '(maximize minimize close) actions))
            (etaf-set-value mode 'maximized)
            (etaf-dispatch-event runtime (car (nth 2 controls)) 'press)
            (should (eq 'restore (car actions)))))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer)))
        (etaf-unmount runtime))
      (kill-buffer buffer))))

(provide 'etaf-ui-font-tests)
;;; etaf-ui-font-tests.el ends here
