;;; etaf-desktop-settings-tests.el --- Settings dialog behavior -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)

(defun desktop-test-ref (desktop name)
  "Return DESKTOP's Host reference for NAME."
  (intern (concat (plist-get (etaf-desktop-state desktop) :token) "-" name)))
(require 'etaf-desktop)

(defun etaf-desktop-test-settings-control (runtime label)
  "Return RUNTIME's committed control with accessible LABEL, or nil."
  (car (cl-find-if
        (lambda (entry) (equal label (plist-get (cdr entry) :aria-label)))
        (etaf-runtime-host-props-entries runtime))))

(defun etaf-desktop-test-settings-text (buffer)
  "Return BUFFER's visible text without properties."
  (with-current-buffer buffer
    (buffer-substring-no-properties (point-min) (point-max))))

(ert-deftest etaf-desktop-settings-tabs-retain-controls-and-active-fields ()
  "Tabs retain usable shell controls while publishing only their active form."
  (let ((desktop (etaf-desktop-create :name " *desktop-settings-tabs*"
                                      :canvas-width 900 :canvas-height 35)))
    (unwind-protect
        (progn
          (etaf-desktop-open-window desktop 'sample :title "Sample"
                                    :width 180 :height 8
                                    :view (etaf-view (text "Sample content")))
          (let* ((buffer (etaf-desktop-mount desktop))
                 (runtime (etaf-runtime-for-buffer buffer))
                 (window (etaf-desktop-window-state desktop 'sample)))
            (etaf-desktop-toggle-settings desktop t)
            (let* ((tabs '("Appearance" "Layout" "Behavior" "Shortcuts"))
                   (targets (mapcar
                             (lambda (label)
                               (etaf-desktop-test-settings-control runtime label))
                             tabs))
                   (sizes (mapcar (lambda (target) (etaf-host-ref-size runtime target))
                                  targets))
                   (dialog (etaf-desktop-test-settings-control
                            runtime "Desktop Settings"))
                   (reset (etaf-desktop-test-settings-control runtime "Reset settings"))
                   (done (etaf-desktop-test-settings-control runtime "Done"))
                   (fields '("Use Emacs default for title font size"
                             "Outer gap" "Drag lock modifier" "Focus next")))
              (should (and dialog reset done (cl-every #'identity targets)))
              (dolist (section
                       '(("Layout" 14 "Outer gap"
                          "Gaps use character widths across and text rows down.")
                         ("Behavior" 16 "Drag lock modifier"
                          "Changes are saved with your desktop session.")
                         ("Shortcuts" 20 "Focus next"
                          "Keys apply while the desktop is active.")
                         ("Appearance" 18 "Use Emacs default for title font size"
                          "Changes are saved with your desktop session.")))
                (let ((target (nth (cl-position (car section) tabs :test #'equal)
                                   targets)))
                  (etaf-focus runtime target)
                  (etaf-dispatch-event runtime target 'press)
                  (should (equal target (etaf-focused-host-ref runtime))))
                (should (equal (list 'lh (nth 1 section))
                               (plist-get (etaf-runtime-host-props-for runtime dialog)
                                          :height)))
                (should (string-match-p
                         (regexp-quote (nth 3 section))
                         (etaf-desktop-test-settings-text buffer)))
                (cl-mapc
                 (lambda (label target size)
                   (should (etaf-host-ref-position runtime target))
                   (let ((selected (plist-get (etaf-runtime-host-props-for runtime target)
                                              :aria-selected))
                         (current-size (etaf-host-ref-size runtime target)))
                     (should (eq (equal label (car section)) selected))
                     (should (equal size current-size))))
                 tabs targets sizes)
                (dolist (field fields)
                  (should (eq (equal field (nth 2 section))
                              (and (etaf-desktop-test-settings-control runtime field)
                                   t))))
                (dolist (target (list dialog reset done))
                  (should (etaf-host-ref-position runtime target)))
                (should (equal window (etaf-desktop-window-state desktop 'sample))))
              ;; Retained footer addresses act on the latest controller settings.
              (etaf-desktop-set-setting desktop :title-font-size 16)
              (etaf-dispatch-event runtime reset 'press)
              (should-not (plist-get (etaf-desktop-settings desktop) :title-font-size))
              (etaf-dispatch-event runtime done 'press)
              (should-not (etaf-desktop-settings-open-p desktop))
              (dolist (target (append targets (list dialog reset done)))
                (should-not (etaf-host-ref-position runtime target))))))
      (etaf-desktop-close desktop))))

(ert-deftest etaf-desktop-settings-reopen-retains-section-and-current-values ()
  "Closing releases the form; reopening shows the last tab with current values."
  (let ((desktop (etaf-desktop-create :name " *desktop-settings-reopen*"
                                      :canvas-width 900 :canvas-height 35)))
    (unwind-protect
        (let* ((buffer (etaf-desktop-mount desktop))
               (runtime (etaf-runtime-for-buffer buffer)))
          (etaf-desktop-toggle-settings desktop t)
          (etaf-dispatch-event
           runtime (etaf-desktop-test-settings-control runtime "Layout") 'press)
          (let ((field (etaf-desktop-test-settings-control runtime "Outer gap")))
            (should field)
            (etaf-desktop-close-settings desktop)
            (should-not (etaf-host-ref-position runtime field)))
          (etaf-desktop-set-setting desktop :tile-outer-gap 3)
          (should-not (etaf-desktop-test-settings-control runtime "Outer gap"))
          (etaf-desktop-toggle-settings desktop t)
          (should (etaf-desktop-test-settings-control runtime "Outer gap"))
          (should-not (etaf-desktop-test-settings-control runtime "Focus next"))
          (should (string-match-p "Outer gap[^0-9]*3"
                                  (etaf-desktop-test-settings-text buffer)))
          (etaf-dispatch-event
           runtime (etaf-desktop-test-settings-control runtime "Reset settings") 'press)
          (should (string-match-p "Outer gap[^0-9]*1"
                                  (etaf-desktop-test-settings-text buffer)))
          (etaf-dispatch-event
           runtime (etaf-desktop-test-settings-control runtime "Done") 'press)
          (should-not (etaf-desktop-settings-open-p desktop)))
      (etaf-desktop-close desktop))))

(ert-deftest etaf-desktop-settings-dismiss-restores-entry-focus ()
  "Done and Escape return focus to Settings after edits, reopening and reset."
  (let ((desktop (etaf-desktop-create :name " *desktop-settings-focus*"
                                      :canvas-width 900 :canvas-height 35)))
    (unwind-protect
        (let* ((buffer (etaf-desktop-mount desktop))
               (runtime (etaf-runtime-for-buffer buffer)))
          (save-window-excursion
            (switch-to-buffer buffer)
            (etaf-focus runtime (desktop-test-ref desktop "etaf-workspace-settings"))
            (etaf-dispatch-event runtime (desktop-test-ref desktop "etaf-workspace-settings") 'press)
            (etaf-dispatch-event runtime (desktop-test-ref desktop "settings-tab-layout") 'press)
            (etaf-desktop-set-setting desktop :tile-outer-gap 0)
            (etaf-desktop-set-setting desktop :tile-inner-gap 1)
            (etaf-desktop-set-setting desktop :tile-outer-gap 4)
            (etaf-desktop-set-setting desktop :tile-inner-gap 4)
            (etaf-dispatch-event
             runtime (etaf-desktop-test-settings-control runtime "Done") 'press)
            (should-not (etaf-desktop-settings-open-p desktop))
            (should (eq (desktop-test-ref desktop "etaf-workspace-settings")
                        (etaf-focused-host-ref runtime)))
            (etaf-dispatch-event runtime (desktop-test-ref desktop "etaf-workspace-settings") 'press)
            (etaf-dispatch-event runtime (desktop-test-ref desktop "settings-tab-layout") 'press)
            (etaf-dispatch-event
             runtime (etaf-desktop-test-settings-control runtime "Reset settings")
             'press)
            (call-interactively (key-binding (kbd "<escape>")))
            (should-not (etaf-desktop-settings-open-p desktop))
            (should (eq (desktop-test-ref desktop "etaf-workspace-settings")
                        (etaf-focused-host-ref runtime)))))
      (etaf-desktop-close desktop))))

(provide 'etaf-desktop-settings-tests)
;;; etaf-desktop-settings-tests.el ends here
