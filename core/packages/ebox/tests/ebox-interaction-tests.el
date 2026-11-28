;;; ebox-interaction-tests.el --- Ebox interaction and focus tests -*- lexical-binding: t; -*-

(require 'ebox-test-support)

(ert-deftest ebox-keymap-create-installs-activation-bindings ()
  (let* ((hits 0)
         (map (ebox-keymap-create :activate (lambda () (setq hits (1+ hits)))))
         (rendered (ebox-render (list 'box :keymap map "Go"))))
    (should (keymapp (get-text-property 0 'keymap rendered)))
    (should (commandp (lookup-key (get-text-property 0 'keymap rendered) (kbd "RET"))))
    (ebox-test-with-mounted (buffer _root (list 'box :keymap map "Go"))
      (goto-char (point-min))
      (ebox-activate)
      (should (= hits 1)))))

(ert-deftest ebox-keyboard-activation-belongs-to-focused-ancestor ()
  (let* ((outer 0) (inner 0)
         (outer-map (ebox-keymap-create :activate (lambda () (setq outer (1+ outer)))))
         (inner-map (ebox-keymap-create :activate (lambda () (setq inner (1+ inner))))))
    (ebox-test-with-mounted (buffer root
                             `(box :id "row" :tab-index 0 :keymap ,outer-map
                                   "Row " (box :id "link" :keymap ,inner-map "link")))
      (ebox-focus (ebox-test--node root "row") buffer)
      (goto-char (point-min))
      (search-forward "link")
      (backward-char)
      (let ((last-input-event ?\r))
        (command-execute (lookup-key (get-char-property (point) 'keymap) (kbd "RET"))))
      (should (= outer 1))
      (should (= inner 0)))))

(ert-deftest ebox-help-create-runs-business-function-in-hovered-buffer ()
  (let* ((help (ebox-help-create (lambda () (buffer-name))))
         (buffer (generate-new-buffer " *ebox-help-test*")))
    (unwind-protect
        (progn
          (ebox-mount buffer (list 'box :help-echo help "Help"))
          (with-current-buffer buffer
            (let ((fn (get-text-property (point-min) 'help-echo)))
              (should (functionp fn))
              (should (equal (funcall fn nil buffer nil) (buffer-name buffer))))))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest ebox-interaction-properties-cover-rendered-text ()
  (let* ((map (ebox-keymap-create :bindings `(("x" . ,(lambda () :ok)))))
         (rendered (ebox-render
                    (list 'box :keymap map :help-echo "help" :pointer 'hand
                          :hover-style '(:background-color "#eeeeee")
                          "Interactive"))))
    (should (eq (get-text-property 0 'keymap rendered) map))
    (should (equal (get-text-property 0 'help-echo rendered) "help"))
    (should (eq (get-text-property 0 'pointer rendered) 'hand))
    (should (equal (get-text-property 0 'mouse-face rendered)
                   '(:background "#eeeeee")))))

(ert-deftest ebox-clipped-overlay-keeps-interaction-on-blank-rows ()
  (let* ((map (ebox-keymap-create :bindings `(("x" . ,(lambda () :ok)))))
         (rendered
          (ebox-render
           `(column :width (ch 12) :height (lh 3) :padding ((lh 0) (ch 2))
                    "page"
                    (column :position absolute :left (ch 0) :top (lh 0)
                            :width (% 100) :height (lh 3) :keymap ,map :pointer hand
                            :background-color "#101010"
                            (box :height (lh 1))
                            "over"
                            (box :height (lh 1))))))
         (covered 0))
    (dotimes (pos (length rendered))
      (when (equal (get-text-property pos 'face rendered) '(:background "#101010"))
        (setq covered (1+ covered))
        (should (eq (get-text-property pos 'keymap rendered) map))
        (should (eq (get-text-property pos 'pointer rendered) 'hand))))
    (should (> covered 4))))

(ert-deftest ebox-focus-first-next-previous-and-cycle-update-focused-node ()
  (ebox-test-with-mounted (buffer root
                           '(column
                             (box :id "a" :tab-index 0 "A")
                             (box :id "b" :tab-index 0 "B")
                             (box :id "c" :tab-index 0 "C")))
    (let ((a (car (ebox-selector-query root "#a")))
          (b (car (ebox-selector-query root "#b")))
          (c (car (ebox-selector-query root "#c"))))
      (should (eq (ebox-focus-first buffer) a))
      (should (eq (ebox-focused-node buffer) a))
      (should (eq (ebox-focus-next 1 nil buffer) b))
      (should (eq (ebox-focus-previous 1 nil buffer) a))
      (should (eq (ebox-focus-previous 1 t buffer) c))
      (should (eq (ebox-focus-next 1 t buffer) a)))))

(ert-deftest ebox-focus-within-stays-inside-container ()
  (ebox-test-with-mounted (buffer root
                           '(column
                             (box :id "outside" :tab-index 0 "Outside")
                             (column :id "group"
                                     (box :id "a" :tab-index 0 "A")
                                     (box :id "b" :tab-index 0 "B"))))
    (let ((group (car (ebox-selector-query root "#group")))
          (a (car (ebox-selector-query root "#a")))
          (b (car (ebox-selector-query root "#b"))))
      (should (eq (ebox-focus-within group 1 nil buffer) a))
      (should (eq (ebox-focus-within group 1 nil buffer) b))
      (should-error (ebox-focus-within group 1 nil buffer) :type 'user-error)
      (should (eq (ebox-focused-node buffer) b)))))

(ert-deftest ebox-focus-edge-respects-explicit-root-and-inner-groups ()
  "A subtree edge never selects a sibling or an enclosing group's member."
  (ebox-test-with-mounted (buffer root
                           '(column :focus-group vertical
                                    (box :id "outside" :tab-index 0 "Outside")
                                    (column :id "scope" :tab-index -1
                                            "Scope"
                                            (box :id "a" :tab-index 0 "A")
                                            (column :focus-group vertical
                                                    (box :id "b" :tab-index 0 "B")
                                                    (box :id "c" :tab-index 0 "C"))
                                            (box :id "d" :tab-index 0 "D")))
                           :width 200 :height 10)
    (let ((scope (car (ebox-selector-query root "#scope"))))
      (ebox-focus (car (ebox-selector-query root "#a")) buffer)
      (let ((end (ebox-focus-edge t buffer scope)))
        (should (equal (ebox-node-id end) "d")))
      (let ((start (ebox-focus-edge nil buffer scope)))
        (should (equal (ebox-node-id start) "a")))
      (ebox-focus (car (ebox-selector-query root "#b")) buffer)
      (let ((end (ebox-focus-edge t buffer scope)))
        (should (equal (ebox-node-id end) "c")))
      (ebox-focus (car (ebox-selector-query root "#outside")) buffer)
      (let ((start (ebox-focus-edge nil buffer scope)))
        (should (equal (ebox-node-id start) "a")))
      (ebox-focus scope buffer)
      (let ((start (ebox-focus-edge nil buffer scope)))
        (should (equal (ebox-node-id start) "a")))
      (let ((detached (ebox-node-create 'box)))
        (should-error (ebox-focus-edge nil buffer detached) :type 'user-error)))))

(defun ebox-test--node (root id)
  "Return ROOT's node with ID."
  (car (ebox-selector-query root (concat "#" id))))

;; Side-by-side regions share screen rows; Tab must finish one first.
(ert-deftest ebox-tab-order-finishes-a-side-region-before-the-next ()
  (ebox-test-with-mounted (buffer root
                           '(row
                             (column :id "side" :width (ch 10)
                                     (box :id "s1" :tab-index 0 "S1")
                                     (box :id "s2" :tab-index 0 "S2"))
                             (column :id "main" :width (ch 10)
                                     (box :id "m1" :tab-index 0 "M1")
                                     (box :id "m2" :tab-index 0 "M2")))
                           :width 40 :height 5)
    (should (equal (ebox-focus-stops buffer)
                   (mapcar (lambda (id) (ebox-test--node root id))
                           '("s1" "s2" "m1" "m2"))))))

(ert-deftest ebox-focus-change-functions-report-each-move ()
  (ebox-test-with-mounted (buffer root
                           '(column
                             (box :id "a" :tab-index 0 "A")
                             (box :id "b" :tab-index 0 "B")))
    (let ((a (ebox-test--node root "a"))
          (b (ebox-test--node root "b"))
          changes)
      (with-current-buffer buffer
        (add-hook 'ebox-focus-change-functions
                  (lambda (old new) (push (cons old new) changes)) nil t))
      (ebox-focus a buffer)
      (ebox-focus a buffer)
      (ebox-focus-next 1 t buffer)
      (ebox-focus nil buffer)
      (should (equal (nreverse changes)
                     (list (cons nil a) (cons a b) (cons b nil)))))))

(ert-deftest ebox-focus-group-is-one-tab-stop-roved-by-arrows ()
  (ebox-test-with-mounted (buffer root
                           '(column
                             (box :id "before" :tab-index 0 "Before")
                             (column :id "list" :focus-group vertical
                                     (box :id "a" :tab-index 0 "A")
                                     (box :id "b" :tab-index 0
                                          :attributes (("aria-selected" . "true")) "B")
                                     (box :id "c" :tab-index 0 "C"))
                             (box :id "after" :tab-index 0 "After"))
                           :width 200 :height 10)
    (cl-flet ((node (id) (ebox-test--node root id)))
      (ebox-focus (node "before") buffer)
      (should (eq (ebox-focus-next 1 nil buffer) (node "b")))
      (should (eq (ebox-focus-direction 'down buffer) (node "c")))
      (should (eq (ebox-focus-next 1 nil buffer) (node "after")))
      (should (eq (ebox-focus-previous 1 nil buffer) (node "c")))
      (should (eq (ebox-focus-direction 'down buffer) (node "after")))
      (should (eq (ebox-focus-direction 'up buffer) (node "c")))
      (should (eq (ebox-focus-edge nil buffer) (node "a")))
      (should (eq (ebox-focus-direction 'up buffer) (node "before")))
      (should (eq (ebox-focus-direction 'up buffer) nil))
      (should (eq (ebox-focused-node buffer) (node "before"))))))

(ert-deftest ebox-focus-direction-moves-to-nearest-stop-and-enters-grids ()
  (ebox-test-with-mounted (buffer root
                           '(column
                             (row (box :id "left" :tab-index 0 :width (ch 6) "Left")
                                  (box :id "right" :tab-index 0 :width (ch 6) "Right"))
                             (row :id "grid" :focus-group grid
                                  (column :width (ch 6)
                                          (box :id "g1" :tab-index 0 "G1")
                                          (box :id "g3" :tab-index 0 "G3"))
                                  (column :width (ch 6)
                                          (box :id "g2" :tab-index 0 "G2")
                                          (box :id "g4" :tab-index 0 "G4"))))
                           :width 300 :height 10)
    (cl-flet ((node (id) (ebox-test--node root id)))
      (ebox-focus (node "left") buffer)
      (should (eq (ebox-focus-direction 'right buffer) (node "right")))
      (should-not (ebox-focus-direction 'right buffer))
      (should (eq (ebox-focus-direction 'left buffer) (node "left")))
      (should (eq (ebox-focus-direction 'down buffer) (node "g1")))
      (should (eq (ebox-focus-direction 'right buffer) (node "g2")))
      (should (eq (ebox-focus-direction 'down buffer) (node "g4")))
      (should (eq (ebox-focus-direction 'left buffer) (node "g3")))
      (should (eq (ebox-focus-direction 'up buffer) (node "g1")))
      (should (eq (ebox-focus-direction 'up buffer) (node "left"))))))

(ert-deftest ebox-focus-direction-honours-a-root-boundary ()
  "ROOT limits candidates and reports the boundary with nil."
  (ebox-test-with-mounted (buffer root
                           '(row
                             (column :id "left" :width (ch 8) :focus-group vertical
                                     (box :id "a" :tab-index 0 "A")
                                     (box :id "b" :tab-index 0 "B"))
                             (box :id "right" :tab-index 0 :width (ch 6) "R"))
                           :width 300 :height 10)
    (cl-flet ((node (id) (ebox-test--node root id)))
      (ebox-focus (node "a") buffer)
      (should (eq (ebox-focus-direction 'down buffer (node "left")) (node "b")))
      (should-not (ebox-focus-direction 'down buffer (node "left")))
      (should (eq (ebox-focus-direction 'right buffer (node "left")) nil))
      (should (eq (ebox-focused-node buffer) (node "b")))
      (should (eq (ebox-focus-direction 'right buffer) (node "right"))))))

(ert-deftest ebox-focus-reaches-a-stop-scrolled-beneath-a-fixed-region ()
  "A tab stop scrolled out of a scroller is focusable even when its layout
line lies under an unrelated overlay; focus reveals it."
  (ebox-test-with-mounted
      (buffer root
              `(column :position relative
                       (column :id "list" :height (lh 3) :overflow scroll
                               ,@(mapcar (lambda (i)
                                           `(box :id ,(format "i%d" i) :tab-index 0
                                                 ,(format "Item %d" i)))
                                         (number-sequence 0 9)))
                       (box :id "bar" :position absolute :left (ch 0) :top (lh 7)
                            :width (ch 20) :height (lh 3) ""))
              :width 200 :height 10)
    (let ((last (ebox-test--node root "i9"))
          (list (ebox-test--node root "list")))
      (ebox-focus last buffer)
      (should (> (ebox-node-scroll-offset list) 0))
      (should (ebox-node-ancestor-p last (ebox-node-at (point) buffer))))))

(ert-deftest ebox-modal-focus-scope-confines-navigation ()
  (ebox-test-with-mounted (buffer root
                           '(column
                             (box :id "outside" :tab-index 0 "Outside")
                             (column :id "dialog" :focus-scope modal
                                     (box :id "x" :tab-index 0 "X")
                                     (box :id "y" :tab-index 0 "Y")))
                           :width 200 :height 10)
    (cl-flet ((node (id) (ebox-test--node root id)))
      (should (eq (ebox-focus-scope buffer) (node "dialog")))
      (should (equal (ebox-focus-stops buffer) (list (node "x") (node "y"))))
      (should (eq (ebox-focus-first buffer) (node "x")))
      (should (eq (ebox-focus-next 1 t buffer) (node "y")))
      (should (eq (ebox-focus-next 1 t buffer) (node "x")))
      (should-not (ebox-focus-direction 'up buffer))
      (ebox-node-remove (node "dialog"))
      (ebox-flush)
      (should (eq (ebox-focus-scope buffer) root))
      (should (eq (ebox-focus-first buffer) (node "outside"))))))

(ert-deftest ebox-focus-reveals-node-inside-scroller ()
  (ebox-test-with-mounted (buffer root
                           `(column :id "list" :height (lh 3) :overflow scroll
                                    ,@(mapcar (lambda (i)
                                                `(box :id ,(format "i%d" i) :tab-index 0
                                                      ,(format "Item %d" i)))
                                              (number-sequence 0 9)))
                           :width 200 :height 6)
    (let ((list (ebox-test--node root "list"))
          (last (ebox-test--node root "i9")))
      (ebox-focus last buffer)
      (should (> (ebox-node-scroll-offset list) 0))
      (should (ebox-node-ancestor-p last (ebox-node-at (point) buffer)))
      (should (equal (string-trim (buffer-substring-no-properties
                                   (line-beginning-position) (line-end-position)))
                     "Item 9")))))

(ert-deftest ebox-focus-navigation-resumes-near-a-removed-node ()
  (ebox-test-with-mounted (buffer root
                           '(column
                             (box :id "a" :tab-index 0 "A")
                             (box :id "b" :tab-index 0 "B")
                             (box :id "c" :tab-index 0 "C"))
                           :width 200 :height 6)
    (cl-flet ((node (id) (ebox-test--node root id)))
      (ebox-focus (node "b") buffer)
      (ebox-node-remove (node "b"))
      (ebox-flush)
      (should-not (ebox-focused-node buffer))
      (should (eq (ebox-focus-next 1 nil buffer) (node "c")))
      (ebox-focus (node "c") buffer)
      (ebox-node-remove (node "c"))
      (ebox-flush)
      (should (eq (ebox-focus-direction 'up buffer) (node "a"))))))

(ert-deftest ebox-focus-shows-hover-content ()
  (ebox-test-with-mounted (buffer root
                           '(column
                             (box :id "row" :tab-index 0 :hover-content "Play" "Song")
                             (box :id "other" :tab-index 0 "Other"))
                           :width 200 :height 6)
    (cl-flet ((node (id) (ebox-test--node root id)))
      (ebox-focus (node "row") buffer)
      (ebox-flush)
      (should (string-match-p "Play" (buffer-substring-no-properties
                                      (point-min) (point-max))))
      (ebox-focus (node "other") buffer)
      (ebox-flush)
      (should (string-match-p "Song" (buffer-substring-no-properties
                                      (point-min) (point-max)))))))

(ert-deftest ebox-buffer-mode-arrows-move-focus-and-scroll-at-the-end ()
  (ebox-test-with-mounted (buffer root
                           '(column (box :id "a" :tab-index 0 "A")
                                    (box :id "b" :tab-index 0 "B"))
                           :width 200 :height 6)
    (cl-flet ((node (id) (ebox-test--node root id)))
      (ebox-focus (node "a") buffer)
      (call-interactively (key-binding (kbd "<down>")))
      (should (eq (ebox-focused-node buffer) (node "b")))
      (call-interactively (key-binding (kbd "C-p")))
      (should (eq (ebox-focused-node buffer) (node "a")))
      (call-interactively (key-binding (kbd "<end>")))
      (should (eq (ebox-focused-node buffer) (node "b"))))))

(ert-deftest ebox-focus-derived-state-matches-selector-and-styles ()
  (ebox-test-with-mounted (buffer root
                           '(column :ecss (("#a:focus" :color "#ff0000"))
                                    (box :id "a" :tab-index 0 "A")
                                    (box :id "b" :tab-index 0 "B")))
    (let ((a (car (ebox-selector-query root "#a"))))
      (ebox-focus a buffer)
      (should (equal (ebox-selector-query-buffer buffer "#a:focus") (list a)))
      (should (equal (get-text-property (point-min) 'face)
                     '(:foreground "#ff0000"))))))

(ert-deftest ebox-overlays-cover-hits-positions-and-focus-in-paint-order ()
  (ebox-test-with-mounted (buffer root
                           '(column :width (ch 20) :height (lh 4)
                                    (box :id "under" :tab-index 0 "Under")
                                    (box :id "cover" :position absolute
                                         :left (ch 0) :top (lh 0)
                                         :width (ch 20) :height (lh 4) "")
                                    (box :id "panel" :position absolute
                                         :left (ch 0) :top (lh 0)
                                         :width (ch 10) :height (lh 1)
                                         :tab-index 0 "Panel")))
    (let ((under (car (ebox-selector-query root "#under")))
          (panel (car (ebox-selector-query root "#panel"))))
      ;; The later overlay paints on top of an equal-z sibling and wins hits.
      (should (ebox-node-ancestor-p panel (ebox-node-at (point-min) buffer)))
      (should (eq (ebox-node-at (+ (point-min) 12) buffer)
                  (car (ebox-selector-query root "#cover"))))
      (should (ebox-node-position panel))
      (should-not (ebox-node-position under))
      (should-error (ebox-focus under buffer) :type 'user-error)
      (should (eq (ebox-focus-first buffer) panel)))))

(ert-deftest ebox-buffer-mode-keeps-paren-matching-off-painted-text ()
  (require 'paren)
  (let ((global show-paren-mode))
    (unwind-protect
        (progn
          (show-paren-mode 1)
          (ebox-test-with-mounted (buffer _root '(column (text "a (b")))
            (with-current-buffer buffer
              (should ebox-buffer-mode)
              (should-not show-paren-mode)
              (ebox-buffer-mode -1)
              (should show-paren-mode)
              (should-not (local-variable-p 'show-paren-mode)))))
      (show-paren-mode (if global 1 -1)))))

(ert-deftest ebox-buffer-mode-shows-no-region-on-the-canvas ()
  (let ((buffer (get-buffer-create " *ebox-no-region*"))
        (config (current-window-configuration))
        (transient-mark-mode t))
    (unwind-protect
        (progn
          (set-window-buffer (selected-window) buffer)
          (set-buffer buffer)
          (ebox-mount buffer '(column (text "one") (text "two")))
          (execute-kbd-macro (kbd "C-SPC C-n"))
          (should-not (region-active-p))
          (ebox-buffer-mode -1)
          (execute-kbd-macro (kbd "C-SPC"))
          (should (region-active-p)))
      (set-window-configuration config)
      (kill-buffer buffer))))

(ert-deftest ebox-allow-text-selection-enables-native-region-on-canvas ()
  (let ((buffer (get-buffer-create " *ebox-allow-region*"))
        (config (current-window-configuration))
        (transient-mark-mode t))
    (unwind-protect
        (progn
          (set-window-buffer (selected-window) buffer)
          (set-buffer buffer)
          (ebox-mount buffer '(column (text "alpha beta") (text "gamma")))
          ;; Default keeps region inactive and overrides down-mouse-1.
          (should (eq (key-binding [down-mouse-1]) #'mouse-set-point))
          (execute-kbd-macro (kbd "C-SPC"))
          (should-not (region-active-p))
          ;; Opting in preserves native mark and releases down-mouse-1.
          (setq-local ebox-allow-text-selection t)
          (should-not (eq (key-binding [down-mouse-1]) #'mouse-set-point))
          (goto-char (point-min))
          (execute-kbd-macro (kbd "C-SPC"))
          (forward-char 5)
          (should (region-active-p))
          (should (equal (buffer-substring-no-properties (region-beginning) (region-end))
                         "alpha")))
      (set-window-configuration config)
      (kill-buffer buffer))))

(ert-deftest ebox-node-at-resolves-padding-cells-to-their-box ()
  (ebox-test-with-mounted (buffer root
                           '(column :width (ch 20)
                                    (box :id "first" "One")
                                    (box :id "second" :padding-top (lh 1)
                                         :padding-left (ch 2) "Two")))
    (let ((second (car (ebox-selector-query root "#second"))))
      ;; The padding line and the indent carry no node property; the hit
      ;; still resolves to the box that owns those cells.
      (should (eq (ebox-node-at (ebox-node-position second) buffer) second))
      (save-excursion
        (goto-char (point-min))
        (forward-line 2)
        (should (eq (ebox-node-at (point) buffer) second))))))

(ert-deftest ebox-node-at-resolves-scrolled-padding-cells-to-their-box ()
  (ebox-test-with-mounted (buffer root
                           '(column :width (ch 20) :height (lh 6)
                                    :overflow scroll
                                    (box :id "first" "One")
                                    (box :id "second" :padding-top (lh 1)
                                         :padding-left (ch 2) "Two")))
    (let ((second (car (ebox-selector-query root "#second"))))
      ;; The scroller's own cells cover its children's blank padding; the
      ;; innermost box covering the cell still owns it.
      (should (eq (ebox-node-at (ebox-node-position second) buffer) second))
      (save-excursion
        (goto-char (point-min))
        (forward-line 2)
        (should (eq (ebox-node-at (point) buffer) second))))))

(ert-deftest ebox-node-bounds-spans-first-or-every-painted-row ()
  (ebox-test-with-mounted (buffer root '(column (box :id "tall" :width (ch 4) :height (lh 2)
                                                     "ab")
                                                (box :width (ch 3) (text :id "wrap" "abc def"))))
    (let ((tall (car (ebox-selector-query root "#tall")))
          (wrap (car (ebox-selector-query root "#wrap"))))
      (pcase-let ((`(,start . ,end) (ebox-node-bounds tall)))
        (should (equal (string-trim-right (buffer-substring-no-properties start end)) "ab")))
      (pcase-let ((`(,start . ,end) (ebox-node-bounds tall t)))
        (should (equal (mapcar #'string-trim-right
                               (split-string (buffer-substring-no-properties start end) "\n"))
                       '("ab" ""))))
      (pcase-let ((`(,start . ,end) (ebox-node-bounds wrap)))
        (should (equal (buffer-substring-no-properties start end) "abc")))
      (pcase-let ((`(,start . ,end) (ebox-node-bounds wrap t)))
        (should (equal (mapcar #'string-trim-right
                               (split-string (buffer-substring-no-properties start end) "\n"))
                       '("abc" "def")))))))

(ert-deftest ebox-node-bounds-include-cells-under-own-overlays ()
  (ebox-test-with-mounted (buffer root '(column :width (ch 10)
                                                (box :id "track" :position relative
                                                     :width (ch 8) "--------"
                                                     (box :position absolute :left (ch 0)
                                                          :top (lh 0) :width (ch 3) "==="))))
    ;; An overlay inside the node paints the node itself; its bounds still
    ;; start at the node's first cell.
    (pcase-let ((`(,start . ,end) (ebox-node-bounds (car (ebox-selector-query root "#track")))))
      (should (= start (point-min)))
      (should (equal (buffer-substring-no-properties start end) "===-----")))))

(ert-deftest ebox-node-bounds-keep-hidden-flow-slots ()
  (ebox-test-with-mounted (buffer root '(box :position relative :width (ch 8) :height (lh 2)
                                             (row (box :id "slot" :visibility hidden
                                                       :width (ch 3) "abc")
                                                  (box "de"))
                                             (box :id "over" :position absolute :visibility hidden
                                                  :left (ch 0) :top (lh 1) :width (ch 2) "xy")))
    (let ((slot (car (ebox-selector-query root "#slot")))
          (over (car (ebox-selector-query root "#over"))))
      (pcase-let ((`(,start . ,end) (ebox-node-bounds slot)))
        (should (= start (point-min)))
        (should-not (string-match-p "[a-z]" (buffer-substring-no-properties start end))))
      (should-not (ebox-node-bounds over)))))

(ert-deftest ebox-descendants-inherit-or-block-native-feedback ()
  (ebox-test-with-mounted (buffer root '(box :help-echo "Outer" :pointer hand
                                             :hover-style (:background-color "#123456")
                                             (box :id "plain" "Plain")
                                             (box :id "own" :help-echo nil :pointer nil
                                                  :hover-style nil "Own")))
    (let ((plain (ebox-node-position (car (ebox-selector-query root "#plain"))))
          (own (ebox-node-position (car (ebox-selector-query root "#own")))))
      (should (equal (funcall (get-text-property plain 'help-echo)
                              (selected-window) (current-buffer) plain)
                     "Outer"))
      (should (eq (get-text-property plain 'pointer) 'hand))
      (should (get-text-property plain 'mouse-face))
      (should-not (get-text-property own 'help-echo))
      (should-not (get-text-property own 'pointer))
      (should-not (get-text-property own 'mouse-face)))))

(ert-deftest ebox-hover-tracks-the-pointer-only-inside-its-buffer ()
  "Mounting alone never enables frame-wide mouse tracking.
The painted help-echo probe paints entry and starts the pointer guard; motion
resolved in another buffer releases the paint without enabling `track-mouse'."
  (ebox-test-with-mounted (buffer root '(box :id "hover"
                                             :hover-style (:background-color "#123456")
                                             "Hover"))
    (save-window-excursion
      (switch-to-buffer buffer)
      (should-not (local-variable-p 'track-mouse))
      (let* ((position (ebox-node-position (car (ebox-selector-query root "#hover"))))
             (help (get-text-property position 'help-echo)))
        (should (functionp help))
        ;; The painted probe paints the target and starts the pointer guard
        ;; without making Emacs report motion for the whole frame.
        (funcall help (selected-window) (current-buffer) position)
        (should-not (local-variable-p 'track-mouse))
        (should (equal (get-char-property position 'face) '(:background "#123456")))
        ;; A motion event resolved in another buffer releases both the paint
        ;; and the guard.
        (let ((other (generate-new-buffer " *ebox-other*")))
          (unwind-protect
              (let ((window (split-window (selected-window))))
                (unwind-protect
                    (progn
                      (set-window-buffer window other)
                      (let ((command (key-binding [mouse-movement])))
                        (should (commandp command))
                        (funcall command
                                 (list 'mouse-movement
                                       (list window (point-min) '(0 . 0) 0)))))
                  (delete-window window)))
            (kill-buffer other)))
        (should-not (local-variable-p 'track-mouse))
        (should-not (equal (get-char-property position 'face)
                           '(:background "#123456")))))))

(ert-deftest ebox-pointer-guard-reads-the-pointer-inside-its-frame ()
  "The pointer guard hit-tests the pointer inside the window's own frame.
A child frame can be placed relative to its parent while its reported absolute
edges omit that origin, so a display-absolute pointer would follow the rows
below the pointer instead of the row under it."
  (ebox-test-with-mounted (buffer root '(column (box :id "target"
                                                    :hover-style (:background-color "#123456")
                                                    "target")
                                               (text "after")))
    (save-window-excursion
      (switch-to-buffer buffer)
      (let* ((window (selected-window))
             (position (ebox-node-position (car (ebox-selector-query root "#target"))))
             (hit nil))
        ;; The painted probe paints the target and starts the pointer guard.
        (funcall (get-text-property position 'help-echo) window buffer position)
        (should (equal (get-char-property position 'face) '(:background "#123456")))
        (cl-letf (((symbol-function 'mouse-position)
                   (lambda () (cons (window-frame window) (cons 0 0))))
                  ((symbol-function 'window-at)
                   (lambda (&rest _arguments) window))
                  ;; The pointer rests 140 by 260 inside its frame.
                  ((symbol-function 'mouse-pixel-position)
                   (lambda () (cons (window-frame window) (cons 140 260))))
                  ;; The window starts 20 pixels below the frame's origin.
                  ((symbol-function 'window-pixel-edges)
                   (lambda (&optional _window) '(0 20 800 600)))
                  ((symbol-function 'window-absolute-pixel-edges)
                   (lambda (&optional _window) '(300 300 1100 900)))
                  ((symbol-function 'mouse-absolute-pixel-position)
                   (lambda () (cons 440 560)))
                  ((symbol-function 'posn-at-x-y)
                   (lambda (x y &optional _window _whole)
                     (setq hit (cons x y))
                     nil)))
          (sit-for 0.25))
        (should (equal hit '(140 . 240)))))))

(ert-deftest ebox-hover-content-follows-pointer-entry-and-leave ()
  "The help probe shows hover content on entry; leaving restores the text."
  (ebox-test-with-mounted (buffer root '(box :id "row" :hover-content "Play" "Song"))
    (save-window-excursion
      (switch-to-buffer buffer)
      (let* ((position (ebox-node-position (car (ebox-selector-query root "#row"))))
             (help (get-text-property position 'help-echo)))
        (should (functionp help))
        (funcall help (selected-window) (current-buffer) position)
        (should (string-match-p "Play" (buffer-substring-no-properties
                                         (point-min) (point-max))))
        (funcall (key-binding [mouse-movement])
                 (list 'mouse-movement
                       (list (selected-window) (point-max) '(0 . 0) 0)))
        (let ((text (buffer-substring-no-properties (point-min) (point-max))))
          (should (string-match-p "Song" text))
          (should-not (string-match-p "Play" text)))))))

(ert-deftest ebox-hover-probe-keeps-an-ancestors-help ()
  "A hover probe records no help of its own, so an ancestor's help still fills.
An explicit nil or an inner help keeps blocking it."
  (ebox-test-with-mounted
      (buffer root '(box :help-echo "Outer"
                         (box :id "probe"
                              :hover-style (:background-color "#123456") "Probe")
                         (box :id "own" :help-echo nil
                              :hover-style (:background-color "#123456") "Own")))
    (cl-flet ((help (id)
                (let ((position (ebox-node-position
                                 (car (ebox-selector-query root id)))))
                  (funcall (get-text-property position 'help-echo)
                           (selected-window) (current-buffer) position))))
      (should (equal (help "#probe") "Outer"))
      (should-not (help "#own")))))

(ert-deftest ebox-hover-face-restates-the-nodes-own-paint ()
  "A background-only hover style keeps the label readable.
Emacs displays `mouse-face' instead of the text's `face', so a face built from
the hover style alone drops the node's own ink and the label falls back to the
frame's default colour.  The hover face starts from the computed face instead,
so the resting paint stays intact."
  (let* ((rendered (ebox-render '(box :color "#E9ECF1" :background-color "#0E1013"
                                       :hover-style (:background-color "#1B1F26")
                                       "Ink")))
         (hover (get-text-property 0 'mouse-face rendered)))
    (should (equal (plist-get hover :foreground) "#E9ECF1"))
    (should (equal (plist-get hover :background) "#1B1F26"))
    ;; A hover style that names its own ink still wins.
    (let* ((own (ebox-render '(box :color "#E9ECF1"
                                   :hover-style (:color "#FF0000")
                                   "Ink")))
           (face (get-text-property 0 'mouse-face own)))
      (should (equal (plist-get face :foreground) "#FF0000")))))

(ert-deftest ebox-hover-paints-over-a-nodes-own-background ()
  ;; Hover paint is unconditional: whether a selected element keeps its own
  ;; surface is application policy (declare :hover-style nil for it), because
  ;; only the application knows which state counts as selected.
  (let ((rendered (ebox-render '(box :background-color "#ffffff"
                                     :hover-style (:background-color "#123456")
                                     "Filled"))))
    (should (equal (get-text-property 0 'mouse-face rendered)
                   '(:background "#123456")))))

(ert-deftest ebox-hover-spans-every-row-of-a-multiline-node ()
  (ebox-test-with-mounted (buffer root '(column :width 'stretch
                                               (box :id "tall" :width 'stretch
                                                    :hover-style (:background-color "#123456")
                                                    (column "aa" "aa" "aa"))
                                               (box :id "after" :height (lh 1) "zz")))
    (let* ((start (ebox-node-position (car (ebox-selector-query root "#tall"))))
           (hover (get-text-property start 'mouse-face)))
      (should hover)
      ;; Every painted cell of the element shares the hover face, so the
      ;; native mouse-face run covers the element's whole area instead of only
      ;; the row under the pointer.  The newlines between its rows carry the
      ;; same face.
      (save-excursion
        (goto-char start)
        (forward-line 1)
        (should (eq hover (get-text-property (1- (point)) 'mouse-face)))
        (forward-line 1)
        (should (eq hover (get-text-property (1- (point)) 'mouse-face)))
        ;; A row that does not continue the element does not carry the run.
        (forward-line 1)
        (should-not (get-text-property (1- (point)) 'mouse-face))))))

(ert-deftest ebox-hover-highlights-disjoint-rows-without-painting-neighbours ()
  "A pointer over one card paints all its rows, not adjacent cards or gaps."
  (ebox-test-with-mounted
      (buffer root '(row :item-gap (ch 2)
                         (box :id "card" :width (ch 7)
                              :hover-style (:background-color "#123456")
                              (column "A" "B" "C"))
                         (box :id "neighbour" :width (ch 7)
                              (column "X" "Y" "Z"))))
    (save-window-excursion
      (switch-to-buffer buffer)
      (let* ((card (car (ebox-selector-query root "#card")))
             (start (ebox-node-position card))
             (command (key-binding [mouse-movement]))
             (before (buffer-substring-no-properties (point-min) (point-max))))
        (should (commandp command))
        (funcall command (list 'mouse-movement (list (selected-window) start '(0 . 0) 0)))
        (save-excursion
          (dolist (label '("A" "B" "C"))
            (goto-char (point-min))
            (search-forward label)
            (should (equal (get-char-property (1- (point)) 'face) '(:background "#123456"))))
          (goto-char (point-min))
          (search-forward "Y")
          (should-not (equal (get-char-property (1- (point)) 'face) '(:background "#123456"))))
        (should (equal before (buffer-substring-no-properties (point-min) (point-max))))
        ;; A publication preserves the pointer region without leaving stale paint.
        (ebox-node-set-props card '(:hover-style (:background-color "#654321")))
        (let ((paint (get-char-property (ebox-node-position card) 'face)))
          (should (equal paint '(:background "#654321"))))
        (funcall command (list 'mouse-movement (list (selected-window) (point-max) '(0 . 0) 0)))
        (let ((paint (get-char-property (ebox-node-position card) 'face)))
          (should-not (equal paint '(:background "#654321"))))))))

(ert-deftest ebox-hover-paints-the-padded-box-through-the-node-style ()
  "Hover paint follows the node's own box, every painted row keeping the fill."
  (ebox-test-with-mounted
      (buffer root '(column :width (ch 12)
                            (box :id "pill" :width (ch 10) :border-radius (px 4)
                                 :background-color "#101010"
                                 :padding ((lh 0.5) (ch 2))
                                 :hover-style (:background-color "#EEEEEE")
                                 "Hi")))
    (save-window-excursion
      (switch-to-buffer buffer)
      (let* ((pill (car (ebox-selector-query root "#pill")))
             (command (key-binding [mouse-movement]))
             (start (ebox-node-position pill)))
        (funcall command (list 'mouse-movement (list (selected-window) start '(0 . 0) 0)))
        (pcase-let ((`(,from . ,to) (ebox-node-bounds pill t)))
          (should from)
          (save-excursion
            (goto-char from)
            (while (< (point) to)
              (when (get-text-property (point) 'ebox-node)
                (should (equal (get-char-property (point) 'face)
                               '(:background "#EEEEEE"))))
              (forward-char))))
        ;; Leaving restores the resting paint on every row, padding included.
        (funcall command (list 'mouse-movement (list (selected-window) (point-max) '(0 . 0) 0)))
        (pcase-let ((`(,from . ,to) (ebox-node-bounds pill t)))
          (save-excursion
            (goto-char from)
            (while (< (point) to)
              (when (get-text-property (point) 'ebox-node)
                (should (equal (get-char-property (point) 'face)
                               '(:background "#101010"))))
              (forward-char))))))))

(ert-deftest ebox-hover-rests-at-an-explicit-nil-blocker ()
  "Hover over a nil blocker leaves the element's resting paint everywhere."
  (ebox-test-with-mounted
      (buffer root '(column :width (ch 12)
                            (box :id "outer" :width (ch 10)
                                 :hover-style (:background-color "#123456")
                                 (box :id "plain" "A")
                                 (box :id "own" :hover-style nil "B"))))
    (save-window-excursion
      (switch-to-buffer buffer)
      (let* ((own (car (ebox-selector-query root "#own")))
             (plain (car (ebox-selector-query root "#plain")))
             (command (key-binding [mouse-movement]))
             (own-start (ebox-node-position own))
             (plain-start (ebox-node-position plain)))
        (funcall command (list 'mouse-movement (list (selected-window) own-start '(0 . 0) 0)))
        (should-not (equal (get-char-property plain-start 'face)
                           '(:background "#123456")))
        (should-not (equal (get-char-property own-start 'face)
                           '(:background "#123456")))
        ;; Moving onto the plain sibling paints the ancestor's hover fill and
        ;; returning to the blocker clears it again.
        (funcall command (list 'mouse-movement
                               (list (selected-window) plain-start '(0 . 0) 0)))
        (should (equal (get-char-property plain-start 'face)
                       '(:background "#123456")))
        (funcall command (list 'mouse-movement (list (selected-window) own-start '(0 . 0) 0)))
        (should-not (equal (get-char-property plain-start 'face)
                           '(:background "#123456")))))))

(ert-deftest ebox-hover-keeps-a-single-row-element-within-its-cells ()
  (ebox-test-with-mounted (buffer root '(column :width 'stretch
                                               (box :id "one" :width 'stretch
                                                    :hover-style (:background-color "#123456") "AB")
                                               (box :height (lh 1) "zz")))
    (let ((start (ebox-node-position (car (ebox-selector-query root "#one")))))
      (should (get-text-property start 'mouse-face))
      ;; The newline after the element's only row carries no face, so hover
      ;; feedback cannot bleed into the rest of the screen row.
      (save-excursion
        (goto-char start)
        (forward-line 1)
        (should-not (get-text-property (1- (point)) 'mouse-face))))))

(ert-deftest ebox-render-carries-hover-across-rendered-rows ()
  (let* ((rendered (ebox-render '(box :width (ch 6)
                                       :hover-style (:background-color "#123456")
                                       (column "aa" "aa" "aa"))))
         (first (string-search "\n" rendered))
         (second (and first (string-search "\n" rendered (1+ first))))
         (hover (get-text-property 0 'mouse-face rendered)))
    (should hover)
    (should first)
    (should second)
    (should (eq hover (get-text-property first 'mouse-face rendered)))
    (should (eq hover (get-text-property second 'mouse-face rendered)))
    (should (eq hover (get-text-property (1- (length rendered)) 'mouse-face rendered)))))

(ert-deftest ebox-hidden-node-paints-no-interaction-feedback ()
  ;; A hidden node keeps its layout slot to preserve the surrounding layout,
  ;; but paints nothing; that includes interaction feedback, so an empty list
  ;; slot offers no hover highlight, pointer or help.
  (ebox-test-with-mounted (buffer _root '(column :width (ch 8)
                                               (box :height (lh 1)
                                                    :hover-style (:background-color "#123456")
                                                    :help-echo "shown" :pointer hand
                                                    "SHOW")
                                               (box :height (lh 1) :visibility hidden
                                                    :hover-style (:background-color "#123456")
                                                    :help-echo "hidden" :pointer hand
                                                    "HIDE")))
    (should (get-text-property (point-min) 'mouse-face))
    (save-excursion
      (goto-char (point-min))
      (forward-line 1)
      (let ((start (point)) (end (line-end-position)))
        (should (> end start))
        (should (string-blank-p (buffer-substring-no-properties start end)))
        (while (< (point) end)
          (should-not (get-text-property (point) 'mouse-face))
          (should-not (get-text-property (point) 'help-echo))
          (should-not (get-text-property (point) 'pointer))
          (forward-char))))))

(ert-deftest ebox-unanchored-overlay-has-no-position-or-focus ()
  (ebox-test-with-mounted (buffer root '(column :width (ch 20) :height (lh 4)
                                         (box :id "base" :tab-index 0 "Base")
                                         (box :id "pop" :position absolute :anchor "absent"
                                              :width (ch 10) :height (lh 1)
                                              (box :id "inner" :tab-index 0 "Inner"))))
    (let ((inner (car (ebox-selector-query root "#inner"))))
      (should-not (string-match-p "Inner" (buffer-string)))
      (should-not (ebox-node-position (car (ebox-selector-query root "#pop"))))
      (should-not (ebox-node-position inner))
      (should-error (ebox-focus inner buffer) :type 'user-error)
      (should (eq (ebox-focus-first buffer) (car (ebox-selector-query root "#base")))))))

(ert-deftest ebox-activate-noerror-returns-nil-without-command ()
  (ebox-test-with-mounted (buffer _root '(box "Plain"))
    (goto-char (point-min))
    (should-not (ebox-activate nil t))))

(ert-deftest ebox-next-and-previous-interaction-move-between-keymap-owners ()
  (let ((map (ebox-keymap-create :bindings `(("x" . ,(lambda () :ok))))))
    (ebox-test-with-mounted (buffer root
                             (list 'column
                                   (list 'box :id "a" :keymap map "A")
                                   '(box "plain")
                                   (list 'box :id "b" :keymap map "B")))
      (goto-char (point-min))
      (should (= (ebox-next-interaction) (ebox-node-position
                                          (car (ebox-selector-query root "#b")))))
      (should (= (ebox-previous-interaction) (ebox-node-position
                                              (car (ebox-selector-query root "#a"))))))))

(ert-deftest ebox-hover-preserves-ancestor-and-own-borders ()
  "Hover `mouse-face' keeps ancestor and self top, bottom and side border paint."
  ;; 1. Interactive child touching a bordered container's top and bottom edges.
  (let* ((rendered (ebox-render
                    '(column :width (ch 20) :border ((px 1) solid "#d1d9e0")
                             (box :width 'stretch :background-color "#f6f8fa"
                                  :hover-style (:background-color "#e6ebf1")
                                  "Header"))))
         (pos (string-match "Header" rendered))
         (mf (and pos (get-text-property pos 'mouse-face rendered))))
    (should pos)
    (should mf)
    (should (equal (plist-get mf :background) "#e6ebf1"))
    (should (equal (plist-get mf :overline) "#d1d9e0"))
    (should (equal (plist-get (plist-get mf :underline) :color) "#d1d9e0")))
  ;; 2. Interactive node carrying its own 4-sided border keeps top, bottom and
  ;; vertical side rules on hover.
  (let* ((rendered (ebox-render
                    '(box :width (ch 20)
                          :border ((px 1) solid "#aabbcc")
                          :background-color "#ffffff"
                          :hover-style (:background-color "#eef2f6")
                          "Button")))
         (pos (string-match "Button" rendered))
         (mf (and pos (get-text-property pos 'mouse-face rendered)))
         (left-face (get-text-property 0 'face rendered))
         (left-mf (get-text-property 0 'mouse-face rendered)))
    (should pos)
    (should (equal (plist-get mf :background) "#eef2f6"))
    (should (equal (plist-get mf :overline) "#aabbcc"))
    (should (equal (plist-get (plist-get mf :underline) :color) "#aabbcc"))
    (should (equal left-mf left-face))))

;;; ebox-interaction-tests.el ends here
