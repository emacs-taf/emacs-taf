;;; etaf-manual-reader-tests.el --- Public API acceptance -*- lexical-binding: t; -*-

;;; Commentary:
;; Test the supported manual reader contract: session state, navigation,
;; language and theme switches, the navigation outline, the mounted
;; rendering and the in-place runnable examples.  Internal helpers are
;; outside this contract.

;;; Code:

(require 'cl-lib)
(require 'ert)
(require 'etaf)
(require 'etaf-manual)

(defconst etaf-manual-reader-test--buffer " *etaf-manual-reader-test*"
  "Buffer name used by the mounted reader tests.")

(defmacro etaf-manual-reader-test--with-reader (session &rest body)
  "Mount SESSION in a test buffer, evaluate BODY, then release it."
  (declare (indent 1))
  `(let ((buffer (get-buffer-create etaf-manual-reader-test--buffer)))
     (unwind-protect
         (progn
           (setq buffer (etaf-mount buffer (etaf-manual-reader-view ,session)))
           (with-current-buffer buffer ,@body))
       (when-let* ((runtime (etaf-runtime-for-buffer etaf-manual-reader-test--buffer)))
         (etaf-unmount runtime))
       (when-let* ((live (get-buffer etaf-manual-reader-test--buffer)))
         (kill-buffer live)))))

(defun etaf-manual-reader-test--text ()
  "Return the plain text of the mounted reader buffer."
  (substring-no-properties (buffer-string)))

(defun etaf-manual-reader-test--hover-p (needle)
  "Return non-nil when some NEEDLE occurrence carries a mouse face."
  (let ((position 0) (found nil))
    (while (and (not found)
                (setq position (string-match needle (buffer-string) position)))
      (when (get-text-property (1+ position) 'mouse-face)
        (setq found t))
      (setq position (1+ position)))
    found))

(defvar etaf-manual-reader-test--surface-session nil
  "Reader session mounted by the surface host during a case.")

(etaf-define-component etaf-manual-reader-test-surface-host (&key surface appearance)
  "Provide SURFACE and APPEARANCE to the reader mounted below."
  :setup (progn
           (etaf-surface-provide surface)
           (when appearance (etaf-appearance-provide appearance)))
  :view (expr (etaf-manual-reader-view etaf-manual-reader-test--surface-session)))

(ert-deftest etaf-manual-reader-create-reports-state ()
  "A new session reads the first chapter and exposes its outline."
  (let* ((session (etaf-manual-reader-create :language "zh-CN"))
         (state (etaf-manual-reader-state session)))
    (should (equal "zh-CN" (plist-get state :language)))
    (should (eq 'introduction (plist-get state :chapter)))
    (should (equal "引言" (plist-get state :chapter-title)))
    (should (zerop (plist-get state :position)))
    (should (> (plist-get state :chapters) 90))
    (should (member "范围" (plist-get state :nodes)))
    (should-not (plist-get state :can-back))))

(ert-deftest etaf-manual-reader-accepts-a-chapter-name ()
  "A chapter may be named by its string name, which opens that chapter.
The reader indexes chapters by symbol, so a name that stays a string used to
match nothing and the page rendered empty."
  (let* ((session (etaf-manual-reader-create :language "zh-CN"
                                             :chapter "posframe-panels"))
         (state (etaf-manual-reader-state session)))
    (should (eq 'posframe-panels (plist-get state :chapter)))
    (should (equal "浮动面板" (plist-get state :chapter-title)))
    (should (member "面板选项" (plist-get state :nodes)))
    (etaf-manual-reader-goto session "introduction")
    (should (eq 'introduction
                (plist-get (etaf-manual-reader-state session) :chapter)))))

(ert-deftest etaf-manual-reader-rejects-an-unknown-chapter ()
  "An unknown chapter signals before a reader shows a blank page.
Arithmetic on the missing reading position used to fail instead, which read as
a renderer bug."
  (should-error (etaf-manual-reader-create :chapter "no-such-chapter")
                :type 'etaf-manual-error)
  (should-error (etaf-manual-reader-create :chapter 'no-such-chapter)
                :type 'etaf-manual-error)
  (let ((session (etaf-manual-reader-create :language "zh-CN"))
        (before nil))
    (setq before (etaf-manual-reader-state session))
    (should-error (etaf-manual-reader-goto session "no-such-chapter")
                  :type 'etaf-manual-error)
    (should (eq (plist-get before :chapter)
                (plist-get (etaf-manual-reader-state session) :chapter)))))

(ert-deftest etaf-manual-reader-navigation-walks-sections-and-chapters ()
  "Next and previous move through sections and roll into other chapters."
  (let ((session (etaf-manual-reader-create :language "zh-CN")))
    (etaf-manual-reader-next session)
    (should (eql 0 (plist-get (etaf-manual-reader-state session) :node)))
    (etaf-manual-reader-next session)
    (should (eql 1 (plist-get (etaf-manual-reader-state session) :node)))
    (etaf-manual-reader-previous session)
    (should (eql 0 (plist-get (etaf-manual-reader-state session) :node)))
    ;; The first chapter has nothing before it.
    (should-error (etaf-manual-reader-previous session) :type 'user-error)
    ;; Walk to the end of the chapter, then roll into the next one.
    (let ((count (length (plist-get (etaf-manual-reader-state session) :nodes))))
      (dotimes (_ (1- count)) (etaf-manual-reader-next session))
      (let ((state (etaf-manual-reader-state session)))
        (should (eq 'introduction (plist-get state :chapter)))
        (should (eql (1- count) (plist-get state :node))))
      (etaf-manual-reader-next session)
      (let ((state (etaf-manual-reader-state session)))
        (should (eq 'ecosystem-and-layers (plist-get state :chapter)))
        (should (eql 0 (plist-get state :node))))
      ;; From the top of the second chapter, previous returns to the last
      ;; section of the first one.
      (etaf-manual-reader-previous session)
      (let ((state (etaf-manual-reader-state session)))
        (should (eq 'introduction (plist-get state :chapter)))
        (should (eql (1- count) (plist-get state :node)))))))

(ert-deftest etaf-manual-reader-up-follows-levels ()
  "Up moves a level-3 section to its level-2 parent and then to the top."
  (let ((session (etaf-manual-reader-create :language "zh-CN")))
    ;; "术语" is a level-3 section of the introduction.
    (let ((nodes (plist-get (etaf-manual-reader-state session) :nodes)))
      (etaf-manual-reader-goto
       session 'introduction
       (cl-position "术语" nodes :test #'equal)))
    (should (equal "术语" (plist-get (etaf-manual-reader-state session) :node-title)))
    (etaf-manual-reader-up session)
    (should (equal "记法约定" (plist-get (etaf-manual-reader-state session) :node-title)))
    (etaf-manual-reader-up session)
    (should-not (plist-get (etaf-manual-reader-state session) :node))))

(ert-deftest etaf-manual-reader-history-walks-both-ways ()
  "Back and forward move through the reading history."
  (let ((session (etaf-manual-reader-create :language "zh-CN")))
    (etaf-manual-reader-goto session 'introduction 0)
    (etaf-manual-reader-goto session 'ecosystem-and-layers 0)
    (should (eq 'ecosystem-and-layers (plist-get (etaf-manual-reader-state session) :chapter)))
    (etaf-manual-reader-back session)
    (should (eq 'introduction (plist-get (etaf-manual-reader-state session) :chapter)))
    (should (eql 0 (plist-get (etaf-manual-reader-state session) :node)))
    (etaf-manual-reader-forward session)
    (should (eq 'ecosystem-and-layers (plist-get (etaf-manual-reader-state session) :chapter)))
    (should (plist-get (etaf-manual-reader-state session) :can-back))))

(ert-deftest etaf-manual-reader-language-switch-keeps-position ()
  "Switching language keeps the chapter and reads the other translation."
  (let ((session (etaf-manual-reader-create :language "zh-CN")))
    (etaf-manual-reader-goto session 'components 0)
    (etaf-manual-reader-set-language session "en")
    (let ((state (etaf-manual-reader-state session)))
      (should (equal "en" (plist-get state :language)))
      (should (eq 'components (plist-get state :chapter)))
      (should (equal "Components" (plist-get state :chapter-title)))
      (should (eql 0 (plist-get state :node))))
    (etaf-manual-reader-set-language session "zh-CN")
    (should (equal "Component" (plist-get (etaf-manual-reader-state session) :chapter-title)))))

(ert-deftest etaf-manual-reader-toggle-theme-switches-palette ()
  "Toggling the theme pins the palette opposite the one on screen."
  (let ((session (etaf-manual-reader-create :language "zh-CN" :theme 'dark)))
    (should (eq (etaf-manual-reader-toggle-theme session) 'light))
    (should (eq 'light (plist-get (etaf-manual-reader-state session) :theme)))
    (should (eq (etaf-manual-reader-toggle-theme session) 'dark)))
  ;; An `auto' reader pins the opposite of the appearance it resolves to.
  (let ((session (etaf-manual-reader-create :language "zh-CN" :theme 'auto)))
    (should (memq (etaf-manual-reader-toggle-theme session) '(light dark)))
    (should-not (eq 'auto (plist-get (etaf-manual-reader-state session) :theme)))))

(ert-deftest etaf-manual-reader-toc-marks-the-current-chapter ()
  "The outline names the parts, chapters and current sections."
  (let* ((session (etaf-manual-reader-create :language "zh-CN" :chapter 'components))
         (toc (etaf-manual-reader-toc session))
         (current (cl-find-if (lambda (chapter) (plist-get chapter :current))
                              (cl-loop for part in toc
                                       append (plist-get part :chapters)))))
    (should (> (length toc) 10))
    (should current)
    (should (eq 'components (plist-get current :id)))
    (should (listp (plist-get current :nodes)))
    (should (plist-get (car (plist-get current :nodes)) :anchor))))

(ert-deftest etaf-manual-reader-view-renders-chapter-and-example ()
  "The mounted reader shows the article, chrome and a runnable example."
  (let ((session (etaf-manual-reader-create :language "zh-CN" :chapter 'introduction)))
    (etaf-manual-reader-test--with-reader session
      (let ((text (etaf-manual-reader-test--text)))
        (should (string-match-p "手册" text))
        (should (string-match-p "引言" text))
        (should (string-match-p "范围" text))
        (should (string-match-p "示例 · introduction-1" text))
        (should (string-match-p "尚未运行" text))
        (should (string-match-p "跳转" text))))))

(ert-deftest etaf-manual-reader-example-runs-and-stops-in-place ()
  "The run control renders the real View; stop clears it again."
  (let* ((session (etaf-manual-reader-create :language "zh-CN" :chapter 'introduction))
         (run-ref 'etaf-manual-example-run-introduction-1)
         (stop-ref 'etaf-manual-example-stop-introduction-1))
    (etaf-manual-reader-test--with-reader session
      (let ((runtime (etaf-runtime-for-buffer etaf-manual-reader-test--buffer)))
        (should (string-match-p "尚未运行" (etaf-manual-reader-test--text)))
        (etaf-dispatch-event runtime run-ref 'press)
        (etaf-runtime-flush runtime)
        (should-not (string-match-p "尚未运行" (etaf-manual-reader-test--text)))
        (should (string-match-p "Hello" (etaf-manual-reader-test--text)))
        (etaf-dispatch-event runtime stop-ref 'press)
        (etaf-runtime-flush runtime)
        (should (string-match-p "尚未运行" (etaf-manual-reader-test--text)))))))

(ert-deftest etaf-manual-reader-example-modes-switch ()
  "Source, preview and side-by-side modes switch per example."
  (let* ((session (etaf-manual-reader-create
                   :language "zh-CN" :chapter 'ui-buttons-and-choice-controls))
         (id "ui-buttons-and-choice-controls-1")
         (source-ref (intern (format "etaf-manual-example-source-%s" id)))
         (split-ref (intern (format "etaf-manual-example-split-%s" id))))
    (etaf-manual-reader-test--with-reader session
      (let ((runtime (etaf-runtime-for-buffer etaf-manual-reader-test--buffer)))
        ;; The default mode shows the preview surface only.
        (should (string-match-p "尚未运行" (etaf-manual-reader-test--text)))
        (etaf-dispatch-event runtime split-ref 'press)
        (etaf-runtime-flush runtime)
        (let ((text (etaf-manual-reader-test--text)))
          (should (string-match-p "源码" text))
          (should (string-match-p "预览" text))
          (should (string-match-p "etaf-view" text)))
        (etaf-dispatch-event runtime source-ref 'press)
        (etaf-runtime-flush runtime)
        (let ((text (etaf-manual-reader-test--text)))
          (should (string-match-p "etaf-view" text))
          (should-not (string-match-p "尚未运行" text)))))))

(ert-deftest etaf-manual-reader-shows-definition-cards ()
  "A chapter with definition entries renders their cards."
  (let ((session (etaf-manual-reader-create
                  :language "zh-CN" :chapter 'ui-buttons-and-choice-controls)))
    (etaf-manual-reader-test--with-reader session
      (let ((text (etaf-manual-reader-test--text)))
        (should (string-match-p "按钮与选择控件" text))
        (should (string-match-p "etaf-button" text))
        (should (string-match-p "Component" text))))))

(ert-deftest etaf-manual-reader-key-help-lists-reader-keys ()
  "The ETAF key help of the mounted reader lists the reader's own keys."
  (let ((session (etaf-manual-reader-create :language "zh-CN" :chapter 'introduction)))
    (etaf-manual-reader-test--with-reader session
      (let ((original (current-buffer)) (windows (window-list))
            (help (etaf-help)))
        (unwind-protect
            (progn
              (should (eq help original))
              (should (equal windows (window-list)))
              (let* ((data (etaf-help-data))
                     (labels (mapcan (lambda (group)
                                       (mapcar (lambda (entry) (plist-get entry :label))
                                               (plist-get group :entries)))
                                     (plist-get data :groups))))
                (should (member "下一节" labels))
                (should (member "中英文切换" labels))
                (should (equal (plist-get data :title) "手册阅读器"))))
          (etaf-help-close))))))

(ert-deftest etaf-manual-reader-page-keys-drive-navigation ()
  "The page Host's `:keys' dispatch the reader keys in the runtime."
  (let ((buffer (etaf-manual-open 'introduction)))
    (unwind-protect
        (progn
          (with-current-buffer buffer
            (should-not (string-match-p "章 · " (substring-no-properties (buffer-string)))))
          (with-current-buffer buffer
            (execute-kbd-macro (kbd "n"))
            (etaf-runtime-flush (etaf-runtime-for-buffer buffer)))
          (with-current-buffer buffer
            (should (string-match-p "章 · " (substring-no-properties (buffer-string))))))
      (when (buffer-live-p buffer)
        (with-current-buffer buffer (etaf-manual-close))))))

(ert-deftest etaf-manual-reader-examples-follow-run-blocks ()
  "Only `:run' blocks become viewers, including those inside definitions."
  (let ((session (etaf-manual-reader-create :language "zh-CN" :chapter 'introduction)))
    (etaf-manual-reader-test--with-reader session
      ;; The notation block before the first runnable example stays code.
      (should (string-match-p (regexp-quote "(etaf-value (etaf-ref 3))")
                              (etaf-manual-reader-test--text)))))
  (let ((session (etaf-manual-reader-create :language "zh-CN" :chapter 'components))
        (run-ref 'etaf-manual-example-run-components-1))
    (etaf-manual-reader-test--with-reader session
      (let ((runtime (etaf-runtime-for-buffer etaf-manual-reader-test--buffer))
            (idle (lambda ()
                    (let ((text (etaf-manual-reader-test--text)) (start 0) (count 0))
                      (while (string-match "尚未运行" text start)
                        (setq start (match-end 0) count (1+ count)))
                      count))))
        (let ((before (funcall idle)))
          (etaf-dispatch-event runtime run-ref 'press)
          (etaf-runtime-flush runtime)
          (should (= (funcall idle) (1- before))))))))

(ert-deftest etaf-manual-lookup-reaches-the-end-of-a-long-chapter ()
  "Looking up the last entry of a long chapter shows its card at once."
  (let ((etaf-manual-language "zh-CN")
        (buffer nil))
    (unwind-protect
        (progn
          (etaf-manual-lookup :outer 'style)
          (setq buffer (get-buffer "*ETAF 手册*"))
          (should buffer)
          (dotimes (_ 3) (accept-process-output nil 0.02))
          (with-current-buffer buffer
            (etaf-runtime-flush (etaf-runtime-for-buffer buffer))
            (let ((text (substring-no-properties (buffer-string))))
              (should (string-match-p "Style" text))
              (should (string-match-p ":outer" text)))))
      (when (buffer-live-p buffer)
        (with-current-buffer buffer (etaf-manual-close))))))

(ert-deftest etaf-manual-reader-jump-targets-cover-the-book ()
  "The jump completion lists chapters, sections, definitions and terms."
  (let* ((session (etaf-manual-reader-create :language "zh-CN"))
         (targets (etaf-manual-reader-jump-targets session))
         (sections (cl-remove-if-not
                    (lambda (entry) (plist-get (cdr entry) :node)) targets))
         (definitions (cl-remove-if-not
                       (lambda (entry) (plist-get (cdr entry) :definition)) targets))
         (terms (cl-remove-if-not
                 (lambda (entry) (plist-get (cdr entry) :anchor)) targets))
         (chapter (cl-find 'introduction (plist-get (etaf-manual-book "zh-CN") :chapters)
                           :key (lambda (entry) (plist-get entry :id))))
         (chapter-target (cl-find-if
                          (lambda (entry)
                            (equal (list :chapter 'introduction) (cdr entry)))
                          targets)))
    (should (> (length targets) 3000))
    (should (> (length sections) 700))
    (should (> (length definitions) 700))
    (should (> (length terms) 1500))
    (should chapter-target)
    (should (string-match-p "\\`章 · " (car chapter-target)))
    (should (etaf-manual-definition
             (plist-get (cdr (car definitions)) :definition)))
    (should (equal (list :chapter 'introduction)
                   (cdr chapter-target)))
    (should (plist-get chapter :nodes))))

(ert-deftest etaf-manual-reader-search-walks-matching-sections ()
  "Search finds matching sections and next/previous walk the results."
  (let* ((session (etaf-manual-reader-create :language "zh-CN"))
         (count (etaf-manual-reader-search session "etaf-ref")))
    (should (> count 1))
    (let ((first (etaf-manual-reader-search-match session)))
      (should (plist-get first :chapter))
      ;; The first result has nothing before it.
      (should-error (etaf-manual-reader-search-previous session) :type 'user-error)
      (let ((second (etaf-manual-reader-search-next session)))
        (should (equal second (etaf-manual-reader-search-match session)))
        (should (equal first (etaf-manual-reader-search-previous session)))
        (should (equal first (etaf-manual-reader-search-match session)))))
    (should-error (etaf-manual-reader-search-previous session) :type 'user-error)
    ;; A query with no match clears the results; an empty query is an error.
    (should (zerop (etaf-manual-reader-search session "zzz-not-in-the-book")))
    (should-not (etaf-manual-reader-search-match session))
    (should-error (etaf-manual-reader-search-next session) :type 'user-error)
    (should-error (etaf-manual-reader-search session "") :type 'user-error)))

(ert-deftest etaf-manual-reader-inline-symbols-link-to-definitions ()
  "A code span naming a definition entry activates as a link."
  (let* ((session (etaf-manual-reader-create :language "zh-CN" :chapter 'reactivity))
         (definition (etaf-manual-definition 'etaf-watch))
         (chapter (cl-find (plist-get definition :chapter)
                           (plist-get (etaf-manual-book "zh-CN") :chapters)
                           :key (lambda (entry) (plist-get entry :id))))
         (expected (let ((index nil))
                     (cl-loop for node in (plist-get chapter :nodes)
                              for position from 0
                              do (when (and (plist-get node :line)
                                            (<= (plist-get node :line)
                                                (plist-get definition :line)))
                                   (setq index position)))
                     index)))
    (should expected)
    (etaf-manual-reader-test--with-reader session
      (let* ((text (etaf-manual-reader-test--text))
             (start 0)
             (position nil))
        (while (and (not position)
                    (setq start (string-match "etaf-watch" text start)))
          ;; Ebox paints its hover handler as `help-echo' and keeps the run's
          ;; own text in `ebox-help-echo', which is what a link carries.
          (when (equal "查看定义：etaf-watch"
                       (get-text-property (1+ start) 'ebox-help-echo))
            (setq position start))
          (setq start (1+ start)))
        (should position)
        ;; RET over the span follows the link exactly like a click.
        (set-window-buffer (selected-window) (current-buffer))
        (goto-char (1+ position))
        (execute-kbd-macro (kbd "RET"))))
    (should (eql expected (plist-get (etaf-manual-reader-state session) :node)))))

(ert-deftest etaf-manual-reader-page-outline-lists-sections ()
  "The mounted wide reader shows the on-this-page column of the chapter."
  (let* ((session (etaf-manual-reader-create :language "zh-CN" :chapter 'components))
         (nodes (plist-get (etaf-manual-reader-state session) :nodes)))
    (etaf-manual-reader-test--with-reader session
      ;; The batch frame is narrow; refit the runtime to a wide viewport.
      (etaf-runtime-refit (etaf-runtime-for-buffer etaf-manual-reader-test--buffer)
                          (* 150 (frame-char-width)) 60)
      (etaf-runtime-flush (etaf-runtime-for-buffer etaf-manual-reader-test--buffer))
      (let ((text (etaf-manual-reader-test--text)))
        (should (string-match-p "本页" text))
        (should (string-match-p (regexp-quote (car nodes)) text))))))

(ert-deftest etaf-manual-reader-chapter-cards-open-neighbours ()
  "The end-of-chapter cards move to the previous and next chapter."
  (let ((session (etaf-manual-reader-create :language "zh-CN" :chapter 'components)))
    (etaf-manual-reader-test--with-reader session
      (let ((runtime (etaf-runtime-for-buffer etaf-manual-reader-test--buffer)))
        ;; A tall wide viewport keeps the end-of-chapter cards in the buffer.
        (etaf-runtime-refit runtime (* 150 (frame-char-width)) 2000)
        (etaf-runtime-flush runtime)
        (let ((text (etaf-manual-reader-test--text)))
          (should (string-match-p "上一章" text))
          (should (string-match-p "下一章" text)))
        (etaf-dispatch-event runtime 'etaf-manual-chapter-next 'press)
        (etaf-runtime-flush runtime)))
    (should-not (eq 'components (plist-get (etaf-manual-reader-state session) :chapter)))
    (etaf-manual-reader-test--with-reader session
      (let ((runtime (etaf-runtime-for-buffer etaf-manual-reader-test--buffer)))
        (etaf-runtime-refit runtime (* 150 (frame-char-width)) 2000)
        (etaf-runtime-flush runtime)
        (etaf-dispatch-event runtime 'etaf-manual-chapter-previous 'press)
        (etaf-runtime-flush runtime)))
    (should (eq 'components (plist-get (etaf-manual-reader-state session) :chapter)))))

(ert-deftest etaf-manual-reader-remembers-the-reading-position ()
  "Remembering a position restores it in a later session."
  (let ((etaf-manual-reader-position-file (make-temp-file "etaf-manual-position")))
    (unwind-protect
        (progn
          (let ((session (etaf-manual-reader-create :language "zh-CN")))
            (etaf-manual-reader-set-language session "en")
            (etaf-manual-reader-goto session 'components 1)
            (should (etaf-manual-reader-remember session)))
          (let ((session (etaf-manual-reader-create :language "zh-CN")))
            (should (etaf-manual-reader-restore session))
            (let ((state (etaf-manual-reader-state session)))
              (should (equal "en" (plist-get state :language)))
              (should (eq 'components (plist-get state :chapter)))
              (should (eql 1 (plist-get state :node)))))
          ;; A malformed or stale file leaves the session untouched.
          (with-temp-file etaf-manual-reader-position-file
            (insert "(this is not a position"))
          (let ((session (etaf-manual-reader-create :language "zh-CN")))
            (should-not (etaf-manual-reader-restore session))
            (should (eq 'introduction
                        (plist-get (etaf-manual-reader-state session) :chapter)))))
      (delete-file etaf-manual-reader-position-file))))

(ert-deftest etaf-manual-reader-edits-and-reruns-an-example ()
  "Submitting the in-place example editor reruns the edited draft."
  (let ((buffer (etaf-manual-open 'introduction)))
    (unwind-protect
        (with-current-buffer buffer
          (let ((runtime (etaf-runtime-for-buffer buffer)))
            (etaf-runtime-refit runtime (* 150 (frame-char-width)) 400)
            (etaf-runtime-flush runtime)
            ;; Focus the example card and open it for editing with the page key.
            (etaf-focus runtime 'etaf-manual-example-introduction-1)
            (execute-kbd-macro (kbd "e"))
            (etaf-runtime-flush runtime)
            (should (string-match-p "C-c C-c 运行" (substring-no-properties (buffer-string))))
            ;; Type a trailing comment and submit it with C-c C-c.
            (etaf-dispatch-event runtime 'etaf-manual-example-edit-introduction-1 'press)
            (execute-kbd-macro "\n;; note")
            (execute-kbd-macro (kbd "C-c C-c"))
            (etaf-runtime-flush runtime)
            (should-not (etaf-text-input-active-p runtime))
            ;; The run control reruns the submitted draft and w copies it.
            (etaf-dispatch-event runtime 'etaf-manual-example-run-introduction-1 'press)
            (etaf-runtime-flush runtime)
            (should (string-match-p "Hello" (substring-no-properties (buffer-string))))
            (execute-kbd-macro (kbd "w"))
            (should (string-match-p ";; note" (current-kill 0)))))
      (when (buffer-live-p buffer)
        (with-current-buffer buffer (etaf-manual-close))))))

(ert-deftest etaf-manual-reader-copies-the-section-code ()
  "The w key copies the current section's code to the kill ring."
  (let* ((session (etaf-manual-reader-create :language "zh-CN" :chapter 'introduction))
         (index (cl-position "求值、渲染、错误与输出的记法"
                             (plist-get (etaf-manual-reader-state session) :nodes)
                             :test #'equal))
         (buffer nil))
    (should index)
    (unwind-protect
        (progn
          (setq buffer (etaf-manual-open 'introduction))
          (with-current-buffer buffer
            (let ((runtime (etaf-runtime-for-buffer buffer)))
              (etaf-runtime-refit runtime (* 150 (frame-char-width)) 400)
              (etaf-runtime-flush runtime)
              ;; Move to the section that holds the static code block.
              (dotimes (_ (1+ index)) (execute-kbd-macro (kbd "n")))
              (etaf-runtime-flush runtime)
              (execute-kbd-macro (kbd "w"))
              (etaf-runtime-flush runtime)
              (should (string-match-p (regexp-quote "(etaf-value (etaf-ref 3))")
                                      (current-kill 0))))))
      (when (buffer-live-p buffer)
        (with-current-buffer buffer (etaf-manual-close))))))

(ert-deftest etaf-manual-reader-resizes-the-side-columns ()
  "The side columns report their widths and resize from their dividers."
  (let ((session (etaf-manual-reader-create :language "zh-CN" :chapter 'components)))
    (should (eql 38 (plist-get (etaf-manual-reader-state session) :sidebar-width)))
    (should (>= (plist-get (etaf-manual-reader-state session) :outline-width) 12))
    (etaf-manual-reader-set-sidebar-width session 30)
    (should (eql 30 (plist-get (etaf-manual-reader-state session) :sidebar-width)))
    ;; Out-of-range values clamp to the supported width.
    (etaf-manual-reader-set-sidebar-width session 1000)
    (should (eql 64 (plist-get (etaf-manual-reader-state session) :sidebar-width)))
    (etaf-manual-reader-set-outline-width session 24)
    (should (eql 24 (plist-get (etaf-manual-reader-state session) :outline-width)))
    ;; nil restores the adaptive width.
    (etaf-manual-reader-set-outline-width session nil)
    (should (>= (plist-get (etaf-manual-reader-state session) :outline-width) 12))
    ;; The focused divider steps the width one column per arrow press.
    (etaf-manual-reader-test--with-reader session
      (let ((runtime (etaf-runtime-for-buffer etaf-manual-reader-test--buffer)))
        (etaf-runtime-refit runtime (* 150 (frame-char-width)) 44)
        (etaf-runtime-flush runtime)
        (should (etaf-focus runtime 'etaf-manual-sidebar-resizer))
        (call-interactively (key-binding (kbd "<right>") t))
        (etaf-runtime-flush runtime)))
    (should (> (plist-get (etaf-manual-reader-state session) :sidebar-width) 30))))

(ert-deftest etaf-manual-reader-interactive-surfaces-hover ()
  "Navigation rows and rendered links carry a pointer hover face."
  (let ((session (etaf-manual-reader-create :language "zh-CN" :chapter 'introduction)))
    (etaf-manual-reader-test--with-reader session
      (etaf-runtime-refit (etaf-runtime-for-buffer etaf-manual-reader-test--buffer)
                          (* 150 (frame-char-width)) 44)
      (etaf-runtime-flush (etaf-runtime-for-buffer etaf-manual-reader-test--buffer))
      ;; An inactive chapter row hovers; the chapter being read keeps its
      ;; selected surface.
      (should (etaf-manual-reader-test--hover-p "生态与分层"))
      (should-not (etaf-manual-reader-test--hover-p "引言"))
      (should (etaf-manual-reader-test--hover-p "响应式系统")))))

(ert-deftest etaf-manual-reader-renders-inline-figures ()
  "A `:figure' block renders its View inline and offers no run control."
  (let ((session (etaf-manual-reader-create :language "zh-CN" :chapter 'views)))
    (etaf-manual-reader-test--with-reader session
      (let ((text (etaf-manual-reader-test--text)))
        (should (string-match-p "图 · 一个 column" text))
        ;; The figure's own View is painted in the chapter.
        (should (string-match-p "左子节点" text))
        (should-not (string-match-p "▶ 运行" text))))))

(ert-deftest etaf-manual-reader-auto-follows-the-host-appearance ()
  "An `auto' reader paints with the appearance its host provides.
A panel keeps that appearance in step with the Emacs theme, so `随' follows
the theme while `亮' and `暗' pin the palette."
  (let ((surface (etaf-surface-create))
        (appearance (etaf-ref 'dark))
        (buffer (generate-new-buffer " *etaf-manual-reader-auto*")))
    (let ((etaf-manual-reader-test--surface-session
           (etaf-manual-reader-create :language "zh-CN" :theme 'auto)))
      (unwind-protect
          (progn
            (etaf-mount buffer
                        (etaf-view (etaf-manual-reader-test-surface-host
                                    :surface surface :appearance appearance))
                        (list :viewport-width 1200 :viewport-height 40))
            (should (eq 'auto (etaf-value (etaf-surface-mode surface))))
            (should (equal "#191a1c"
                           (plist-get (etaf-value (etaf-surface-theme surface))
                                      :ui-bg)))
            ;; The host switches appearance; the auto reader follows it.
            (etaf-set-value appearance 'light)
            (etaf-runtime-flush (etaf-runtime-for-buffer buffer))
            (should (equal "#ffffff"
                           (plist-get (etaf-value (etaf-surface-theme surface))
                                      :ui-bg))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest etaf-manual-reader-mounted-by-a-host-saves-its-position ()
  "A host-mounted reader resolves its own session and saves the position.
Both look the session up in the buffer the host renders into; a panel that
recorded neither left closing inert and never saved where the reader was."
  (let* ((file (make-temp-file "etaf-manual-position" nil ".eld"))
         (etaf-manual-reader-position-file file)
         (session (etaf-manual-reader-create :language "zh-CN"
                                             :chapter 'introduction))
         (buffer (generate-new-buffer " *etaf-manual-reader-host*")))
    (unwind-protect
        (progn
          (etaf-mount buffer (etaf-manual-reader-view session))
          (with-current-buffer buffer
            (etaf-runtime-flush (etaf-runtime-for-buffer buffer))
            (etaf-manual-reader-goto session 'introduction 2)
            ;; Closing from the reader buffer finds the session the host
            ;; recorded, and remembers the section the reader moved to.
            (call-interactively #'etaf-manual-close))
          (should (file-exists-p file))
          (let ((saved (with-temp-buffer
                         (insert-file-contents file)
                         (read (current-buffer)))))
            (should (eq 'introduction (plist-get saved :chapter)))
            (should (eql 2 (plist-get saved :node)))))
      (when-let* ((runtime (and (buffer-live-p buffer)
                                (etaf-runtime-for-buffer buffer))))
        (ignore-errors (etaf-unmount runtime)))
      (when (buffer-live-p buffer) (kill-buffer buffer))
      (when (file-exists-p file) (delete-file file)))))

(ert-deftest etaf-manual-reader-session-is-recorded-by-its-host ()
  "A host that mounts the reader records its session in the host buffer.
`etaf-manual-open' is one such host; a panel or a desktop host is another,
which is why the reader's commands and Host keys find the mounted session
there instead of reporting that the buffer is not a reader."
  (let* ((session (etaf-manual-reader-create :language "zh-CN"
                                             :chapter 'introduction))
         (buffer (generate-new-buffer " *etaf-manual-reader-host*")))
    (unwind-protect
        (progn
          (should-not (etaf-manual-reader-session buffer))
          (etaf-mount buffer (etaf-manual-reader-view session))
          (with-current-buffer buffer
            (etaf-runtime-flush (etaf-runtime-for-buffer buffer)))
          (should (eq session (etaf-manual-reader-session buffer)))
          (with-current-buffer buffer
            (should (eq session (etaf-manual-reader-session))))
          (etaf-unmount (etaf-runtime-for-buffer buffer))
          (should-not (etaf-manual-reader-session buffer)))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer)))
        (ignore-errors (etaf-unmount runtime)))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(ert-deftest etaf-manual-reader-declares-its-palette-to-a-host ()
  "A panel frames the reader with the reader's palette and switch.
The session's palette mode is the one cell the reader's own header switch and
the panel's title bar both write."
  (let ((surface (etaf-surface-create))
        (buffer (generate-new-buffer " *etaf-manual-reader-surface*")))
    (let ((etaf-manual-reader-test--surface-session
           (etaf-manual-reader-create :language "zh-CN" :theme 'dark)))
      (unwind-protect
          (progn
            (etaf-mount buffer
                        (etaf-view (etaf-manual-reader-test-surface-host
                                    :surface surface))
                        (list :viewport-width 1200 :viewport-height 40))
            (should (equal '((light . "亮") (auto . "随") (dark . "暗"))
                           (etaf-surface-modes surface)))
            (should (eq 'dark (etaf-value (etaf-surface-mode surface))))
            (should (equal "#191a1c"
                           (plist-get (etaf-value (etaf-surface-theme surface))
                                      :ui-bg)))
            ;; A title-bar click writes the session's own palette mode, and
            ;; the surface repaints from it.
            (etaf-set-value (etaf-surface-mode surface) 'light)
            (should (eq 'light
                        (plist-get (etaf-manual-reader-state
                                    etaf-manual-reader-test--surface-session)
                                   :theme)))
            (should (equal "#ffffff"
                           (plist-get (etaf-value (etaf-surface-theme surface))
                                      :ui-bg))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(provide 'etaf-manual-reader-tests)
;;; etaf-manual-reader-tests.el ends here
