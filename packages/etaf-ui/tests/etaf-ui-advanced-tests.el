;;; etaf-ui-advanced-tests.el --- Composed advanced UI behavior -*- lexical-binding: t; -*-

;;; Code:
(require 'ert)
(require 'etaf-ui)

(defun etaf-ui-advanced-test-activate (runtime label)
  "Activate visible LABEL using RUNTIME's public target interface."
  (let ((target (car (cl-find-if
                     (lambda (entry)
                       (and (equal label (plist-get (cdr entry) :aria-label))
                            (etaf-host-ref-position runtime (car entry))))
                     (etaf-runtime-host-props-entries runtime)))))
    (should target)
    (etaf-focus runtime target)
    (etaf-activate runtime)))

(ert-deftest etaf-ui-advanced-components-compose-public-contracts ()
  "DatePicker, Tree, Calendar and CommandPalette keep caller-owned values."
  (let ((buffer (generate-new-buffer " *advanced-components*"))
        (date (etaf-ref "2026-09-16"))
        (expanded (etaf-ref '(root)))
        (palette (etaf-ref nil))
        selected selected-date)
    (unwind-protect
        (with-current-buffer buffer
          (etaf-mount
           buffer
           (etaf-view
            (column :width '(ch 120) :height '(lh 50)
              (etaf-date-picker :bind date :label "Release date")
              (etaf-tree
               :items '((:key root :label "Release"
                          :children ((:key design :label "Design"))))
               :expanded expanded
               :on-toggle (lambda (keys) (setf (etaf-value expanded) keys))
               :on-select (lambda (key) (setq selected key)))
              (etaf-calendar :month '(2026 9) :value 16
                             :on-change (lambda (next) (setq selected-date next)))
              (etaf-button :label "Open palette"
                           :on-press (lambda () (setf (etaf-value palette) t)))
              (etaf-command-palette
               :open palette :title "Commands"
               :items '((:key open :title "Open" :description "Open item"))
               :on-select (lambda (key) (setq selected key))
               :on-close (lambda () (setf (etaf-value palette) nil))))))
          (let ((runtime (etaf-runtime-for-buffer buffer)))
            (should (string-match-p "Release date" (buffer-string)))
            (etaf-ui-advanced-test-activate runtime "September 16")
            (should (equal selected-date '(2026 9 16)))
            (etaf-ui-advanced-test-activate runtime "Release")
            (should-not (string-match-p "Design" (buffer-string)))
            (etaf-ui-advanced-test-activate runtime "Release")
            (etaf-ui-advanced-test-activate runtime "Design")
            (should (eq selected 'design))
            (etaf-ui-advanced-test-activate runtime "Open palette")
            (should (string-match-p "Commands" (buffer-string)))
            (should (string-match-p "Open item" (buffer-string)))
            (etaf-ui-advanced-test-activate runtime "Open")
            (should (eq selected 'open))))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer)))
        (etaf-unmount runtime))
      (kill-buffer buffer))))

(defun etaf-ui-advanced-test--key (key)
  "Execute the native command bound to KEY in the current test buffer."
  (let ((command (key-binding (kbd key))))
    (should (commandp command))
    (call-interactively command)))

(ert-deftest etaf-ui-qr-paint-draws-modules-with-scannable-contrast ()
  "The painted code pairs module rows, keeps a quiet zone and stays black on white."
  (let ((code (etaf-ui-qr-paint '("111" "101" "111"))))
    (should (equal (split-string code "\n")
                   (list "           "
                         "           "
                         "    █▀█    "
                         "    ▀▀▀    "
                         "           "
                         "           ")))
    (dolist (position '(2 4 5 16 17))
      (let ((face (get-text-property position 'face code)))
        (should (equal "#000000" (plist-get face :foreground)))
        (should (equal "#FFFFFF" (plist-get face :background))))))
  ;; A shorter row is blank past its end, and QUIET sets the margin exactly.
  (should (equal (etaf-ui-qr-paint '("1" "11") 0) "█▄"))
  (should (equal (nth 1 (split-string (etaf-ui-qr-paint '("11" "10") 2) "\n"))
                 "  █▀  "))
  (should-error (etaf-ui-qr-paint '("1" 2)) :type 'wrong-type-argument))

(ert-deftest etaf-ui-qr-login-overlays-the-code-and-returns-its-dismissal ()
  "The sign-in panel follows caller state, blocks the page and reports close."
  (with-temp-buffer
    (let ((open (etaf-ref nil))
          (code (etaf-ref (etaf-ui-qr-paint '("111" "101" "111"))))
          (status (etaf-ref "等待扫码…"))
          (background 0))
      (unwind-protect
          (progn
            (etaf-mount
             (current-buffer)
             (etaf-view
              (column :width '(ch 80) :height '(lh 25)
                (etaf-button :ref 'entry :label "Sign in"
                             :on-press (lambda () (setf (etaf-value open) t)))
                (etaf-button :ref 'background :label "Library"
                             :on-press (lambda () (cl-incf background)))
                (etaf-ui-qr-login :open open :code code :status status
                                  :on-close (lambda () (setf (etaf-value open) nil))))))
            (let ((runtime (etaf-runtime-for-buffer (current-buffer))))
              (should-not (string-match-p "扫码登录" (buffer-string)))
              (etaf-focus runtime 'entry)
              (etaf-activate runtime)
              (should (string-match-p "扫码登录" (buffer-string)))
              (should (string-match-p "█" (buffer-string)))
              (should (string-match-p "等待扫码…" (buffer-string)))
              (should (string-match-p "请用手机客户端扫码" (buffer-string)))
              (should-not (etaf-host-ref-position runtime 'background))
              (should-error (etaf-focus runtime 'background) :type 'etaf-event-error)
              (setf (etaf-value status) "已扫码，请在手机上确认")
              (should (string-match-p "已扫码，请在手机上确认" (buffer-string)))
              (etaf-ui-advanced-test--key "<escape>")
              (should-not (etaf-value open))
              (should-not (string-match-p "扫码登录" (buffer-string)))
              (should (eq 'entry (etaf-focused-host-ref runtime)))
              (etaf-activate runtime)
              (etaf-ui-advanced-test-activate runtime "取消")
              (should-not (etaf-value open))
              (should (= background 0))))
        (when-let* ((runtime (etaf-runtime-for-buffer (current-buffer))))
          (etaf-unmount runtime))))
    (dolist (props '((:open bogus :on-close ignore)
                     (:code 42 :on-close ignore)
                     (:status 42 :on-close ignore)
                     (:hint 7 :on-close ignore)
                     (:open t)))
      (with-temp-buffer
        (should-error (etaf-mount (current-buffer)
                                  (etaf-node 'etaf-ui-qr-login props nil))
                      :type 'etaf-component-call-error)))))

;;; etaf-ui-advanced-tests.el ends here
