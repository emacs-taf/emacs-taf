;;; -*- lexical-binding: t; -*-
;;; etaf-ui-key-help-tests.el --- Public modal keyboard help scenarios

;;; Code:
(require 'ert)
(require 'etaf-ui)

(defun etaf-ui-key-help-test-control (runtime label)
  "Return the visible public Host reference with LABEL in RUNTIME."
  (car (cl-find-if
        (lambda (entry)
          (and (equal (plist-get (cdr entry) :aria-label) label)
               (etaf-host-ref-position runtime (car entry))))
        (etaf-runtime-host-props-entries runtime))))

(defun etaf-ui-key-help-test-text ()
  "Return the current canvas without display properties."
  (buffer-substring-no-properties (point-min) (point-max)))

(defun etaf-ui-key-help-test-key (key)
  "Run the effective command bound to KEY."
  (let ((command (key-binding (kbd key) t)))
    (should (commandp command))
    (call-interactively command)))

(etaf-define-component etaf-ui-key-help-test-page (&key theme counter revision)
  "Provide a themed app whose effective bindings can be inspected."
  :setup (etaf-theme-provide theme)
  :view
  (column :ref 'help-test-app :aria-label "RSS 阅读器"
          :width 'stretch :height '(lh 40)
          :color (etaf-theme-token :ui-panel-fg)
          :background-color (etaf-theme-token :ui-panel-bg)
          :help "阅读进度不会因查看帮助而改变。"
          :keys (list (list "g" (lambda () (cl-incf (etaf-value counter))) "刷新列表")
                      (list "T" (lambda () (cl-incf (etaf-value counter))) "切换主题"))
    (text "保留的背景内容")
    (text (expr (format "Revision %s" (etaf-value revision))))
    (column :ref 'help-test-region :aria-label "文章列表"
            :region '(:id articles :label "文章列表" :key "a")
            :keys (list (list "s" (lambda () (cl-incf (etaf-value counter))) "收藏文章")
                        (list "n" (lambda () (cl-incf (etaf-value counter))) "下一条未读"))
      (etaf-button :ref 'help-test-opener :label "打开帮助" :on-press #'etaf-help))))

(defmacro etaf-ui-key-help-test-with-app (&rest body)
  "Mount a themed app and run BODY with RUNTIME, THEME, COUNTER and REVISION."
  (declare (indent 0))
  `(with-temp-buffer
     (let* ((counter (etaf-ref 0))
            (revision (etaf-ref 1))
            (theme (etaf-ref '(:ui-panel-bg "#fafbfd" :ui-panel-fg "#25334a"
                              :ui-panel-border "#c8d2e1" :ui-accent "#405f9b"
                              :ui-muted-fg "#647187")))
            (runtime nil))
       (unwind-protect
           (progn
             (etaf-mount (current-buffer)
                         (etaf-view (etaf-ui-key-help-test-page
                                     :theme theme :counter counter :revision revision))
                         '(:viewport-width 1200 :viewport-height 40))
             (setq runtime (etaf-runtime-for-buffer (current-buffer)))
             (etaf-focus runtime 'help-test-opener)
             ,@body)
         (when (and runtime (etaf-runtime-mounted-p runtime))
           (etaf-unmount runtime))))))

(ert-deftest etaf-ui-key-help-opens-in-place-and-restores-its-opener ()
  "Help keeps the same buffer and window tree and restores the caller on Escape."
  (etaf-ui-key-help-test-with-app
    (let ((windows (window-list)) (buffers (buffer-list))
          (before (etaf-ui-key-help-test-text)))
      (etaf-ui-key-help-test-key "?")
      (let ((text (etaf-ui-key-help-test-text))
            (close (etaf-ui-key-help-test-control runtime "关闭帮助")))
        (should (string-match-p "快捷键" text))
        (should (string-match-p "收藏文章" text))
        (should close)
        (should (equal windows (window-list)))
        (should (equal buffers (buffer-list)))
        (should (= (etaf-value counter) 0)))
      (etaf-ui-key-help-test-key "<escape>")
      (should (equal before (etaf-ui-key-help-test-text)))
      (let ((focused (etaf-focused-host-ref runtime)))
        (should (eq focused 'help-test-opener))))))

(ert-deftest etaf-ui-key-help-guards-local-commands-and-repeated-open ()
  "A modal blocks both business letters and local sequences without changing bindings."
  (etaf-ui-key-help-test-with-app
    (let ((map (make-sparse-keymap)))
      (define-key map (kbd "C-c b")
                  (lambda () (interactive) (cl-incf (etaf-value counter))))
      (use-local-map map))
    (etaf-help runtime)
    (let ((first (etaf-ui-key-help-test-text)))
      (etaf-ui-key-help-test-key "?")
      (should (equal first (etaf-ui-key-help-test-text))))
    (etaf-ui-key-help-test-key "g")
    (etaf-ui-key-help-test-key "s")
    (etaf-ui-key-help-test-key "C-c b")
    (should (= (etaf-value counter) 0))
    (should (eq (key-binding (kbd "C-g")) 'keyboard-quit))
    (etaf-help-close runtime)
    (etaf-ui-key-help-test-key "g")
    (etaf-ui-key-help-test-key "C-c b")
    (should (= (etaf-value counter) 2))))

(ert-deftest etaf-ui-key-help-keeps-its-snapshot-through-background-updates ()
  "Updating the app behind help leaves its opening bindings and modal alive."
  (etaf-ui-key-help-test-with-app
    (let ((data (etaf-help-data runtime)))
      (etaf-help runtime)
      (etaf-set-value revision 2)
      (let ((current (etaf-help-data runtime))
            (close (etaf-ui-key-help-test-control runtime "关闭帮助")))
        (should (equal data current))
        (should close))
      (etaf-help-close runtime)
      (should (string-match-p "Revision 2" (etaf-ui-key-help-test-text))))))

(ert-deftest etaf-ui-key-help-search-keeps-question-mark-as-text ()
  "Native search filters help, and Escape exits editing before closing it."
  (save-window-excursion
    (etaf-ui-key-help-test-with-app
      (switch-to-buffer (current-buffer))
      (etaf-help runtime)
      (etaf-ui-key-help-test-key "/")
      (let ((editing (etaf-text-input-active-p runtime)))
        (should editing))
      (execute-kbd-macro (kbd "?"))
      (let ((text (etaf-ui-key-help-test-text)))
        (should (string-match-p "查看快捷键" text))
        (should-not (string-match-p "收藏文章" text)))
      (execute-kbd-macro (kbd "<escape>"))
      (let ((editing (etaf-text-input-active-p runtime))
            (close (etaf-ui-key-help-test-control runtime "关闭帮助")))
        (should-not editing)
        (should close))
      (execute-kbd-macro (kbd "<escape>"))
      (should (string-match-p "保留的背景内容" (etaf-ui-key-help-test-text)))
      (should (= (etaf-value counter) 0)))))

(ert-deftest etaf-ui-key-help-backdrop-click-ends-search-and-restores-focus ()
  "An outside click closes help even during search, without a background action."
  (save-window-excursion
    (etaf-ui-key-help-test-with-app
      (switch-to-buffer (current-buffer))
      (etaf-help runtime)
      (etaf-ui-key-help-test-key "/")
      (execute-kbd-macro "refresh")
      (let* ((map (get-text-property (point-min) 'keymap))
             (command (and (keymapp map) (lookup-key map [mouse-1])))
             (last-input-event (list 'mouse-1 (list (selected-window) 1 '(0 . 0) 0))))
        (should (commandp command))
        (call-interactively command))
      (let ((editing (etaf-text-input-active-p runtime))
            (closed (etaf-help-close runtime))
            (focus (etaf-focused-host-ref runtime)))
        (should-not editing)
        (should-not closed)
        (should (eq focus 'help-test-opener)))
      (should (= (etaf-value counter) 0)))))

(provide 'etaf-ui-key-help-tests)
;;; etaf-ui-key-help-tests.el ends here
