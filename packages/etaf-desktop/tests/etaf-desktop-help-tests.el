;;; -*- lexical-binding: t; -*-
;;; etaf-desktop-help-tests.el --- Same-buffer help and nested modal lifetime

(require 'ert)
(require 'etaf-desktop)

(defmacro etaf-desktop-help-test-with-desktop (binding &rest body)
  "Run BODY with a mounted desktop and its Runtime named by BINDING."
  (declare (indent 1))
  `(let* ((,(car binding) (etaf-desktop-create :name " *desktop-help-test*"
                                             :canvas-width 1000 :canvas-height 40))
          (buffer (etaf-desktop-mount ,(car binding)))
          (,(cadr binding) (etaf-runtime-for-buffer buffer)))
     (unwind-protect
         (save-window-excursion
           (switch-to-buffer buffer)
           ,@body)
       (etaf-desktop-close ,(car binding)))))

(ert-deftest etaf-desktop-help-preserves-scoped-keys-and-window-state ()
  "Help is read-only, honors child keys and preserves the application's window."
  (etaf-desktop-help-test-with-desktop (desktop runtime)
    (etaf-desktop-open-window
     desktop 'notes :title "Notes" :x 3 :y 2 :width 300 :height 12
     :view (etaf-view
            (box :padding '((lh 1) (ch 2)) :aria-label "Notes"
                 :keys (list (list "n" (lambda () (error "Help executed a command")) "New note"))
              (box :ref 'note-entry :tab-index 0 "Read a note"))))
    (etaf-focus runtime 'note-entry)
    (let* ((windows (window-list)) (buffers (buffer-list))
           (state (etaf-desktop-window-state desktop 'notes))
           (fields '(:x :y :width :height :z-index :minimized :maximized))
           (geometry (mapcar (lambda (key) (plist-get state key)) fields)))
      (execute-kbd-macro "?")
      (let* ((data (etaf-help-data runtime))
             (title (plist-get data :title))
             (entries (mapcan (lambda (group) (copy-sequence (plist-get group :entries)))
                              (plist-get data :groups)))
             (entry (cl-find "n" entries :key (lambda (value) (plist-get value :key)) :test #'equal))
             (move (cl-find "M-<left>" entries :key (lambda (value) (plist-get value :key)) :test #'equal))
             (move-source (plist-get move :source)))
        (should (equal title "ETAF Desktop"))
        (should (equal (plist-get entry :label) "New note"))
        (should (equal move-source "Notes")))
      (should (equal windows (window-list)))
      (should (equal buffers (buffer-list)))
      (execute-kbd-macro "nqo")
      (execute-kbd-macro (kbd "/ n ? <escape>"))
      (let ((editing (etaf-text-input-active-p runtime))
            (text (buffer-substring-no-properties (point-min) (point-max))))
        (should-not editing)
        (should (string-match-p "快捷键" text)))
      (execute-kbd-macro (kbd "<escape>"))
      (let* ((after (etaf-desktop-window-state desktop 'notes))
             (after-geometry (mapcar (lambda (key) (plist-get after key)) fields))
             (active (etaf-desktop-active-window desktop))
             (focus (etaf-focused-host-ref runtime))
             (closed (etaf-help-close runtime)))
        (should (equal geometry after-geometry))
        (should (eq active 'notes))
        (should (eq focus 'note-entry))
        (should-not closed)))))

(ert-deftest etaf-desktop-help-dismisses-only-the-top-modal ()
  "Closing help opened over Settings leaves Settings open until its own Escape."
  (etaf-desktop-help-test-with-desktop (desktop runtime)
    (etaf-desktop-toggle-settings desktop t)
    (execute-kbd-macro "?")
    (execute-kbd-macro (kbd "<escape>"))
    (let ((settings (etaf-desktop-settings-open-p desktop))
          (help (etaf-help-close runtime)))
      (should settings)
      (should-not help))
    (execute-kbd-macro (kbd "<escape>"))
    (let ((settings (etaf-desktop-settings-open-p desktop)))
      (should-not settings))))

(provide 'etaf-desktop-help-tests)
