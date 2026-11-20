;;; etaf-ui-editor-tests.el --- Native editing behavior acceptance -*- lexical-binding: t; -*-

(require 'ert)
(require 'etaf-ui)

(ert-deftest etaf-ui-editor-preserves-native-editing-state ()
  "Enabling, configuring and disabling preserve text, undo and selection."
  (with-temp-buffer
    (text-mode)
    (buffer-enable-undo)
    (insert "first\n中文 é 🙂")
    (undo-boundary)
    (goto-char 3)
    (set-mark 2)
    (setq mark-active t)
    (let ((modified (buffer-modified-p)) (tick (buffer-chars-modified-tick))
          (map (current-local-map)) (completion completion-at-point-functions))
      (etaf-ui-editor-mode 1)
      (etaf-ui-editor-configure :placeholder "write")
      (should (= (point) 3))
      (should (= (mark) 2))
      (should mark-active)
      (should (eq (current-local-map) map))
      (should (equal completion-at-point-functions completion))
      (should (= (buffer-chars-modified-tick) tick))
      (should (eq (buffer-modified-p) modified))
      (should (equal (etaf-ui-editor-value) "first\n中文 é 🙂"))
      (etaf-ui-editor-mode -1)
      (should (equal (buffer-substring-no-properties (point-min) (point-max)) "first\n中文 é 🙂"))
      (let ((last-command nil)) (undo-only 1))
      (should (= (buffer-size) 0)))))

(ert-deftest etaf-ui-editor-placeholder-never-becomes-text ()
  "The visible empty hint is absent from copy, selection, text and undo."
  (with-temp-buffer
    (text-mode)
    (buffer-enable-undo)
    (let ((observed nil))
      (etaf-ui-editor-mode 1)
      (etaf-ui-editor-configure :placeholder "请直接输入" :placeholder-face 'shadow
                                :on-change (lambda (buffer) (push (etaf-ui-editor-value buffer) observed)))
      (should (equal (etaf-ui-editor-value) ""))
      (should-not (buffer-modified-p))
      (should-not observed)
      (insert "text")
      (should (equal observed '("text")))
      (erase-buffer)
      (should (equal (car observed) ""))
      (etaf-ui-editor-mode -1)
      (insert "unobserved")
      (should (equal (car observed) "")))))

(ert-deftest etaf-ui-editor-replacement-is-undoable-and-coalesced ()
  "Accepted external replacement is one undoable edit with a final-value event."
  (with-temp-buffer
    (text-mode)
    (buffer-enable-undo)
    (insert "before")
    (undo-boundary)
    (etaf-ui-editor-mode 1)
    (let ((observed nil))
      (etaf-ui-editor-configure :on-change (lambda (buffer) (push (etaf-ui-editor-value buffer) observed)))
      (should (etaf-ui-editor-replace (current-buffer) "after\n多行"))
      (should (equal observed '("after\n多行")))
      (let ((tick (buffer-chars-modified-tick)) (position (point)))
        (should (etaf-ui-editor-replace (current-buffer) "after\n多行"))
        (should (= tick (buffer-chars-modified-tick)))
        (should (= position (point)))
        (should (equal observed '("after\n多行"))))
      (let ((last-command nil)) (undo-only 1))
      (should (equal (etaf-ui-editor-value) "before"))
      (should (equal (car observed) "before")))))

(ert-deftest etaf-ui-editor-stale-update-preserves-edit-then-undo ()
  "An old tick is stale even when native undo restores identical text."
  (with-temp-buffer
    (text-mode)
    (buffer-enable-undo)
    (insert "keep")
    (undo-boundary)
    (etaf-ui-editor-mode 1)
    (let ((tick (buffer-chars-modified-tick)))
      (insert "new")
      (undo-boundary)
      (should-not (etaf-ui-editor-replace (current-buffer) "" tick))
      (let ((last-command nil)) (undo-only 1))
      (should (equal (etaf-ui-editor-value) "keep"))
      (should-not (etaf-ui-editor-replace (current-buffer) "" tick))
      (should (etaf-ui-editor-replace (current-buffer) "" (buffer-chars-modified-tick)))
      (should (equal (etaf-ui-editor-value) "")))))

(ert-deftest etaf-ui-editor-copy-narrowing-and-read-only ()
  "Values widen without moving selection and never export text properties."
  (with-temp-buffer
    (text-mode)
    (insert (propertize "first\nsecond" 'face 'bold))
    (etaf-ui-editor-mode 1)
    (narrow-to-region 1 6)
    (goto-char 2)
    (let ((text (etaf-ui-editor-value)))
      (should (equal text "first\nsecond"))
      (should-not (text-properties-at 0 text))
      (aset text 0 ?X)
      (should (equal (etaf-ui-editor-value) "first\nsecond"))
      (should (= (point) 2))
      (should (= (point-max) 6)))
    (setq buffer-read-only t)
    (should-error (insert "bad") :type 'buffer-read-only)
    (should (etaf-ui-editor-replace (current-buffer) "updated"))
    (should (equal (etaf-ui-editor-value) "updated"))
    (should buffer-read-only)))

(ert-deftest etaf-ui-editor-observer-failure-preserves-accepted-text ()
  "Observer failures propagate; no accepted edit is silently erased."
  (with-temp-buffer
    (text-mode)
    (etaf-ui-editor-mode 1)
    (etaf-ui-editor-configure :on-change (lambda (_buffer) (error "Observer failed")))
    (should-error (etaf-ui-editor-replace (current-buffer) "keep") :type 'error)
    (should (equal (etaf-ui-editor-value) "keep"))
    (etaf-ui-editor-configure :on-change (lambda (buffer) (etaf-ui-editor-replace buffer "recursive")))
    (should-error (etaf-ui-editor-replace (current-buffer) "accepted") :type 'user-error)
    (should (equal (etaf-ui-editor-value) "accepted"))))

(ert-deftest etaf-ui-editor-configuration-is-validated-before-change ()
  "Invalid settings leave the existing hint and observer unchanged."
  (with-temp-buffer
    (text-mode)
    (should-error (etaf-ui-editor-configure :placeholder "no mode") :type 'user-error)
    (etaf-ui-editor-mode 1)
    (let ((observed nil))
      (etaf-ui-editor-configure :placeholder "original"
                                :on-change (lambda (buffer) (setq observed (etaf-ui-editor-value buffer))))
      (should-error (etaf-ui-editor-configure :placeholder "wrong" :on-change 3) :type 'user-error)
      (insert "still observed")
      (should (equal observed "still observed")))
    (should-error (etaf-ui-editor-replace (current-buffer) 3) :type 'user-error)
    (should-error (etaf-ui-editor-replace (current-buffer) "a" 'bad-tick) :type 'user-error)
    (etaf-ui-editor-mode -1)
    (should-error (etaf-ui-editor-value) :type 'user-error)))

(ert-deftest etaf-ui-editor-instance-and-mode-lifecycle ()
  "Native editors isolate observations and release behavior on mode changes."
  (let ((one (generate-new-buffer " *editor one*")) (two (generate-new-buffer " *editor two*"))
        (observed nil))
    (unwind-protect
        (progn
          (with-current-buffer one
            (text-mode) (etaf-ui-editor-mode 1)
            (etaf-ui-editor-configure :placeholder "one" :on-change (lambda (b) (push (etaf-ui-editor-value b) observed))))
          (with-current-buffer two (text-mode) (etaf-ui-editor-mode 1) (insert "two"))
          (should-not observed)
          (etaf-ui-editor-replace one "one")
          (should (equal observed '("one")))
          (should (equal (etaf-ui-editor-value two) "two"))
          (with-current-buffer one
            (fundamental-mode)
            (insert "preserved")
            (should (equal observed '("one")))
            (should-error (etaf-ui-editor-value) :type 'user-error))
          (kill-buffer two)
          (should-error (etaf-ui-editor-value two) :type 'user-error))
      (when (buffer-live-p one) (kill-buffer one))
      (when (buffer-live-p two) (kill-buffer two)))))

(provide 'etaf-ui-editor-tests)
;;; etaf-ui-editor-tests.el ends here
