;;; etaf-desktop-demo-tests.el --- Runnable demo application behavior -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

(require 'ert)
(require 'etaf-desktop)

(defun etaf-desktop-demo-test--control (runtime label)
  "Return the mounted control named LABEL in RUNTIME."
  (let ((ref (car (cl-find label (etaf-runtime-host-props-entries runtime)
                           :key (lambda (entry) (plist-get (cdr entry) :aria-label))
                           :test #'equal))))
    (should ref)
    (should (etaf-host-ref-position runtime ref))
    ref))

(defun etaf-desktop-demo-test--body-ref (runtime id)
  "Return the mounted app body Host reference of window ID in RUNTIME.
The window Host carries :id; the body Host is its descendant with the demo
app body class, found through the public ancestry table."
  (let* ((entries (etaf-runtime-host-props-entries runtime))
         (window (car (cl-find-if
                       (lambda (entry)
                         (equal (format "%s" id) (plist-get (cdr entry) :id)))
                       entries)))
         (bodies (cl-loop for entry in entries
                          when (member "etaf-desktop-demo-app-body"
                                       (split-string
                                        (or (plist-get (cdr entry) :class) "")
                                        " " t))
                          collect (car entry))))
    (should window)
    (let ((ancestries (etaf-runtime-host-ancestries runtime bodies)))
      (cl-loop for body in bodies
               when (member window (gethash body ancestries))
               return body))))

(defun etaf-desktop-demo-test--scroll-offset (runtime id)
  "Return the scroll offset of window ID's demo body in RUNTIME."
  (etaf-scroll-offset runtime (etaf-desktop-demo-test--body-ref runtime id)))

(defun etaf-desktop-demo-test--scrollable-p (runtime id)
  "Return non-nil when window ID's demo body in RUNTIME can scroll further."
  (let* ((ref (etaf-desktop-demo-test--body-ref runtime id))
         (offset (etaf-scroll-offset runtime ref)))
    (prog1 (> (etaf-scroll-by runtime ref 1) offset)
      (etaf-scroll-to runtime ref offset))))

(ert-deftest etaf-desktop-demo-body-scroll-keeps-header-footer-live ()
  "The real Notes app scrolls inside resized chrome and retains input/actions."
  (let ((frame-width (frame-width)) (frame-height (frame-height))
        before-timers desktop owned-timers)
    ;; Native input starts Emacs's global undo housekeeping on first use.
    ;; Initialize it before attributing newly mounted timers to the demo.
    (with-temp-buffer
      (buffer-enable-undo)
      (undo-auto-amalgamate)
      (insert "Initialize native editing"))
    (setq before-timers (copy-sequence timer-list))
    (unwind-protect
        (save-window-excursion
          (set-frame-size (selected-frame) 800 50)
          (setq desktop (etaf-desktop-demo-open " *desktop-demo-scroll-test*"))
          (setq owned-timers (cl-set-difference timer-list before-timers :test #'eq))
          (should owned-timers)
          (let* ((buffer (get-buffer " *desktop-demo-scroll-test*"))
                 (runtime (etaf-runtime-for-buffer buffer))
                 (notes (cl-find "Notes" (etaf-desktop-windows desktop)
                                 :key (lambda (window) (plist-get window :title))
                                 :test #'equal))
                 (id (plist-get notes :id)))
            (should id)
            (set-window-buffer (selected-window) buffer)
            (dolist (window (etaf-desktop-windows desktop))
              (unless (equal id (plist-get window :id))
                (etaf-desktop-minimize-window desktop (plist-get window :id))))
            (etaf-desktop-focus-window desktop id)
            (etaf-desktop-move-window desktop id 0 0)
            (etaf-desktop-resize-window desktop id 300 9)
            (dotimes (_ 6)
              (etaf-dispatch-event
               runtime (etaf-desktop-demo-test--control runtime "Add line") 'press))
            (should (etaf-desktop-demo-test--scrollable-p runtime id))
            (with-current-buffer buffer
              (goto-char (point-min))
              (search-forward "Ideas worth keeping:")
              (goto-char (match-beginning 0))
              (let ((header-line (line-number-at-pos
                                  (etaf-host-ref-position
                                   runtime (etaf-desktop-demo-test--control runtime "Title"))))
                    (footer-line (line-number-at-pos
                                  (etaf-host-ref-position
                                   runtime (etaf-desktop-demo-test--control runtime "Add line")))))
                (etaf-scroll-by runtime (etaf-desktop-demo-test--body-ref runtime id) 2)
                (should (= 2 (etaf-desktop-demo-test--scroll-offset runtime id)))
                (should (= header-line
                           (line-number-at-pos
                            (etaf-host-ref-position
                             runtime (etaf-desktop-demo-test--control runtime "Title")))))
                (should (= footer-line
                           (line-number-at-pos
                            (etaf-host-ref-position
                             runtime (etaf-desktop-demo-test--control runtime "Add line")))))
                (etaf-scroll-by runtime (etaf-desktop-demo-test--body-ref runtime id) -2)
                (should (= 0 (etaf-desktop-demo-test--scroll-offset runtime id)))))
            (etaf-desktop-resize-window desktop id 300 30)
            (should-not (etaf-desktop-demo-test--scrollable-p runtime id))
            (etaf-desktop-resize-window desktop id 300 9)
            (should (= 0 (etaf-desktop-demo-test--scroll-offset runtime id)))
            (let ((ref (etaf-desktop-demo-test--control runtime "Title")))
              (with-current-buffer buffer cursor-type)
              (etaf-dispatch-event runtime ref 'press)
              (should (etaf-text-input-active-p runtime))
              (with-current-buffer buffer (should cursor-type))
              (execute-kbd-macro (vconcat (kbd "C-a C-k") "Edited note"))
              (etaf-text-input-end)
              (with-current-buffer buffer (should cursor-type)))
            (etaf-dispatch-event
             runtime (etaf-desktop-demo-test--control runtime "Clear") 'press)
            (with-current-buffer buffer
              (let ((text (buffer-substring-no-properties (point-min) (point-max))))
                (should (string-match-p "Edited note" text))
                (should (string-match-p "Empty note" text))))))
      (when desktop (etaf-desktop-close desktop))
      (set-frame-size (selected-frame) frame-width frame-height))
    (should-not (cl-intersection owned-timers timer-list :test #'eq))))

(provide 'etaf-desktop-demo-tests)
;;; etaf-desktop-demo-tests.el ends here
