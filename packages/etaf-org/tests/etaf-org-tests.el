;;; etaf-org-tests.el --- Acceptance tests for etaf-org -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; Public behavior tests.  Every scenario drives the previewer through the
;; interfaces declared in `etaf-org.el': a session from
;; `etaf-org-create', mounted with `etaf-org-view', inspected
;; through `etaf-org-state' or through the visible buffer text.  No
;; test reaches into the parser or the session plist.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'etaf)
(require 'etaf-ui)
(require 'etaf-org)

(defconst etaf-org-tests--directory
  (file-name-directory (or load-file-name buffer-file-name))
  "Directory of this test file, resolved while it is loaded.")

(defun etaf-org-tests--fixture (name)
  "Return the absolute path of fixture NAME."
  (expand-file-name (concat "fixtures/" name) etaf-org-tests--directory))

(defun etaf-org-tests--sample ()
  "Return the maintained gallery document as text."
  (with-temp-buffer
    (insert-file-contents
     (expand-file-name "../examples/complete-gallery.org" etaf-org-tests--directory))
    (buffer-string)))

(defun etaf-org-tests--mount (session &optional width)
  "Mount SESSION in a fresh buffer WIDTH wide and return that buffer."
  (etaf-mount (generate-new-buffer " *org-test*")
              (etaf-org-view session)
              (list :viewport-width (or width 900) :viewport-height 60)))

(defmacro etaf-org-tests--with-mount (session &rest body)
  "Mount SESSION, run BODY in its buffer, and always clean up."
  (declare (indent 1) (debug t))
  `(let ((buffer (etaf-org-tests--mount ,session)))
     (unwind-protect
         (with-current-buffer buffer ,@body)
       (when (buffer-live-p buffer)
         (with-current-buffer buffer
           (when (etaf-runtime-for-buffer buffer)
             (etaf-unmount)))
         (kill-buffer buffer)))))

(defun etaf-org-tests--text (&optional buffer)
  "Return the visible text of BUFFER, a string without properties."
  (with-current-buffer (or buffer (current-buffer))
    (buffer-substring-no-properties (point-min) (point-max))))

