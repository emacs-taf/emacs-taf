;;; -*- lexical-binding: t; -*-
;;; etaf-ui-modern-tests.el --- Public modern catalog behavior

;;; Code:
(require 'ert)
(require 'etaf-ui)

(defun etaf-ui-modern-test-activate (runtime label)
  "Activate the visible LABEL through RUNTIME's public target interface."
  (let ((target
         (car (cl-find-if
               (lambda (entry)
                 (and (equal label (plist-get (cdr entry) :aria-label))
                      (etaf-host-ref-position runtime (car entry))))
               (etaf-runtime-host-props-entries runtime)))))
    (should target)
    (etaf-focus runtime target)
    (etaf-activate runtime)))

(ert-deftest etaf-ui-feedback-and-navigation-render-public-contracts ()
  "Feedback and navigation Components render and dispatch through public refs."
  (with-temp-buffer
    (let ((active (etaf-ref 'one))
          (open (etaf-ref nil))
          (selected nil))
      (unwind-protect
          (progn
            (etaf-mount
             (current-buffer)
             (etaf-view
              (column :width '(ch 80) :height '(lh 25)
                (etaf-alert :title "Notice" :message "Ready" :variant 'info)
                (etaf-tabs :items '((:key one :label "One" :count 17)
                                    (:key two :label "Two"))
                           :active active
                           :on-change (lambda (key) (setf selected key (etaf-value active) key)))
                (etaf-accordion
                 :items '((:key details :label "Details" :content "More"))
                 :open open :multiple nil
                 :on-toggle (lambda (keys) (setf (etaf-value open) keys)))
                (etaf-badge :text "Ready" :variant 'success)
                (etaf-breadcrumb :items '("Home" "Collection" "Item")
                                 :on-select (lambda (index) (setq selected index)))
                (etaf-progress :value 3 :max 4 :label "Progress"))))
            (let ((runtime (etaf-runtime-for-buffer (current-buffer))))
              (should (string-match-p "Notice" (buffer-string)))
              (should (etaf-runtime-mounted-p runtime))
              (should (string-match-p "Progress" (buffer-string)))
              (should (string-match-p "17" (buffer-string)))
              (etaf-ui-modern-test-activate runtime "Two")
              (should (eq selected 'two))
              (should (eq (etaf-value active) 'two))
              (etaf-ui-modern-test-activate runtime "Details")
              (should (equal (etaf-value open) '(details)))
              (should (string-match-p "More" (buffer-string)))
              (etaf-ui-modern-test-activate runtime "Home")
              (should (equal selected 0))
              (etaf-ui-modern-test-activate runtime "Collection")
              (should (equal selected 1))))
        (when-let* ((runtime (etaf-runtime-for-buffer (current-buffer))))
          (etaf-unmount runtime))))))

(ert-deftest etaf-ui-tabs-address-items-by-ref ()
  "A tab item's optional :ref reaches the rendered control."
  (with-temp-buffer
    (let ((active (etaf-ref 'one))
          (selected nil))
      (unwind-protect
          (progn
            (etaf-mount
             (current-buffer)
             (etaf-view
              (column :width '(ch 40)
                (etaf-tabs :items '((:key one :label "One" :ref one-tab)
                                    (:key two :label "Two" :ref two-tab))
                           :active active
                           :on-change (lambda (key)
                                        (setf selected key
                                              (etaf-value active) key))))))
            (let ((runtime (etaf-runtime-for-buffer (current-buffer))))
              (should (etaf-host-ref-position runtime 'two-tab))
              (etaf-dispatch-event runtime 'two-tab 'press)
              (should (eq selected 'two))
              (should (eq (etaf-value active) 'two))))
        (when-let* ((runtime (etaf-runtime-for-buffer (current-buffer))))
          (etaf-unmount runtime))))))

(ert-deftest etaf-ui-tabs-keep-every-label-in-place-when-switching ()
  "Switching the active tab never moves any tab label."
  (with-temp-buffer
    (let ((active (etaf-ref 'one)))
      (unwind-protect
          (progn
            (etaf-mount
             (current-buffer)
             (etaf-view
              (column :width '(ch 60)
                (etaf-tabs :items '((:key one :label "One" :count 3)
                                    (:key two :label "Two")
                                    (:key three :label "Three"))
                           :active active
                           :on-change (lambda (key) (setf (etaf-value active) key))))))
            (cl-flet ((columns ()
                        (mapcar (lambda (label)
                                  (save-excursion
                                    (goto-char (point-min))
                                    (search-forward label)
                                    (- (current-column) (length label))))
                                '("One" "Two" "Three"))))
              (let ((before (columns)))
                (setf (etaf-value active) 'three)
                (should (equal (columns) before))
                (setf (etaf-value active) 'two)
                (should (equal (columns) before)))))
        (when-let* ((runtime (etaf-runtime-for-buffer (current-buffer))))
          (etaf-unmount runtime))))))

(defun etaf-ui-modern-test-label-layout (runtime labels)
  "Return LABELS' painted positions, sizes and font weights in RUNTIME."
  (mapcar
   (lambda (label)
     (let* ((entry (cl-find-if
                    (lambda (entry) (equal label (plist-get (cdr entry) :aria-label)))
                    (etaf-runtime-host-props-entries runtime)))
            (size (etaf-host-ref-size runtime (car entry))))
       (save-excursion
         (goto-char (point-min))
         (search-forward label)
         (list (- (current-column) (string-width label)) size
               (plist-get (cdr entry) :font-weight)))))
   labels))

(ert-deftest etaf-ui-selection-keeps-label-positions-sizes-and-typeface ()
  "Choice controls change selection paint, never label geometry."
  (dolist (component '(etaf-tabs etaf-segmented etaf-steps etaf-select
                      etaf-taskbar etaf-workspace-bar))
    (with-temp-buffer
      (let* ((value (etaf-ref 'one))
             (change (lambda (next) (etaf-set-value value next)))
             (items '((:key one :label "One") (:key two :label "Two")
                      (:key three :label "Three")))
             (props (pcase component
                      ('etaf-tabs (list :items items :active value :on-change change))
                      ('etaf-steps (list :items items :current value :on-change change))
                      ('etaf-taskbar (list :items items :active value :on-select change))
                      ('etaf-workspace-bar (list :workspaces items :active value :on-select change))
                      (_ (list :options '((one . "One") (two . "Two") (three . "Three"))
                               :bind value))))
             (runtime (progn
                        (etaf-mount (current-buffer) (etaf-node component props nil))
                        (etaf-runtime-for-buffer (current-buffer)))))
        (unwind-protect
            (let ((before (etaf-ui-modern-test-label-layout runtime '("One" "Two" "Three"))))
              (dolist (label '("Three" "Two" "One"))
                (etaf-ui-modern-test-activate runtime label)
                (let ((after (etaf-ui-modern-test-label-layout runtime '("One" "Two" "Three"))))
                  (ert-info ((format "%s selecting %s" component label))
                    (should (equal before after))))))
          (etaf-unmount runtime))))))

(ert-deftest etaf-ui-disclosures-use-arrows-and-stable-control-names ()
  "Disclosure arrows are visual cues, never letters in accessible control names."
  (with-temp-buffer
    (let ((open (etaf-ref nil)) (expanded (etaf-ref nil)))
      (unwind-protect
          (progn
            (etaf-mount
             (current-buffer)
             (etaf-view
              (column :width '(ch 80) :height '(lh 30)
                (etaf-menu :label "Operations" :items '((:key copy :label "Copy"))
                           :on-select #'ignore)
                (etaf-select :label "Choice" :placeholder "Choose" :options '((a . "Alpha"))
                             :presentation 'dropdown :on-change #'ignore)
                (etaf-dropdown-menu :label "Actions" :items '((:key copy :label "Copy"))
                                    :on-select #'ignore)
                (etaf-accordion :items '((:key details :label "Details" :content "Body"))
                                :open open :on-toggle (lambda (keys) (etaf-set-value open keys)))
                (etaf-tree :items '((:key branch :label "Branch"
                                    :children ((:key leaf :label "Leaf"))))
                           :expanded expanded
                           :on-toggle (lambda (keys) (etaf-set-value expanded keys))))))
            (let* ((runtime (etaf-runtime-for-buffer (current-buffer)))
                   (text (buffer-substring-no-properties (point-min) (point-max))))
              (dolist (caption '("Operations ⌄" "Choose ⌄" "Actions ⌄" "› Details" "› Branch"))
                (should (string-match-p (regexp-quote caption) text)))
              (etaf-ui-modern-test-activate runtime "Details")
              (let ((before (etaf-ui-modern-test-label-layout runtime '("Branch"))))
                (etaf-ui-modern-test-activate runtime "Branch")
                (let ((after (etaf-ui-modern-test-label-layout runtime '("Branch"))))
                  (should (equal before after))))
              (setq text (buffer-substring-no-properties (point-min) (point-max)))
              (should (string-match-p "⌄ Details" text))
              (should (string-match-p "⌄ Branch" text))
              (should (string-match-p "Body" text))
              (should (string-match-p "Leaf" text))))
        (when-let* ((runtime (etaf-runtime-for-buffer (current-buffer))))
          (etaf-unmount runtime))))))

(ert-deftest etaf-ui-calendar-aligns-weekdays-dates-and-selection ()
  "Every date stays under its weekday, including leading blanks and selection."
  (with-temp-buffer
    (let ((day (etaf-ref 14)))
      (unwind-protect
          (progn
            (etaf-mount
             (current-buffer)
             (etaf-view
              (etaf-calendar :month '(2026 10) :value (etaf-value day)
                             :on-change (lambda (date) (etaf-set-value day (nth 2 date))))))
            (let* ((runtime (etaf-runtime-for-buffer (current-buffer)))
                   (weekdays
                    (mapcar (lambda (label)
                              (save-excursion
                                (goto-char (point-min)) (search-forward label)
                                (etaf-string-pixel-width
                                 (buffer-substring (line-beginning-position) (- (point) 2)))))
                            '("Mo" "Tu" "We" "Th" "Fr" "Sa" "Su"))))
              (dolist (selected '(1 16 31))
                (etaf-ui-modern-test-activate runtime (format "October %d" selected))
                (should (= (etaf-value day) selected))
                (dotimes (index 31)
                  (let* ((date (1+ index))
                         (entry (cl-find-if
                                 (lambda (entry)
                                   (equal (format "October %d" date)
                                          (plist-get (cdr entry) :aria-label)))
                                 (etaf-runtime-host-props-entries runtime)))
                         (bounds (etaf-host-ref-bounds runtime (car entry)))
                         (column (save-excursion
                                   (goto-char (car bounds))
                                   (search-forward (format "%2d" date) (cdr bounds))
                                   (etaf-string-pixel-width
                                    (buffer-substring (line-beginning-position) (- (point) 2))))))
                    (ert-info ((format "Day %d with %d selected" date selected))
                      (should (= column (nth (% (+ index 3) 7) weekdays)))))))))
        (when-let* ((runtime (etaf-runtime-for-buffer (current-buffer))))
          (etaf-unmount runtime))))))

(ert-deftest etaf-ui-selection-components-render-public-contracts ()
  "Selection Components render controlled values through the public DSL."
  (with-temp-buffer
    (let ((choice (etaf-ref 'cozy))
          (kind (etaf-ref 'brand))
          (enabled (etaf-ref t))
          (zoom (etaf-ref 80))
          (name (etaf-ref "Atelier"))
          (launch-date (etaf-ref "2026-09-16")))
      (unwind-protect
          (progn
            (etaf-mount
             (current-buffer)
             (etaf-view
              (column :width '(ch 80) :height '(lh 25)
                (etaf-radio :bind choice :label "Density"
                            :options '((compact . "Compact") (cozy . "Cozy")))
                (etaf-segmented :bind kind
                                :options '((brand . "Brand") (product . "Product")))
                (etaf-switch :bind enabled :label "Live updates")
                (etaf-slider :bind zoom :label "Zoom" :min 40 :max 120 :step 10)
                (etaf-text-input :bind name :label "Name")
                (etaf-date-picker :bind launch-date :label "Launch date"))))
            (let ((runtime (etaf-runtime-for-buffer (current-buffer))))
              (should (etaf-runtime-mounted-p runtime))
              (should (string-match-p "Density" (buffer-string)))
              (should (string-match-p "Live updates" (buffer-string)))
              (should (string-match-p "80" (buffer-string)))
              (should (string-match-p "Launch date" (buffer-string)))))
        (when-let* ((runtime (etaf-runtime-for-buffer (current-buffer))))
          (etaf-unmount runtime))))))

(ert-deftest etaf-ui-slider-arrows-stay-on-aligned-values ()
  "Bound sliders keep every arrow result aligned, including non-step maxima."
  (dolist (case '((0 5 2 4 ((right . 4) (left . 2) (left . 0) (left . 0)
                            (right . 2) (right . 4) (right . 4)))
                  (-5 2 3 1 ((right . 1) (left . -2) (left . -5) (left . -5)))
                  (3 4 5 3 ((right . 3) (left . 3)))
                  (7 7 2 7 ((right . 7) (left . 7)))
                  (0 6 2 4 ((right . 6) (right . 6) (left . 4)))))
    (pcase-let ((`(,low ,high ,step ,initial ,moves) case))
      (with-temp-buffer
        (let ((value (etaf-ref initial)))
          (unwind-protect
              (progn
                (etaf-mount
                 (current-buffer)
                 (etaf-view
                  (etaf-slider :bind value :min low :max high :step step
                               :label "Aligned value")))
                (let* ((runtime (etaf-runtime-for-buffer (current-buffer)))
                       (target (car (cl-find-if
                                     (lambda (entry)
                                       (equal "Aligned value"
                                              (plist-get (cdr entry) :aria-label)))
                                     (etaf-runtime-host-props-entries runtime)))))
                  (should target)
                  (etaf-focus runtime target)
                  (dolist (move moves)
                    (etaf-direction (car move) runtime)
                    (ert-info ((format "%s..%s step %s, %s" low high step (car move)))
                      (should (= (etaf-value value) (cdr move)))
                      (let* ((bounds (etaf-host-ref-bounds runtime target))
                             (text (buffer-substring-no-properties (car bounds) (cdr bounds))))
                        (should (string-match-p (format "◀  %d  ▶" (cdr move)) text)))))))
            (when-let* ((runtime (etaf-runtime-for-buffer (current-buffer))))
              (etaf-unmount runtime))))))))

(ert-deftest etaf-ui-keycap-and-check-mark-render-public-contracts ()
  "Keycaps keep both levels and dispatch; check marks draw all four states."
  (with-temp-buffer
    (let ((pressed nil))
      (unwind-protect
          (progn
            (etaf-mount
             (current-buffer)
             (etaf-view
              ;; One control per row: a batch canvas is narrow at one cell per
              ;; column, so a caption only survives in its own row.
              (column :width '(ch 30)
                (etaf-keycap :text "x" :label "Done" :aria-label "Done"
                             :on-press (lambda () (setq pressed 'action)))
                (etaf-keycap :text "B" :level 'region :label "Tasks" :active t)
                (etaf-keycap :text "m" :label "Move" :disabled t)
                (etaf-keycap :text "Esc" :label "Close")
                (etaf-check-mark :state 'empty)
                (etaf-check-mark :state 'done)
                (etaf-check-mark :state 'dropped)
                (etaf-check-mark :state 'skipped)
                (etaf-check-mark :state 'done :glyph "OK"))))
            (let ((runtime (etaf-runtime-for-buffer (current-buffer)))
                  (text (buffer-substring-no-properties (point-min) (point-max))))
              (should (etaf-runtime-mounted-p runtime))
              ;; Captions are drawn beside the cap, not inside it.
              (should (string-match-p "x" text))
              (should (string-match-p "Done" text))
              (should (string-match-p "Tasks" text))
              (should (string-match-p "Move" text))
              ;; A text frame spells each mark with its own word.
              (should (string-match-p "待" text))
              (should (string-match-p "完" text))
              (should (string-match-p "弃" text))
              (should (string-match-p "跳" text))
              ;; An explicit glyph replaces the default spelling.
              (should (string-match-p "OK" text))
              (should-error (etaf-render (etaf-view (etaf-keycap :text ""))))
              (should-error (etaf-render (etaf-view (etaf-keycap :text "x" :level 'huge))))
              (should-error (etaf-render (etaf-view (etaf-check-mark :state 'maybe))))
              (etaf-ui-modern-test-activate runtime "Done")
              (should (eq pressed 'action))))
        (when-let* ((runtime (etaf-runtime-for-buffer (current-buffer))))
          (etaf-unmount runtime))))))

(ert-deftest etaf-ui-composition-components-render-public-contracts ()
  "Tag, Kbd, Steps and List compose with caller-owned selection callbacks."
  (with-temp-buffer
    (let ((current (etaf-ref 'one)) (selected nil) (closed nil))
      (unwind-protect
          (progn
            (etaf-mount
             (current-buffer)
             (etaf-view
              (column :width '(ch 80) :height '(lh 25)
                (etaf-tag :text "Ready" :variant 'success :closable t
                          :on-close (lambda () (setq closed t)))
                (etaf-kbd :keys '("Ctrl" "K"))
                (row :item-gap '(ch 1)
                  (etaf-avatar :name "Mina")
                  (etaf-avatar :name "")
                  (etaf-avatar :name "Ada" :initials "AL" :size '(ch 4)
                               :lines 2 :background "#2563eb")
                  (etaf-avatar :name "Zed" :src "/nonexistent/photo.png"))
                (etaf-steps
                 :current current
                 :items '((:key one :label "Plan") (:key two :label "Build"))
                 :on-change (lambda (key) (setf (etaf-value current) key)))
                (etaf-list
                 :items '((:key one :title "Overview" :description "Start here")
                          (:key two :title "Details" :description "Keep composing"))
                 :on-select (lambda (key) (setf selected key))))))
            (let ((runtime (etaf-runtime-for-buffer (current-buffer))))
              (should (etaf-runtime-mounted-p runtime))
              (should (string-match-p "Ready" (buffer-string)))
              (should (string-match-p "Ctrl" (buffer-string)))
              (should (string-match-p "MI" (buffer-string)))
              (should (string-match-p (regexp-quote "?") (buffer-string)))
              ;; Text frames fall back to initials even with a photo source.
              (should (string-match-p "ZE" (buffer-string)))
              (should-error (etaf-render (etaf-view (etaf-avatar :name "x" :shape 'star))))
              (let ((start (string-match "AL" (buffer-string))))
                (should start)
                (should (member '(:background "#2563eb")
                                (get-text-property (1+ start) 'face))))
              (should (string-match-p "Build" (buffer-string)))
              (should (string-match-p "1  Plan" (buffer-string)))
              (should (string-match-p "2  Build" (buffer-string)))
              (should (string-match-p "Keep composing" (buffer-string)))
              (etaf-ui-modern-test-activate runtime "Build")
              (should (eq (etaf-value current) 'two))
              (etaf-ui-modern-test-activate runtime "Details")
              (should (eq selected 'two))
              (etaf-ui-modern-test-activate runtime "Remove Ready")
              (should closed)))
        (when-let* ((runtime (etaf-runtime-for-buffer (current-buffer))))
          (etaf-unmount runtime))))))

(ert-deftest etaf-ui-list-draws-checkbox-selection-and-meta ()
  "A list draws the checkbox column, the trailing meta and the selected row."
  (with-temp-buffer
    (let ((selected nil))
      (etaf-mount
       (current-buffer)
       (etaf-view
        (etaf-list
         :checkbox t
         :selected 'b
         :items '((:key a :title "Alpha" :meta "09:00" :checked nil)
                  (:key b :title "Beta" :meta "10:00" :checked t))
         :on-select (lambda (key) (setq selected key))))
       nil)
      (let ((text (buffer-substring-no-properties (point-min) (point-max))))
        (should (string-match-p "\\[ \\] +Alpha" text))
        (should (string-match-p "\\[x\\] +Beta" text))
        (should (string-match-p (regexp-quote "10:00") text)))
      (let* ((runtime (etaf-runtime-for-buffer (current-buffer)))
             (start (string-match "Beta" (buffer-substring-no-properties
                                          (point-min) (point-max)))))
        (should start)
        (should (get-text-property (1+ start) 'face))
        (etaf-ui-modern-test-activate runtime "Alpha")
        (should (eq selected 'a)))
      (when-let* ((runtime (etaf-runtime-for-buffer (current-buffer))))
        (etaf-unmount runtime)))))

(ert-deftest etaf-ui-composition-components-reject-invalid-props ()
  "Invalid shortcut keys, duplicate list identities and absent steps are rejected."
  (dolist (view '((etaf-kbd :keys ("Ctrl" 2))
                  (etaf-list :items ((:key same :title "First")
                                     (:key same :title "Second")))
                  (etaf-tabs :items ((:key one :label "One" :count (1 2)))
                             :active one :on-change ignore)
                  (etaf-steps :items ((:key one :label "Plan")) :current missing)))
    (with-temp-buffer
      (should-error (etaf-mount (current-buffer) (etaf-node (car view) (cdr view) nil))
                    :type 'etaf-view-error))))

;;; etaf-ui-modern-tests.el ends here
