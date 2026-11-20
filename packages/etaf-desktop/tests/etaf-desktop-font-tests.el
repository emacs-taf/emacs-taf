;;; etaf-desktop-font-tests.el --- Desktop font preferences -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'etaf-desktop)

(defun etaf-desktop-test-font-height (buffer text &optional occurrence)
  "Return face height on TEXT at OCCURRENCE in BUFFER, or nil."
  (with-current-buffer buffer
    (save-excursion
      (goto-char (point-min))
      (should (search-forward text nil t (or occurrence 1)))
      (cl-labels ((height (face)
                    (cond ((and (listp face) (keywordp (car face)))
                           (plist-get face :height))
                          ((listp face) (cl-some #'height face))
                          ((and (symbolp face) (facep face))
                           (let ((value (face-attribute face :height nil)))
                             (unless (eq value 'unspecified) value))))))
        (height (get-text-property (1- (point)) 'face))))))

(defun etaf-desktop-test-font-press (runtime label)
  "Press the public Host with aria LABEL in RUNTIME."
  (let ((target
         (car (cl-find-if
               (lambda (entry) (equal label (plist-get (cdr entry) :aria-label)))
               (etaf-runtime-host-props-entries runtime)))))
    (should target)
    (etaf-dispatch-event runtime target 'press)))

(ert-deftest etaf-desktop-font-default-overrides-and-reset ()
  "Default typography inherits; independent pixel overrides reset to inheritance."
  (let ((desktop (etaf-desktop-create :name " *desktop-font-default*"
                                      :canvas-width 900 :canvas-height 35)))
    (unwind-protect
        (progn
          (should-not (plist-get (etaf-desktop-settings desktop) :title-font-size))
          (should-not (plist-get (etaf-desktop-settings desktop) :content-font-size))
          (etaf-desktop-open-window
           desktop 'sample :title "FontTitle" :width 600 :height 20
           ;; A desktop window is seamless: its resize strips cover the
           ;; frame's outermost body row and columns, so the application here
           ;; keeps that margin cell clear of its controls.
           :view (etaf-view
                  (box :width 'stretch :height 'stretch
                       :padding '((lh 0) (ch 2) (lh 1) (ch 2))
                    (column (etaf-label :text "FontBody")
                            (etaf-button :label "FontButton")
                            (etaf-text-input :value "FontInput" :hide-label t)))))
          (let ((buffer (etaf-desktop-mount desktop)))
            (dolist (text '("FontTitle" "FontBody" "FontButton" "FontInput"))
              (should-not (etaf-desktop-test-font-height
                           buffer text (if (equal text "FontTitle") 2 1))))
            (etaf-desktop-set-setting desktop :title-font-size 16)
            ;; 16 points is a 1.6 ratio of the 12 pt body, and Ebox reports
            ;; face heights in 1/10 pt, so the painted height is 192.
            (should (= 192 (etaf-desktop-test-font-height buffer "FontTitle" 2)))
            (should-not (etaf-desktop-test-font-height buffer "FontBody"))
            (etaf-desktop-set-setting desktop :content-font-size 20)
            (dolist (text '("FontBody" "FontButton" "FontInput"))
              (should (= 240 (etaf-desktop-test-font-height
                           buffer text (if (equal text "FontTitle") 2 1)))))
            (etaf-desktop-set-setting desktop :title-font-size nil)
            (should-not (etaf-desktop-test-font-height buffer "FontTitle" 2))
            (should (= 240 (etaf-desktop-test-font-height buffer "FontBody")))
            (etaf-desktop-reset-settings desktop)
            (dolist (text '("FontTitle" "FontBody" "FontButton" "FontInput"))
              (should-not (etaf-desktop-test-font-height
                           buffer text (if (equal text "FontTitle") 2 1))))
            (dolist (invalid '(0 7 33 "large" inherited))
              (should-error (etaf-desktop-set-setting desktop :content-font-size invalid)
                            :type 'etaf-desktop-error)
              (should-not (plist-get (etaf-desktop-settings desktop)
                                     :content-font-size)))))
      (etaf-desktop-close desktop))))

(ert-deftest etaf-desktop-font-settings-restore-inheritance ()
  "Settings offers the Emacs default and restores inherited sizes independently."
  (let ((desktop (etaf-desktop-create :name " *desktop-font-settings*"
                                      :canvas-width 900 :canvas-height 35)))
    (unwind-protect
        (let* ((buffer (etaf-desktop-mount desktop))
               (runtime (etaf-runtime-for-buffer buffer)))
          (etaf-desktop-toggle-settings desktop t)
          (dolist (text '("Desktop Settings" "Appearance" "Title font size"
                          "Content font size" "Emacs default" "Done"))
            (should-not (etaf-desktop-test-font-height buffer text)))
          (etaf-desktop-set-setting desktop :title-font-size 16)
          (etaf-desktop-set-setting desktop :content-font-size 12)
          (etaf-desktop-test-font-press runtime "Use Emacs default for title font size")
          (should-not (plist-get (etaf-desktop-settings desktop) :title-font-size))
          (should (= 12 (plist-get (etaf-desktop-settings desktop) :content-font-size)))
          (etaf-desktop-test-font-press runtime "Use Emacs default for content font size")
          (should-not (plist-get (etaf-desktop-settings desktop) :content-font-size))
          (etaf-desktop-set-setting desktop :content-font-size 12)
          (etaf-desktop-test-font-press runtime "Reset settings")
          (should-not (plist-get (etaf-desktop-settings desktop) :content-font-size))
          (should-not (etaf-desktop-test-font-height buffer "Emacs default"))
          (etaf-desktop-test-font-press runtime "Done")
          (should-not (etaf-desktop-settings-open-p desktop)))
      (etaf-desktop-close desktop))))

(provide 'etaf-desktop-font-tests)
;;; etaf-desktop-font-tests.el ends here
