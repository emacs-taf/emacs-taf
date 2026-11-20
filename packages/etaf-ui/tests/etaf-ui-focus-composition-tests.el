;;; etaf-ui-focus-composition-tests.el --- Public desktop focus composition -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Real UI bars and window controls publish coordinated focus, stacking and
;; status changes with the same public appearance as a fresh mount.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'etaf)
(require 'etaf-ui)
(require 'ebox)

(etaf-define-component etaf-ui-focus-composition-test--desktop
    (&key active status notes-z files-z reject scalar-controls)
  :bindings
  ((notes-active (etaf-computed (lambda () (eq (etaf-value active) 'notes))))
   (files-active (etaf-computed (lambda () (eq (etaf-value active) 'files))))
   (caption
    (etaf-computed
     (lambda ()
       (let ((value (etaf-value status)))
         (when (funcall reject) (error "Rejected focus status"))
         value)))))
  :view
  (column :width '(ch 80) :height '(lh 9) :item-gap '(lh 0)
    (etaf-workspace-bar
     :workspaces '(main dev) :active 'main :status caption
     :layout-label "Floating" :layout-action #'ignore
     :settings-label "Settings" :settings-action #'ignore)
    (box :position 'relative :width 'stretch :height '(lh 6)
      (box :ref 'focus-notes-panel :position 'absolute
           :left '(ch 1) :top '(lh 1) :width '(ch 28) :height '(lh 3)
           :z-index (etaf-value notes-z) :background-color "#FFFFFB"
        (etaf-window-controls
         :active (if scalar-controls (etaf-value notes-active) notes-active)
         :group 'focus-notes-lights
         :on-close #'ignore :on-minimize #'ignore :on-maximize #'ignore)
        (text "Notes content"))
      (box :ref 'focus-files-panel :position 'absolute
           :left '(ch 20) :top '(lh 2) :width '(ch 28) :height '(lh 3)
           :z-index (etaf-value files-z) :background-color "#FFFFFB"
        (etaf-window-controls
         :active (if scalar-controls (etaf-value files-active) files-active)
         :group 'focus-files-lights
         :on-close #'ignore :on-minimize #'ignore :on-maximize #'ignore)
        (text "Files content")))
    (etaf-taskbar
     :active active :on-select #'ignore
     :items '((:key notes :label "Notes" :ref focus-notes-task)
              (:key files :label "Files" :ref focus-files-task)))))

(defun etaf-ui-focus-composition-test--view
    (active status notes-z files-z reject &optional scalar-controls)
  "Compose ACTIVE, STATUS, NOTES-Z and FILES-Z, with a REJECT predicate.
SCALAR-CONTROLS resolves the controlled inputs before passing Component props."
  (etaf-view
   (etaf-ui-focus-composition-test--desktop
    :active active :status status :notes-z notes-z :files-z files-z :reject reject
    :scalar-controls scalar-controls)))

(defun etaf-ui-focus-composition-test--appearance (text)
  "Return observable TEXT characters, display values and faces."
  (cons (substring-no-properties text)
        (cl-loop for position below (length text)
                 collect (list (get-text-property position 'display text)
                               (get-text-property position 'face text)))))

(defun etaf-ui-focus-composition-test--properties (props)
  "Select public presentation and interaction facts from Host PROPS."
  (cl-loop for key in '(:class :role :aria-label :disabled :tab-index :pointer
                        :color :background-color :border :font-weight :hover-content
                        :left :top :width :height :z-index)
           append (list key (plist-get props key))))

(defun etaf-ui-focus-composition-test--light (runtime group label)
  "Return RUNTIME's public control props for GROUP and accessible LABEL."
  (cdr
   (or (cl-find-if
        (lambda (entry)
          (and (equal label (plist-get (cdr entry) :aria-label))
               (equal (symbol-name group)
                      (format "%s" (plist-get (cdr entry) :hover-group)))))
        (etaf-runtime-host-props-entries runtime))
       (error "Missing focus control: %S %s" group label))))

(defun etaf-ui-focus-composition-test--presentation (runtime buffer)
  "Capture RUNTIME's public props and displayed BUFFER."
  (list
   :props
   (mapcar
    (lambda (ref)
      (etaf-ui-focus-composition-test--properties (etaf-runtime-host-props-for runtime ref)))
    '(focus-notes-panel focus-files-panel focus-notes-task focus-files-task
      etaf-workspace-main etaf-workspace-dev etaf-workspace-layout etaf-workspace-settings))
   :lights
   (cl-loop for group in '(focus-notes-lights focus-files-lights)
            append
            (mapcar
             (lambda (label)
               (etaf-ui-focus-composition-test--properties
                (etaf-ui-focus-composition-test--light runtime group label)))
             '("Close" "Minimize" "Zoom")))
   :output
   (etaf-ui-focus-composition-test--appearance
    (with-current-buffer buffer (buffer-string)))))

(defun etaf-ui-focus-composition-test--assert-selection (runtime selected)
  "Require RUNTIME's controls and taskbar to present SELECTED consistently."
  (dolist (key '(notes files))
    (let* ((active (eq key selected))
           (ref (if (eq key 'notes) 'focus-notes-task 'focus-files-task))
           (group (if (eq key 'notes) 'focus-notes-lights 'focus-files-lights))
           (props (etaf-runtime-host-props-for runtime ref)))
      (should (eq active (and (member "active" (split-string (plist-get props :class))) t)))
      (should (eq 'normal (plist-get props :font-weight)))
      ;; Selection paints the fallback Desktop Theme tokens: the accent on
      ;; a soft accent tint for the active item, shell colors otherwise.
      (should (equal (if active "#2F6FE4" "#4A5664") (plist-get props :color)))
      (should (equal (if active "#DCE7FA" "#E3E9F0")
                     (plist-get props :background-color)))
      (cl-loop for label in '("Close" "Minimize" "Zoom")
               for color in '("#FF5F57" "#FEBC2E" "#28C840")
               for glyph in (if (and (display-graphic-p) (image-type-available-p 'svg))
                      '("⊗" "⊖" "⊕") '("x" "-" "+"))
               do
               (let ((light (etaf-ui-focus-composition-test--light runtime group label)))
                 (should (equal (if active color "#7B8794") (plist-get light :color)))
                 (should (equal glyph (substring-no-properties (plist-get light :hover-content)))))))))

(defun etaf-ui-focus-composition-test--assert-fresh
    (runtime buffer fresh active status notes-z files-z reject)
  "Compare RUNTIME/BUFFER with FRESH using the same public focus inputs.
ACTIVE, STATUS, NOTES-Z, FILES-Z and REJECT supply the current fixture state."
  (let ((fresh-runtime
         (etaf-runtime-for-buffer
          (etaf-mount
           fresh (etaf-ui-focus-composition-test--view active status notes-z files-z reject)))))
    (unwind-protect
        (should (equal-including-properties
                 (etaf-ui-focus-composition-test--presentation runtime buffer)
                 (etaf-ui-focus-composition-test--presentation fresh-runtime fresh)))
      (etaf-unmount fresh-runtime))))

(defun etaf-ui-focus-composition-test--cleanup (buffers)
  "Unmount and remove fixture BUFFERS."
  (dolist (buffer buffers)
    (when-let* ((runtime (etaf-runtime-for-buffer buffer))) (etaf-unmount runtime))
    (when (buffer-live-p buffer) (kill-buffer buffer))))

(ert-deftest etaf-ui-focus-composition-batches-match-fresh-ui ()
  "Focus paint, stacking and variable status match fresh UI in one revision."
  (should
   (stringp
    (ebox-render
     (etaf-render
      (etaf-view
       (column :width '(ch 80)
         (etaf-workspace-bar :workspaces '(main dev) :active 'main :status "Pure status")
         (etaf-window-controls :active t :on-close #'ignore)
         (etaf-taskbar :items '((:key notes :label "Notes")) :active 'notes)))))))
  (let ((buffer (generate-new-buffer " *etaf-ui-focus-composition*"))
        (fresh (generate-new-buffer " *etaf-ui-focus-composition-fresh*"))
        (active (etaf-ref 'notes)) (status (etaf-ref "Notes"))
        (notes-z (etaf-ref 2)) (files-z (etaf-ref 1)))
    (unwind-protect
        (let ((runtime
               (etaf-runtime-for-buffer
                (etaf-mount
                 buffer (etaf-ui-focus-composition-test--view
                         active status notes-z files-z (lambda () nil))))))
          (etaf-ui-focus-composition-test--assert-selection runtime 'notes)
          (dolist (entry (list '(files "Files detail" 2 3)
                              (list 'notes (concat "Long status " (make-string 120 ?x)) 4 3)
                              '(files "F" 4 5)
                              '(notes "" 6 5)
                              '(files "File browser ready" 6 7)
                              '(notes "Notes" 8 7)))
            (let* ((revision (etaf-runtime-revision runtime))
                   (before (etaf-ui-focus-composition-test--presentation runtime buffer)))
              (etaf-batch
                (etaf-set-value active (nth 0 entry))
                (etaf-set-value status (nth 1 entry))
                (etaf-set-value notes-z (nth 2 entry))
                (etaf-set-value files-z (nth 3 entry))
                (should (= revision (etaf-runtime-revision runtime)))
                (should (equal-including-properties
                         before (etaf-ui-focus-composition-test--presentation runtime buffer))))
              (should (= (1+ revision) (etaf-runtime-flush runtime)))
              (etaf-ui-focus-composition-test--assert-selection runtime (nth 0 entry))
              (should (equal (nth 1 entry) (etaf-value status)))
              (etaf-ui-focus-composition-test--assert-fresh
               runtime buffer fresh active status notes-z files-z (lambda () nil)))))
      (etaf-ui-focus-composition-test--cleanup (list buffer fresh)))))

(ert-deftest etaf-ui-focus-composition-rejection-keeps-committed-ui-until-retry ()
  "A rejected status preserves all committed focus facts and retries one batch."
  (let ((buffer (generate-new-buffer " *etaf-ui-focus-composition-retry*"))
        (fresh (generate-new-buffer " *etaf-ui-focus-composition-retry-fresh*"))
        (active (etaf-ref 'notes)) (status (etaf-ref "Notes"))
        (notes-z (etaf-ref 2)) (files-z (etaf-ref 1)) rejected)
    (unwind-protect
        (let* ((reject (lambda () rejected))
               (runtime
                (etaf-runtime-for-buffer
                 (etaf-mount buffer (etaf-ui-focus-composition-test--view
                                     active status notes-z files-z reject)))))
          (etaf-batch
            (etaf-set-value active 'files)
            (etaf-set-value status "Files accepted")
            (etaf-set-value files-z 3))
          (let ((revision (etaf-runtime-flush runtime))
                (before (etaf-ui-focus-composition-test--presentation runtime buffer)))
            (setq rejected t)
            (should-error
             (etaf-batch
               (etaf-set-value active 'notes)
               (etaf-set-value status "Notes after retry")
               (etaf-set-value notes-z 4))
             :type 'error)
            (should (eq 'notes (etaf-value active)))
            (should (equal "Notes after retry" (etaf-value status)))
            (should (= 4 (etaf-value notes-z)))
            (should (= revision (etaf-runtime-revision runtime)))
            (should (equal-including-properties
                     before (etaf-ui-focus-composition-test--presentation runtime buffer)))
            (etaf-ui-focus-composition-test--assert-selection runtime 'files)
            (setq rejected nil)
            (should (= (1+ revision) (etaf-runtime-flush runtime)))
            (etaf-ui-focus-composition-test--assert-selection runtime 'notes)
            (etaf-ui-focus-composition-test--assert-fresh
             runtime buffer fresh active status notes-z files-z reject)))
      (etaf-ui-focus-composition-test--cleanup (list buffer fresh)))))

(ert-deftest etaf-ui-focus-scalar-props-match-fresh-ui ()
  "Changing scalar Component props keeps control content aligned with a fresh mount."
  (let ((buffer (generate-new-buffer " *etaf-ui-scalar-focus*"))
        (fresh (generate-new-buffer " *etaf-ui-scalar-focus-fresh*"))
        (active (etaf-ref 'notes)) (status (etaf-ref "Notes"))
        (notes-z (etaf-ref 2)) (files-z (etaf-ref 1)))
    (unwind-protect
        (let ((runtime
               (etaf-runtime-for-buffer
                (etaf-mount
                 buffer (etaf-ui-focus-composition-test--view
                         active status notes-z files-z #'ignore t)))))
          (dolist (entry '((files "Files" 2 3) (notes "Notes again" 4 3)))
            (progn
              (etaf-batch
                (etaf-set-value active (nth 0 entry))
                (etaf-set-value status (nth 1 entry))
                (etaf-set-value notes-z (nth 2 entry))
                (etaf-set-value files-z (nth 3 entry)))
              (etaf-runtime-flush runtime)
              (etaf-ui-focus-composition-test--assert-selection runtime (nth 0 entry))
              (etaf-ui-focus-composition-test--assert-fresh
               runtime buffer fresh active status notes-z files-z #'ignore))))
      (etaf-ui-focus-composition-test--cleanup (list buffer fresh)))))

;; ---------------------------------------------------------------------------
;; Keyboard composites
;; ---------------------------------------------------------------------------

(ert-deftest etaf-ui-composites-are-one-tab-stop-entered-at-the-selection ()
  "Tabs are one Tab stop entered at the active tab; arrows move inside."
  (let ((buffer-name " *etaf-ui-composite-keys*") changes)
    (unwind-protect
        (progn
          (etaf-mount
           buffer-name
           (etaf-view
            (column
             (etaf-button :label "Before" :ref 'before :on-press #'ignore)
             (etaf-tabs :items '((:key a :label "Alpha" :ref tab-a)
                                 (:key b :label "Beta" :ref tab-b)
                                 (:key c :label "Gamma" :ref tab-c))
                        :active 'b
                        :on-change (lambda (key) (push key changes)))
             (etaf-button :label "After" :ref 'after :on-press #'ignore))))
          (with-current-buffer buffer-name
            (let ((runtime (etaf-runtime-for-buffer buffer-name)))
              (etaf-focus runtime 'before)
              (etaf-focus-next runtime)
              (should (eq (etaf-focused-host-ref runtime) 'tab-b))
              (call-interactively (key-binding (kbd "<right>") t))
              (should (eq (etaf-focused-host-ref runtime) 'tab-c))
              (call-interactively (key-binding (kbd "C-b") t))
              (should (eq (etaf-focused-host-ref runtime) 'tab-b))
              (etaf-focus-next runtime)
              (should (eq (etaf-focused-host-ref runtime) 'after))
              (etaf-focus-previous runtime)
              (should (eq (etaf-focused-host-ref runtime) 'tab-b))
              (should-not changes))))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer-name)))
        (etaf-unmount runtime))
      (when-let* ((buffer (get-buffer buffer-name)))
        (kill-buffer buffer)))))

(ert-deftest etaf-ui-tree-branches-open-right-and-close-left ()
  "A focused tree branch expands with Right and collapses with Left."
  (let ((buffer-name " *etaf-ui-tree-keys*") (expanded (etaf-ref nil)))
    (unwind-protect
        (progn
          (etaf-mount
           buffer-name
           (etaf-view
            (etaf-tree :items '((:key src :label "src"
                                 :children ((:key main :label "main.el"))))
                       :expanded expanded
                       :on-toggle (lambda (keys) (etaf-set-value expanded keys)))))
          (with-current-buffer buffer-name
            (let ((runtime (etaf-runtime-for-buffer buffer-name)))
              (etaf-focus-next runtime)
              (call-interactively (key-binding (kbd "<right>") t))
              (etaf-runtime-flush runtime)
              (should (equal (etaf-value expanded) '(src)))
              (etaf-focus-next runtime)
              (etaf-focus-previous runtime)
              (call-interactively (key-binding (kbd "<left>") t))
              (should (null (etaf-value expanded))))))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer-name)))
        (etaf-unmount runtime))
      (when-let* ((buffer (get-buffer buffer-name)))
        (kill-buffer buffer)))))

(provide 'etaf-ui-focus-composition-tests)
;;; etaf-ui-focus-composition-tests.el ends here
