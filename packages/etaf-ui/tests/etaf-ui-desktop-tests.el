;;; etaf-ui-desktop-tests.el --- Desktop navigation Component contracts -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'etaf-ui)

(defun etaf-ui-desktop-test--cleanup (buffer)
  "Unmount and remove BUFFER after a desktop Component test."
  (when-let* ((runtime (etaf-runtime-for-buffer buffer)))
    (etaf-unmount runtime))
  (when-let* ((live (get-buffer buffer)))
    (kill-buffer live)))

(defun etaf-ui-desktop-test--ref (runtime label)
  "Return the host ref in RUNTIME whose ARIA label is LABEL."
  (car (cl-find-if
        (lambda (entry)
          (equal label (plist-get (cdr entry) :aria-label)))
        (etaf-runtime-host-props-entries runtime))))

(defun etaf-ui-desktop-test--host-geometry (runtime buffer ref)
  "Return REF's rendered row, horizontal position and width in BUFFER."
  (let ((bounds (etaf-host-ref-bounds runtime ref)))
    (should bounds)
    (with-current-buffer buffer
      (save-excursion
        (goto-char (car bounds))
        (list (line-number-at-pos)
              (ebox-string-pixel-width
               (buffer-substring (line-beginning-position) (car bounds)))
              (ebox-string-pixel-width
               (buffer-substring (car bounds) (cdr bounds))))))))

