;;; etaf-ui-field-tests.el --- In-place text field acceptance -*- lexical-binding: t; -*-

;;; Commentary:
;; The catalog's text input edits its value natively inside the application
;; layout; these scenarios type through the command loop and observe values,
;; callbacks and the published buffer through public ETAF APIs.

;;; Code:
(require 'ert)
(require 'cl-lib)
(require 'etaf-ui)

(defmacro etaf-ui-field-test--with (spec &rest body)
  "Mount a form with one text input, bind SPEC (BUFFER RUNTIME VALUE . PROPS), run BODY.
The buffer is selected so keyboard macros reach it."
  (declare (indent 1))
  (pcase-let ((`(,buffer ,runtime ,value . ,props) spec))
    `(let* ((,buffer (generate-new-buffer " *field test*"))
            (,value (etaf-ref "初始")))
       (unwind-protect
           (progn
             (etaf-mount
              ,buffer
              (etaf-node 'column (list :width '(ch 40))
                         (list (etaf-node 'etaf-text-input
                                          (append (list :ref 'field :bind ,value :label "标题"
                                                        :placeholder "写点什么")
                                                  (list ,@props))
                                          nil)
                               (etaf-node 'etaf-button
                                          (list :ref 'sibling :label "Sibling" :on-press #'ignore) nil)))
              '(:viewport-width 600 :viewport-height 20))
             (switch-to-buffer ,buffer)
             (let ((,runtime (etaf-runtime-for-buffer ,buffer)))
               ,@body))
         (when-let* ((runtime (etaf-runtime-for-buffer ,buffer))) (etaf-unmount runtime))
         (kill-buffer ,buffer)))))

(defun etaf-ui-field-test--type (keys)
  "Type KEYS, a `kbd' string or a vector, through the command loop."
  (execute-kbd-macro (if (stringp keys) (kbd keys) keys)))

(defun etaf-ui-field-test--text (buffer)
  "Return BUFFER's text without properties."
  (with-current-buffer buffer (buffer-substring-no-properties (point-min) (point-max))))

(ert-deftest etaf-ui-text-input-edits-the-value-in-place ()
  "Typing edits the controlled value inside the field; submit keeps it."
  (let (submitted)
    (etaf-ui-field-test--with (buffer runtime value
                                      :on-submit (lambda (text) (setq submitted text)))
      (let ((lines (count-lines (point-min) (point-max))))
        (should-not (etaf-text-input-active-p runtime))
        (etaf-dispatch-event runtime 'field 'press)
        (should (etaf-text-input-active-p runtime))
        (etaf-ui-field-test--type [?\s ?文 ?本])
        (should (equal (etaf-value value) "初始 文本"))
        (should (string-match-p "初始 文本" (etaf-ui-field-test--text buffer)))
        (should (= lines (count-lines (point-min) (point-max))))
        (etaf-ui-field-test--type "RET")
        (should (equal submitted "初始 文本"))
        (should-not (etaf-text-input-active-p runtime))
        (should (equal (etaf-value value) "初始 文本"))
        (should (string-match-p "初始 文本" (etaf-ui-field-test--text buffer)))))))

(ert-deftest etaf-ui-text-input-escape-keeps-text-and-c-c-c-k-restores ()
  "Escape leaves the session keeping its text and Host focus; C-c C-k restores."
  (let (cancelled)
    (etaf-ui-field-test--with (buffer runtime value
                                      :on-cancel (lambda (text) (setq cancelled text)))
      (etaf-dispatch-event runtime 'field 'press)
      (etaf-ui-field-test--type [?不 ?要])
      (should (equal (etaf-value value) "初始不要"))
      (etaf-ui-field-test--type "<escape>")
      (should-not cancelled)
      (should-not (etaf-text-input-active-p runtime))
      (should (equal (etaf-value value) "初始不要"))
      (should (eq 'field (etaf-focused-host-ref runtime)))
      (etaf-dispatch-event runtime 'field 'press)
      (etaf-ui-field-test--type [?改])
      (etaf-ui-field-test--type "C-c C-k")
      (should (equal cancelled "初始不要改"))
      (should (equal (etaf-value value) "初始不要"))
      (should-not (etaf-text-input-active-p runtime)))))

(ert-deftest etaf-ui-text-input-arrow-boundary-keeps-draft-and-caret ()
  "Left at the value start leaves the field; re-editing resumes there."
  (etaf-ui-field-test--with (buffer runtime value)
    (etaf-dispatch-event runtime 'field 'press)
    (etaf-ui-field-test--type "AB")
    (should (equal (etaf-value value) "初始AB"))
    (etaf-ui-field-test--type "C-a")
    (etaf-ui-field-test--type "<left>")
    (should-not (etaf-text-input-active-p runtime))
    (should (equal (etaf-value value) "初始AB"))
    (should (eq 'field (etaf-focused-host-ref runtime)))
    (etaf-dispatch-event runtime 'field 'press)
    (etaf-ui-field-test--type "X")
    (should (equal (etaf-value value) "X初始AB"))))

(ert-deftest etaf-ui-text-input-multiline-grows-with-newlines ()
  "A multi-line field inserts unindented newlines and grows until submit."
  (let (submitted)
    (etaf-ui-field-test--with (buffer runtime value :rows 2
                                      :on-submit (lambda (text) (setq submitted text)))
      (let ((lines (count-lines (point-min) (point-max))))
        (setq-local electric-indent-mode t)
        (etaf-dispatch-event runtime 'field 'press)
        (etaf-ui-field-test--type "RET a S-<return> b C-j c")
        (should-not submitted)
        (should (equal (etaf-value value) "初始\na\nb\nc"))
        (should (= (count-lines (point-min) (point-max)) (+ lines 2)))
        (etaf-ui-field-test--type "C-c C-c")
        (should (equal submitted "初始\na\nb\nc"))))))

(ert-deftest etaf-ui-text-input-placeholder-is-never-the-value ()
  "An empty field shows its placeholder after the caret until text is typed."
  (etaf-ui-field-test--with (buffer runtime value)
    (setf (etaf-value value) "")
    (should (string-match-p "写点什么" (etaf-ui-field-test--text buffer)))
    (etaf-dispatch-event runtime 'field 'press)
    (should (equal (buffer-substring-no-properties (point) (+ (point) 4)) "写点什么"))
    (etaf-ui-field-test--type "x")
    (should (equal (etaf-value value) "x"))
    (should-not (string-match-p "写点什么" (etaf-ui-field-test--text buffer)))
    (etaf-ui-field-test--type "DEL")
    (should (equal (etaf-value value) ""))
    (should (string-match-p "写点什么" (etaf-ui-field-test--text buffer)))
    (should (equal (etaf-text-input-end) ""))))

(ert-deftest etaf-ui-text-input-runs-native-editing-keys-on-the-value ()
  "Line, word, kill, undo and deletion keys edit only the field's value."
  (etaf-ui-field-test--with (buffer runtime value)
    (etaf-dispatch-event runtime 'field 'press)
    (etaf-ui-field-test--type "SPC o n e SPC t w o")
    (etaf-ui-field-test--type "M-DEL C-a C-d C-e C-y")
    (should (equal (etaf-value value) "始 one two"))
    (etaf-ui-field-test--type "C-/")
    (should (equal (etaf-value value) "始 one "))
    (etaf-ui-field-test--type "C-a C-k")
    (should (equal (etaf-value value) ""))
    (should (string-match-p "标题" (etaf-ui-field-test--text buffer)))
    (should (string-match-p "Sibling" (etaf-ui-field-test--text buffer)))))

(ert-deftest etaf-ui-text-input-keys-reach-the-field-over-application-bindings ()
  "Printing keys bound by the application still type into the field."
  (etaf-ui-field-test--with (buffer runtime value)
    (let ((quit nil))
      (use-local-map (define-keymap "q" (lambda () (interactive) (setq quit t))))
      (etaf-dispatch-event runtime 'field 'press)
      (etaf-ui-field-test--type "q")
      (should-not quit)
      (should (equal (etaf-value value) "初始q")))))

(ert-deftest etaf-ui-text-input-publishes-other-changes-during-editing ()
  "Application changes elsewhere publish while the field edits."
  (let ((status (etaf-ref "idle")) (value (etaf-ref "v")))
    (let ((buffer (generate-new-buffer " *field publish*")))
      (unwind-protect
          (progn
            (etaf-mount buffer
                        (etaf-view (column (etaf-text-input :ref 'field :bind value)
                                           (text (expr (etaf-value status)))))
                        '(:viewport-width 600 :viewport-height 20))
            (switch-to-buffer buffer)
            (etaf-dispatch-event (etaf-runtime-for-buffer buffer) 'field 'press)
            (setf (etaf-value status) "busy")
            (should (string-match-p "busy" (etaf-ui-field-test--text buffer)))
            (etaf-ui-field-test--type "w")
            (should (equal (etaf-value value) "vw")))
        (when-let* ((runtime (etaf-runtime-for-buffer buffer))) (etaf-unmount runtime))
        (kill-buffer buffer)))))

(ert-deftest etaf-ui-text-input-disabled-and-read-only-are-not-editable ()
  "Disabled and read-only fields open no session."
  (etaf-ui-field-test--with (buffer runtime value :disabled t)
    (should-not (etaf-text-input-begin runtime 'field))
    (should-not (etaf-text-input-active-p runtime)))
  (etaf-ui-field-test--with (buffer runtime value :read-only t)
    (etaf-dispatch-event runtime 'field 'press)
    (should-not (etaf-text-input-begin runtime 'field))
    (should-not (etaf-text-input-active-p runtime))))

(ert-deftest etaf-ui-text-input-installs-completion-and-keymap ()
  "Completion functions complete the value; field bindings run in the app."
  (let* ((pressed nil)
         (capf (lambda ()
                 (save-excursion
                   (let ((end (point)))
                     (skip-chars-backward "a-z")
                     (list (point) end '("hello"))))))
         (map (define-keymap "C-c x" (lambda () (interactive)
                                       (setq pressed (current-buffer))))))
    (etaf-ui-field-test--with (buffer runtime value
                                      :completion-functions (list capf) :keymap map)
      (setf (etaf-value value) "")
      (etaf-dispatch-event runtime 'field 'press)
      (etaf-ui-field-test--type "h e C-M-i")
      (should (equal (etaf-value value) "hello"))
      (etaf-ui-field-test--type "C-c x")
      (should (eq pressed buffer))
      (should-not (memq capf completion-at-point-functions)))))

(ert-deftest etaf-ui-text-input-leaving-keeps-the-draft ()
  "Pressing another Host or unmounting leaves the field with its text."
  (etaf-ui-field-test--with (buffer runtime value)
    (etaf-dispatch-event runtime 'field 'press)
    (etaf-ui-field-test--type [?草 ?稿])
    (etaf-dispatch-event runtime 'field 'press)
    (should (etaf-text-input-active-p runtime))
    (etaf-dispatch-event runtime 'sibling 'press)
    (should-not (etaf-text-input-active-p runtime))
    (should-not (etaf-runtime-input-finisher runtime))
    (should (equal (etaf-value value) "初始草稿"))
    (should (string-match-p "初始草稿" (etaf-ui-field-test--text buffer)))
    (etaf-dispatch-event runtime 'field 'press)
    (etaf-ui-field-test--type "!")
    (etaf-unmount runtime)
    (should (equal (etaf-value value) "初始草稿!"))))

(ert-deftest etaf-ui-text-input-relayouts-while-editing ()
  "A viewport refit applies at once and editing continues."
  (etaf-ui-field-test--with (buffer runtime value)
    (etaf-dispatch-event runtime 'field 'press)
    (should (etaf-runtime-refit runtime 500 19))
    (should (equal (etaf-runtime-viewport runtime) '(500 . 19)))
    (etaf-ui-field-test--type "z")
    (should (equal (etaf-value value) "初始z"))))

(ert-deftest etaf-ui-text-input-focus-recolours-a-reserved-frame ()
  "Focus changes only the outlined frame's colour; the plain variant has none."
  (etaf-ui-field-test--with (buffer runtime value)
    (let* ((border (lambda () (plist-get (etaf-runtime-host-props-for runtime 'field)
                                         :border)))
           (idle (funcall border))
           (bounds (etaf-host-ref-bounds runtime 'field))
           (lines (count-lines (point-min) (point-max))))
      (should idle)
      (etaf-dispatch-event runtime 'field 'press)
      (should-not (equal (funcall border) idle))
      (should (= (car (etaf-host-ref-bounds runtime 'field)) (car bounds)))
      (should (= lines (count-lines (point-min) (point-max))))
      (etaf-text-input-end t)
      (should (equal (funcall border) idle))
      (should (equal (etaf-host-ref-bounds runtime 'field) bounds))))
  (etaf-ui-field-test--with (buffer runtime value :variant 'plain)
    (should-not (plist-get (etaf-runtime-host-props-for runtime 'field) :border)))
  (should-error (etaf-ui-field-test--with (buffer runtime value :variant 'boxed) nil)))

(ert-deftest etaf-ui-text-input-shows-a-caret-and-restores-state ()
  "Editing shows a bar caret and ending restores the buffer's cursor."
  (etaf-ui-field-test--with (buffer runtime value)
    (setq-local cursor-type nil)
    (etaf-dispatch-event runtime 'field 'press)
    (should (equal cursor-type '(bar . 2)))
    (etaf-text-input-end t)
    (should-not cursor-type)
    (should (local-variable-p 'cursor-type))))

(ert-deftest etaf-ui-text-input-validates-props-and-ends-once ()
  "Invalid props are reported in context; ending twice releases once."
  (let ((reserved (let ((map (make-sparse-keymap)))
                    (define-key map (kbd "TAB") #'ignore)
                    (define-key map (kbd "<left>") #'ignore)
                    map)))
    (dolist (props (list (list :rows 0) (list :rows "3") (list :label 7)
                         (list :placeholder 7)
                         (list :completion-functions '(not-a-function))
                         (list :keymap "map") (list :keymap reserved)))
      (with-temp-buffer
        (should-error (etaf-mount (current-buffer)
                                  (etaf-node 'etaf-text-input props nil))
                    :type 'etaf-component-call-error)))
    (with-temp-buffer
      (let ((error (should-error
                    (etaf-mount (current-buffer)
                                (etaf-node 'etaf-text-input (list :keymap reserved) nil))
                    :type 'etaf-component-call-error)))
        (should (string-match-p "TAB" (error-message-string error)))
        (should (string-match-p "<left>" (error-message-string error))))))
  (etaf-ui-field-test--with (buffer runtime value)
    (etaf-dispatch-event runtime 'field 'press)
    (etaf-ui-field-test--type [?一 ?次])
    (should (equal (etaf-text-input-end) "初始一次"))
    (should-not (etaf-text-input-end))
    (should-not (etaf-text-input-active-p runtime))
    (should-not (etaf-runtime-input-finisher runtime))))

(provide 'etaf-ui-field-tests)
(ert-deftest etaf-ui-search-field-edits-clears-and-keeps-editing ()
  "A search field edits its query live and its clear control empties it."
  (let ((query (etaf-ref "")) cleared
        (buffer (generate-new-buffer " *search test*")))
    (unwind-protect
        (progn
          (etaf-mount buffer
                      (lambda ()
                        (etaf-view
                         (etaf-search-field :bind query :ref 'search
                                            :placeholder "搜索" :icon t
                                            :on-clear (lambda () (setq cleared t)))))
                      '(:viewport-width 400 :viewport-height 6))
          (switch-to-buffer buffer)
          (let ((runtime (etaf-runtime-for-buffer buffer)))
            (should (string-match-p "搜索" (etaf-ui-field-test--text buffer)))
            (etaf-dispatch-event runtime 'search 'press)
            (etaf-ui-field-test--type [?e ?m ?a ?c ?s])
            (should (equal (etaf-value query) "emacs"))
            (etaf-runtime-flush runtime)
            (let ((clear (car (cl-find-if
                               (lambda (entry)
                                 (equal "Clear" (plist-get (cdr entry) :help-echo)))
                               (etaf-runtime-host-props-entries runtime)))))
              (should clear)
              (etaf-dispatch-event runtime clear 'press))
            (should (equal (etaf-value query) ""))
            (should cleared)
            (should (etaf-text-input-active-p runtime))))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer))) (etaf-unmount runtime))
      (kill-buffer buffer))))

;;; etaf-ui-field-tests.el ends here
