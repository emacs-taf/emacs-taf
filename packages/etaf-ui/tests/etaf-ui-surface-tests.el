;;; etaf-ui-surface-tests.el --- Floating panel public behavior -*- lexical-binding: t; -*-

;;; Commentary:
;; Exercise catalog Components through their rendered controls and native keys.

;;; Code:
(require 'ert)
(require 'etaf-ui)
(require 'ebox)

(defun etaf-ui-surface-test--control (runtime label)
  "Find the visible control with LABEL in RUNTIME's public Host properties."
  (car (cl-find-if
        (lambda (entry)
          (and (equal label (plist-get (cdr entry) :aria-label))
               (etaf-host-ref-position runtime (car entry))))
        (etaf-runtime-host-props-entries runtime))))

(defun etaf-ui-surface-test--key (key)
  "Execute the native command bound to KEY in the current test buffer."
  (let ((command (key-binding (kbd key))))
    (should (commandp command))
    (call-interactively command)))

(ert-deftest etaf-ui-drawer-composes-both-sides-and-restores-focus ()
  "Both modal drawer edges retain controlled values and restore their opener."
  (dolist (side '(left right))
    (with-temp-buffer
      (let ((open (etaf-ref nil)) (checked (etaf-ref nil)))
        (unwind-protect
            (progn
              (etaf-mount
               (current-buffer)
               (etaf-view
                (column :width '(ch 80) :height '(lh 25)
                  (etaf-button :ref 'open :label "Inspect"
                               :on-press (lambda () (setf (etaf-value open) t)))
                  (etaf-drawer :open open :placement side :title "Inspector"
                               :on-close (lambda () (setf (etaf-value open) nil))
                    (etaf-checkbox :bind checked :label "Reviewed")
                    (slot :name 'footer
                      (etaf-button :label "Done"
                                   :on-press (lambda () (setf (etaf-value open) nil))))))))
              (let ((runtime (etaf-runtime-for-buffer (current-buffer))))
                (etaf-focus runtime 'open)
                (etaf-activate runtime)
                (should-not (etaf-host-ref-position runtime 'open))
                (should (string-match-p "Inspector" (buffer-string)))
                (etaf-activate runtime)
                (should (etaf-value checked))
                (etaf-ui-surface-test--key "<escape>")
                (should-not (etaf-value open))
                (should (eq 'open (etaf-focused-host-ref runtime)))
                (etaf-activate runtime)
                (should (etaf-value checked))
                (etaf-focus runtime (etaf-ui-surface-test--control runtime "Done"))
                (etaf-activate runtime)
                (should-not (etaf-value open))
                (should (eq 'open (etaf-focused-host-ref runtime)))))
          (when-let* ((runtime (etaf-runtime-for-buffer (current-buffer))))
            (etaf-unmount runtime)))))))

(defun etaf-ui-surface-test--underlay-face ()
  "Return the face of the painted \"Underlay\" run in the current buffer."
  (save-excursion
    (goto-char (point-min))
    (when (search-forward "Underlay" nil t)
      (get-text-property (match-beginning 0) 'face))))

(ert-deftest etaf-ui-modal-backdrop-dims-and-restores-the-painted-application ()
  "A modal keeps the application painted, dims it, and restores it on close."
  (with-temp-buffer
    (let ((open (etaf-ref nil)) (pressed 0))
      (unwind-protect
          (progn
            (etaf-mount
             (current-buffer)
             (etaf-view
              (column :ref 'root :width '(ch 60) :height '(lh 20)
                (box :color "#FFFFFF" "Underlay")
                (etaf-button :ref 'entry :label "Open"
                             :on-press (lambda ()
                                         (cl-incf pressed)
                                         (setf (etaf-value open) t)))
                (etaf-dialog :open open :title "Preferences"
                             :on-close (lambda () (setf (etaf-value open) nil))
                  (etaf-label :text "Content")))))
            (let* ((runtime (etaf-runtime-for-buffer (current-buffer)))
                   (before (etaf-ui-surface-test--underlay-face)))
              (should before)
              (etaf-dispatch-event runtime 'entry 'press)
              (should (etaf-value open))
              (should (string-match-p "Underlay" (buffer-string)))
              (should (string-match-p "Preferences" (buffer-string)))
              (let ((dimmed (etaf-ui-surface-test--underlay-face)))
                (should dimmed)
                (should-not (equal before dimmed)))
              (etaf-ui-surface-test--key "<escape>")
              (should-not (etaf-value open))
              (should (equal (etaf-ui-surface-test--underlay-face) before))))
        (when-let* ((runtime (etaf-runtime-for-buffer (current-buffer))))
          (etaf-unmount runtime))))))

(ert-deftest etaf-ui-modal-backdrop-click-dismisses-without-click-through ()
  "Dialog and drawer backdrops dismiss by pointer only and restore the opener."
  (dolist (component '(etaf-dialog etaf-drawer))
    (with-temp-buffer
      (let ((open (etaf-ref nil)) (checked (etaf-ref nil)) (closed 0) (pressed 0))
        (unwind-protect
            (progn
              (etaf-mount
               (current-buffer)
               (etaf-view
                (column :width '(ch 80) :height '(lh 30)
                  (etaf-button :ref 'entry :label "Open"
                               :on-press (lambda () (setf (etaf-value open) t)))
                  (etaf-button :ref 'background :label "Background"
                               :on-press (lambda () (cl-incf pressed)))
                  (expr
                   (etaf-node component
                              (list :open open :title "Preferences"
                                    :on-close (lambda ()
                                                (cl-incf closed)
                                                (setf (etaf-value open) nil)))
                              (list (etaf-view (etaf-checkbox :ref 'enabled :bind checked
                                                              :label "Enabled"))))))))
              (let ((runtime (etaf-runtime-for-buffer (current-buffer))))
                (etaf-focus runtime 'entry)
                (etaf-activate runtime)
                (let* ((backdrop
                        (car (cl-find-if
                              (lambda (entry) (plist-get (cdr entry) :backdrop-filter))
                              (etaf-runtime-host-props-entries runtime))))
                       (click (list 'mouse-1 (list (selected-window) 1 '(0 . 0) 0))))
                  (should backdrop)
                  (let ((last-input-event ?\s))
                    (etaf-dispatch-event runtime backdrop 'press))
                  (should (= closed 0))
                  (let ((last-input-event click))
                    (etaf-dispatch-event runtime 'enabled 'press))
                  (should (etaf-value checked))
                  (should (etaf-value open))
                  (let ((last-input-event click))
                    (etaf-dispatch-event runtime backdrop 'press))
                  (should (= closed 1))
                  (should (= pressed 0))
                  (should-not (etaf-value open))
                  (should (eq (etaf-focused-host-ref runtime) 'entry)))))
          (when-let* ((runtime (etaf-runtime-for-buffer (current-buffer))))
            (etaf-unmount runtime)))))))

(ert-deftest etaf-ui-dropdown-opens-navigates-selects-and-restores-focus ()
  "A dropdown renders its items, skips disabled ones and invokes selection once."
  (with-temp-buffer
    (let (selected)
      (unwind-protect
          (progn
            (etaf-mount
             (current-buffer)
             (etaf-view
              (column :width '(ch 80) :height '(lh 25)
                (etaf-dropdown-menu
                 :label "Actions"
                 :items '((:key edit :label "Edit") (:key delete :label "Delete" :disabled t)
                          (:key copy :label "Copy"))
                 :on-select (lambda (key) (push key selected)))
                (etaf-button :label "Outside" :on-press #'ignore))))
            (let* ((runtime (etaf-runtime-for-buffer (current-buffer)))
                   (trigger (etaf-ui-surface-test--control runtime "Actions"))
                   (before-map (key-binding (kbd "<escape>"))))
              (should trigger)
              (etaf-focus runtime trigger)
              (etaf-activate runtime)
              (should (string-match-p "Edit" (buffer-string)))
              (should (string-match-p "Delete" (buffer-string)))
              (should (equal (etaf-focused-host-ref runtime)
                          (etaf-ui-surface-test--control runtime "Edit")))
              (etaf-ui-surface-test--key "<down>")
              (should (equal (etaf-focused-host-ref runtime)
                          (etaf-ui-surface-test--control runtime "Copy")))
              (etaf-ui-surface-test--key "TAB")
              (should (equal (etaf-focused-host-ref runtime)
                          (etaf-ui-surface-test--control runtime "Edit")))
              (etaf-ui-surface-test--key "RET")
              (should (equal selected '(edit)))
              (should-not (string-match-p "Delete" (buffer-string)))
              (should (equal trigger (etaf-focused-host-ref runtime)))
              (should (eq before-map (key-binding (kbd "<escape>"))))
              (etaf-activate runtime)
              (etaf-ui-surface-test--key "<escape>")
              (should (equal selected '(edit)))
              (should (equal trigger (etaf-focused-host-ref runtime)))))
        (when-let* ((runtime (etaf-runtime-for-buffer (current-buffer))))
          (etaf-unmount runtime))))))

(etaf-define-component etaf-ui-surface-test--themed-menu ()
  "A dropdown that reads the application's provided theme tokens."
  :setup (etaf-theme-provide '(:ui-accent-soft-bg "#123456"))
  :render
  (etaf-view
   (column :width '(ch 80) :height '(lh 10)
     (etaf-dropdown-menu
      :label "Actions"
      :items '((:key edit :label "Edit" :icon play))
      :on-select #'ignore))))

(ert-deftest etaf-ui-menu-hover-token-resolves-against-the-provided-theme ()
  "An iconic dropdown row hovers with the application's accent tint.
A deferred token nested in `:hover-style' is not lowered by ETAF host
props, so the catalog resolves it before the mouse face reaches Ebox."
  (with-temp-buffer
    (unwind-protect
        (progn
          (etaf-mount (current-buffer) (etaf-view (etaf-ui-surface-test--themed-menu)))
          (let* ((runtime (etaf-runtime-for-buffer (current-buffer)))
                 (trigger (etaf-ui-surface-test--control runtime "Actions")))
            (should trigger)
            (etaf-focus runtime trigger)
            (etaf-activate runtime)
            (let* ((ref (etaf-ui-surface-test--control runtime "Edit"))
                   (props (and ref (etaf-runtime-host-props-for runtime ref))))
              (should ref)
              (should (equal (plist-get (plist-get props :hover-style) :background-color)
                             "#123456")))))
      (when-let* ((runtime (etaf-runtime-for-buffer (current-buffer))))
        (etaf-unmount runtime)))))

(ert-deftest etaf-ui-dialog-composes-slots-and-blocks-covered-controls ()
  "The modal canvas covers background targets and returns focus after closing."
  (with-temp-buffer
    (let ((open (etaf-ref nil)) (value (etaf-ref nil)) (background 0))
      (unwind-protect
          (progn
            (etaf-mount
             (current-buffer)
             (etaf-view
              (column :width '(ch 80) :height '(lh 25)
                (etaf-button :ref 'entry :label "Open dialog"
                             :on-press (lambda () (setf (etaf-value open) t)))
                (etaf-button :ref 'background :label "Background"
                             :on-press (lambda () (cl-incf background)))
                (etaf-dialog :open open :title "Preferences"
                             :on-close (lambda () (setf (etaf-value open) nil))
                  (etaf-checkbox :bind value :label "Enabled")
                  (slot :name 'footer
                    (etaf-button :label "Save"
                                 :on-press (lambda () (setf (etaf-value open) nil))))))))
            (let ((runtime (etaf-runtime-for-buffer (current-buffer))))
              (etaf-focus runtime 'entry)
              (etaf-activate runtime)
              (should (string-match-p "Preferences" (buffer-string)))
              (should-not (etaf-host-ref-position runtime 'background))
              (should-error (etaf-focus runtime 'background) :type 'etaf-event-error)
              (etaf-activate runtime)
              (should (etaf-value value))
              (dotimes (_ 5)
                (etaf-ui-surface-test--key "TAB")
                (should-not (memq (etaf-focused-host-ref runtime) '(entry background))))
              (etaf-ui-surface-test--key "<escape>")
              (should-not (etaf-value open))
              (should (eq 'entry (etaf-focused-host-ref runtime)))
              (should (etaf-host-ref-position runtime 'background))
              (should (= background 0))))
        (when-let* ((runtime (etaf-runtime-for-buffer (current-buffer))))
          (etaf-unmount runtime))))))

(ert-deftest etaf-ui-dismisses-surfaces-on-presses-outside-their-panel ()
  "A root press capture closes open surfaces the press missed, keeping the hit one."
  (with-temp-buffer
    (let ((open (etaf-ref nil)) (value (etaf-ref nil)) (background 0)
          (dismissed nil))
      (unwind-protect
          (progn
            (etaf-mount
             (current-buffer)
             (etaf-view
              (column :ref 'root :width '(ch 80) :height '(lh 25)
                      :on-press-capture
                      (lambda () (push (etaf-ui-dismiss-outside-press) dismissed))
                (etaf-button :ref 'entry :label "Open dialog"
                             :on-press (lambda () (setf (etaf-value open) t)))
                (etaf-button :ref 'background :label "Background"
                             :on-press (lambda () (cl-incf background)))
                (etaf-dialog :open open :title "Preferences" :backdrop nil
                             :on-close (lambda () (setf (etaf-value open) nil))
                  (etaf-checkbox :ref 'enabled :bind value :label "Enabled")))))
            (let ((runtime (etaf-runtime-for-buffer (current-buffer))))
              (etaf-dispatch-event runtime 'entry 'press)
              (should (etaf-value open))
              (should (string-match-p "Preferences" (buffer-string)))
              (etaf-dispatch-event runtime 'enabled 'press)
              (should (etaf-value value))
              (should (etaf-value open))
              (etaf-dispatch-event runtime 'background 'press)
              (should (= background 1))
              (should-not (etaf-value open))
              (should-not (string-match-p "Preferences" (buffer-string)))
              (etaf-dispatch-event runtime 'background 'press)
              (should (equal dismissed '(0 1 0 0)))
              (should-error (etaf-ui-dismiss-outside-press)
                            :type 'etaf-event-error)))
        (when-let* ((runtime (etaf-runtime-for-buffer (current-buffer))))
          (etaf-unmount runtime))))))

(ert-deftest etaf-ui-dialog-compact-height-keeps-one-row-header ()
  "A compact dialog uses the requested height and no extra header gap."
  (with-temp-buffer
    (let ((open (etaf-ref t)))
      (unwind-protect
          (progn
            (etaf-mount
             (current-buffer)
             (etaf-view
              (column :width '(ch 80) :height '(lh 30)
                (etaf-label :text "Background")
                (etaf-dialog :open open :title "Settings"
                             :width '(ch 42) :height '(lh 18) :compact t
                             :backdrop nil
                             :on-close (lambda () (setf (etaf-value open) nil))
                  (etaf-label :text "One-row content")))))
            (let* ((runtime (etaf-runtime-for-buffer (current-buffer)))
                   (panel
                    (cl-find-if
                     (lambda (entry)
                       (equal "etaf-floating-panel"
                              (plist-get (cdr entry) :class)))
                     (etaf-runtime-host-props-entries runtime)))
                   (props (cdr panel)))
              (should panel)
              (should (equal '(lh 18) (plist-get props :height)))
              (should (equal '(lh 0) (plist-get props :item-gap)))
              (should (string-match-p "Background" (buffer-string)))
              (setf (etaf-value open) nil)
              (should (string-match-p "Background" (buffer-string)))))
        (when-let* ((runtime (etaf-runtime-for-buffer (current-buffer))))
          (etaf-unmount runtime))))))

(ert-deftest etaf-ui-floating-surfaces-nest-and-release-buffer-shortcuts ()
  "Escape closes a menu inside a dialog first, then the dialog, then nothing."
  (with-temp-buffer
    (let ((open (etaf-ref t)) (outer 0))
      (unwind-protect
          (progn
            (etaf-mount
             (current-buffer)
             (etaf-view
              (column :width '(ch 80) :height '(lh 30)
                      :keys (list (list "o" (lambda () (cl-incf outer))))
                (etaf-button :ref 'start :label "Start" :on-press #'ignore)
                (etaf-dialog :open open :title "Outer"
                             :on-close (lambda () (setf (etaf-value open) nil))
                  (etaf-dropdown-menu :label "Nested"
                                      :items '((:key one :label "Nested choice"))
                                      :on-select #'ignore)))))
            (let* ((runtime (etaf-runtime-for-buffer (current-buffer)))
                   (trigger (etaf-ui-surface-test--control runtime "Nested")))
              (etaf-focus runtime trigger)
              (etaf-activate runtime)
              (should (etaf-ui-surface-test--control runtime "Nested choice"))
              (should (eq (key-binding (kbd "o")) #'ignore))
              (etaf-ui-surface-test--key "<escape>")
              (should-not (etaf-ui-surface-test--control runtime "Nested choice"))
              (should (etaf-value open))
              (should (equal trigger (etaf-focused-host-ref runtime)))
              (etaf-ui-surface-test--key "<escape>")
              (should-not (etaf-value open))
              (etaf-ui-surface-test--key "o")
              (should (= outer 1))
              (etaf-unmount runtime)
              (should-not (commandp (key-binding (kbd "<escape>"))))))
        (when-let* ((runtime (etaf-runtime-for-buffer (current-buffer))))
          (etaf-unmount runtime))))))

(ert-deftest etaf-ui-popover-keeps-instance-state-and-independent-open-inputs ()
  "Two controlled popovers have independent state and clean up their slots."
  (with-temp-buffer
    (let ((open (etaf-ref nil)) (count (etaf-ref 0)))
      (unwind-protect
          (progn
            (etaf-mount
             (current-buffer)
             (etaf-view
              (column :width '(ch 90) :height '(lh 25)
                (etaf-button :ref 'first :id "first" :label "First"
                             :on-press (lambda () (setf (etaf-value open) t)))
                (etaf-popover :open open :anchor "first"
                              :on-close (lambda () (setf (etaf-value open) nil))
                  (etaf-button :label "Increment" :on-press (lambda () (cl-incf (etaf-value count)))))
                (etaf-popover :open nil :anchor "absent" :on-close #'ignore
                  (text "Not open")))))
            (let ((runtime (etaf-runtime-for-buffer (current-buffer))))
              (etaf-focus runtime 'first)
              (etaf-activate runtime)
              (etaf-activate runtime)
              (should (= 1 (etaf-value count)))
              (should-not (string-match-p "Not open" (buffer-string)))
              (setf (etaf-value open) nil)
              (should (eq 'first (etaf-focused-host-ref runtime)))
              (should-not (etaf-ui-surface-test--control runtime "Increment"))))
        (when-let* ((runtime (etaf-runtime-for-buffer (current-buffer))))
          (etaf-unmount runtime))))))

(ert-deftest etaf-ui-nested-dialog-covers-parent-and-restores-its-controls ()
  "A nested modal blocks the outer panel and restores it on close."
  (with-temp-buffer
    (let ((inner (etaf-ref nil)) (outer (etaf-ref t)))
      (unwind-protect
          (progn
            (etaf-mount
             (current-buffer)
             (etaf-view
              (column :width '(ch 80) :height '(lh 30)
                (etaf-dialog :open outer :title "Outer"
                             :on-close (lambda () (setf (etaf-value outer) nil))
                  (etaf-button :ref 'nested-entry :label "Open inner"
                               :on-press (lambda () (setf (etaf-value inner) t)))
                  (etaf-dialog :open inner :title "Inner" :width '(ch 32)
                               :on-close (lambda () (setf (etaf-value inner) nil))
                    (text "Inner content"))))))
            (let ((runtime (etaf-runtime-for-buffer (current-buffer))))
              (etaf-focus runtime 'nested-entry)
              (etaf-activate runtime)
              (should (string-match-p "Inner content" (buffer-string)))
              (should-not (etaf-host-ref-position runtime 'nested-entry))
              (etaf-ui-surface-test--key "<escape>")
              (should-not (etaf-value inner))
              (should (eq 'nested-entry (etaf-focused-host-ref runtime)))
              (etaf-activate runtime)
              (let* ((map (get-text-property (point-min) 'keymap))
                     (command (and (keymapp map) (lookup-key map [mouse-1])))
                     (last-input-event (list 'mouse-1 (list (selected-window) 1 '(0 . 0) 0))))
                (should (commandp command))
                (call-interactively command))
              (should-not (etaf-value inner))
              (should (etaf-value outer))
              (should (eq 'nested-entry (etaf-focused-host-ref runtime)))))
        (when-let* ((runtime (etaf-runtime-for-buffer (current-buffer))))
          (etaf-unmount runtime))))))

(ert-deftest etaf-ui-unpainted-popover-does-not-capture-keys ()
  "An unavailable anchor leaves the mounted buffer's ordinary keys usable."
  (with-temp-buffer
    (let ((before (key-binding (kbd "<escape>"))))
      (unwind-protect
          (progn
            (etaf-mount
             (current-buffer)
             (etaf-view
              (column :width '(ch 80) :height '(lh 20)
                (etaf-popover :open t :anchor "absent" :on-close #'ignore
                  (etaf-button :label "Not visible" :on-press #'ignore)))))
            (should-not (string-match-p "Not visible" (buffer-string)))
            (should (eq before (key-binding (kbd "<escape>")))))
        (when-let* ((runtime (etaf-runtime-for-buffer (current-buffer))))
          (etaf-unmount runtime))))))

(ert-deftest etaf-ui-surfaces-example-composes-menu-dialog-and-input ()
  "The runnable example hands menu focus to a dialog and back to its trigger."
  (let ((buffer (etaf-ui-surfaces-open)))
    (unwind-protect
        (with-current-buffer buffer
          (let* ((runtime (etaf-runtime-for-buffer buffer))
                 (trigger (etaf-ui-surface-test--control runtime "操作")))
            (etaf-focus runtime trigger)
            (etaf-activate runtime)
            (etaf-activate runtime)
            (should-not (etaf-ui-surface-test--control runtime "编辑偏好"))
            (should (etaf-ui-surface-test--control runtime "名称"))
            ;; The text field edits its own published text in place.
            (etaf-focus (etaf-runtime-for-buffer buffer)
                        (etaf-ui-surface-test--control runtime "名称"))
            (etaf-activate (etaf-runtime-for-buffer buffer))
            (should (etaf-text-input-active-p))
            (switch-to-buffer buffer)
            (execute-kbd-macro "新工作空间")
            (etaf-text-input-end)
            (should (string-match-p "新工作空间" (buffer-string)))
            (etaf-ui-surface-test--key "<escape>")
            (should (equal trigger (etaf-focused-host-ref runtime)))
            (should (string-match-p "新工作空间" (buffer-string)))))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer))) (etaf-unmount runtime))
      (kill-buffer buffer))))

(ert-deftest etaf-ui-media-viewer-owns-keys-browses-and-closes ()
  "An open viewer outranks application keys, browses, closes and returns focus."
  (with-temp-buffer
    (let* ((open (etaf-ref nil)) (index (etaf-ref 0)) (app-keys 0)
           (app-map (make-sparse-keymap)))
      (keymap-set app-map "x" (lambda () (interactive) (cl-incf app-keys)))
      (keymap-set app-map "n" (lambda () (interactive) (cl-incf app-keys)))
      (setq-local emulation-mode-map-alists
                  (cons (list (cons 'etaf-ui-media-test-app app-map))
                        emulation-mode-map-alists))
      (setq-local etaf-ui-media-test-app t)
      (unwind-protect
          (progn
            (etaf-mount
             (current-buffer)
             (etaf-view
              (column :width '(ch 80) :height '(lh 24)
                (etaf-button :ref 'thumb :label "Photo"
                             :on-press (lambda () (setf (etaf-value open) t)))
                (etaf-media-viewer
                 :open open :src "missing.png" :source-size '(400 . 300)
                 :title (format "Photo %d" (etaf-value index))
                 :caption "Harbor at dusk"
                 :on-close (lambda () (setf (etaf-value open) nil))
                 :on-previous (lambda () (etaf-update-value index #'1-))
                 :on-next (lambda () (etaf-update-value index #'1+))))))
            (let ((runtime (etaf-runtime-for-buffer (current-buffer))))
              (etaf-focus runtime 'thumb)
              (etaf-activate runtime)
              (should (string-match-p "Photo 0" (buffer-string)))
              (should (string-match-p "Harbor at dusk" (buffer-string)))
              (should-not (etaf-host-ref-position runtime 'thumb))
              (etaf-ui-surface-test--key "n")
              (etaf-ui-surface-test--key "<right>")
              (should (= (etaf-value index) 2))
              (should (string-match-p "Photo 2" (buffer-string)))
              (etaf-ui-surface-test--key "<left>")
              (etaf-ui-surface-test--key "p")
              (should (= (etaf-value index) 0))
              (etaf-ui-surface-test--key "x")
              (should (= app-keys 0))
              (etaf-ui-surface-test--key "q")
              (should-not (etaf-value open))
              (should (eq 'thumb (etaf-focused-host-ref runtime)))
              (etaf-ui-surface-test--key "x")
              (should (= app-keys 1))
              (setf (etaf-value open) t)
              (etaf-ui-surface-test--key "<escape>")
              (should-not (etaf-value open))))
        (when-let* ((runtime (etaf-runtime-for-buffer (current-buffer))))
          (etaf-unmount runtime))))))

(ert-deftest etaf-ui-media-viewer-closes-on-backdrop-and-close-control ()
  "A click on the backdrop or the close control requests closing; a key does not."
  (with-temp-buffer
    (let ((open (etaf-ref t)) (closed 0))
      (unwind-protect
          (progn
            (etaf-mount
             (current-buffer)
             (etaf-view
              (column :width '(ch 80) :height '(lh 24)
                (etaf-media-viewer
                 :open open :src "missing.png" :source-size '(400 . 300)
                 :title "Album"
                 :on-close (lambda ()
                             (cl-incf closed)
                             (setf (etaf-value open) nil))))))
            (let ((runtime (etaf-runtime-for-buffer (current-buffer)))
                  (click (list 'mouse-1 (list (selected-window) 1 '(0 . 0) 0))))
              (let ((last-input-event ?\s))
                (etaf-dispatch-event runtime (etaf-ui-surface-test--control runtime "Album")
                                     'press))
              (should (= closed 0))
              (let ((last-input-event click))
                (etaf-dispatch-event runtime (etaf-ui-surface-test--control runtime "Album")
                                     'press))
              (should (= closed 1))
              (setf (etaf-value open) t)
              (etaf-dispatch-event runtime (etaf-ui-surface-test--control runtime "Close (Esc)")
                                   'press)
              (should (= closed 2))
              (should-not (string-match-p "Album" (buffer-string)))))
        (when-let* ((runtime (etaf-runtime-for-buffer (current-buffer))))
          (etaf-unmount runtime))))))

(ert-deftest etaf-ui-media-viewer-hides-the-mounted-buffer-cursor ()
  "Opening from another buffer hides and later restores the app buffer's cursor."
  (let ((app (generate-new-buffer " *viewer-app*"))
        (open (etaf-ref nil)))
    (unwind-protect
        (progn
          (with-current-buffer app
            (setq-local cursor-type 'bar)
            (etaf-mount
             app
             (etaf-view
              (column :width '(ch 80) :height '(lh 24)
                (etaf-media-viewer
                 :open open :src "missing.png" :source-size '(400 . 300)
                 :on-close (lambda () (setf (etaf-value open) nil)))))))
          (with-temp-buffer
            (setf (etaf-value open) t)
            (should (eq (buffer-local-value 'cursor-type (current-buffer))
                        (default-value 'cursor-type)))
            (should-not (buffer-local-value 'cursor-type app))
            (setf (etaf-value open) nil)
            (should (eq (buffer-local-value 'cursor-type app) 'bar))))
      (when-let* ((runtime (etaf-runtime-for-buffer app)))
        (etaf-unmount runtime))
      (kill-buffer app))))

(ert-deftest etaf-ui-media-viewer-shows-audio-with-a-transport ()
  "An audio viewer shows the speaker stage, its total time and the caption."
  (with-temp-buffer
    (let ((open (etaf-ref t)))
      (unwind-protect
          (progn
            (etaf-mount
             (current-buffer)
             (etaf-view
              (column :width '(ch 80) :height '(lh 24)
                (etaf-media-viewer
                 :open open :kind 'audio :src "missing.ogg" :duration 90
                 :title "Voice message" :caption "Hello there"
                 :autoplay nil
                 :on-close (lambda () (setf (etaf-value open) nil))))))
            (should (string-match-p "Voice message" (buffer-string)))
            (should (string-match-p "0:00 / 1:30" (buffer-string)))
            (should (string-match-p "Hello there" (buffer-string))))
        (when-let* ((runtime (etaf-runtime-for-buffer (current-buffer))))
          (etaf-unmount runtime))))))

(provide 'etaf-ui-surface-tests)
;;; etaf-ui-surface-tests.el ends here