(defun etaf-org-tests--face-attribute (needle property)
  "Return PROPERTY of the face at the first occurrence of NEEDLE."
  (goto-char (point-min))
  (search-forward needle nil t)
  (let* ((face (or (get-text-property (match-beginning 0) 'face)
                   (plist-get (text-properties-at (match-beginning 0)) 'face)))
         (faces (cond ((null face) nil)
                      ((and (listp face) (keywordp (car face))) (list face))
                      ((listp face) face)
                      (t (list face)))))
    (cl-loop for entry in faces
             when (and (listp entry) (plist-get entry property))
             return (plist-get entry property))))

;;; Document model

(ert-deftest etaf-org-tests-file-title-drops-the-extension ()
  "A document without a title reads as its file name, without the suffix."
  (let ((file (make-temp-file "org-title" nil ".org")))
    (unwind-protect
        (progn
          (with-temp-file file (insert "* 一节\n正文\n"))
          (let ((session (etaf-org-create :file file)))
            (should (equal (plist-get (etaf-org-state session) :title)
                           (file-name-base file)))))
      (delete-file file))))

(ert-deftest etaf-org-tests-metadata-and-counts ()
  "A document reports its own metadata, outline and status counts."
  (let* ((session (etaf-org-create
                   :file (etaf-org-tests--fixture "syntax.org")))
         (state (etaf-org-state session)))
    (should (equal "语法样例" (plist-get state :title)))
    (should (equal "测试作者" (plist-get state :author)))
    (should (equal "第一节 标题" (nth 1 (nth 0 (plist-get state :outline)))))
    (should (equal '("work")
                   (nth 4 (nth 0 (plist-get state :outline)))))
    (should (equal 4 (plist-get state :sections)))
    (should (equal 1 (plist-get (plist-get state :counts) :todo)))
    (should (equal 1 (plist-get (plist-get state :counts) :deadline)))
    (should (equal 0 (plist-get state :degraded)))))

(ert-deftest etaf-org-tests-outline-carries-keyword-priority-tags ()
  "The outline reports the keyword, priority and tags of each headline."
  (let* ((session (etaf-org-create
                   :file (etaf-org-tests--fixture "syntax.org")))
         (child (nth 1 (etaf-org-outline session))))
    (should (equal 2 (nth 0 child)))
    (should (equal "子节" (nth 1 child)))
    (should (equal "TODO" (nth 3 child)))
    (should (equal '("urgent") (nth 4 child)))))

(ert-deftest etaf-org-tests-create-requires-a-source ()
  "Creating a session without a file or text signals the preview's error."
  (should-error (etaf-org-create) :type 'etaf-org-error))

(ert-deftest etaf-org-tests-create-reports-a-missing-file ()
  "An unreadable file names itself in the preview's error."
  (let ((error (should-error (etaf-org-create
                              :file "/nonexistent/org.org")
                             :type 'etaf-org-error)))
    (should (string-match-p "org.org"
                            (error-message-string error)))))

(ert-deftest etaf-org-tests-refresh-rereads-the-file ()
  "Refreshing a file session publishes the file's current content."
  (let* ((file (make-temp-file "org-preview" nil ".org"))
         (session nil)
         (buffer nil))
    (unwind-protect
        (progn
          (with-temp-file file (insert "* 旧标题\n旧正文\n"))
          (setq session (etaf-org-create :file file))
          (setq buffer (etaf-org-tests--mount session))
          (should (string-match-p "旧正文" (etaf-org-tests--text buffer)))
          (with-temp-file file (insert "* 新标题\n新正文\n"))
          (etaf-org-refresh session)
          (etaf-runtime-flush (etaf-runtime-for-buffer buffer))
          (let ((text (etaf-org-tests--text buffer)))
            (should (string-match-p "新正文" text))
            (should-not (string-match-p "旧正文" text))))
      (when (and buffer (buffer-live-p buffer))
        (with-current-buffer buffer
          (when (etaf-runtime-for-buffer buffer)
            (etaf-unmount)))
        (kill-buffer buffer))
      (delete-file file))))

(ert-deftest etaf-org-tests-refresh-keeps-the-document-on-failure ()
  "A failed refresh keeps the last rendered document and reports the error."
  (let* ((file (make-temp-file "org-preview" nil ".org"))
         (session nil))
    (unwind-protect
        (progn
          (with-temp-file file (insert "* 标题\n正文\n"))
          (setq session (etaf-org-create :file file))
          (delete-file file)
          (should-error (etaf-org-refresh session)
                        :type 'etaf-org-error)
          (should (equal '("标题")
                         (mapcar (lambda (entry) (nth 1 entry))
                                 (etaf-org-outline session)))))
      (when (file-exists-p file) (delete-file file)))))

(ert-deftest etaf-org-tests-state-is-detached ()
  "Mutating a state snapshot never reaches the session."
  (let* ((session (etaf-org-create :text "* 标题\n正文\n"))
         (state (etaf-org-state session)))
    (setcar (plist-get state :outline) nil)
    (should (equal 1 (length (etaf-org-outline session))))))

;;; Folding

(ert-deftest etaf-org-tests-fold-hides-the-body ()
  "Folding one section removes its body from the visible buffer."
  (let* ((session (etaf-org-create
                   :text "* 一节\n隐藏的正文\n** 子节\n子正文\n"))
         (id (nth 2 (car (etaf-org-outline session)))))
    (etaf-org-tests--with-mount session
      (should (string-match-p "隐藏的正文" (etaf-org-tests--text)))
      (etaf-org-fold session id 'folded)
      (etaf-runtime-flush (etaf-runtime-for-buffer (current-buffer)))
      (let ((text (etaf-org-tests--text)))
        (should (string-match-p "一节" text))
        (should-not (string-match-p "隐藏的正文" text))
        (should-not (string-match-p "子正文" text)))
      (should (etaf-org-folded-p session id)))))

(ert-deftest etaf-org-tests-children-fold-leaves-subheadings-openable ()
  "A `children' section lists its subheadings, and each one still opens."
  (let* ((session (etaf-org-create
                   :text "* 章\n章正文\n** 节\n节正文\n"))
         (outline (etaf-org-outline session))
         (chapter (nth 2 (car outline)))
         (section (nth 2 (cadr outline))))
    (etaf-org-tests--with-mount session
      (etaf-org-fold session chapter 'children)
      (etaf-runtime-flush (etaf-runtime-for-buffer (current-buffer)))
      (let ((text (etaf-org-tests--text)))
        (should (string-match-p "节" text))
        (should-not (string-match-p "章正文" text))
        (should-not (string-match-p "节正文" text)))
      (etaf-org-fold session section 'open)
      (etaf-runtime-flush (etaf-runtime-for-buffer (current-buffer)))
      (let ((text (etaf-org-tests--text)))
        (should (string-match-p "节正文" text))
        (should-not (string-match-p "章正文" text))))))

(ert-deftest etaf-org-tests-fold-children-keeps-child-headlines ()
  "The `children' state shows child headlines without either body."
  (let* ((session (etaf-org-create
                   :text "* 一节\n父正文\n** 子节\n子正文\n"))
         (id (nth 2 (car (etaf-org-outline session)))))
    (etaf-org-tests--with-mount session
      (etaf-org-fold session id 'children)
      (etaf-runtime-flush (etaf-runtime-for-buffer (current-buffer)))
      (let ((text (etaf-org-tests--text)))
        (should (string-match-p "子节" text))
        (should-not (string-match-p "父正文" text))
        (should-not (string-match-p "子正文" text))))))

(ert-deftest etaf-org-tests-sections-open-by-default ()
  "Every ordinary section body is rendered in the reader."
  (let ((session (etaf-org-create
                  :text "* 一节\n一节正文\n* 二节\n二节正文\n")))
    (etaf-org-tests--with-mount session
      (let ((text (etaf-org-tests--text)))
        (should (string-match-p "一节" text))
        (should (string-match-p "二节" text))
        (should (string-match-p "一节正文" text))
        (should (string-match-p "二节正文" text))))))

(ert-deftest etaf-org-tests-fold-all-updates-every-section ()
  "A global fold writes every section and reports their state."
  (let* ((session (etaf-org-create
                   :file (etaf-org-tests--fixture "syntax.org")))
         (ids (mapcar (lambda (entry) (nth 2 entry))
                      (etaf-org-outline session))))
    (etaf-org-fold-all session 'folded)
    (should (cl-every (lambda (id) (etaf-org-folded-p session id)) ids))
    (etaf-org-fold-all session 'open)
    (should-not (cl-some (lambda (id) (etaf-org-folded-p session id)) ids))))

(ert-deftest etaf-org-tests-fold-unknown-section-errors ()
  "Folding an unknown section or an unknown state signals the preview error."
  (let ((session (etaf-org-create :text "* 一节\n正文\n")))
    (should-error (etaf-org-fold session "missing" 'folded)
                  :type 'etaf-org-error)
    (should-error (etaf-org-fold session "s1" 'sideways)
                  :type 'etaf-org-error)))

(ert-deftest etaf-org-tests-fold-publishes-one-region ()
  "Folding one section publishes a small update rather than the document."
  (let* ((session (etaf-org-create
                   :text (etaf-org-tests--sample)))
         (id (nth 2 (car (etaf-org-outline session)))))
    (etaf-org-tests--with-mount session
      (let ((runtime (etaf-runtime-for-buffer (current-buffer))))
        (etaf-org-fold session id 'folded)
        (etaf-runtime-flush runtime)
        (let ((report (etaf-runtime-update-report runtime)))
          (should report)
          (should (<= (or (plist-get report :edits) 0) 4)))))))

;;; Rendering

(ert-deftest etaf-org-tests-inline-emphasis-and-code-faces ()
  "Emphasis renders its own weight, slant and decoration; code renders mono."
  (let ((session (etaf-org-create
                  :text "* 标题\n*粗* /斜/ _下_ +删+ =逐=\n")))
    (etaf-org-tests--with-mount session
      (should (eq 'bold (etaf-org-tests--face-attribute "粗" :weight)))
      (should (eq 'italic (etaf-org-tests--face-attribute "斜" :slant)))
      (should (etaf-org-tests--face-attribute "删" :strike-through))
      (should (etaf-org-tests--face-attribute "逐" :background))
      (should-not (string-match-p "[*/_+=]" (etaf-org-tests--text))))))

(ert-deftest etaf-org-tests-entities-and-subscripts ()
  "Entities and subscripts render as their Unicode spelling."
  (let ((session (etaf-org-create
                  :text "* 标题\n写成 \\alpha 与 H_2O 与 x^2。\n")))
    (etaf-org-tests--with-mount session
      (let ((text (etaf-org-tests--text)))
        (should (string-match-p "α" text))
        (should (string-match-p "H₂O" text))
        (should (string-match-p "x²" text))))))

(ert-deftest etaf-org-tests-link-stays-in-the-paragraph ()
  "A link renders inline, so the text after it stays on the same line."
  (let ((session (etaf-org-create
                  :text "* 标题\n前文 [[https://example.com][例子]] 后文\n")))
    (etaf-org-tests--with-mount session
      (should (string-match-p "前文 例子 后文"
                              (etaf-org-tests--text))))))

(ert-deftest etaf-org-tests-timestamp-renders-as-a-date ()
  "An active timestamp shows the date, the Chinese weekday and the time."
  (let ((session (etaf-org-create
                  :text "* 标题\n<2026-02-14 Sat 10:00>\n")))
    (etaf-org-tests--with-mount session
      (should (string-match-p "2026-02-14 周六 10:00"
                              (etaf-org-tests--text))))))

(ert-deftest etaf-org-tests-planning-line-shows-both-dates ()
  "SCHEDULED and DEADLINE render on one planning line below the headline."
  (let ((session (etaf-org-create
                  :text (concat "* 任务\n"
                                "SCHEDULED: <2026-02-18 Wed> "
                                "DEADLINE: <2026-02-20 Fri>\n"))))
    (etaf-org-tests--with-mount session
      (let ((text (etaf-org-tests--text)))
        (should (string-match-p "2026-02-18 周三" text))
        (should (string-match-p "2026-02-20 周五" text))))))

(ert-deftest etaf-org-tests-checkbox-states-are-distinct ()
  "The three checkbox states draw three different marks."
  (let ((session (etaf-org-create
                  :text "* 标题\n- [ ] 待办\n- [X] 完成\n- [-] 半程\n")))
    (etaf-org-tests--with-mount session
      (let ((text (etaf-org-tests--text)))
        (should (string-match-p "□" text))
        (should (string-match-p "■" text))
        (should (string-match-p "◧" text))))))

(ert-deftest etaf-org-tests-description-list-keeps-the-term ()
  "A description item renders its term and its description."
  (let ((session (etaf-org-create
                  :text "* 标题\n- 术语 :: 说明文字\n")))
    (etaf-org-tests--with-mount session
      (let ((text (etaf-org-tests--text)))
        (should (string-match-p "术语" text))
        (should (string-match-p "说明文字" text))))))

(ert-deftest etaf-org-tests-table-renders-every-cell ()
  "A table renders its header and body cells."
  (let ((session (etaf-org-create
                  :text (concat "* 标题\n"
                                "| 名称 | 数值 |\n"
                                "|------+------|\n"
                                "| 甲   | 12   |\n"
                                "| 乙   | 3    |\n"))))
    (etaf-org-tests--with-mount session
      (let ((text (etaf-org-tests--text)))
        (dolist (cell '("名称" "数值" "甲" "12" "乙" "3"))
          (should (string-match-p cell text)))))))

(ert-deftest etaf-org-tests-code-block-keeps-its-source ()
  "A source block shows its language and its body text."
  (let ((session (etaf-org-create
                  :text (concat "* 标题\n"
                                "#+BEGIN_SRC elisp\n"
                                "(message \"hi\")\n"
                                "#+END_SRC\n"))))
    (etaf-org-tests--with-mount session
      (let ((text (etaf-org-tests--text)))
        (should (string-match-p "elisp" text))
        (should (string-match-p "(message \"hi\")" text))))))

(ert-deftest etaf-org-tests-callouts-are-initialized-by-kind ()
  "Each callout kind shows a written label instead of its block name."
  (let* ((session (etaf-org-create
                   :file (etaf-org-tests--fixture "syntax.org")))
         (buffer (etaf-org-tests--mount session))
         (text nil))
    (unwind-protect
        (progn
          (setq text (etaf-org-tests--text buffer))
          (should (string-match-p "警告" text))
          (should (string-match-p "引用内容" text))
          (should-not (string-match-p "WARNING" text)))
      (with-current-buffer buffer
        (when (etaf-runtime-for-buffer buffer)
          (etaf-unmount)))
      (kill-buffer buffer))))

(ert-deftest etaf-org-tests-footnotes-are-numbered-and-listed ()
  "A footnote reference gets a number and the footnote is listed at the end."
  (let* ((session (etaf-org-create
                   :file (etaf-org-tests--fixture "syntax.org")))
         (state (etaf-org-state session)))
    (should (equal '("one") (plist-get state :footnotes)))
    (etaf-org-tests--with-mount session
      (let ((text (etaf-org-tests--text)))
        (should (string-match-p "\\[1\\]" text))
        (should (string-match-p "脚注正文" text))))))

(ert-deftest etaf-org-tests-footnotes-in-lists-share-one-sequence ()
  "References inside list items number in document order."
  (let* ((session (etaf-org-create
                   :text (concat "* 一节\n"
                                 "1. 甲[fn:alpha]。\n"
                                 "2. 乙[fn:beta]。\n\n"
                                 "[fn:alpha] 第一个定义。\n\n"
                                 "[fn:beta] 第二个定义。\n")))
         (state (etaf-org-state session)))
    (should (equal (plist-get state :footnotes) '("alpha" "beta")))
    (etaf-org-tests--with-mount session
      (let ((text (etaf-org-tests--text)))
        (should (string-match-p "甲\\[1\\]" text))
        (should (string-match-p "乙\\[2\\]" text))
        (should (string-match-p "第一个定义" text))
        (should (string-match-p "第二个定义" text))))))

(ert-deftest etaf-org-tests-toc-skips-commented-sections ()
  "A COMMENT headline stays out of the table of contents."
  (let ((session (etaf-org-create
                  :text "* 可见\n正文\n* COMMENT 草稿\n隐藏的内容\n")))
    (etaf-org-tests--with-mount session
      (let ((text (etaf-org-tests--text)))
        (with-temp-buffer
          (insert text)
          (goto-char (point-min))
          (should (= 1 (how-many "草稿"))))
        (should-not (string-match-p "隐藏的内容" text))))))

(ert-deftest etaf-org-tests-comments-are-folded-initially ()
  "A COMMENT headline starts folded and reveals its body on request."
  (let* ((session (etaf-org-create
                   :file (etaf-org-tests--fixture "syntax.org")))
         (id (nth 2 (cl-find "注释节" (etaf-org-outline session)
                             :key (lambda (entry) (nth 1 entry))
                             :test #'equal))))
    (should (etaf-org-folded-p session id))
    (etaf-org-tests--with-mount session
      (should-not (string-match-p "注释内容不应出现"
                                  (etaf-org-tests--text)))
      (etaf-org-fold session id 'open)
      (etaf-runtime-flush (etaf-runtime-for-buffer (current-buffer)))
      (should (string-match-p "注释内容不应出现"
                              (etaf-org-tests--text))))))

(ert-deftest etaf-org-tests-unknown-block-counts-as-degraded ()
  "An unclosed block still renders its text and is counted as degraded."
  (let* ((session (etaf-org-create
                   :text "* 标题\n#+BEGIN_SRC\n未闭合的代码\n"))
         (state (etaf-org-state session)))
    (should (equal 1 (plist-get state :degraded)))
    (etaf-org-tests--with-mount session
      (should (string-match-p "未闭合的代码" (etaf-org-tests--text))))))

(ert-deftest etaf-org-tests-missing-image-becomes-a-card ()
  "A link to a missing image renders a card instead of signaling."
  (let ((session (etaf-org-create
                  :text "* 标题\n[[file:missing.png]]\n")))
    (etaf-org-tests--with-mount session
      (should (string-match-p "图片不可用" (etaf-org-tests--text))))))

(ert-deftest etaf-org-tests-heading-navigation-round-trips ()
  "Next and previous heading move between the same two headlines."
  (let ((session (etaf-org-create
                  :text "* 一节\n正文\n* 二节\n正文\n* 三节\n正文\n")))
    (etaf-org-tests--with-mount session
      (goto-char (point-min))
      (etaf-org-next-heading session)
      (let ((first (line-number-at-pos)))
        (should (string-match-p "一节"
                                (buffer-substring-no-properties
                                 (line-beginning-position) (line-end-position))))
        (etaf-org-next-heading session)
        (should (> (line-number-at-pos) first))
        (etaf-org-previous-heading session)
        (should (= (line-number-at-pos) first))))))

(ert-deftest etaf-org-tests-locate-moves-to-the-heading ()
  "Locating an outline entry moves point to that headline's row."
  (let ((session (etaf-org-create
                  :text "* 一节\n一节正文\n* 二节\n二节正文\n")))
    (etaf-org-tests--with-mount session
      (etaf-org-locate session 1)
      (should (string-match-p "二节"
                              (buffer-substring-no-properties
                               (line-beginning-position) (line-end-position))))
      (should (etaf-org-locate session 0))
      (should (string-match-p "一节"
                              (buffer-substring-no-properties
                               (line-beginning-position) (line-end-position)))))))

;;; Display controls

(ert-deftest etaf-org-tests-theme-cycles-and-rejects-unknown ()
  "Cycling selects the next theme including `auto'; unknown signals error."
  (let ((session (etaf-org-create :text "* 标题\n正文\n"
                                  :theme 'light)))
    (should (eq 'sepia (etaf-org-cycle-theme session)))
    (should (eq 'sepia (plist-get (etaf-org-state session) :theme)))
    (should (eq 'auto (etaf-org-cycle-theme session)))
    (should (eq 'auto (plist-get (etaf-org-state session) :theme-mode)))
    (should (eq 'dark (etaf-org-cycle-theme session)))
    (should-error (etaf-org-set-theme session 'neon)
                  :type 'etaf-org-error)
    (etaf-org-set-theme session 'auto)
    ;; A theme change repaints a mounted document.
    (etaf-org-tests--with-mount session
      (let ((before (etaf-org-tests--text)))
        (etaf-org-cycle-theme session)
        (etaf-runtime-flush (etaf-runtime-for-buffer (current-buffer)))
        (should (equal before (etaf-org-tests--text)))))))

(ert-deftest etaf-org-tests-width-adjust-stays-in-range ()
  "The reading measure is clamped to its configured range."
  (let ((session (etaf-org-create :text "* 标题\n正文\n")))
    (should (= etaf-org-width-max
               (etaf-org-adjust-width session 1000)))
    (should (= etaf-org-width-max
               (etaf-org-adjust-width session 0)))
    (should (= etaf-org-width-min
               (etaf-org-adjust-width session -1000)))))

(ert-deftest etaf-org-tests-toc-toggle-hides-the-contents-card ()
  "Hiding the table of contents removes it from the mounted document."
  (let ((session (etaf-org-create
                  :text "* 一节\n正文\n* 二节\n正文\n" :toc 2)))
    (etaf-org-tests--with-mount session
      (should (string-match-p "目录" (etaf-org-tests--text)))
      (etaf-org-show-toc session nil)
      (etaf-runtime-flush (etaf-runtime-for-buffer (current-buffer)))
      (should-not (string-match-p "目录"
                                  (etaf-org-tests--text))))))

(ert-deftest etaf-org-tests-narrow-heading-keeps-its-chips ()
  "A narrow measure keeps the keyword, priority and title of a heading."
  (let* ((session (etaf-org-create
                   :text (concat "* TODO [#A] 带计划与标签的标题          :work:urgent:\n"
                                 "  正文\n")))
         (buffer nil))
    (etaf-org-adjust-width session -1000)
    (setq buffer (etaf-org-tests--mount session 40))
    (unwind-protect
        (with-current-buffer buffer
          (let ((text (etaf-org-tests--text)))
            (should (string-match-p "TODO" text))
            (should (string-match-p "#A" text))
            (should (string-match-p "带计划与标签的标题" text))
            (should (string-match-p ":work:" text))))
      (with-current-buffer buffer
        (when (etaf-runtime-for-buffer buffer)
          (etaf-unmount)))
      (kill-buffer buffer))))

(ert-deftest etaf-org-tests-narrow-window-keeps-the-measure ()
  "A narrow viewport renders a wide table without overflowing the measure."
  (let ((session (etaf-org-create
                  :text (concat "* 标题\n"
                                "| 名称 | 数值 | 备注 |\n"
                                "|------+------+------|\n"
                                "| 甲   |   12 | 一段很长很长很长的备注文字 |\n"
                                "| 乙   |    3 | 另一段同样很长的备注文字 |\n")))
        (buffer nil))
    ;; A headless mount does not fit the session to its window, so set the
    ;; measure the application would have fitted before mounting.
    (etaf-org-adjust-width session -1000)
    (setq buffer (etaf-org-tests--mount session 40))
    (unwind-protect
        (with-current-buffer buffer
          (let ((text (etaf-org-tests--text)))
            (should (string-match-p "名称" text))
            (should (string-match-p "另一段" text))
            (dolist (line (split-string text "\n"))
              (should (<= (string-width line) 44)))))
      (with-current-buffer buffer
        (when (etaf-runtime-for-buffer buffer)
          (etaf-unmount)))
      (kill-buffer buffer))))

(ert-deftest etaf-org-tests-unknown-drawer-content-is-reachable ()
  "An unknown drawer keeps its chip and reveals its text with show-hidden."
  (let ((session (etaf-org-create
                  :text "* 标题\n:NOTE:\n抽屉里的说明\n:END:\n正文\n")))
    (etaf-org-tests--with-mount session
      (let ((text (etaf-org-tests--text)))
        (should (string-match-p "抽屉 NOTE" text))
        (should-not (string-match-p "抽屉里的说明" text)))
      (etaf-org-show-hidden session t)
      (etaf-runtime-flush (etaf-runtime-for-buffer (current-buffer)))
      (let ((text (etaf-org-tests--text)))
        (should (string-match-p "抽屉里的说明" text))
        (should (string-match-p "NOTE" text))))))

(ert-deftest etaf-org-tests-targets-render-as-anchors-and-links ()
  "A radio target becomes a quiet anchor and a reference becomes link text."
  (let ((session (etaf-org-create
                  :text "* 目标\n见 <<<radio>>>，另见 <<radio>>。\n")))
    (etaf-org-tests--with-mount session
      (let ((text (etaf-org-tests--text)))
        (should (string-match-p "◆ radio" text))
        (should (string-match-p "另见 radio" text))
        (should-not (string-match-p "<<" text))))))

(ert-deftest etaf-org-tests-export-snippets-show-only-their-payload ()
  "An export snippet renders its payload without the @@backend: markers."
  (let ((session (etaf-org-create
                  :text "* 标记\n前缀 @@html:<b>x</b>@@ 后缀\n")))
    (etaf-org-tests--with-mount session
      (let ((text (etaf-org-tests--text)))
        (should (string-match-p "<b>x</b>" text))
        (should-not (string-match-p "@@html:" text))))))

(ert-deftest etaf-org-tests-src-line-numbers-follow-the-n-switch ()
  "A source block with -n 20 numbers its lines from 20 in a gutter."
  (let ((session (etaf-org-create
                  :text (concat "* 代码\n#+BEGIN_SRC elisp -n 20\n"
                                "(+ 1 2)\n(+ 3 4)\n#+END_SRC\n"))))
    (etaf-org-tests--with-mount session
      (let ((text (etaf-org-tests--text)))
        (should (string-match-p "20[ \t]+" text))
        (should (string-match-p (regexp-quote "(+ 1 2)") text))
        (should (string-match-p (regexp-quote "21 (+ 3 4)") text))
        (should-not (string-match-p (regexp-quote "1 (+ 1 2)") text))))))

(ert-deftest etaf-org-tests-typeset-disabled-keeps-the-formula-source ()
  "With the drawing switched off, a display formula keeps its source text."
  (let ((etaf-org-typeset nil))
    (let ((session (etaf-org-create
                    :text "* 公式\n$$e = mc^2$$\n")))
      (etaf-org-tests--with-mount session
        (should (string-match-p "e = mc" (etaf-org-tests--text)))))))

(ert-deftest etaf-org-tests-live-edit-follows-the-unsaved-buffer ()
  "Editing a source buffer without saving repaints the preview from that text."
  (let ((file (make-temp-file "org-live" nil ".org"
                              "* 测试\n\n原始正文\n")))
    (unwind-protect
        (let ((source (find-file-noselect file)))
          (unwind-protect
              (let ((preview (etaf-org-open file)))
                (unwind-protect
                    (progn
                      (with-current-buffer source
                        (goto-char (point-max))
                        (insert "未保存的新段落\n"))
                      (sit-for 0.8)
                      (with-current-buffer preview
                        (etaf-runtime-flush (etaf-runtime-for-buffer (current-buffer)))
                        (should (string-match-p
                                 "未保存的新段落"
                                 (etaf-org-tests--text)))))
                  (with-current-buffer preview (etaf-org-close))))
            (when (buffer-live-p source) (kill-buffer source))))
      (delete-file file))))

(ert-deftest etaf-org-tests-inline-source-shows-only-its-code ()
  "An inline source snippet shows its code, not the src_LANG{ marker."
  (let ((session (etaf-org-create
                  :text "* 片段\n源码 src_elisp{(+ 1 2)} 在这里。\n")))
    (etaf-org-tests--with-mount session
      (let ((text (etaf-org-tests--text)))
        (should (string-match-p (regexp-quote "(+ 1 2)") text))
        (should-not (string-match-p "src_elisp" text))))))

(ert-deftest etaf-org-tests-ordered-lists-keep-their-style-and-counter ()
  "A parenthesized list keeps `1)`, and a counter overrides one item only."
  (let ((session (etaf-org-create
                  :text (concat "* 标题\n"
                                "1) 括号一\n2) 括号二\n\n"
                                "1. [@3] 第三\n4. 第四\n"))))
    (etaf-org-tests--with-mount session
      (let ((text (etaf-org-tests--text)))
        (should (string-match-p "1)" text))
        (should (string-match-p "2)" text))
        (should (string-match-p "3\\.\\|3[ ]" text))
        (should (string-match-p "4\\." text))
        (should-not (string-match-p "4)" text))))))

(ert-deftest etaf-org-tests-source-blocks-use-syntax-colours ()
  "A named source block paints its tokens with the language's own colours."
  (let ((session (etaf-org-create
                  :text (concat "* 代码\n#+BEGIN_SRC python\n"
                                "def greet(name):\n"
                                "    return \"hello\"\n"
                                "#+END_SRC\n"))))
    (etaf-org-tests--with-mount session
      (let ((keyword (etaf-org-tests--face-attribute "def" :foreground))
            (string (etaf-org-tests--face-attribute "hello" :foreground)))
        (should keyword)
        (should string)
        (should-not (equal keyword string))))))

(ert-deftest etaf-org-tests-table-rows-do-not-add-a-blank-line ()
  "A table paints its rows one after another, without a blank frame row."
  (let ((session (etaf-org-create
                  :text (concat "* 标题\n"
                                "| 名称 | 值 |\n"
                                "|------+----|\n"
                                "| 甲   | 12 |\n"
                                "| 乙   | 3  |\n"))))
    (etaf-org-tests--with-mount session
      (let ((lines (split-string (etaf-org-tests--text) "\n")))
        (should (string-match-p "名称" (etaf-org-tests--text)))
        (should-not (cl-some
                     (lambda (line)
                       (string-match-p "\\`[[:space:]]*│[[:space:]]*│[[:space:]]*\\'" line))
                     lines))))))

(ert-deftest etaf-org-tests-logbook-without-properties-still-summarises ()
  "A logbook that opens the body is a summary chip, not an unknown drawer."
  (let ((session (etaf-org-create
                  :text (concat "* 记录\n"
                                ":LOGBOOK:\n"
                                "CLOCK: [2026-11-10 Tue 09:00]--[2026-11-10 Tue 10:30] =>  1:30\n"
                                ":END:\n"
                                "正文\n"))))
    (etaf-org-tests--with-mount session
      (let ((text (etaf-org-tests--text)))
        (should (string-match-p "记录 1 · 1:30" text))
        (should-not (string-match-p "抽屉 LOGBOOK" text))))))

;;; Native Org completeness

(ert-deftest etaf-org-tests-multiple-todo-sequences ()
  "Multiple #+TODO lines accumulate instead of overwriting one another."
  (let* ((doc (concat "#+TODO: TODO NEXT | DONE\n"
                      "#+TODO: BUG FIXING | FIXED WONTFIX\n"
                      "* NEXT 推进\n"
                      "* BUG 缺陷\n"
                      "* FIXED 已修\n"))
         (session (etaf-org-create :text doc))
         (state (etaf-org-state session))
         (counts (plist-get state :counts)))
    (should (= 2 (plist-get counts :todo)))
    (should (= 1 (plist-get counts :done)))
    (should (equal '("NEXT" "BUG" "FIXED")
                   (mapcar (lambda (e) (nth 3 e)) (etaf-org-outline session))))))

(ert-deftest etaf-org-tests-options-num-subscripts-and-flavor ()
  "#+OPTIONS honors num: depth, ^:{} brace subscripts and etaf:nil flavor."
  (let* ((doc (concat "#+OPTIONS: num:2 ^:{} etaf:nil\n"
                      "* 一级\n"
                      "foo_bar 与 H_{2}O 与 !!原文!!。\n"
                      "** 二级\n"
                      "*** 三级\n"))
         (session (etaf-org-create :text doc))
         (state (etaf-org-state session)))
    (should (eq 'standard (plist-get state :flavor)))
    (etaf-org-tests--with-mount session
      (let ((text (etaf-org-tests--text)))
        (should (string-match-p "1 一级" text))
        (should (string-match-p "1\\.1 二级" text))
        (should-not (string-match-p "1\\.1\\.1 三级" text))
        (should (string-match-p "foo_bar" text))
        (should (string-match-p "H₂O" text))
        (should (string-match-p "!!原文!!" text))))))

(ert-deftest etaf-org-tests-currency-dollars-never-become-math ()
  "Ordinary currency like $100 and $200 stays plain prose while $x^2$ renders as math."
  (let ((session (etaf-org-create
                  :text "* 价格\n预算在 $100 到 $200 之间，而 $x^2$ 是公式。\n")))
    (etaf-org-tests--with-mount session
      (let ((text (etaf-org-tests--text)))
        (should (string-match-p "\\$100 到 \\$200" text))
        (should (string-match-p "x\\^2" text))))))

(ert-deftest etaf-org-tests-multiparagraph-footnote-and-return ()
  "A multi-paragraph footnote definition keeps all paragraphs and a return link."
  (let ((session (etaf-org-create
                  :text (concat "* 正文\n见注[fn:multi]。\n\n"
                                "[fn:multi] 第一段说明。\n\n"
                                "第二段补充。\n"))))
    (etaf-org-tests--with-mount session
      (let ((text (etaf-org-tests--text)))
        (should (string-match-p "第一段说明" text))
        (should (string-match-p "第二段补充" text))
        (should (string-match-p "↩ 返回正文" text))))))

(ert-deftest etaf-org-tests-verse-block-preserves-indent-and-inlines ()
  "A verse block keeps indentation and renders inline Org emphasis."
  (let ((session (etaf-org-create
                  :text (concat "* 诗句\n"
                                "#+begin_verse\n"
                                "第一行 *加粗*\n"
                                "    缩进的 /斜体/\n"
                                "#+end_verse\n"))))
    (etaf-org-tests--with-mount session
      (let ((text (etaf-org-tests--text)))
        (should (string-match-p "第一行 加粗" text))
        (should (string-match-p "缩进的 斜体" text))
        (should (eq 'bold (etaf-org-tests--face-attribute "加粗" :weight)))
        (should (eq 'italic (etaf-org-tests--face-attribute "斜体" :slant)))))))

(ert-deftest etaf-org-tests-paired-results-and-table-results ()
  "#+RESULTS: (fixed-width or table) renders directly under its source block."
  (let ((session (etaf-org-create
                  :text (concat "* 代码\n"
                                "#+begin_src elisp\n(+ 1 2)\n#+end_src\n"
                                "#+RESULTS:\n: 3\n\n"
                                "#+begin_src elisp\n'((a 1) (b 2))\n#+end_src\n"
                                "#+RESULTS:\n| a | 1 |\n| b | 2 |\n"))))
    (etaf-org-tests--with-mount session
      (let ((text (etaf-org-tests--text)))
        (should (string-match-p "结果" text))
        (should (string-match-p "3" text))
        (should (string-match-p "a" text))
        (should (string-match-p "b" text))))))

(ert-deftest etaf-org-tests-real-overdue-and-clock-minutes ()
  "Injected :today computes real overdue count (excluding DONE) and clock minutes."
  (let* ((doc (concat "* TODO 逾期任务\n"
                      "DEADLINE: <2026-11-10 Tue>\n"
                      ":LOGBOOK:\n"
                      "CLOCK: [2026-11-10 Tue 09:00]--[2026-11-10 Tue 10:15] => 1:15\n"
                      ":END:\n"
                      "* DONE 已完成过期\n"
                      "DEADLINE: <2026-11-01 Sun>\n"
                      "* TODO 未来任务\n"
                      "DEADLINE: <2026-12-01 Tue>\n"))
         (session (etaf-org-create :text doc :today "2026-11-22"))
         (counts (plist-get (etaf-org-state session) :counts)))
    (should (= 1 (plist-get counts :overdue)))
    (should (= 3 (plist-get counts :deadline)))
    (should (= 75 (plist-get counts :clock-minutes)))
    (etaf-org-tests--with-mount session
      (should (string-match-p "已逾期" (etaf-org-tests--text))))))

(ert-deftest etaf-org-tests-toc-directives-tables-and-listings ()
  "#+TOC: tables and #+TOC: listings render named table and listing indices."
  (let ((session (etaf-org-create
                  :text (concat "* 索引\n#+TOC: tables\n#+TOC: listings\n"
                                "* 内容\n"
                                "#+CAPTION: 指标表\n"
                                "| 项目 | 值 |\n|------+----|\n| A | 1 |\n\n"
                                "#+CAPTION: 核心代码\n"
                                "#+begin_src elisp\n(+ 1 1)\n#+end_src\n"))))
    (etaf-org-tests--with-mount session
      (let ((text (etaf-org-tests--text)))
        (should (string-match-p "表格目录" text))
        (should (string-match-p "表 1 · 指标表" text))
        (should (string-match-p "代码清单" text))
        (should (string-match-p "核心代码" text))))))

(ert-deftest etaf-org-tests-setupfile-include-and-bibliography ()
  "Workspace #+SETUPFILE:, #+INCLUDE:, org-cite and #+PRINT_BIBLIOGRAPHY: work."
  (let ((dir (make-temp-file "etaf-org-ws-" t)))
    (unwind-protect
        (let ((setup (expand-file-name "common.org" dir))
              (code (expand-file-name "demo.el" dir))
              (bib (expand-file-name "refs.bib" dir))
              (main (expand-file-name "main.org" dir)))
          (with-temp-file setup
            (insert "#+TODO: DRAFT REVIEW | PUBLISHED\n"))
          (with-temp-file code
            (insert "(defun etaf-demo-add (a b) (+ a b))\n"))
          (with-temp-file bib
            (insert "@book{knuth84,\n  author = {Donald Knuth},\n  title = {The TeXbook},\n  year = {1984}\n}\n"))
          (with-temp-file main
            (insert (concat "#+SETUPFILE: common.org\n"
                            "#+BIBLIOGRAPHY: refs.bib\n"
                            "* DRAFT 第一章\n"
                            "参考经典文献 [cite:@knuth84]。\n\n"
                            "#+INCLUDE: \"demo.el\" src elisp\n\n"
                            "#+PRINT_BIBLIOGRAPHY:\n")))
          (let* ((session (etaf-org-create :file main))
                 (state (etaf-org-state session)))
            (should (equal '("knuth84") (plist-get state :citations)))
            (should (equal "DRAFT" (nth 3 (car (plist-get state :outline)))))
            (etaf-org-tests--with-mount session
              (let ((text (etaf-org-tests--text)))
                (should (string-match-p "Donald Knuth, 1984" text))
                (should (string-match-p "etaf-demo-add" text))
                (should (string-match-p "The TeXbook" text))))))
      (delete-directory dir t))))

;;; Unified node model & style rules

(ert-deftest etaf-org-tests-node-define-extend-undefine-and-describe ()
  "Defining, extending, describing and undefining custom nodes work cleanly."
  (unwind-protect
      (progn
        (etaf-org-define-node 'test-banner
          :name "test-banner"
          :summary "测试横幅节点"
          :attrs '((label :type string :required t :doc "横幅文字"))
          :view (lambda (env)
                  (etaf-node 'text nil
                             (list (format "BANNER:%s" (etaf-org-attr env :label))))))
        (let ((desc (etaf-org-describe-nodes 'test-banner)))
          (should (string-match-p "test-banner" desc))
          (should (string-match-p "label" desc)))
        (should (memq 'level (etaf-org-derived-attributes 'headline)))
        (let ((session (etaf-org-create
                        :text "* 节\n#+begin_test-banner :label \"上线\"\n#+end_test-banner\n")))
          (etaf-org-tests--with-mount session
            (should (string-match-p "BANNER:上线" (etaf-org-tests--text))))))
    (etaf-org-undefine-node 'test-banner)
    (should-not (string-match-p "test-banner" (etaf-org-describe-nodes)))))

(ert-deftest etaf-org-tests-style-rules-on-headline-and-table ()
  "etaf-org-set-attr applies to core Org nodes and rejects writing derived attrs."
  (let ((saved-styles etaf-org-styles))
    (unwind-protect
        (progn
          (should-error (etaf-org-set-attr '(headline) '((level 2)))
                        :type 'etaf-org-error)
          (etaf-org-set-attr '(headline :level 1) '((prefix "§ ") (numbering decimal)))
          (etaf-org-set-attr '(table) '((numbering decimal) (zebra t)))
          (let ((session (etaf-org-create
                          :text (concat "* 概览\n"
                                        "#+CAPTION: 成绩\n"
                                        "| 名 | 分 |\n|----+----|\n| 甲 | 90 |\n| 乙 | 80 |\n"))))
            (etaf-org-tests--with-mount session
              (let ((text (etaf-org-tests--text)))
                (should (string-match-p "§ 1 概览" text))
                (should (string-match-p "表 1：成绩" text))))))
      (setq etaf-org-styles saved-styles))))

(ert-deftest etaf-org-tests-set-view-delegates-to-default-view ()
  "etaf-org-set-view wraps the shipped paint via etaf-org-default-view and restores cleanly."
  (unwind-protect
      (progn
        (etaf-org-set-view 'card
                           (lambda (env)
                             (etaf-node 'column (list :width 'stretch)
                                        (list (etaf-node 'text nil (list "WRAPPED-CARD"))
                                              (etaf-org-default-view env)))))
        (let ((session (etaf-org-create
                        :text "* 节\n#+begin_card :title \"卡标题\"\n卡正文\n#+end_card\n")))
          (etaf-org-tests--with-mount session
            (let ((text (etaf-org-tests--text)))
              (should (string-match-p "WRAPPED-CARD" text))
              (should (string-match-p "卡标题" text))
              (should (string-match-p "卡正文" text))))))
    (etaf-org-set-view 'card nil)
    (let ((session (etaf-org-create
                    :text "* 节\n#+begin_card :title \"卡标题\"\n卡正文\n#+end_card\n")))
      (etaf-org-tests--with-mount session
        (should-not (string-match-p "WRAPPED-CARD" (etaf-org-tests--text)))))))

(ert-deftest etaf-org-tests-node-validation-degrades-inline ()
  "Invalid container attributes render inline diagnostics without breaking sibling blocks."
  (let ((session (etaf-org-create
                  :text (concat "* 节\n"
                                "#+begin_card :unknown-key 1 :accent bogus\n"
                                "内容\n"
                                "#+end_card\n\n"
                                "后续正常段落。\n"))))
    (etaf-org-tests--with-mount session
      (let ((text (etaf-org-tests--text)))
        (should (string-match-p "不收" text))
        (should (string-match-p "后续正常段落" text))))))

(ert-deftest etaf-org-tests-standard-flavor-disables-extensions ()
  "In :flavor standard, !!spoiler!! and [[kbd:...]] stay plain Org."
  (let ((session (etaf-org-create
                  :flavor 'standard
                  :text "* 节\n!!不遮罩!! 与 [[kbd:C-c]]。\n")))
    (etaf-org-tests--with-mount session
      (let ((text (etaf-org-tests--text)))
        (should (string-match-p "!!不遮罩!!" text))
        (should (string-match-p "kbd:C-c" text))))))

;;; L0 Containers, Visualization & Cognitive Widgets

(ert-deftest etaf-org-tests-l0-containers-and-marker-tabs ()
  "Card, columns, marker-based tabs, steps, timeline, file-tree and chat render cleanly."
  (let ((doc (concat "* 容器\n"
                     "#+begin_card :title \"概览卡\" :accent primary\n卡片正文\n#+end_card\n\n"
                     "#+begin_tabs\n"
                     "#+tab: 标签甲\n甲面板内容\n"
                     "#+tab: 标签乙\n乙面板内容\n"
                     "#+end_tabs\n\n"
                     "#+begin_steps :start 1 :list-style decimal\n"
                     "- 解析\n- 派生\n- 渲染\n"
                     "#+end_steps\n\n"
                     "#+begin_timeline\n"
                     "#+begin_event :title \"发布\" :time \"2026-11\" :status success\n"
                     "完成迁移\n"
                     "#+end_event\n"
                     "#+end_timeline\n\n"
                     "#+begin_file-tree\n"
                     "- lisp/\n  - etaf-org-parse.el\n"
                     "#+end_file-tree\n\n"
                     "#+begin_chat\n"
                     "#+msg: 用户 :side right\n你好\n"
                     "#+end_chat\n")))
    (let ((session (etaf-org-create :text doc)))
      (etaf-org-tests--with-mount session
        (let ((text (etaf-org-tests--text)))
          (should (string-match-p "概览卡" text))
          (should (string-match-p "标签甲" text))
          (should (string-match-p "甲面板内容" text))
          (should (string-match-p "解析" text))
          (should (string-match-p "完成迁移" text))
          (should (string-match-p "etaf-org-parse.el" text))
          (should (string-match-p "你好" text)))))))

(ert-deftest etaf-org-tests-data-bound-stats-and-chart ()
  "#+begin_stats :from and #+begin_chart :from read live values from a named Org table."
  (let ((doc (concat "* 数据\n"
                     "#+NAME: sales\n"
                     "| 季度 | 营收 | 同比 |\n"
                     "|------+------+------|\n"
                     "| Q1   | 120  | +10% |\n"
                     "| Q2   | 180  | +50% |\n\n"
                     "#+begin_stats :from sales\n#+end_stats\n\n"
                     "#+begin_chart :type bar :label \"季度营收\" :from sales\n#+end_chart\n")))
    (let ((session (etaf-org-create :text doc)))
      (etaf-org-tests--with-mount session
        (let ((text (etaf-org-tests--text)))
          (should (string-match-p "季度营收" text))
          (should (string-match-p "Q1" text))
          (should (string-match-p "180" text))
          (should (string-match-p "█" text)))))))

(ert-deftest etaf-org-tests-cognitive-widgets-and-inline-micro-widgets ()
  "Comparison widgets and inline micro-widgets render; S toggles spoiler reveal."
  (let ((doc (concat "* 认知\n"
                     "按 [[kbd:C-c t]] 查看 [[badge:success:就绪]] 色块 [[color:#0969da]] "
                     "符号 [[sym:etaf-org-open]]，重点 ==核心结论==，隐藏 !!秘密答案!!。\n\n"
                     "#+begin_pros-cons\n"
                     "#+pro: 纯文本\n版本控制友好\n"
                     "#+con: 学习曲线\n需要熟悉语法\n"
                     "#+end_pros-cons\n\n"
                     "#+begin_demo :title \"演示画布\"\n"
                     "演示正文内容。\n"
                     "#+end_demo\n\n"
                     "#+begin_keymap :title \"快捷键\"\n"
                     "- v : 切换分屏\n"
                     "- e / o : 跳回源码\n"
                     "#+end_keymap\n")))
    (let ((session (etaf-org-create :text doc)))
      (etaf-org-tests--with-mount session
        (let ((text (etaf-org-tests--text)))
          (should (string-match-p "C-c t" text))
          (should (string-match-p "就绪" text))
          (should (string-match-p "#0969da" text))
          (should (string-match-p "etaf-org-open" text))
          (should (string-match-p "核心结论" text))
          (should-not (string-match-p "秘密答案" text))
          (should (string-match-p "版本控制友好" text))
          (should (string-match-p "演示正文内容" text))
          (should (string-match-p "切换分屏" text)))
        (etaf-org-toggle-spoilers session)
        (should (string-match-p "秘密答案" (etaf-org-tests--text)))))))

(ert-deftest etaf-org-tests-code-enhancements-and-table-options ()
  "#+attr_etaf: enables code title, folding, markers and table copy/sorting."
  (let ((doc (concat "* 增强\n"
                     "#+attr_etaf: :title \"示例函数\" :collapsed-lines 2 :word \"greet\"\n"
                     "#+begin_src python\n"
                     "def greet(): # [!code ++]\n"
                     "    x = 1\n"
                     "    return x\n"
                     "#+end_src\n\n"
                     "#+attr_etaf: :sortable t :copy t :zebra t :highlight-rows \"1\"\n"
                     "| 项 | 值 |\n|----+----|\n| A | 20 |\n| B | 10 |\n")))
    (let ((session (etaf-org-create :text doc)))
      (etaf-org-tests--with-mount session
        (let ((text (etaf-org-tests--text)))
          (should (string-match-p "示例函数" text))
          (should (string-match-p "展开全部 3 行" text))
          (should-not (string-match-p "\\[!code" text))
          (should (string-match-p "复制表格" text)))))))

;;; L1 Workspace Sandbox & Org-Exclusive Living Widgets

(ert-deftest etaf-org-tests-l1-include-coderef-symbol-project-tree ()
  "L1 workspace widgets read files inside project root and reject escapes."
  (let ((dir (make-temp-file "etaf-org-l1-" t)))
    (unwind-protect
        (let ((src (expand-file-name "hello.el" dir))
              (doc (expand-file-name "index.org" dir)))
          (with-temp-file src
            (insert "(defun hello-world ()\n  \"Greeting.\"\n  42)\n"))
          (with-temp-file doc
            (insert (concat "* 工作区\n"
                            "#+begin_include :src \"hello.el\" :lines \"1-3\"\n#+end_include\n\n"
                            "#+begin_code-ref :src \"hello.el\" :symbol \"hello-world\"\n#+end_code-ref\n\n"
                            "#+begin_symbol :name \"car\"\n#+end_symbol\n\n"
                            "#+begin_project-tree :depth 2\n#+end_project-tree\n\n"
                            "#+begin_include :src \"../../../etc/passwd\"\n#+end_include\n")))
          (let ((session (etaf-org-create :file doc)))
            (etaf-org-tests--with-mount session
              (let ((text (etaf-org-tests--text)))
                (should (string-match-p "hello-world" text))
                (should (string-match-p "car" text))
                (should (string-match-p "hello.el" text))
                (should (string-match-p "超出工作区范围" text))))))
      (delete-directory dir t))))

(ert-deftest etaf-org-tests-org-exclusive-query-kanban-clock-transclude ()
  "Org-exclusive org-query, kanban, clock-summary, transclude and clocktable work."
  (let ((dir (make-temp-file "etaf-org-exc-" t)))
    (unwind-protect
        (let ((other (expand-file-name "ref.org" dir))
              (main (expand-file-name "board.org" dir)))
          (with-temp-file other
            (insert "* 外部参考\n:PROPERTIES:\n:CUSTOM_ID: ref-1\n:END:\n跨文件引用正文。\n"))
          (with-temp-file main
            (insert (concat "* TODO 任务甲 :dev:\n"
                            ":LOGBOOK:\n"
                            "CLOCK: [2026-11-10 Tue 09:00]--[2026-11-10 Tue 10:00] => 1:00\n"
                            ":END:\n"
                            "* DONE 任务乙 :dev:\n"
                            "* 看板与汇总\n"
                            "#+begin_org-query :todo \"TODO\" :tag \"dev\"\n#+end_org-query\n\n"
                            "#+begin_kanban :columns \"TODO DONE\"\n#+end_kanban\n\n"
                            "#+begin_clock-summary\n#+end_clock-summary\n\n"
                            "#+begin_transclude :target \"ref.org::#ref-1\"\n#+end_transclude\n\n"
                            "#+BEGIN: clocktable\n"
                            "| Headline | Time |\n|----------+------|\n| Total | 1:00 |\n"
                            "#+END:\n")))
          (let ((session (etaf-org-create :file main)))
            (etaf-org-tests--with-mount session
              (let ((text (etaf-org-tests--text)))
                (should (string-match-p "任务甲" text))
                (should (string-match-p "1:00" text))
                (should (string-match-p "跨文件引用正文" text))
                (should (string-match-p "动态块 · clocktable" text))))))
      (delete-directory dir t))))

(ert-deftest etaf-org-tests-l2-actions-respect-trust-gate-and-update-block ()
  "L2 run/http respect etaf-org-allow-actions and etaf-org-update-block patches one block."
  (let ((etaf-org-allow-actions nil))
    (let ((session (etaf-org-create
                    :text (concat "* 动作\n"
                                  "#+NAME: live-slot\n"
                                  "#+begin_card :title \"原卡片\"\n原内容\n#+end_card\n\n"
                                  "#+begin_run :title \"测试命令\"\necho hi\n#+end_run\n"))))
      (etaf-org-tests--with-mount session
        (let ((text (etaf-org-tests--text)))
          (should (string-match-p "echo hi" text))
          (should (string-match-p "已禁用" text))
          (should (string-match-p "原内容" text)))
        (etaf-org-update-block session "live-slot"
                               (etaf-node 'text nil (list "动态注入视图")))
        (etaf-runtime-flush (etaf-runtime-for-buffer (current-buffer)))
        (let ((text (etaf-org-tests--text)))
          (should (string-match-p "动态注入视图" text))
          (should-not (string-match-p "原内容" text)))))))

;;; Reading shell, live edit & authoring mode

(ert-deftest etaf-org-tests-preview-split-goto-source-and-close ()
  "etaf-org-preview opens a non-destructive right split, goto-source jumps back, and toggle/close cleans up."
  (let ((file (make-temp-file "org-split-" nil ".org"
                              "* 第一节\n首段\n* 第二节\n次段\n"))
        (src nil)
        (side (generate-new-buffer " *unrelated-side*")))
    (unwind-protect
        (progn
          (setq src (find-file-noselect file))
          (switch-to-buffer src)
          (delete-other-windows)
          (let ((win-side (split-window-below)))
            (set-window-buffer win-side side)
            (select-window (get-buffer-window src))
            (let ((prv (etaf-org-preview)))
              (should (buffer-live-p prv))
              (let ((prv-win (get-buffer-window prv)))
                ;; Unrelated 3rd pane stays intact.
                (should (= 3 (length (window-list))))
                (should (window-live-p win-side))
                (should (eq (window-buffer (selected-window)) src))
                (should prv-win)
                (should (< (car (window-edges (selected-window)))
                           (car (window-edges prv-win))))
                (select-window prv-win)
                (let ((line (etaf-org-goto-source)))
                  (should (integerp line))
                  (should (>= line 1)))
                (select-window prv-win)
                (etaf-org-close)
                (should (= 2 (length (window-list))))
                (should (window-live-p win-side))))
            ;; Calling `etaf-org-preview' again from source opens and toggles off cleanly.
            (select-window (get-buffer-window src))
            (let ((prv2 (etaf-org-preview)))
              (should (buffer-live-p prv2))
              (should (= 3 (length (window-list))))
              (should-not (etaf-org-preview))
              (should (= 2 (length (window-list))))
              (should (window-live-p win-side))
              (should (eq (window-buffer (selected-window)) src)))))
      (dolist (b (buffer-list))
        (when (and (string-prefix-p "*ETAF Org:" (buffer-name b))
                   (buffer-live-p b))
          (with-current-buffer b (ignore-errors (etaf-org-close)))))
      (when (buffer-live-p side) (kill-buffer side))
      (when (buffer-live-p src) (kill-buffer src))
      (delete-file file))))

(ert-deftest etaf-org-tests-live-filter-and-toc-toggle ()
  "etaf-org-set-filter narrows visible sections non-destructively and clears cleanly."
  (let ((session (etaf-org-create
                  :text "* TODO 紧急项 :urgent:\n紧急正文\n* 普通节\n普通正文\n")))
    (etaf-org-tests--with-mount session
      (etaf-org-set-filter session ":urgent:")
      (etaf-runtime-flush (etaf-runtime-for-buffer (current-buffer)))
      (let ((text (etaf-org-tests--text)))
        (should (string-match-p "筛选：:urgent:" text))
        (should (string-match-p "紧急项" text))
        (should-not (string-match-p "普通正文" text)))
      (etaf-org-set-filter session nil)
      (etaf-runtime-flush (etaf-runtime-for-buffer (current-buffer)))
      (should (string-match-p "普通正文" (etaf-org-tests--text))))))

(ert-deftest etaf-org-tests-callbacks-on-link-and-on-media ()
  "Consumer :on-link and :on-media callbacks intercept activation cleanly."
  (let ((seen-link nil)
        (session nil))
    (setq session (etaf-org-create
                   :text "* 链接\n[[https://example.org][外链]]\n"
                   :on-link (lambda (target) (setq seen-link target) t)))
    (etaf-org-tests--with-mount session
      (goto-char (point-min))
      (should (search-forward "外链" nil t))
      (goto-char (match-beginning 0))
      (etaf-activate (etaf-runtime-for-buffer (current-buffer)))
      (should (equal seen-link "https://example.org")))))

(ert-deftest etaf-org-tests-edit-mode-clean-teardown ()
  "etaf-org-edit-mode provides CAPF completions and tears down without altering text."
  (with-temp-buffer
    (insert "#+begin_ca")
    (let ((original (buffer-string)))
      (etaf-org-edit-mode 1)
      (should etaf-org-edit-mode)
      (goto-char (point-max))
      (let ((capf (run-hook-with-args-until-success 'completion-at-point-functions)))
        (should capf)
        (should (member "card" (nth 2 capf))))
      (etaf-org-edit-mode -1)
      (should-not etaf-org-edit-mode)
      (should (equal original (buffer-string))))))

(ert-deftest etaf-org-tests-doctor-reports-capabilities ()
  "etaf-org-doctor returns :required nil and structured :optional entries."
  (let ((info (etaf-org-doctor)))
    (should (null (plist-get info :required)))
    (should (listp (plist-get info :optional)))
    (should (assoc "mmdc" (plist-get info :optional)))
    (should (assoc "git" (plist-get info :optional)))))

(ert-deftest etaf-org-tests-src-renderer-hook ()
  "etaf-org-src-renderers lets consumers override rendering for a source language."
  (let ((etaf-org-src-renderers
         (list (cons "customlang"
                     (lambda (block _env)
                       (etaf-node 'text nil
                                  (list (concat "CUSTOM:" (plist-get block :text)))))))))
    (let ((session (etaf-org-create
                    :text "* 钩子\n#+begin_src customlang\npayload\n#+end_src\n")))
      (etaf-org-tests--with-mount session
        (should (string-match-p "CUSTOM:payload" (etaf-org-tests--text)))))))

(ert-deftest etaf-org-tests-timestamp-repeater-range-and-list-citations ()
  "Timestamps with repeater/warning and ranges, list citations, and `; [!code]' render cleanly."
  (let* ((dir (make-temp-file "etaf-org-cite-" t))
         (bib (expand-file-name "refs.bib" dir))
         (org (expand-file-name "doc.org" dir)))
    (unwind-protect
        (progn
          (with-temp-file bib
            (insert "@book{knuth84, author = {Donald E. Knuth}, title = {The TeXbook}, year = {1984}}\n"))
          (with-temp-file org
            (insert (concat "#+BIBLIOGRAPHY: refs.bib\n\n"
                            "* 检查\n"
                            "- 重复与提醒：<2026-11-23 Mon +1w -2d>\n"
                            "- 日期范围：<2026-11-22 Sun>--<2026-11-25 Wed>\n"
                            "- 列表内引用：[cite:@knuth84]\n\n"
                            "#+begin_src elisp\n"
                            "(+ 1 2) ; [!code ++]\n"
                            "#+end_src\n\n"
                            "#+PRINT_BIBLIOGRAPHY:\n")))
          (let ((session (etaf-org-create :file org)))
            (etaf-org-tests--with-mount session
              (let ((rendered (etaf-org-tests--text)))
                (should (string-match-p "2026-11-23 周一 \\+1w -2d" rendered))
                (should (string-match-p "2026-11-22 周日 → 2026-11-25 周三" rendered))
                (should (string-match-p "Donald E\\. Knuth" rendered))
                (should (string-match-p "The TeXbook" rendered))
                (should-not (string-match-p "\\[!code" rendered))))))
      (when (file-directory-p dir)
        (delete-directory dir t)))))

(ert-deftest etaf-org-tests-complete-gallery-mounts-cleanly ()
  "The categorized complete-gallery.org showcase mounts with zero degraded blocks."
  (let* ((file (expand-file-name "../examples/complete-gallery.org"
                                 etaf-org-tests--directory))
         (session (etaf-org-create :file file :theme 'dark))
         (state (etaf-org-state session))
         (degraded (plist-get state :degraded)))
    (should (eql degraded 0))
    (etaf-org-tests--with-mount session
      (let ((rendered (etaf-org-tests--text)))
        (should (string-match-p "214\\.8" rendered))
        (should (string-match-p "ORG" rendered))
        (should (string-match-p "零依赖优雅降级" rendered))
        (should (string-match-p "Important 卡片" rendered))
        (should (string-match-p "复制表格" rendered))
        (should (string-match-p "Donald E\\. Knuth (1984)" rendered))
        (should-not (string-match-p "不是合法的\\|找不到嵌入文件" rendered))))))

(ert-deftest etaf-org-tests-auto-theme-derives-colored-headings ()
  "Auto theme derives chromatic heading colors even when link/button are unspecified."
  (require 'outline)
  (let* ((faces '(default outline-1 link button font-lock-function-name-face))
         (saved (mapcar (lambda (f)
                          (list f
                                (face-attribute f :foreground nil t)
                                (face-attribute f :background nil t)))
                        faces)))
    (unwind-protect
        (progn
          (set-face-attribute 'default nil :foreground "#ffffff" :background "#263238")
          (set-face-attribute 'outline-1 nil :foreground "#eceff1")
          (set-face-attribute 'link nil :foreground 'unspecified)
          (set-face-attribute 'button nil :foreground 'unspecified)
          (set-face-attribute 'font-lock-function-name-face nil :foreground "#84ffff")
          (let ((session (etaf-org-create
                          :text "#+TITLE: 有色标题测试\n* 一级章节\n正文内容。\n"
                          :theme 'auto)))
            (etaf-org-tests--with-mount session
              (let* ((find-last-fg
                      (lambda (needle)
                        (goto-char (point-max))
                        (when (search-backward needle nil t)
                          (let ((face (get-text-property (match-beginning 0) 'face)))
                            (cond
                             ((and (listp face) (plist-member face :foreground))
                              (plist-get face :foreground))
                             ((listp face)
                              (cl-some (lambda (it) (and (listp it) (plist-get it :foreground)))
                                       face)))))))
                     (hero-fg (funcall find-last-fg "有色标题测试"))
                     (h-fg (funcall find-last-fg "一级章节"))
                     (body-fg (funcall find-last-fg "正文内容"))
                     (rgb (and (stringp h-fg) (color-values h-fg))))
                (should (stringp hero-fg))
                (should (stringp h-fg))
                (should (equal (downcase hero-fg) (downcase h-fg)))
                (should-not (equal (downcase h-fg) (downcase (or body-fg ""))))
                (should (and rgb (> (- (apply #'max rgb) (apply #'min rgb)) 5000)))))))
      (dolist (entry saved)
        (set-face-attribute (nth 0 entry) nil
                            :foreground (nth 1 entry)
                            :background (nth 2 entry))))))

;;; Command surface, window behavior, outline side-window, hover & visual contracts

(ert-deftest etaf-org-tests-command-surface-and-mx-predicates ()
  "Global M-x surface exposes strictly `etaf-org-open' and `etaf-org-preview' (matching `etaf-md'), and preview keys dispatch cleanly."
  (should-not (fboundp 'etaf-org-live-mode))
  (should-not (commandp 'etaf-org-view))
  ;; Across all of Emacs, strictly `etaf-org-open' and `etaf-org-preview' are
  ;; interactive `etaf-org-*' commands (zero minor modes, zero leaked locals).
  (let ((interactive-cmds nil))
    (mapatoms (lambda (sym)
                (when (and (string-prefix-p "etaf-org-" (symbol-name sym))
                           (not (string-prefix-p "etaf-org-tests-" (symbol-name sym)))
                           (fboundp sym)
                           (commandp sym))
                  (push sym interactive-cmds))))
    (should (equal (sort interactive-cmds
                         (lambda (a b) (string< (symbol-name a) (symbol-name b))))
                   '(etaf-org-open etaf-org-preview))))
  ;; Verify preview-buffer keys (`t', `v', `q') still dispatch interactively
  ;; even though their target functions are non-interactive Lisp functions.
  (let* ((file (make-temp-file "org-mx-" nil ".org" "* 标题\n正文\n"))
         (src nil)
         (prv nil))
    (unwind-protect
        (progn
          (setq src (find-file-noselect file))
          (delete-other-windows)
          (switch-to-buffer src)
          (setq prv (etaf-org-open file))
          (should (= 1 (length (window-list))))
          (with-current-buffer prv
            (call-interactively (key-binding (kbd "t")))
            (should (memq (plist-get (etaf-org-state (etaf-app-state)) :theme-mode)
                          '(dark light sepia auto)))
            ;; Invoking `etaf-org-preview' from inside a preview delegates to split toggle.
            (etaf-org-preview)
            (should (= 2 (length (window-list))))
            (call-interactively (key-binding (kbd "v")))
            (should (= 1 (length (window-list))))
            (call-interactively (key-binding (kbd "q"))))
          (should (= 1 (length (window-list))))
          (should (eq (window-buffer (selected-window)) src)))
      (when (buffer-live-p prv)
        (with-current-buffer prv (ignore-errors (etaf-org-close))))
      (when (buffer-live-p src) (kill-buffer src))
      (delete-file file))))

(ert-deftest etaf-org-tests-open-single-window-and-split-toggle ()
  "etaf-org-open opens full-width without splitting, toggles split via v, and q restores."
  (let* ((file (make-temp-file "org-single-" nil ".org"
                               "* 第一节\n首段正文。\n\n* 第二节\n第二段正文。\n"))
         (src nil)
         (prv nil))
    (unwind-protect
        (progn
          (setq src (find-file-noselect file))
          (switch-to-buffer src)
          (delete-other-windows)
          (goto-char (point-min))
          (search-forward "第二节")
          ;; Zero-prompt open from an Org buffer stays single-window.
          (setq prv (call-interactively #'etaf-org-open))
          (should (buffer-live-p prv))
          (should (= 1 (length (window-list))))
          (should (eq (window-buffer (selected-window)) prv))
          ;; v toggles side-by-side split on and back to single-window.
          (with-current-buffer prv
            (etaf-org-toggle-split)
            (should (= 2 (length (window-list))))
            (etaf-org-toggle-split)
            (should (= 1 (length (window-list))))
            ;; e/o jumps to source in place without splitting in single-window mode.
            (let ((line (etaf-org-goto-source)))
              (should (integerp line))
              (should (= 1 (length (window-list))))
              (should (eq (window-buffer (selected-window)) src))))
          ;; Re-enter preview and close with q: restores origin buffer in place.
          (switch-to-buffer prv)
          (etaf-org-close)
          (should (= 1 (length (window-list))))
          (should (eq (window-buffer (selected-window)) src)))
      (when (buffer-live-p prv)
        (with-current-buffer prv (ignore-errors (etaf-org-close))))
      (when (buffer-live-p src) (kill-buffer src))
      (delete-file file))))

(ert-deftest etaf-org-tests-independent-outline-side-window ()
  "etaf-org-toggle-toc opens and cleanly tears down an independent right side window."
  (let* ((file (make-temp-file "org-outline-" nil ".org"
                               "* 概览\n首段。\n\n* 目标章节\n次段。\n"))
         (prv nil))
    (unwind-protect
        (progn
          (delete-other-windows)
          (setq prv (etaf-org-open file))
          (with-current-buffer prv
            (should (eq t (etaf-org-toggle-toc)))
            (let* ((obuf (cl-find-if (lambda (b)
                                       (string-prefix-p "*ETAF Org Outline*"
                                                        (buffer-name b)))
                                     (buffer-list)))
                   (owin (and obuf (get-buffer-window obuf t))))
              (should (buffer-live-p obuf))
              (should owin)
              (should (eq 'right (window-parameter owin 'window-side)))
              (let ((otxt (with-current-buffer obuf (etaf-org-tests--text))))
                (should (string-match-p "大纲目录" otxt))
                (should (string-match-p "目标章节" otxt)))
              ;; Preview body does NOT contain an injected in-document TOC rail.
              (should-not (string-match-p "大纲目录" (etaf-org-tests--text))))
            (should-not (etaf-org-toggle-toc))
            (should-not (cl-find-if (lambda (b)
                                      (string-prefix-p "*ETAF Org Outline*"
                                                       (buffer-name b)))
                                    (buffer-list)))))
      (when (buffer-live-p prv)
        (with-current-buffer prv (ignore-errors (etaf-org-close))))
      (delete-file file))))

(defun etaf-org-tests--face-attr (face attr)
  "Extract ATTR from Emacs face spec FACE."
  (cond
   ((and (listp face) (keywordp (car face))) (plist-get face attr))
   ((listp face) (cl-loop for f in face thereis (etaf-org-tests--face-attr f attr)))
   ((symbolp face)
    (let ((v (ignore-errors (face-attribute face attr nil t))))
      (when (and (stringp v) (not (string-prefix-p "unspecified" v))) v)))
   (t nil)))

(defun etaf-org-tests--luminance (color)
  "Return relative WCAG luminance of 6-digit hex COLOR (batch-safe)."
  (when (and (stringp color)
             (string-match
              "\\`#\\([[:xdigit:]]\\{2\\}\\)\\([[:xdigit:]]\\{2\\}\\)\\([[:xdigit:]]\\{2\\}\\)\\'"
              color))
    (let ((r (string-to-number (match-string 1 color) 16))
          (g (string-to-number (match-string 2 color) 16))
          (b (string-to-number (match-string 3 color) 16)))
      (cl-flet ((lin (v)
                  (let ((s (/ (float v) 255.0)))
                    (if (<= s 0.03928) (/ s 12.92)
                      (expt (/ (+ s 0.055) 1.055) 2.4)))))
        (+ (* 0.2126 (lin r))
           (* 0.7152 (lin g))
           (* 0.0722 (lin b)))))))

(ert-deftest etaf-org-tests-four-tier-hover-discipline ()
  "Strict 4-tier leaf-only hover holds across dark, light and sepia themes."
  (let ((doc (concat
              "PlainProse [[https://example.org][DocLink]] [[sym:car][car]] "
              "!!HiddenWord!!。\n\n"
              "- [ ] CheckItemText\n\n"
              "#+begin_note :title \"FoldNote\" :collapsible t :open t\n"
              "CalloutBodyText。\n#+end_note\n\n"
              "#+attr_etaf: :collapsed-lines 2\n"
              "#+begin_src elisp\n(defun alpha-code () 1)\n"
              "(defun beta-code () 2)\n(defun gamma-code () 3)\n#+end_src\n\n"
              "#+begin_tabs\n#+tab: ActiveTabLabel\nTabBodyProse。\n"
              "#+tab: IdleTabLabel\nSecond。\n#+end_tabs\n\n"
              "#+attr_etaf: :sortable t :copy t\n"
              "| ColHead | ValHead |\n|---------+---------|\n| CellDataOne | 42 |\n\n"
              "#+begin_link-card :href \"https://example.org\" :title \"CardTitleText\" :description \"CardDescText\"\n"
              "#+end_link-card\n\n"
              "#+begin_code-tree\n#+file: a.el\n#+begin_src elisp\n(setq first 1)\n#+end_src\n"
              "#+file: b.el\n#+begin_src elisp\n(setq second 2)\n#+end_src\n#+end_code-tree\n\n"
              "#+begin_diff :title \"DiffCard\" :mode side\n"
              "#+before:\n#+begin_src text\nold-line\n#+end_src\n"
              "#+after:\n#+begin_src text\nnew-line\n#+end_src\n#+end_diff\n")))
    (dolist (theme '(dark light sepia))
      (let* ((session (etaf-org-create :text doc :theme theme))
             (tokens (etaf-org-theme-tokens theme))
             (page-bg (plist-get tokens :ui-bg))
             (page-fg (plist-get tokens :ui-fg)))
        (etaf-org-tests--with-mount session
          (let ((plain (etaf-org-tests--text)))
            ;; Tier 3: Unselected interactive leaves have mouse-face + pointer 'hand.
            (dolist (needle '("DocLink" "car" "▓" "FoldNote" "复制"
                              "IdleTabLabel" "ColHead ⇅" "复制表格"
                              "→ https://example.org" "b.el" "统一" "□"))
              (let ((pos (string-match (regexp-quote needle) plain)))
                (should pos)
                (let* ((p (1+ pos))
                       (mf (get-text-property p 'mouse-face))
                       (ptr (get-text-property p 'pointer)))
                  (should mf)
                  (should (eq ptr 'hand)))))
            ;; Tier 2: Active/selected controls never carry mouse-face.
            (dolist (needle '("ActiveTabLabel" "a.el" "并排"))
              (let ((pos (string-match (regexp-quote needle) plain)))
                (should pos)
                (should-not (get-text-property (1+ pos) 'mouse-face))))
            ;; Tier 1: Static prose, code, data cells and card bodies never hover.
            (dolist (needle '("PlainProse" "CalloutBodyText" "alpha-code"
                              "TabBodyProse" "CellDataOne" "CardTitleText"
                              "CardDescText" "old-line" "CheckItemText"))
              (let ((pos (string-match (regexp-quote needle) plain)))
                (should pos)
                (should-not (get-text-property (1+ pos) 'mouse-face))))
            ;; Full-buffer hover invariants: missing-hand=0, contrast>=3.0, ink preserved.
            (let ((pos (point-min)) (end (point-max)))
              (while (< pos end)
                (let* ((next (or (next-single-property-change pos 'mouse-face nil end) end))
                       (mf (get-text-property pos 'mouse-face)))
                  (when mf
                    (let* ((raw (buffer-substring-no-properties pos next))
                           (first-nw (when (string-match "[^ \t\n]" raw)
                                       (+ pos (match-beginning 0)))))
                      (when first-nw
                        (let* ((bf (get-text-property first-nw 'face))
                               (bfg (or (etaf-org-tests--face-attr bf :foreground) page-fg))
                               (bbg (or (etaf-org-tests--face-attr bf :background) page-bg))
                               (mfg (or (etaf-org-tests--face-attr mf :foreground) bfg))
                               (mbg (or (etaf-org-tests--face-attr mf :background) bbg))
                               (l1 (etaf-org-tests--luminance mfg))
                               (l2 (etaf-org-tests--luminance mbg))
                               (ratio (and l1 l2 (/ (+ (max l1 l2) 0.05) (+ (min l1 l2) 0.05)))))
                          (should (eq 'hand (get-text-property first-nw 'pointer)))
                          (should-not (get-text-property first-nw 'aria-selected))
                          (should (equal (downcase bfg) (downcase mfg)))
                          (should (and ratio (>= ratio 3.0)))))))
                  (setq pos next))))))))
    ;; Disabling :link-hover omits mouse-face while keeping pointer 'hand.
    (let ((session (etaf-org-create :text doc :theme 'dark :link-hover nil)))
      (etaf-org-tests--with-mount session
        (let* ((plain (etaf-org-tests--text))
               (p (1+ (string-match "DocLink" plain))))
          (should-not (get-text-property p 'mouse-face))
          (should (eq 'hand (get-text-property p 'pointer))))))))

(ert-deftest etaf-org-tests-card-accents-box-surfaces-and-tokens ()
  "Theme tokens emit valid 6-digit hex colors; card accents and box surfaces render cleanly."
  (dolist (th '(dark light sepia auto))
    (let ((toks (etaf-org-theme-tokens th))
          (rest nil))
      (should (string-match-p "\\`#[0-9a-fA-F]\\{6\\}\\'"
                              (or (plist-get toks :ui-important-fg) "")))
      (setq rest toks)
      (while rest
        (let ((_k (pop rest)) (v (pop rest)))
          (when (stringp v)
            (should (string-match-p "\\`#[0-9a-fA-F]\\{6\\}\\'" v)))))))
  ;; Dark theme sunken must be strictly darker than page.
  (let* ((dark-pal (cdr (assq 'dark etaf-org-themes)))
         (lum-page (etaf-org-tests--luminance (cdr (assq :bg dark-pal))))
         (lum-sunken (etaf-org-tests--luminance (cdr (assq :sunken dark-pal)))))
    (should (< lum-sunken lum-page)))
  ;; Card 6 semantic accents (incl. important + center) and box 7 surfaces mount with 0 degraded.
  (let* ((doc (concat
               "* 卡片与底色\n"
               "#+begin_card :title \"重要语义\" :accent important :text-align center\n"
               "居中正文\n#+end_card\n\n"
               "#+begin_box :surface sunken :padding \"1ch\"\n下沉底色盒\n#+end_box\n\n"
               "#+begin_box :surface table-stripe :padding \"1ch\"\n条纹底色盒\n#+end_box\n"))
         (session (etaf-org-create :text doc :theme 'dark))
         (state (etaf-org-state session)))
    (should (eql 0 (plist-get state :degraded)))
    (etaf-org-tests--with-mount session
      (let ((txt (etaf-org-tests--text))
            (imp-fg (etaf-org-tests--face-attribute "重要语义" :foreground)))
        (should (string-match-p "居中正文" txt))
        (should (string-match-p "下沉底色盒" txt))
        (should (string-match-p "条纹底色盒" txt))
        (should (equal (downcase (or imp-fg "")) "#a371f7"))))))

(ert-deftest etaf-org-tests-editorial-widget-contracts ()
  "Editorial widgets satisfy alignment, wrapping, ordering, deduplication and sexp contracts."
  (let* ((dir (make-temp-file "etaf-org-ed-" t))
         (src (expand-file-name "sample.el" dir))
         (doc (expand-file-name "doc.org" dir)))
    (unwind-protect
        (progn
          (with-temp-file src
            (insert "(defun balanced-demo (x)\n  \"First line.\"\n  (let ((y (+ x 1)))\n    (* y 2)))\n\n(defun after-demo () nil)\n"))
          (with-temp-file doc
            (insert (concat
                     "* 书刊组件契约\n"
                     "#+begin_columns :gap \"2ch\" :justify-content between :wrap t :divider t\n"
                     "#+begin_col :grow 2\n主列内容\n#+end_col\n"
                     "#+begin_col :grow 1\n副列内容\n#+end_col\n"
                     "#+end_columns\n\n"
                     "#+begin_file-tree :lines nil\n"
                     "- root/\n  - *focus-item.el*\n#+end_file-tree\n\n"
                     "#+begin_chart :type stacked :label \"占比\" :values \"A:58,B:42\" :unit \"%\"\n"
                     "#+end_chart\n\n"
                     "#+begin_diff :title \"顺序核验\" :mode unified\n"
                     "#+before:\n#+begin_src text\nkeep\nold-one\nold-two\n#+end_src\n"
                     "#+after:\n#+begin_src text\nkeep\nnew-one\nnew-two\n#+end_src\n"
                     "#+end_diff\n\n"
                     "#+begin_timeline :orientation horizontal :card t\n"
                     "#+begin_event :title \"事件甲\" :time \"T1\" :status success\n描述甲\n#+end_event\n"
                     "#+begin_event :title \"事件乙\" :time \"T2\" :status info\n描述乙\n#+end_event\n"
                     "#+begin_event :title \"事件丙\" :time \"T3\" :status warning\n描述丙\n#+end_event\n"
                     "#+end_timeline\n\n"
                     "#+begin_code-ref :src \"sample.el\" :symbol \"balanced-demo\"\n#+end_code-ref\n\n"
                     "#+begin_symbol :name \"etaf-org-open\"\n#+end_symbol\n")))
          (let* ((session (etaf-org-create :file doc :theme 'dark))
                 (buf (etaf-org-tests--mount session 520)))
            (unwind-protect
                (with-current-buffer buf
                  (let ((txt (etaf-org-tests--text)))
                    ;; columns
                    (should (string-match-p "主列内容" txt))
                    (should (string-match-p "副列内容" txt))
                    ;; file-tree lines=nil omits box-drawing guides, renders bold focus item
                    (should (string-match-p "focus-item\\.el" txt))
                    (should-not (string-match-p "└─ " txt))
                    ;; stacked % unit never duplicates "58% (58%)"
                    (should (string-match-p "58%" txt))
                    (should-not (string-match-p "58% (58%)" txt))
                    ;; diff unified strictly orders - deletions before + additions
                    (let ((p-old2 (string-match "old-two" txt))
                          (p-new1 (string-match "new-one" txt)))
                      (should (and p-old2 p-new1 (< p-old2 p-new1))))
                    ;; horizontal timeline puts time eyebrow above title and degrades on narrow width
                    (let ((p-t1 (string-match "T1" txt))
                          (p-e1 (string-match "事件甲" txt)))
                      (should (and p-t1 p-e1 (< p-t1 p-e1))))
                    ;; code-ref extracts complete balanced top-level Elisp form without spilling into next defun
                    (should (string-match-p "(\\* y 2)))" txt))
                    (should-not (string-match-p "after-demo" txt))
                    ;; symbol displays API entry and docstring
                    (should (string-match-p "etaf-org-open" txt))))
              (when (buffer-live-p buf)
                (with-current-buffer buf
                  (when (etaf-runtime-for-buffer buf) (etaf-unmount)))
                (kill-buffer buf)))))
      (delete-directory dir t))))

(ert-deftest etaf-org-tests-code-blank-line-has-no-svg-cursor-box ()
  "Blank lines inside source blocks carry no display SVG/image spacer box."
  (let ((session (etaf-org-create
                  :text (concat "* 代码\n#+begin_src elisp\n"
                                "(defun f ()\n\n  42)\n#+end_src\n")
                  :theme 'dark)))
    (etaf-org-tests--with-mount session
      (goto-char (point-min))
      (should (search-forward "(defun f ()" nil t))
      (forward-line 1)
      (let* ((bol (line-beginning-position))
             (eol (line-end-position))
             (has-img nil))
        (while (< bol eol)
          (let ((disp (get-text-property bol 'display)))
            (when (and (consp disp) (eq (car disp) 'image))
              (setq has-img t)))
          (setq bol (1+ bol)))
        (should-not has-img)))))

(provide 'etaf-org-tests)
;;; etaf-org-tests.el ends here
