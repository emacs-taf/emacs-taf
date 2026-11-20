;;; etaf-desktop-cursor-tests.el --- Native cursor visibility -*- lexical-binding: t; -*-

(require 'ert)
(require 'etaf-desktop)
(require 'etaf)

(defun etaf-desktop-cursor-test--redisplay (window)
  "Deliver Emacs's pre-redisplay event for WINDOW, including in batch tests."
  (with-current-buffer (window-buffer window)
    (run-hook-with-args 'pre-redisplay-functions window)))

(ert-deftest etaf-desktop-image-cursor-is-window-local-and-restored ()
  "A mounted surface owns the native cursor, and editing is the only caret.
Every ETAF buffer hides the native text cursor, so a click never leaves a
block over application content; a text input sets its own caret instead."
  (save-window-excursion
    (let* ((desktop (etaf-desktop-create :name " *desktop-cursor-test*"
                                        :canvas-width 400 :canvas-height 12))
           (other (generate-new-buffer " *desktop-cursor-other*"))
           (window (selected-window))
           (initial-visibility (internal-show-cursor-p window))
           (shape (default-value 'cursor-type)))
      (unwind-protect
          (progn
            (etaf-desktop-open-window
             desktop 'surface :title "Surface"
             :view (etaf-view
                    (column :padding '((lh 0) (ch 2) (lh 1) (ch 2))
                     (image :ref 'art :columns 8 :rows 2
                            :src '(image :type svg :data
                                         "<svg xmlns='http://www.w3.org/2000/svg' width='80' height='40'><rect width='80' height='40' fill='#203040'/></svg>"))
                     (text :ref 'copy "Navigate here")
                     (etaf-text-input :ref 'field :hide-label t :width '(ch 24)))))
            (let* ((buffer (etaf-desktop-mount desktop))
                   (runtime (etaf-runtime-for-buffer buffer))
                   (art (etaf-host-ref-position runtime 'art))
                   (copy (etaf-host-ref-position runtime 'copy)))
              (should (integerp art))
              (should (integerp copy))
              (set-window-buffer window buffer)
              (internal-show-cursor window t)
              ;; Keyboard navigation keeps the native cursor: it is how the
              ;; user sees which element the arrows reached.
              (should (equal (buffer-local-value 'cursor-type buffer) shape))
              ;; A pointer press hides the stray block it would leave behind.
              (dolist (position (list art copy))
                (set-window-point window position)
                (with-current-buffer buffer
                  (let ((last-command-event '(mouse-1 (nil 1 (0 . 0)))))
                    (run-hooks 'pre-command-hook)))
                (should-not (buffer-local-value 'cursor-type buffer)))
              ;; The next keyboard command brings the cursor back.
              (with-current-buffer buffer
                (let ((last-command-event ?j))
                  (run-hooks 'pre-command-hook)))
              (should (equal (buffer-local-value 'cursor-type buffer) shape))
              ;; Editing is the one state that installs a caret.
              (etaf-text-input-begin runtime 'field)
              (should (equal '(bar . 2) (buffer-local-value 'cursor-type buffer)))
              (etaf-text-input-end)
              (should (equal (buffer-local-value 'cursor-type buffer) shape))
              ;; Switching to an unrelated buffer and unmounting leave the
              ;; caller's cursor state as it was.
              (set-window-buffer window other)
              (should-not (local-variable-p 'cursor-type other))
              (set-window-buffer window buffer)
              (etaf-desktop-close desktop)
              (should-not (local-variable-p 'cursor-type buffer))))
        (etaf-desktop-close desktop)
        (internal-show-cursor window initial-visibility)
        (kill-buffer other)))))

(ert-deftest etaf-desktop-launcher-keeps-visible-keyboard-navigation ()
  "A opens the launcher; arrows move its focus and RET opens the chosen app.
Keyboard navigation keeps the native cursor, which marks the focused row."
  (save-window-excursion
    (let ((desktop (etaf-desktop-demo-open " *desktop-cursor-launcher*")))
      (unwind-protect
          (let* ((buffer (get-buffer " *desktop-cursor-launcher*"))
                 (runtime (etaf-runtime-for-buffer buffer)))
            (switch-to-buffer buffer)
            (execute-kbd-macro (kbd "a"))
            (should (etaf-desktop-launcher-open-p desktop))
            (let ((first (etaf-focused-host-ref runtime)))
              (should first)
              ;; Keyboard navigation keeps the native cursor visible.
              (with-current-buffer buffer (should cursor-type))
              (execute-kbd-macro (kbd "<down>"))
              (let ((next (etaf-focused-host-ref runtime)))
                (should (not (equal first next))))
              (execute-kbd-macro (kbd "<up>"))
              (let ((back (etaf-focused-host-ref runtime)))
                (should (equal first back)))
              (execute-kbd-macro (kbd "RET"))
              (should-not (etaf-desktop-launcher-open-p desktop))
              (let ((active (etaf-desktop-window-state
                             desktop (etaf-desktop-active-window desktop))))
                (should (equal "Calculator" (plist-get active :title))))))
        (etaf-desktop-close desktop)))))

(provide 'etaf-desktop-cursor-tests)
;;; etaf-desktop-cursor-tests.el ends here