(ert-deftest etaf-ui-taskbar-and-workspace-bar-publish-controlled-actions ()
  "Taskbar and workspace controls expose caller-owned selection callbacks."
  (let ((buffer (generate-new-buffer "*etaf-ui-desktop-bars*"))
        selected workspace settings)
    (unwind-protect
        (progn
          (etaf-mount
           buffer
           (etaf-view
           (column :width '(ch 80) :height '(lh 25)
             (etaf-taskbar
              :items '((:key notes :label "Notes" :state active)
                       (:key files :label "Files" :state minimized))
              :active 'notes
              :on-select (lambda (key) (setq selected key)))
             (etaf-workspace-bar
              :workspaces '(main dev)
             :active 'main
              :on-select (lambda (key) (setq workspace key))
              :settings-label "Settings"
              :settings-action (lambda () (setq settings t))))))
          (let ((runtime (etaf-runtime-for-buffer buffer)))
            (let ((active-props
                   (etaf-runtime-host-props-for
                    runtime (etaf-ui-desktop-test--ref runtime "Notes")))
                  (minimized-props
                   (etaf-runtime-host-props-for
                    runtime (etaf-ui-desktop-test--ref runtime "Files")))
                  (settings-props
                   (etaf-runtime-host-props-for
                    runtime 'etaf-workspace-settings)))
              ;; Bar items paint the fallback Desktop Theme tokens: the
              ;; active item sits on the soft accent tint, the others on
              ;; the shell background without a border.
              (should (equal "#DCE7FA" (plist-get active-props :background-color)))
              (should (equal "#E3E9F0" (plist-get minimized-props :background-color)))
              (should-not (plist-get minimized-props :border))
              (should (equal "Settings" (plist-get settings-props :aria-label))))
            (etaf-dispatch-event runtime
                                 (etaf-ui-desktop-test--ref runtime "Files") 'press)
            (etaf-dispatch-event runtime
                                 (etaf-ui-desktop-test--ref runtime "dev") 'press)
            (etaf-dispatch-event runtime 'etaf-workspace-settings 'press)
            (should (eq selected 'files))
            (should (eq workspace 'dev))
            (should settings)
            (should (string-match-p "Notes" (with-current-buffer buffer (buffer-string))))))
      (etaf-ui-desktop-test--cleanup buffer))))

(ert-deftest etaf-ui-desktop-bars-follow-selection-and-status-sources ()
  "Bar sources publish selection and status while preserving input targets."
  (let* ((buffer (generate-new-buffer " *etaf-ui-bar-sources*"))
         (active (etaf-ref 'notes))
         (workspace (etaf-ref 'main))
         (status (etaf-ref "Notes focused"))
         (scope (etaf-effect-scope :detached t))
         (selected-source
          (etaf-scope-run scope (lambda () (etaf-computed (lambda () (etaf-value active))))))
         selected)
    (unwind-protect
        (progn
          (dolist (value '(notes files nil))
            (should
             (stringp (ebox-render
              (etaf-render
               (etaf-view
                (column
                 (etaf-taskbar :items '((:key notes :label "Notes")) :active value)
                 (etaf-workspace-bar :workspaces '(main dev) :active 'main
                                     :status "Pure status"))))))))
          (etaf-mount
           buffer
           (etaf-view
            (column :width '(ch 80)
             (etaf-taskbar
              :items '((:key notes :label "Notes" :ref notes-button)
                       (:key files :label "Files" :ref files-button :state minimized)
                       (:key locked :label "Locked" :ref locked-button :disabled t))
              :active selected-source :on-select (lambda (key) (setq selected key)))
             (etaf-workspace-bar :workspaces '(main dev) :active workspace :status status))))
          (let* ((runtime (etaf-runtime-for-buffer buffer))
                 (notes-position (etaf-host-ref-position runtime 'notes-button))
                 (files-position (etaf-host-ref-position runtime 'files-button)))
            (should notes-position)
            (should files-position)
            (etaf-batch
              (etaf-set-value active 'files)
              (etaf-set-value workspace 'dev)
              (etaf-set-value status "Files focused"))
            (should (equal "#DCE7FA"
                           (plist-get (etaf-runtime-host-props-for runtime 'files-button)
                                      :background-color)))
            (should (equal "#E3E9F0"
                           (plist-get (etaf-runtime-host-props-for runtime 'notes-button)
                                      :background-color)))
            (should (equal "#DCE7FA"
                           (plist-get (etaf-runtime-host-props-for runtime 'etaf-workspace-dev)
                                      :background-color)))
            (should (equal notes-position (etaf-host-ref-position runtime 'notes-button)))
            (should (equal files-position (etaf-host-ref-position runtime 'files-button)))
            (should (string-match-p "Files focused" (with-current-buffer buffer (buffer-string))))
            (etaf-dispatch-event runtime 'files-button 'press)
            (should (eq selected 'files))
            (should-error (etaf-dispatch-event runtime 'locked-button 'press)
                          :type 'etaf-event-error)
            (should (eq selected 'files))
            (etaf-batch (etaf-set-value active nil) (etaf-set-value status nil))
            (should (equal "#E3E9F0"
                           (plist-get (etaf-runtime-host-props-for runtime 'files-button)
                                      :background-color)))
            (should-not (string-match-p "Files focused" (with-current-buffer buffer (buffer-string))))
            (etaf-set-value status "Ready again")
            (should (string-match-p "Ready again" (with-current-buffer buffer (buffer-string))))))
      (etaf-ui-desktop-test--cleanup buffer)
      (etaf-scope-stop scope))))

(ert-deftest etaf-ui-workspace-status-keeps-trailing-actions-visible ()
  "Variable status text clips within one region and preserves trailing actions."
  (let ((buffer (generate-new-buffer " *etaf-ui-workspace-status*"))
        (status (etaf-ref "Notes"))
        (layouts 0) (settings 0))
    (unwind-protect
        (progn
          (should
           (string-match-p
            "Floating.*Settings"
            (ebox-render
             (etaf-render
              (etaf-view
               (box :width '(ch 80)
                 (etaf-workspace-bar
                  :workspaces '(main dev) :status "Pure title"
                  :layout-label "Floating" :layout-action #'ignore
                  :settings-label "Settings" :settings-action #'ignore)))))))
          (etaf-mount
           buffer
           (etaf-view
            (box :width '(ch 80)
              (etaf-workspace-bar
               :workspaces '(main dev) :status status
               :layout-label "Floating" :layout-action (lambda () (cl-incf layouts))
               :settings-label "Settings" :settings-action (lambda () (cl-incf settings))))))
          (let* ((runtime (etaf-runtime-for-buffer buffer))
                 (status-ref
                  (car (cl-find-if
                        (lambda (entry)
                          (equal "etaf-workspace-status" (plist-get (cdr entry) :class)))
                        (etaf-runtime-host-props-entries runtime))))
                 (refs (list status-ref 'etaf-workspace-layout 'etaf-workspace-settings))
                 (geometry
                  (mapcar (lambda (ref)
                            (etaf-ui-desktop-test--host-geometry runtime buffer ref)) refs))
                 (width (with-current-buffer buffer (ebox-string-pixel-width (buffer-string))))
                 (long (concat "Long status " (make-string 200 ?x) " invisible-tail")))
            (should status-ref)
            (dolist (entry (list (cons "A longer title" "A longer title")
                                (cons long "Long status")
                                (cons "First line\nHidden second line" "First line")
                                (cons nil nil)
                                (cons "Restored" "Restored")))
              (etaf-set-value status (car entry))
              (should (equal (car entry) (etaf-value status)))
              (should
               (equal geometry
                      (mapcar (lambda (ref)
                                (etaf-ui-desktop-test--host-geometry runtime buffer ref)) refs)))
              (with-current-buffer buffer
                (let ((text (buffer-string)))
                  (should (= width (ebox-string-pixel-width text)))
                  (when (cdr entry) (should (string-match-p (regexp-quote (cdr entry)) text)))
                  (should-not (string-match-p "invisible-tail\\|Hidden second line" text))
                  (should (string-match-p "Floating.*Settings" text))))
              (etaf-dispatch-event runtime 'etaf-workspace-layout 'press)
              (etaf-dispatch-event runtime 'etaf-workspace-settings 'press))
            (should (= layouts 5))
            (should (= settings 5))))
      (etaf-ui-desktop-test--cleanup buffer))))

(ert-deftest etaf-ui-workspace-layout-label-updates-as-prepared-text ()
  "A reactive layout label changes its text inside a fixed control without re-rendering."
  (let ((buffer (generate-new-buffer " *etaf-ui-workspace-layout*"))
        (label (etaf-ref "Floating"))
        (layouts 0))
    (unwind-protect
        (progn
          (etaf-mount
           buffer
           (etaf-view
            (column :width '(ch 80) :height '(lh 6) :item-gap '(lh 0)
              (etaf-workspace-bar
               :workspaces '(main dev) :status "Ready"
               :layout-label label :layout-action (lambda () (cl-incf layouts))
               :settings-label "Settings" :settings-action #'ignore)
              (box :position 'relative :width 'stretch :height '(lh 4)
                (box :ref 'panel :position 'absolute :left '(ch 1) :top '(lh 1)
                     :width '(ch 20) :height '(lh 2) :z-index 1
                  (text "Panel"))))))
          (let* ((runtime (etaf-runtime-for-buffer buffer))
                 (generation (etaf-runtime-revision runtime))
                 (refs '(etaf-workspace-layout etaf-workspace-settings panel))
                 (geometry
                  (mapcar (lambda (ref)
                            (etaf-ui-desktop-test--host-geometry runtime buffer ref)) refs)))
            (dolist (value '("Tiled" "Floating" "Tiled"))
              (etaf-set-value label value)
              ;; One in-place text commit, with the same Host geometry.
              (should (= (cl-incf generation) (etaf-runtime-revision runtime)))
              (should (equal geometry
                             (mapcar (lambda (ref)
                                       (etaf-ui-desktop-test--host-geometry runtime buffer ref))
                                     refs)))
              (with-current-buffer buffer
                (should (string-match-p (concat "Ready.*" value ".*Settings") (buffer-string)))
                (should-not (string-match-p (if (equal value "Tiled") "Floating" "Tiled")
                                            (buffer-string)))))
            (etaf-dispatch-event runtime 'etaf-workspace-layout 'press)
            (should (= layouts 1))
            (should-error
             (etaf-render
              (etaf-view (etaf-workspace-bar :workspaces '(main) :layout-label 'tiled
                                             :layout-action #'ignore)))
             :type 'etaf-component-call-error)))
      (etaf-ui-desktop-test--cleanup buffer))))

(ert-deftest etaf-ui-launcher-and-switcher-remain-controlled ()
  "Picker Components render only when OPEN is true and delegate selection."
  (let ((buffer (generate-new-buffer "*etaf-ui-desktop-pickers*"))
        (launcher-open (etaf-ref t)) (switcher-open (etaf-ref nil))
        (selected (etaf-ref 'editor)) picked)
    (unwind-protect
        (progn
          (etaf-mount
           buffer
           (etaf-view
            (column :width '(ch 80) :height '(lh 25)
             (etaf-launcher :open launcher-open
                            :items '((:key editor :label "Editor" :description "Code")
                                     (:key terminal :label "Terminal"))
                            :on-select (lambda (key) (setq picked key))
                            :on-close (lambda () (setf (etaf-value launcher-open) nil)))
             (etaf-switcher :open switcher-open :selected selected
                            :items '((:key editor :label "Editor")
                                     (:key terminal :label "Terminal"))
                            :on-select (lambda (key) (setq picked key))
                            :on-close (lambda () (setf (etaf-value switcher-open) nil))))))
          (should (string-match-p "Applications" (with-current-buffer buffer (buffer-string))))
          (setf (etaf-value launcher-open) nil
                (etaf-value switcher-open) t)
          (etaf-runtime-flush (etaf-runtime-for-buffer buffer))
          (should (string-match-p "Switch application" (with-current-buffer buffer (buffer-string))))
          (should (string-match-p "Editor" (with-current-buffer buffer (buffer-string))))
          (should (eq 'editor (etaf-value selected)))
          (setf (etaf-value switcher-open) nil)
          (etaf-runtime-flush (etaf-runtime-for-buffer buffer))
          (should-not (string-match-p "Switch application" (with-current-buffer buffer (buffer-string)))))
      (etaf-ui-desktop-test--cleanup buffer))))

(ert-deftest etaf-ui-splitter-projects-named-panes-and-divider ()
  "Splitter keeps ratio controlled and exposes an accessible divider gesture."
  (let ((buffer (generate-new-buffer "*etaf-ui-desktop-splitter*")) (ratio (etaf-ref 0.4)) gesture)
    (unwind-protect
        (progn
          (etaf-mount
           buffer
           (etaf-view
            (etaf-splitter :orientation 'horizontal :ratio ratio
                           :on-change (lambda (event) (setq gesture event))
                           (slot :name 'first (etaf-label :text "Files"))
                           (slot :name 'second (etaf-label :text "Preview")))))
          (let* ((runtime (etaf-runtime-for-buffer buffer))
                 (divider (etaf-ui-desktop-test--ref runtime "Resize columns")))
            (should divider)
            (etaf-dispatch-event runtime divider 'drag
                                 '(:phase move :delta (8 . 0)) t)
            (should (equal (plist-get gesture :phase) 'move))
            (should (string-match-p "Files" (with-current-buffer buffer (buffer-string))))
            (should (string-match-p "Preview" (with-current-buffer buffer (buffer-string))))))
      (etaf-ui-desktop-test--cleanup buffer))))

(ert-deftest etaf-ui-splitter-overlay-uses-caller-rectangle ()
  "An overlay divider uses its caller's exact positioned rectangle."
  (let ((buffer (generate-new-buffer "*etaf-ui-splitter-overlay*")) gesture)
    (unwind-protect
        (progn
          (etaf-mount
           buffer
           (etaf-view
            (box :position 'relative :width '(px 80) :height '(lh 8)
              (etaf-splitter
               :orientation 'vertical :ratio 0.5 :overlay t
               :overlay-rect '(:left (px 5) :top (lh 3)
                               :width (px 30) :height (lh 1))
               :divider-content "----"
               :on-change (lambda (event) (setq gesture event))))))
          (let* ((runtime (etaf-runtime-for-buffer buffer))
                 (divider (etaf-ui-desktop-test--ref runtime "Resize rows"))
                 (props (etaf-runtime-host-props-for runtime divider)))
            (should divider)
            (dolist (entry '((:left . (px 5)) (:top . (lh 3))
                             (:width . (px 30)) (:height . (lh 1))))
              (should (equal (cdr entry) (plist-get props (car entry)))))
            (etaf-dispatch-event runtime divider 'drag
                                 '(:phase move :delta (0 . 2)) t)
            (should (eq 'move (plist-get gesture :phase)))))
      (etaf-ui-desktop-test--cleanup buffer))))

(ert-deftest etaf-ui-window-chrome-uses-macos-traffic-lights ()
  "Window chrome puts red/yellow/green controls on the left of the title."
  (let ((buffer (generate-new-buffer "*etaf-ui-macos-chrome*")))
    (unwind-protect
        (progn
          (etaf-mount
           buffer
           (etaf-view
            (etaf-window-chrome
             :title "Demo"
             :on-close (lambda ())
             :on-minimize (lambda ())
             :on-maximize (lambda ()))))
          (let* ((runtime (etaf-runtime-for-buffer buffer))
                 (controls
                  (cl-remove-if-not
                   (lambda (entry)
                     (member (plist-get (cdr entry) :aria-label)
                             '("Close" "Minimize" "Zoom")))
                   (etaf-runtime-host-props-entries runtime))))
            (let ((labels (mapcar (lambda (entry)
                                    (plist-get (cdr entry) :aria-label)) controls))
                  (colors (mapcar (lambda (entry)
                                    (plist-get (cdr entry) :color)) controls))
                  (hover-labels (mapcar (lambda (entry)
                                          (substring-no-properties
                                           (plist-get (cdr entry) :hover-content)))
                                        controls)))
            (should (equal '("Close" "Minimize" "Zoom") labels))
            (should (equal '("#FF5F57" "#FEBC2E" "#28C840") colors))
            (should (equal (if (and (display-graphic-p) (image-type-available-p 'svg))
                      '("⊗" "⊖" "⊕") '("x" "-" "+")) hover-labels))
            (dolist (entry controls)
              (let ((props (cdr entry)))
                (should (eq 'arrow (plist-get props :pointer)))
                (should (equal "#F7F9FC" (plist-get props :background-color)))
                (should-not (plist-get props :border))))
            (with-current-buffer buffer
                (should (string-match-p "D" (buffer-string)))))))
      (etaf-ui-desktop-test--cleanup buffer))))

(ert-deftest etaf-ui-window-controls-react-to-active-paint-and-retain-targets ()
  "Active-state paint changes preserve each traffic light's native input target."
  (dolist (active '(t nil))
    (should (stringp (ebox-render
             (etaf-render (etaf-view (etaf-window-controls :active active))))))
    (should (string-match-p
             "Pure title"
             (ebox-render
              (etaf-render
               (etaf-view (etaf-window-chrome :title "Pure title" :active active)))))))
  (let ((buffer (generate-new-buffer " *window-active-paint*"))
        (active (etaf-ref t)) (mode (etaf-ref 'normal))
        (closed 0) (minimized 0) (maximized 0) (restored 0))
    (unwind-protect
        (progn
          (etaf-mount
           buffer
           (etaf-view
            (etaf-window-controls :active active :group 'lights :mode mode
                                  :on-close (lambda () (cl-incf closed))
                                  :on-minimize (lambda () (cl-incf minimized))
                                  :on-maximize (lambda () (cl-incf maximized))
                                  :on-restore (lambda () (cl-incf restored)))))
          (let* ((runtime (etaf-runtime-for-buffer buffer))
                 (controls
                  (cl-remove-if-not
                   (lambda (entry)
                     (member (plist-get (cdr entry) :aria-label)
                             '("Close" "Minimize" "Zoom")))
                   (etaf-runtime-host-props-entries runtime)))
                 (labels '("Close" "Minimize" "Zoom"))
                 ;; Contribution enumeration is not visual or semantic order.
                 ;; Retain each action's original target by its public label.
                 (refs (mapcar
                        (lambda (label)
                          (car (cl-find label controls :test #'equal
                                        :key (lambda (entry)
                                               (plist-get (cdr entry) :aria-label)))))
                        labels)))
            (should (= 3 (length controls)))
            (should (cl-every #'identity refs))
            (should (= 3 (length (delete-dups (copy-sequence refs)))))
            (dolist (value '(nil t nil t))
              (etaf-set-value active value)
              (dolist (ref refs)
                (should (etaf-host-ref-position runtime ref)))
              (should (equal labels
                             (mapcar (lambda (ref)
                                       (plist-get (etaf-runtime-host-props-for runtime ref)
                                                  :aria-label))
                                     refs)))
              (should (equal (if value '("#FF5F57" "#FEBC2E" "#28C840")
                               '("#7B8794" "#7B8794" "#7B8794"))
                             (mapcar (lambda (ref)
                                       (plist-get (etaf-runtime-host-props-for runtime ref)
                                                  :color))
                                     refs))))
            (etaf-dispatch-event runtime (nth 0 refs) 'press)
            (should (equal '(1 0 0) (list closed minimized maximized)))
            (etaf-dispatch-event runtime (nth 1 refs) 'press)
            (should (equal '(1 1 0) (list closed minimized maximized)))
            (etaf-dispatch-event runtime (nth 2 refs) 'press)
            (should (equal '(1 1 1) (list closed minimized maximized)))
            ;; Zoom follows the live mode: a maximized window restores, and
            ;; the mode change keeps the same retained control target.
            (let ((revision (etaf-runtime-revision runtime)))
              (etaf-set-value mode 'maximized)
              (should (= revision (etaf-runtime-revision runtime)))
              (should (etaf-host-ref-position runtime (nth 2 refs)))
              (etaf-dispatch-event runtime (nth 2 refs) 'press)
              (should (equal '(1 1 1 1) (list closed minimized maximized restored))))))
      (etaf-ui-desktop-test--cleanup buffer))))

(ert-deftest etaf-ui-window-controls-is-reusable-and-grouped ()
  "Traffic-light controls are a standalone reusable Component with grouping."
  (let ((buffer (generate-new-buffer "*etaf-ui-window-controls*")))
    (unwind-protect
        (progn
          (etaf-mount
           buffer
           (etaf-view
            (etaf-window-controls
             :group 'probe-controls
             :on-close (lambda ())
             :on-minimize (lambda ())
             :on-maximize (lambda ()))))
          (let* ((runtime (etaf-runtime-for-buffer buffer))
                 (controls
                  (cl-remove-if-not
                   (lambda (entry)
                     (member (plist-get (cdr entry) :aria-label)
                             '("Close" "Minimize" "Zoom")))
                   (etaf-runtime-host-props-entries runtime))))
            (should (= 3 (length controls)))
            (should (equal '("probe-controls" "probe-controls" "probe-controls")
                           (mapcar (lambda (entry)
                                     (format "%s" (plist-get (cdr entry)
                                                               :hover-group)))
                                   controls)))))
      (etaf-ui-desktop-test--cleanup buffer))))

(ert-deftest etaf-ui-pane-resizer-reports-clamped-widths ()
  "Dragging a pane resizer reports clamped widths and the final one on release."
  (let ((buffer (generate-new-buffer " *resizer test*"))
        (size (etaf-ref 200)) ends)
    (unwind-protect
        (progn
          (etaf-mount buffer
                      (lambda ()
                        (etaf-view
                         (row :height '(lh 1)
                              (box :width (list 'px (etaf-value size)) "pane")
                              (etaf-pane-resizer
                               :ref 'pane-resizer
                               :size size :min 120 :max 300
                               :on-change (lambda (w) (etaf-set-value size w))
                               :on-end (lambda (w) (push w ends))))))
                      '(:viewport-width 600 :viewport-height 4))
          (let* ((runtime (etaf-runtime-for-buffer buffer))
                 (ref 'pane-resizer)
                 (drag (lambda (phase dx)
                         (etaf-dispatch-event
                          runtime ref 'drag
                          (list :phase phase :delta (cons dx 0) :buffer buffer)
                          t))))
            (should ref)
            (funcall drag 'start 0)
            (funcall drag 'move 40)
            (should (= (etaf-value size) 240))
            (funcall drag 'move 500)
            (should (= (etaf-value size) 300))
            (funcall drag 'end -500)
            (should (= (etaf-value size) 120))
            (should (equal ends '(120)))
            ;; The focused divider steps sideways from the keyboard only.
            (with-current-buffer buffer
              (etaf-focus runtime ref)
              (call-interactively (key-binding (kbd "<right>") t))
              (etaf-runtime-flush runtime)
              (should (> (etaf-value size) 120))
              (should (= (length ends) 2))
              (should-not (eq (key-binding (kbd "<up>") t)
                              (key-binding (kbd "<right>") t))))))
      (etaf-ui-desktop-test--cleanup buffer))))

(ert-deftest etaf-ui-bars-namespace-their-own-host-references ()
  "Two bars in one Runtime keep distinct controls through :ref-prefix.
A host that embeds a whole application can mount several bars; without a
prefix their tabs and trailing controls spell the same reference and shadow
each other."
  (let ((buffer (generate-new-buffer "*etaf-ui-desktop-prefixed-bars*"))
        (outer-pressed 0) (inner-pressed 0))
    (unwind-protect
        (progn
          (etaf-mount
           buffer
           (etaf-view
            (column :width '(ch 70) :height '(lh 12)
              (etaf-workspace-bar
               :workspaces '(main)
               :ref-prefix "outer-"
               :layout-label "Floating"
               :layout-action (lambda () (cl-incf outer-pressed))
               :settings-label "Settings"
               :settings-action (lambda () (cl-incf outer-pressed)))
              (etaf-workspace-bar
               :workspaces '(main)
               :ref-prefix "inner-"
               :layout-label "Floating"
               :layout-action (lambda () (cl-incf inner-pressed))
               :settings-label "Settings"
               :settings-action (lambda () (cl-incf inner-pressed))))))
          (let ((runtime (etaf-runtime-for-buffer buffer)))
            (should (etaf-runtime-host-props-for
                     runtime 'outer-etaf-workspace-layout))
            (should (etaf-runtime-host-props-for
                     runtime 'inner-etaf-workspace-layout))
            (should-not (etaf-runtime-host-props-for
                         runtime 'etaf-workspace-layout))
            (etaf-dispatch-event runtime 'outer-etaf-workspace-settings 'press)
            (should (= 1 outer-pressed))
            (should (= 0 inner-pressed))
            (etaf-dispatch-event runtime 'inner-etaf-workspace-layout 'press)
            (should (= 1 outer-pressed))
            (should (= 1 inner-pressed))
            (should (= 2 (length (seq-filter
                                  (lambda (entry)
                                    (equal "Settings"
                                           (plist-get (cdr entry) :aria-label)))
                                  (etaf-runtime-host-props-entries runtime)))))))
      (etaf-ui-desktop-test--cleanup buffer))))

;;; etaf-ui-desktop-tests.el ends here
