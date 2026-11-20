;;; -*- lexical-binding: t; -*-
;;; etaf-help-tests.el --- Public keyboard-help lifecycle acceptance

(require 'ert)
(require 'etaf)
(require 'etaf-test-support)

(defun etaf-help-test-text ()
  "Read the current application's visible text without properties."
  (buffer-substring-no-properties (point-min) (point-max)))

(defun etaf-help-test-labels (data)
  "Return the advertised labels in help DATA."
  (mapcan (lambda (group)
            (mapcar (lambda (entry) (plist-get entry :label))
                    (plist-get group :entries)))
          (plist-get data :groups)))

(defun etaf-help-test-first-command ()
  "First local command."
  (interactive))

(defun etaf-help-test-second-command ()
  "Second local command."
  (interactive))

(ert-deftest etaf-help-snapshot-respects-scope-shadowing-and-copy-ownership ()
  "Only effective labelled keys appear, and caller mutation cannot alter help."
  (let ((note (copy-sequence "Keep this note")))
    (etaf-test-with-mount
        (runtime (etaf-view
                  (column :aria-label "Reader" :help note
                          :keys (list (list "r" #'ignore "Outer reload")
                                      (list "s" #'ignore "Outer save"))
                    (column :aria-label "Articles"
                            :region '(:id articles :label "Articles" :key "a")
                            :keys (list (list "r" #'ignore)
                                        (list "s" #'ignore "Save article"))
                      (box :ref 'entry :tab-index 0 "Entry")))))
      (etaf-focus runtime 'entry)
      (let* ((data (etaf-help-data runtime))
             (labels (etaf-help-test-labels data)))
        (should (equal (plist-get data :scope) "Articles"))
        (should (member "Save article" labels))
        (should-not (member "Outer reload" labels))
        (should-not (member "Outer save" labels))
        (aset (car (plist-get data :notes)) 0 ?X)
        (should (equal note "Keep this note")))
      (etaf-help runtime)
      (let ((data (etaf-help-data runtime)))
        (aset (plist-get data :title) 0 ?X)
        (setcar (plist-get data :notes) "Changed"))
      (let ((data (etaf-help-data runtime)))
        (should (equal (plist-get data :title) "Reader"))
        (should (equal (plist-get data :notes) '("Keep this note")))))))

(ert-deftest etaf-help-tracks-effective-local-maps-between-openings ()
  "Local keymap changes appear on the next opening, not in a captured snapshot."
  (etaf-test-with-mount (runtime (etaf-view (text "Short application")))
    (let ((map (make-sparse-keymap)))
      (define-key map (kbd "C-c b")
                  '(menu-item "First shortcut" etaf-help-test-first-command))
      (use-local-map map)
      (etaf-help runtime)
      (define-key map (kbd "C-c b") #'etaf-help-test-second-command)
      (let ((labels (etaf-help-test-labels (etaf-help-data runtime))))
        (should (member "First shortcut" labels))
        (should-not (member "Second local command." labels)))
      (etaf-help-close runtime)
      (should (eq (key-binding (kbd "C-c b") t) #'etaf-help-test-second-command))
      (let ((labels (etaf-help-test-labels (etaf-help-data runtime))))
        (should (member "Second local command." labels))
        (should-not (member "First shortcut" labels))))))

(ert-deftest etaf-help-covers-short-and-text-roots-without-changing-them ()
  "A short or text-only application gets a full modal then its original extent."
  (dolist (view (list (etaf-view (text :ref 'root "Text root"))
                      (etaf-view (column :ref 'root (text "Short column")))
                      (etaf-view (fragment (text "First") (text "Second")))))
    (etaf-test-with-mount (runtime view)
      (let ((before (etaf-help-test-text))
            (buffers (buffer-list))
            (windows (window-list)))
        (etaf-help runtime)
        (should (string-match-p "通用导航" (etaf-help-test-text)))
        (should (string-match-p "关闭帮助" (etaf-help-test-text)))
        (should (equal buffers (buffer-list)))
        (should (equal windows (window-list)))
        (etaf-help-close runtime)
        (should (equal before (etaf-help-test-text)))))))

(ert-deftest etaf-help-preserves-provider-observation-across-canvas-changes ()
  "Opening and closing help keep actual Ebox flush reports in Runtime operations."
  (etaf-test-with-mount (runtime (etaf-view (text "Observed application")))
    (etaf-performance-start runtime)
    (dolist (operation (list (lambda () (etaf-help runtime))
                            (lambda () (etaf-help-close runtime))))
      (etaf-performance-call-operation runtime 'help "Help transition" operation)
      (let* ((record (car (etaf-performance-records)))
             (reports (etaf-performance-operation-stages record))
             (flush (cl-find-if
                     (lambda (report)
                       (and (eq (etaf-performance-stage-provider report) 'ebox)
                            (eq (etaf-performance-stage-name report) 'flush)
                            (> (plist-get (etaf-performance-stage-metadata report) :lines) 0)))
                     reports)))
        (should flush)))))

(ert-deftest etaf-help-renders-without-a-known-window-height ()
  "An offscreen mount with an indefinite height can open and close help."
  (with-temp-buffer
    (etaf-mount (current-buffer) (etaf-view (text "Offscreen application")))
    (unwind-protect
        (progn
          (etaf-help)
          (should (string-match-p "关闭帮助" (etaf-help-test-text)))
          (etaf-help-close)
          (should (equal (string-trim (etaf-help-test-text)) "Offscreen application")))
      (etaf-unmount (etaf-runtime-for-buffer (current-buffer))))))

(ert-deftest etaf-help-retains-scrolling-and-surviving-focus ()
  "Opening help never remounts application state or resets its scroll offset."
  (etaf-test-with-mount
      (runtime (etaf-view
                (column :ref 'page :width 'stretch :height '(lh 40)
                  (box :ref 'entry :tab-index 0 "Entry")
                  (column :ref 'log :height '(lh 6) :overflow 'scroll
                    (expr (mapcar (lambda (n) (etaf-view (text (expr (format "Row %d" n)))))
                                  (number-sequence 1 50)))))))
    (etaf-focus runtime 'entry)
    (etaf-scroll-to runtime 'log 17)
    (let ((before (etaf-help-test-text))
          (size (etaf-host-ref-size runtime 'page)))
      (etaf-help runtime)
      (let ((offset (etaf-scroll-offset runtime 'log))
            (during-size (etaf-host-ref-size runtime 'page)))
        (should (= offset 17))
        (should (equal size during-size)))
      (etaf-help-close runtime)
      (let ((offset (etaf-scroll-offset runtime 'log)))
        (should (= offset 17)))
      (should (eq (etaf-focused-host-ref runtime) 'entry))
      (should (equal before (etaf-help-test-text))))))

(ert-deftest etaf-help-survives-root-replacement-and-removed-opener ()
  "A background root replacement preserves help and closes without stale focus."
  (let ((revision (etaf-ref 1)))
    (etaf-test-with-mount
        (runtime (lambda ()
                   (if (= (etaf-value revision) 1)
                       (etaf-view (column :aria-label "Original" :width 'stretch :height '(lh 40)
                                    (box :ref 'entry :tab-index 0 "Entry")))
                     (etaf-view (text :aria-label "Replacement" "New application")))))
      (etaf-focus runtime 'entry)
      (etaf-help runtime)
      (setf (etaf-value revision) 2)
      (should (string-match-p "关闭帮助" (etaf-help-test-text)))
      (let ((data (etaf-help-data runtime)))
        (should (equal (plist-get data :title) "Original")))
      (etaf-help-close runtime)
      (should (equal (string-trim (etaf-help-test-text)) "New application"))
      (let ((data (etaf-help-data runtime)))
        (should (equal (plist-get data :title) "Replacement"))))))

(ert-deftest etaf-help-render-failure-leaves-application-usable ()
  "A failing custom renderer leaves no modal or stale help state and can retry."
  (etaf-test-with-mount
      (runtime (etaf-view (column (box :ref 'entry :tab-index 0 "Entry"))))
    (etaf-focus runtime 'entry)
    (let ((before (etaf-help-test-text))
          (etaf-help-view-function
           (lambda (_data _close)
             (etaf-view (box :help 42 "Invalid help metadata")))))
      (let ((failed (condition-case nil
                        (progn (etaf-help runtime) nil)
                      (etaf-renderer-error t))))
        (should failed))
      (should (equal before (etaf-help-test-text)))
      (let ((closed (etaf-help-close runtime)))
        (should-not closed)))
    (let ((etaf-help-view-function nil))
      (etaf-help runtime)
      (should (string-match-p "关闭帮助" (etaf-help-test-text)))
      (etaf-help-close runtime)
      (should (eq (etaf-focused-host-ref runtime) 'entry)))))

(ert-deftest etaf-help-isolates-mounts-and-releases-on-unmount ()
  "Closing or unmounting one application does not retire another's help."
  (etaf-test-with-mount (first (etaf-view (text "First")))
    (etaf-help first)
    (etaf-test-with-mount (second (etaf-view (text "Second")))
      (etaf-help second)
      (etaf-unmount first)
      (should (string-match-p "关闭帮助" (etaf-help-test-text)))
      (etaf-help-close second)
      (should (equal (string-trim (etaf-help-test-text)) "Second")))
    (etaf-mount (current-buffer) (etaf-view (text "Remounted"))
                '(:viewport-width 800 :viewport-height 40))
    (let ((runtime (etaf-runtime-for-buffer (current-buffer))))
      (etaf-help runtime)
      (should (string-match-p "关闭帮助" (etaf-help-test-text)))
      (etaf-help-close runtime)
      (should (equal (string-trim (etaf-help-test-text)) "Remounted")))))

(ert-deftest etaf-help-opening-prepares-only-the-nearest-enabled-scope ()
  "Help preparation runs once per opening, within the effective modal scope."
  (let ((prepared nil) (disabled (etaf-ref nil)))
    (etaf-test-with-mount
        (runtime (etaf-view
                  (column :on-help-open (lambda () (push 'outer prepared))
                    (column :disabled (etaf-value disabled)
                            :on-help-open (lambda () (push 'inner prepared))
                      (box :ref 'entry :tab-index 0 "Entry")))))
      (etaf-focus runtime 'entry)
      (call-interactively (key-binding (kbd "?") t))
      (should (equal prepared '(inner)))
      (etaf-help runtime)
      (should (equal prepared '(inner)))
      (etaf-help-close runtime)
      (should (equal prepared '(inner)))
      (setf (etaf-value disabled) t)
      (etaf-help runtime)
      (should (equal prepared '(outer inner))))
    (setq prepared nil)
    (etaf-test-with-mount
        (runtime (etaf-view
                  (column :on-help-open (lambda () (push 'outer prepared))
                    (column :focus-scope 'modal
                      (box :ref 'entry :tab-index 0 "Dialog entry")))))
      (etaf-focus runtime 'entry)
      (etaf-help runtime)
      (should-not prepared))))

(ert-deftest etaf-help-opening-failure-preserves-policy-state-and-permits-retry ()
  "Preparation can pause activity; failures never open help or undo that pause."
  (let ((running (etaf-ref t)) (reject t))
    (etaf-test-with-mount
        (runtime (etaf-view
                  (column :help (if (etaf-value running) "Running" "Paused")
                          :on-help-open
                          (lambda ()
                            (setf (etaf-value running) nil)
                            (when reject (user-error "Preparation rejected")))
                    (box :ref 'entry :tab-index 0 "Application"))))
      (etaf-focus runtime 'entry)
      (let ((failed (condition-case nil (progn (etaf-help runtime) nil)
                      (user-error t)))
            (paused (not (etaf-value running))))
        (should failed)
        (should paused))
      (let ((closed (etaf-help-close runtime))
            (text (string-trim (etaf-help-test-text))))
        (should-not closed)
        (should (equal text "Application")))
      (setq reject nil)
      (etaf-help runtime)
      (let ((notes (plist-get (etaf-help-data runtime) :notes)))
        (should (equal notes '("Paused"))))
      (etaf-help-close runtime)
      (let ((running-now (etaf-value running))
            (focus (etaf-focused-host-ref runtime)))
        (should-not running-now)
        (should (eq focus 'entry))))))

(ert-deftest etaf-help-opening-from-an-event-waits-for-preparation-publication ()
  "A button sees settled preparation notes and repeated requests reuse help."
  (let ((note (etaf-ref "Running")) (prepared nil))
    (etaf-test-with-mount
        (runtime (etaf-view
                  (column :help (etaf-value note)
                          :on-help-open (lambda ()
                                          (push 'paused prepared)
                                          (setf (etaf-value note) "Paused"))
                    (box :ref 'opener :tab-index 0 :role 'button
                         :on-press (lambda () (etaf-help) (etaf-help))
                      "Open help"))))
      (etaf-focus runtime 'opener)
      (etaf-activate runtime)
      (let ((notes (plist-get (etaf-help-data runtime) :notes)))
        (should (equal notes '("Paused"))))
      (should (equal prepared '(paused)))
      (etaf-help-close runtime)
      (let ((focus (etaf-focused-host-ref runtime)))
        (should (eq focus 'opener))))))

(ert-deftest etaf-help-closing-event-restores-after-publication ()
  "A close callback restores focus and native scrolling after removing help."
  (save-window-excursion
    (let ((etaf-help-view-function
           (lambda (_data close)
             (etaf-view
              (box :position 'absolute :layer 'root :left '(px 0) :top '(lh 0)
                   :width '(ch 40) :height '(lh 8) :focus-scope 'modal
                   :ref 'help-panel :tab-index 0 :on-dismiss close
                (box :ref 'help-close :tab-index 0 :role 'button :on-press close
                  "Close help"))))))
      (etaf-test-with-mount
          (runtime (etaf-view
                    (column :width 'stretch :height '(lh 40)
                      (expr (mapcar (lambda (n)
                                      (etaf-view (text (expr (format "Application row %d" n)))))
                                    (number-sequence 1 28)))
                      (box :ref 'entry :tab-index 0 "Application entry"))))
        (set-window-buffer (selected-window) (current-buffer))
        (etaf-focus runtime 'entry)
        (let ((focused (etaf-focused-host-ref runtime)))
          (should (eq focused 'entry)))
        (let ((start (save-excursion (goto-char (point-min)) (forward-line 5) (point))))
          (set-window-start (selected-window) start t)
          (etaf-help runtime)
          (should (= (window-start) (point-min)))
          (etaf-dispatch-event runtime 'help-close 'press)
          (let ((focus (etaf-focused-host-ref runtime)) (restored (window-start)))
            (should (eq focus 'entry))
            (should (= restored start))))))))

(ert-deftest etaf-help-render-failure-restores-native-window-position ()
  "A renderer rejection restores the native scroll used before opening."
  (save-window-excursion
    (etaf-test-with-mount
        (runtime (etaf-view
                  (column :height '(lh 40)
                    (text (expr (make-string 28 ?\n)))
                    (box :ref 'entry :tab-index 0 "Entry"))))
      (set-window-buffer (selected-window) (current-buffer))
      (etaf-focus runtime 'entry)
      (let ((start (save-excursion (goto-char (point-min)) (forward-line 5) (point)))
            (origin (point))
            (etaf-help-view-function
             (lambda (_data _close)
               (etaf-view (box :help 42 "Rejected renderer")))))
        (set-window-start (selected-window) start t)
        (let ((failed (condition-case nil (progn (etaf-help runtime) nil)
                        (etaf-renderer-error t))))
          (should failed))
        (should (= start (window-start)))
        (should (= origin (point)))
        (let ((closed (etaf-help-close runtime)))
          (should-not closed))))))

(ert-deftest etaf-help-deferred-close-respects-newer-lifecycles ()
  "Closing in a batch neither refocuses an unmount nor steals a newer help."
  (etaf-test-with-mount
      (runtime (etaf-view (box :ref 'entry :tab-index 0 "Entry")))
    (etaf-focus runtime 'entry)
    (etaf-help runtime)
    (etaf-batch
      (etaf-help-close runtime)
      (etaf-help runtime))
    (let ((focus (etaf-focused-host-ref runtime))
          (text (etaf-help-test-text)))
      (should-not (eq focus 'entry))
      (should (string-match-p "关闭帮助" text)))
    (etaf-batch
      (etaf-help-close runtime)
      (etaf-unmount runtime))
    (let ((mounted (etaf-runtime-for-buffer (current-buffer))))
      (should-not mounted))))

(ert-deftest etaf-help-panel-measures-the-canvas-face ()
  "The panel sizes and centres itself in the cells the canvas draws.
The frame's own face is a different cell whenever the canvas font or a text
scale differs from it, and a panel measured with the frame's one would sit
off the centre it computed."
  (etaf-test-with-mount
      (runtime (etaf-view (box :ref 'entry :tab-index 0 "Entry")))
    ;; The canvas reports a 10-pixel cell where the frame's face has 20, so
    ;; the panel's column count tells which face measured it.
    (cl-letf (((symbol-function 'ebox-display-metrics)
               (lambda (&optional _buffer)
                 (list :char-width 10 :line-height 18 :ascent 100)))
              ((symbol-function 'frame-char-width) (lambda (&optional _frame) 20))
              ((symbol-function 'frame-char-height) (lambda (&optional _frame) 40)))
      (etaf-help runtime)
      (let* ((viewport (car (etaf-runtime-viewport runtime)))
             ;; Ten-pixel cells keep four of the canvas's columns free.
             (width (max 1 (min 88 (- (/ viewport 10) 4))))
             (box (etaf-host-ref-size runtime 'etaf-help-panel)))
        (should box)
        (should (= (car box) width))))))

(provide 'etaf-help-tests)
