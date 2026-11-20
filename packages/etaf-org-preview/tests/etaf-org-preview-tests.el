;;; etaf-org-preview-tests.el --- Acceptance tests for etaf-org-preview -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; Public behavior tests.  Every scenario drives the previewer through the
;; interfaces declared in `etaf-org-preview.el': a session from
;; `etaf-org-preview-create', mounted with `etaf-org-preview-view', inspected
;; through `etaf-org-preview-state' or through the visible buffer text.  No
;; test reaches into the parser or the session plist.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'etaf)
(require 'etaf-ui)
(require 'etaf-org-preview)

(defconst etaf-org-preview-tests--directory
  (file-name-directory (or load-file-name buffer-file-name))
  "Directory of this test file, resolved while it is loaded.")

(defun etaf-org-preview-tests--fixture (name)
  "Return the absolute path of fixture NAME."
  (expand-file-name (concat "fixtures/" name) etaf-org-preview-tests--directory))

(defun etaf-org-preview-tests--sample ()
  "Return the maintained sample document as text."
  (with-temp-buffer
    (insert-file-contents
     (expand-file-name "../examples/sample.org" etaf-org-preview-tests--directory))
    (buffer-string)))

(defun etaf-org-preview-tests--mount (session &optional width)
  "Mount SESSION in a fresh buffer WIDTH wide and return that buffer."
  (etaf-mount (generate-new-buffer " *org-preview-test*")
              (etaf-org-preview-view session)
              (list :viewport-width (or width 900) :viewport-height 60)))

(defmacro etaf-org-preview-tests--with-mount (session &rest body)
  "Mount SESSION, run BODY in its buffer, and always clean up."
  (declare (indent 1) (debug t))
  `(let ((buffer (etaf-org-preview-tests--mount ,session)))
     (unwind-protect
         (with-current-buffer buffer ,@body)
       (when (buffer-live-p buffer)
         (with-current-buffer buffer
           (when (etaf-runtime-for-buffer buffer)
             (etaf-unmount)))
         (kill-buffer buffer)))))

(defun etaf-org-preview-tests--text (&optional buffer)
  "Return the visible text of BUFFER, a string without properties."
  (with-current-buffer (or buffer (current-buffer))
    (buffer-substring-no-properties (point-min) (point-max))))

(defun etaf-org-preview-tests--face-attribute (needle property)
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

(ert-deftest etaf-org-preview-tests-file-title-drops-the-extension ()
  "A document without a title reads as its file name, without the suffix."
  (let ((file (make-temp-file "org-preview-title" nil ".org")))
    (unwind-protect
        (progn
          (with-temp-file file (insert "* 一节\n正文\n"))
          (let ((session (etaf-org-preview-create :file file)))
            (should (equal (plist-get (etaf-org-preview-state session) :title)
                           (file-name-base file)))))
      (delete-file file))))

(ert-deftest etaf-org-preview-tests-metadata-and-counts ()
  "A document reports its own metadata, outline and status counts."
  (let* ((session (etaf-org-preview-create
                   :file (etaf-org-preview-tests--fixture "syntax.org")))
         (state (etaf-org-preview-state session)))
    (should (equal "语法样例" (plist-get state :title)))
    (should (equal "测试作者" (plist-get state :author)))
    (should (equal "第一节 标题" (nth 1 (nth 0 (plist-get state :outline)))))
    (should (equal '("work")
                   (nth 4 (nth 0 (plist-get state :outline)))))
    (should (equal 4 (plist-get state :sections)))
    (should (equal 1 (plist-get (plist-get state :counts) :todo)))
    (should (equal 1 (plist-get (plist-get state :counts) :deadline)))
    (should (equal 0 (plist-get state :degraded)))))

(ert-deftest etaf-org-preview-tests-outline-carries-keyword-priority-tags ()
  "The outline reports the keyword, priority and tags of each headline."
  (let* ((session (etaf-org-preview-create
                   :file (etaf-org-preview-tests--fixture "syntax.org")))
         (child (nth 1 (etaf-org-preview-outline session))))
    (should (equal 2 (nth 0 child)))
    (should (equal "子节" (nth 1 child)))
    (should (equal "TODO" (nth 3 child)))
    (should (equal '("urgent") (nth 4 child)))))

(ert-deftest etaf-org-preview-tests-create-requires-a-source ()
  "Creating a session without a file or text signals the preview's error."
  (should-error (etaf-org-preview-create) :type 'etaf-org-preview-error))

(ert-deftest etaf-org-preview-tests-create-reports-a-missing-file ()
  "An unreadable file names itself in the preview's error."
  (let ((error (should-error (etaf-org-preview-create
                              :file "/nonexistent/org-preview.org")
                             :type 'etaf-org-preview-error)))
    (should (string-match-p "org-preview.org"
                            (error-message-string error)))))

(ert-deftest etaf-org-preview-tests-refresh-rereads-the-file ()
  "Refreshing a file session publishes the file's current content."
  (let* ((file (make-temp-file "org-preview" nil ".org"))
         (session nil)
         (buffer nil))
    (unwind-protect
        (progn
          (with-temp-file file (insert "* 旧标题\n旧正文\n"))
          (setq session (etaf-org-preview-create :file file))
          (setq buffer (etaf-org-preview-tests--mount session))
          (should (string-match-p "旧正文" (etaf-org-preview-tests--text buffer)))
          (with-temp-file file (insert "* 新标题\n新正文\n"))
          (etaf-org-preview-refresh session)
          (etaf-runtime-flush (etaf-runtime-for-buffer buffer))
          (let ((text (etaf-org-preview-tests--text buffer)))
            (should (string-match-p "新正文" text))
            (should-not (string-match-p "旧正文" text))))
      (when (and buffer (buffer-live-p buffer))
        (with-current-buffer buffer
          (when (etaf-runtime-for-buffer buffer)
            (etaf-unmount)))
        (kill-buffer buffer))
      (delete-file file))))

(ert-deftest etaf-org-preview-tests-refresh-keeps-the-document-on-failure ()
  "A failed refresh keeps the last rendered document and reports the error."
  (let* ((file (make-temp-file "org-preview" nil ".org"))
         (session nil))
    (unwind-protect
        (progn
          (with-temp-file file (insert "* 标题\n正文\n"))
          (setq session (etaf-org-preview-create :file file))
          (delete-file file)
          (should-error (etaf-org-preview-refresh session)
                        :type 'etaf-org-preview-error)
          (should (equal '("标题")
                         (mapcar (lambda (entry) (nth 1 entry))
                                 (etaf-org-preview-outline session)))))
      (when (file-exists-p file) (delete-file file)))))

(ert-deftest etaf-org-preview-tests-state-is-detached ()
  "Mutating a state snapshot never reaches the session."
  (let* ((session (etaf-org-preview-create :text "* 标题\n正文\n"))
         (state (etaf-org-preview-state session)))
    (setcar (plist-get state :outline) nil)
    (should (equal 1 (length (etaf-org-preview-outline session))))))

;;; Folding

(ert-deftest etaf-org-preview-tests-fold-hides-the-body ()
  "Folding one section removes its body from the visible buffer."
  (let* ((session (etaf-org-preview-create
                   :text "* 一节\n隐藏的正文\n** 子节\n子正文\n"))
         (id (nth 2 (car (etaf-org-preview-outline session)))))
    (etaf-org-preview-tests--with-mount session
      (should (string-match-p "隐藏的正文" (etaf-org-preview-tests--text)))
      (etaf-org-preview-fold session id 'folded)
      (etaf-runtime-flush (etaf-runtime-for-buffer (current-buffer)))
      (let ((text (etaf-org-preview-tests--text)))
        (should (string-match-p "一节" text))
        (should-not (string-match-p "隐藏的正文" text))
        (should-not (string-match-p "子正文" text)))
      (should (etaf-org-preview-folded-p session id)))))

(ert-deftest etaf-org-preview-tests-children-fold-leaves-subheadings-openable ()
  "A `children' section lists its subheadings, and each one still opens."
  (let* ((session (etaf-org-preview-create
                   :text "* 章\n章正文\n** 节\n节正文\n"))
         (outline (etaf-org-preview-outline session))
         (chapter (nth 2 (car outline)))
         (section (nth 2 (cadr outline))))
    (etaf-org-preview-tests--with-mount session
      (etaf-org-preview-fold session chapter 'children)
      (etaf-runtime-flush (etaf-runtime-for-buffer (current-buffer)))
      (let ((text (etaf-org-preview-tests--text)))
        (should (string-match-p "节" text))
        (should-not (string-match-p "章正文" text))
        (should-not (string-match-p "节正文" text)))
      (etaf-org-preview-fold session section 'open)
      (etaf-runtime-flush (etaf-runtime-for-buffer (current-buffer)))
      (let ((text (etaf-org-preview-tests--text)))
        (should (string-match-p "节正文" text))
        (should-not (string-match-p "章正文" text))))))

(ert-deftest etaf-org-preview-tests-fold-children-keeps-child-headlines ()
  "The `children' state shows child headlines without either body."
  (let* ((session (etaf-org-preview-create
                   :text "* 一节\n父正文\n** 子节\n子正文\n"))
         (id (nth 2 (car (etaf-org-preview-outline session)))))
    (etaf-org-preview-tests--with-mount session
      (etaf-org-preview-fold session id 'children)
      (etaf-runtime-flush (etaf-runtime-for-buffer (current-buffer)))
      (let ((text (etaf-org-preview-tests--text)))
        (should (string-match-p "子节" text))
        (should-not (string-match-p "父正文" text))
        (should-not (string-match-p "子正文" text))))))

(ert-deftest etaf-org-preview-tests-sections-open-by-default ()
  "Every ordinary section body is rendered in the reader."
  (let ((session (etaf-org-preview-create
                  :text "* 一节\n一节正文\n* 二节\n二节正文\n")))
    (etaf-org-preview-tests--with-mount session
      (let ((text (etaf-org-preview-tests--text)))
        (should (string-match-p "一节" text))
        (should (string-match-p "二节" text))
        (should (string-match-p "一节正文" text))
        (should (string-match-p "二节正文" text))))))

(ert-deftest etaf-org-preview-tests-fold-all-updates-every-section ()
  "A global fold writes every section and reports their state."
  (let* ((session (etaf-org-preview-create
                   :file (etaf-org-preview-tests--fixture "syntax.org")))
         (ids (mapcar (lambda (entry) (nth 2 entry))
                      (etaf-org-preview-outline session))))
    (etaf-org-preview-fold-all session 'folded)
    (should (cl-every (lambda (id) (etaf-org-preview-folded-p session id)) ids))
    (etaf-org-preview-fold-all session 'open)
    (should-not (cl-some (lambda (id) (etaf-org-preview-folded-p session id)) ids))))

(ert-deftest etaf-org-preview-tests-fold-unknown-section-errors ()
  "Folding an unknown section or an unknown state signals the preview error."
  (let ((session (etaf-org-preview-create :text "* 一节\n正文\n")))
    (should-error (etaf-org-preview-fold session "missing" 'folded)
                  :type 'etaf-org-preview-error)
    (should-error (etaf-org-preview-fold session "s1" 'sideways)
                  :type 'etaf-org-preview-error)))

(ert-deftest etaf-org-preview-tests-fold-publishes-one-region ()
  "Folding one section publishes a small update rather than the document."
  (let* ((session (etaf-org-preview-create
                   :text (etaf-org-preview-tests--sample)))
         (id (nth 2 (car (etaf-org-preview-outline session)))))
    (etaf-org-preview-tests--with-mount session
      (let ((runtime (etaf-runtime-for-buffer (current-buffer))))
        (etaf-org-preview-fold session id 'folded)
        (etaf-runtime-flush runtime)
        (let ((report (etaf-runtime-update-report runtime)))
          (should report)
          (should (<= (or (plist-get report :edits) 0) 4)))))))

;;; Rendering

(ert-deftest etaf-org-preview-tests-inline-emphasis-and-code-faces ()
  "Emphasis renders its own weight, slant and decoration; code renders mono."
  (let ((session (etaf-org-preview-create
                  :text "* 标题\n*粗* /斜/ _下_ +删+ =逐=\n")))
    (etaf-org-preview-tests--with-mount session
      (should (eq 'bold (etaf-org-preview-tests--face-attribute "粗" :weight)))
      (should (eq 'italic (etaf-org-preview-tests--face-attribute "斜" :slant)))
      (should (etaf-org-preview-tests--face-attribute "删" :strike-through))
      (should (etaf-org-preview-tests--face-attribute "逐" :family))
      (should-not (string-match-p "[*/_+=]" (etaf-org-preview-tests--text))))))

(ert-deftest etaf-org-preview-tests-entities-and-subscripts ()
  "Entities and subscripts render as their Unicode spelling."
  (let ((session (etaf-org-preview-create
                  :text "* 标题\n写成 \\alpha 与 H_2O 与 x^2。\n")))
    (etaf-org-preview-tests--with-mount session
      (let ((text (etaf-org-preview-tests--text)))
        (should (string-match-p "α" text))
        (should (string-match-p "H₂O" text))
        (should (string-match-p "x²" text))))))

(ert-deftest etaf-org-preview-tests-link-stays-in-the-paragraph ()
  "A link renders inline, so the text after it stays on the same line."
  (let ((session (etaf-org-preview-create
                  :text "* 标题\n前文 [[https://example.com][例子]] 后文\n")))
    (etaf-org-preview-tests--with-mount session
      (should (string-match-p "前文 例子 后文"
                              (etaf-org-preview-tests--text))))))

(ert-deftest etaf-org-preview-tests-timestamp-renders-as-a-date ()
  "An active timestamp shows the date, the Chinese weekday and the time."
  (let ((session (etaf-org-preview-create
                  :text "* 标题\n<2026-02-14 Sat 10:00>\n")))
    (etaf-org-preview-tests--with-mount session
      (should (string-match-p "2026-02-14 周六 10:00"
                              (etaf-org-preview-tests--text))))))

(ert-deftest etaf-org-preview-tests-planning-line-shows-both-dates ()
  "SCHEDULED and DEADLINE render on one planning line below the headline."
  (let ((session (etaf-org-preview-create
                  :text (concat "* 任务\n"
                                "SCHEDULED: <2026-02-18 Wed> "
                                "DEADLINE: <2026-02-20 Fri>\n"))))
    (etaf-org-preview-tests--with-mount session
      (let ((text (etaf-org-preview-tests--text)))
        (should (string-match-p "2026-02-18 周三" text))
        (should (string-match-p "2026-02-20 周五" text))))))

(ert-deftest etaf-org-preview-tests-checkbox-states-are-distinct ()
  "The three checkbox states draw three different marks."
  (let ((session (etaf-org-preview-create
                  :text "* 标题\n- [ ] 待办\n- [X] 完成\n- [-] 半程\n")))
    (etaf-org-preview-tests--with-mount session
      (let ((text (etaf-org-preview-tests--text)))
        (should (string-match-p "待" text))
        (should (string-match-p "完" text))
        (should (string-match-p "跳" text))))))

(ert-deftest etaf-org-preview-tests-description-list-keeps-the-term ()
  "A description item renders its term and its description."
  (let ((session (etaf-org-preview-create
                  :text "* 标题\n- 术语 :: 说明文字\n")))
    (etaf-org-preview-tests--with-mount session
      (let ((text (etaf-org-preview-tests--text)))
        (should (string-match-p "术语" text))
        (should (string-match-p "说明文字" text))))))

(ert-deftest etaf-org-preview-tests-table-renders-every-cell ()
  "A table renders its header and body cells."
  (let ((session (etaf-org-preview-create
                  :text (concat "* 标题\n"
                                "| 名称 | 数值 |\n"
                                "|------+------|\n"
                                "| 甲   | 12   |\n"
                                "| 乙   | 3    |\n"))))
    (etaf-org-preview-tests--with-mount session
      (let ((text (etaf-org-preview-tests--text)))
        (dolist (cell '("名称" "数值" "甲" "12" "乙" "3"))
          (should (string-match-p cell text)))))))

(ert-deftest etaf-org-preview-tests-code-block-keeps-its-source ()
  "A source block shows its language and its body text."
  (let ((session (etaf-org-preview-create
                  :text (concat "* 标题\n"
                                "#+BEGIN_SRC elisp\n"
                                "(message \"hi\")\n"
                                "#+END_SRC\n"))))
    (etaf-org-preview-tests--with-mount session
      (let ((text (etaf-org-preview-tests--text)))
        (should (string-match-p "elisp" text))
        (should (string-match-p "(message \"hi\")" text))))))

(ert-deftest etaf-org-preview-tests-callouts-are-initialized-by-kind ()
  "Each callout kind shows a written label instead of its block name."
  (let* ((session (etaf-org-preview-create
                   :file (etaf-org-preview-tests--fixture "syntax.org")))
         (buffer (etaf-org-preview-tests--mount session))
         (text nil))
    (unwind-protect
        (progn
          (setq text (etaf-org-preview-tests--text buffer))
          (should (string-match-p "警告" text))
          (should (string-match-p "引用内容" text))
          (should-not (string-match-p "WARNING" text)))
      (with-current-buffer buffer
        (when (etaf-runtime-for-buffer buffer)
          (etaf-unmount)))
      (kill-buffer buffer))))

(ert-deftest etaf-org-preview-tests-footnotes-are-numbered-and-listed ()
  "A footnote reference gets a number and the footnote is listed at the end."
  (let* ((session (etaf-org-preview-create
                   :file (etaf-org-preview-tests--fixture "syntax.org")))
         (state (etaf-org-preview-state session)))
    (should (equal '("one") (plist-get state :footnotes)))
    (etaf-org-preview-tests--with-mount session
      (let ((text (etaf-org-preview-tests--text)))
        (should (string-match-p "\\[1\\]" text))
        (should (string-match-p "脚注正文" text))))))

(ert-deftest etaf-org-preview-tests-footnotes-in-lists-share-one-sequence ()
  "References inside list items number in document order."
  (let* ((session (etaf-org-preview-create
                   :text (concat "* 一节\n"
                                 "1. 甲[fn:alpha]。\n"
                                 "2. 乙[fn:beta]。\n\n"
                                 "[fn:alpha] 第一个定义。\n\n"
                                 "[fn:beta] 第二个定义。\n")))
         (state (etaf-org-preview-state session)))
    (should (equal (plist-get state :footnotes) '("alpha" "beta")))
    (etaf-org-preview-tests--with-mount session
      (let ((text (etaf-org-preview-tests--text)))
        (should (string-match-p "甲\\[1\\]" text))
        (should (string-match-p "乙\\[2\\]" text))
        (should (string-match-p "第一个定义" text))
        (should (string-match-p "第二个定义" text))))))

(ert-deftest etaf-org-preview-tests-toc-skips-commented-sections ()
  "A COMMENT headline stays out of the table of contents."
  (let ((session (etaf-org-preview-create
                  :text "* 可见\n正文\n* COMMENT 草稿\n隐藏的内容\n")))
    (etaf-org-preview-tests--with-mount session
      (let ((text (etaf-org-preview-tests--text)))
        (with-temp-buffer
          (insert text)
          (goto-char (point-min))
          (should (= 1 (how-many "草稿"))))
        (should-not (string-match-p "隐藏的内容" text))))))

(ert-deftest etaf-org-preview-tests-comments-are-folded-initially ()
  "A COMMENT headline starts folded and reveals its body on request."
  (let* ((session (etaf-org-preview-create
                   :file (etaf-org-preview-tests--fixture "syntax.org")))
         (id (nth 2 (cl-find "注释节" (etaf-org-preview-outline session)
                             :key (lambda (entry) (nth 1 entry))
                             :test #'equal))))
    (should (etaf-org-preview-folded-p session id))
    (etaf-org-preview-tests--with-mount session
      (should-not (string-match-p "注释内容不应出现"
                                  (etaf-org-preview-tests--text)))
      (etaf-org-preview-fold session id 'open)
      (etaf-runtime-flush (etaf-runtime-for-buffer (current-buffer)))
      (should (string-match-p "注释内容不应出现"
                              (etaf-org-preview-tests--text))))))

(ert-deftest etaf-org-preview-tests-unknown-block-counts-as-degraded ()
  "An unclosed block still renders its text and is counted as degraded."
  (let* ((session (etaf-org-preview-create
                   :text "* 标题\n#+BEGIN_SRC\n未闭合的代码\n"))
         (state (etaf-org-preview-state session)))
    (should (equal 1 (plist-get state :degraded)))
    (etaf-org-preview-tests--with-mount session
      (should (string-match-p "未闭合的代码" (etaf-org-preview-tests--text))))))

(ert-deftest etaf-org-preview-tests-missing-image-becomes-a-card ()
  "A link to a missing image renders a card instead of signaling."
  (let ((session (etaf-org-preview-create
                  :text "* 标题\n[[file:missing.png]]\n")))
    (etaf-org-preview-tests--with-mount session
      (should (string-match-p "图片不可用" (etaf-org-preview-tests--text))))))

(ert-deftest etaf-org-preview-tests-heading-navigation-round-trips ()
  "Next and previous heading move between the same two headlines."
  (let ((session (etaf-org-preview-create
                  :text "* 一节\n正文\n* 二节\n正文\n* 三节\n正文\n")))
    (etaf-org-preview-tests--with-mount session
      (goto-char (point-min))
      (etaf-org-preview-next-heading session)
      (let ((first (line-number-at-pos)))
        (should (string-match-p "一节"
                                (buffer-substring-no-properties
                                 (line-beginning-position) (line-end-position))))
        (etaf-org-preview-next-heading session)
        (should (> (line-number-at-pos) first))
        (etaf-org-preview-previous-heading session)
        (should (= (line-number-at-pos) first))))))

(ert-deftest etaf-org-preview-tests-locate-moves-to-the-heading ()
  "Locating an outline entry moves point to that headline's row."
  (let ((session (etaf-org-preview-create
                  :text "* 一节\n一节正文\n* 二节\n二节正文\n")))
    (etaf-org-preview-tests--with-mount session
      (etaf-org-preview-locate session 1)
      (should (string-match-p "二节"
                              (buffer-substring-no-properties
                               (line-beginning-position) (line-end-position))))
      (should (etaf-org-preview-locate session 0))
      (should (string-match-p "一节"
                              (buffer-substring-no-properties
                               (line-beginning-position) (line-end-position)))))))

;;; Display controls

(ert-deftest etaf-org-preview-tests-theme-cycles-and-rejects-unknown ()
  "Cycling selects the next palette; an unknown palette signals the error."
  (let ((session (etaf-org-preview-create :text "* 标题\n正文\n"
                                          :theme 'light)))
    (should (eq 'sepia (etaf-org-preview-cycle-theme session)))
    (should (eq 'sepia (plist-get (etaf-org-preview-state session) :theme)))
    (should (eq 'dark (etaf-org-preview-cycle-theme session)))
    (should-error (etaf-org-preview-set-theme session 'neon)
                  :type 'etaf-org-preview-error)
    (etaf-org-preview-set-theme session 'auto)
    ;; A theme change repaints a mounted document.
    (etaf-org-preview-tests--with-mount session
      (let ((before (etaf-org-preview-tests--text)))
        (etaf-org-preview-cycle-theme session)
        (etaf-runtime-flush (etaf-runtime-for-buffer (current-buffer)))
        (should (equal before (etaf-org-preview-tests--text)))))))

(ert-deftest etaf-org-preview-tests-width-adjust-stays-in-range ()
  "The reading measure is clamped to its configured range."
  (let ((session (etaf-org-preview-create :text "* 标题\n正文\n")))
    (should (= etaf-org-preview-width-max
               (etaf-org-preview-adjust-width session 1000)))
    (should (= etaf-org-preview-width-max
               (etaf-org-preview-adjust-width session 0)))
    (should (= etaf-org-preview-width-min
               (etaf-org-preview-adjust-width session -1000)))))

(ert-deftest etaf-org-preview-tests-toc-toggle-hides-the-contents-card ()
  "Hiding the table of contents removes it from the mounted document."
  (let ((session (etaf-org-preview-create
                  :text "* 一节\n正文\n* 二节\n正文\n" :toc 2)))
    (etaf-org-preview-tests--with-mount session
      (should (string-match-p "目录" (etaf-org-preview-tests--text)))
      (etaf-org-preview-show-toc session nil)
      (etaf-runtime-flush (etaf-runtime-for-buffer (current-buffer)))
      (should-not (string-match-p "目录"
                                  (etaf-org-preview-tests--text))))))

(ert-deftest etaf-org-preview-tests-narrow-heading-keeps-its-chips ()
  "A narrow measure keeps the keyword, priority and title of a heading."
  (let* ((session (etaf-org-preview-create
                   :text (concat "* TODO [#A] 带计划与标签的标题          :work:urgent:\n"
                                 "  正文\n")))
         (buffer nil))
    (etaf-org-preview-adjust-width session -1000)
    (setq buffer (etaf-org-preview-tests--mount session 40))
    (unwind-protect
        (with-current-buffer buffer
          (let ((text (etaf-org-preview-tests--text)))
            (should (string-match-p "TODO" text))
            (should (string-match-p "#A" text))
            (should (string-match-p "带计划与标签的标题" text))
            (should (string-match-p ":work:" text))))
      (with-current-buffer buffer
        (when (etaf-runtime-for-buffer buffer)
          (etaf-unmount)))
      (kill-buffer buffer))))

(ert-deftest etaf-org-preview-tests-narrow-window-keeps-the-measure ()
  "A narrow viewport renders a wide table without overflowing the measure."
  (let ((session (etaf-org-preview-create
                  :text (concat "* 标题\n"
                                "| 名称 | 数值 | 备注 |\n"
                                "|------+------+------|\n"
                                "| 甲   |   12 | 一段很长很长很长的备注文字 |\n"
                                "| 乙   |    3 | 另一段同样很长的备注文字 |\n")))
        (buffer nil))
    ;; A headless mount does not fit the session to its window, so set the
    ;; measure the application would have fitted before mounting.
    (etaf-org-preview-adjust-width session -1000)
    (setq buffer (etaf-org-preview-tests--mount session 40))
    (unwind-protect
        (with-current-buffer buffer
          (let ((text (etaf-org-preview-tests--text)))
            (should (string-match-p "名称" text))
            (should (string-match-p "另一段" text))
            (dolist (line (split-string text "\n"))
              (should (<= (string-width line) 44)))))
      (with-current-buffer buffer
        (when (etaf-runtime-for-buffer buffer)
          (etaf-unmount)))
      (kill-buffer buffer))))

(ert-deftest etaf-org-preview-tests-unknown-drawer-content-is-reachable ()
  "An unknown drawer keeps its chip and reveals its text with show-hidden."
  (let ((session (etaf-org-preview-create
                  :text "* 标题\n:NOTE:\n抽屉里的说明\n:END:\n正文\n")))
    (etaf-org-preview-tests--with-mount session
      (let ((text (etaf-org-preview-tests--text)))
        (should (string-match-p "抽屉 NOTE" text))
        (should-not (string-match-p "抽屉里的说明" text)))
      (etaf-org-preview-show-hidden session t)
      (etaf-runtime-flush (etaf-runtime-for-buffer (current-buffer)))
      (let ((text (etaf-org-preview-tests--text)))
        (should (string-match-p "抽屉里的说明" text))
        (should (string-match-p "NOTE" text))))))

(ert-deftest etaf-org-preview-tests-targets-render-as-anchors-and-links ()
  "A radio target becomes a quiet anchor and a reference becomes link text."
  (let ((session (etaf-org-preview-create
                  :text "* 目标\n见 <<<radio>>>，另见 <<radio>>。\n")))
    (etaf-org-preview-tests--with-mount session
      (let ((text (etaf-org-preview-tests--text)))
        (should (string-match-p "◆ radio" text))
        (should (string-match-p "另见 radio" text))
        (should-not (string-match-p "<<" text))))))

(ert-deftest etaf-org-preview-tests-export-snippets-show-only-their-payload ()
  "An export snippet renders its payload without the @@backend: markers."
  (let ((session (etaf-org-preview-create
                  :text "* 标记\n前缀 @@html:<b>x</b>@@ 后缀\n")))
    (etaf-org-preview-tests--with-mount session
      (let ((text (etaf-org-preview-tests--text)))
        (should (string-match-p "<b>x</b>" text))
        (should-not (string-match-p "@@html:" text))))))

(ert-deftest etaf-org-preview-tests-src-line-numbers-follow-the-n-switch ()
  "A source block with -n 20 numbers its lines from 20 in a gutter."
  (let ((session (etaf-org-preview-create
                  :text (concat "* 代码\n#+BEGIN_SRC elisp -n 20\n"
                                "(+ 1 2)\n(+ 3 4)\n#+END_SRC\n"))))
    (etaf-org-preview-tests--with-mount session
      (let ((text (etaf-org-preview-tests--text)))
        (should (string-match-p "20[ \t]+" text))
        (should (string-match-p (regexp-quote "(+ 1 2)") text))
        (should (string-match-p (regexp-quote "21 (+ 3 4)") text))
        (should-not (string-match-p (regexp-quote "1 (+ 1 2)") text))))))

(ert-deftest etaf-org-preview-tests-typeset-disabled-keeps-the-formula-source ()
  "With the drawing switched off, a display formula keeps its source text."
  (let ((etaf-org-preview-typeset nil))
    (let ((session (etaf-org-preview-create
                    :text "* 公式\n$$e = mc^2$$\n")))
      (etaf-org-preview-tests--with-mount session
        (should (string-match-p "e = mc" (etaf-org-preview-tests--text)))))))

(ert-deftest etaf-org-preview-tests-live-edit-follows-the-unsaved-buffer ()
  "Editing a source buffer without saving repaints the preview from that text."
  (let ((file (make-temp-file "org-preview-live" nil ".org"
                              "* 测试\n\n原始正文\n")))
    (unwind-protect
        (let ((source (find-file-noselect file)))
          (unwind-protect
              (let ((preview (etaf-org-preview-open file)))
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
                                 (etaf-org-preview-tests--text)))))
                  (with-current-buffer preview (etaf-org-preview-close))))
            (when (buffer-live-p source) (kill-buffer source))))
      (delete-file file))))

(ert-deftest etaf-org-preview-tests-inline-source-shows-only-its-code ()
  "An inline source snippet shows its code, not the src_LANG{ marker."
  (let ((session (etaf-org-preview-create
                  :text "* 片段\n源码 src_elisp{(+ 1 2)} 在这里。\n")))
    (etaf-org-preview-tests--with-mount session
      (let ((text (etaf-org-preview-tests--text)))
        (should (string-match-p (regexp-quote "(+ 1 2)") text))
        (should-not (string-match-p "src_elisp" text))))))

(ert-deftest etaf-org-preview-tests-ordered-lists-keep-their-style-and-counter ()
  "A parenthesized list keeps `1)`, and a counter overrides one item only."
  (let ((session (etaf-org-preview-create
                  :text (concat "* 标题\n"
                                "1) 括号一\n2) 括号二\n\n"
                                "1. [@3] 第三\n4. 第四\n"))))
    (etaf-org-preview-tests--with-mount session
      (let ((text (etaf-org-preview-tests--text)))
        (should (string-match-p "1)" text))
        (should (string-match-p "2)" text))
        (should (string-match-p "3\\.\\|3[ ]" text))
        (should (string-match-p "4\\." text))
        (should-not (string-match-p "4)" text))))))

(ert-deftest etaf-org-preview-tests-source-blocks-use-syntax-colours ()
  "A named source block paints its tokens with the language's own colours."
  (let ((session (etaf-org-preview-create
                  :text (concat "* 代码\n#+BEGIN_SRC python\n"
                                "def greet(name):\n"
                                "    return \"hello\"\n"
                                "#+END_SRC\n"))))
    (etaf-org-preview-tests--with-mount session
      (let ((keyword (etaf-org-preview-tests--face-attribute "def" :foreground))
            (string (etaf-org-preview-tests--face-attribute "hello" :foreground)))
        (should keyword)
        (should string)
        (should-not (equal keyword string))))))

(ert-deftest etaf-org-preview-tests-table-rows-do-not-add-a-blank-line ()
  "A table paints its rows one after another, without a blank frame row."
  (let ((session (etaf-org-preview-create
                  :text (concat "* 标题\n"
                                "| 名称 | 值 |\n"
                                "|------+----|\n"
                                "| 甲   | 12 |\n"
                                "| 乙   | 3  |\n"))))
    (etaf-org-preview-tests--with-mount session
      (let ((lines (split-string (etaf-org-preview-tests--text) "\n")))
        (should (string-match-p "名称" (etaf-org-preview-tests--text)))
        (should-not (cl-some
                     (lambda (line)
                       (string-match-p "\\`[[:space:]]*│[[:space:]]*│[[:space:]]*\\'" line))
                     lines))))))

(ert-deftest etaf-org-preview-tests-logbook-without-properties-still-summarises ()
  "A logbook that opens the body is a summary chip, not an unknown drawer."
  (let ((session (etaf-org-preview-create
                  :text (concat "* 记录\n"
                                ":LOGBOOK:\n"
                                "CLOCK: [2026-11-10 Tue 09:00]--[2026-11-10 Tue 10:30] =>  1:30\n"
                                ":END:\n"
                                "正文\n"))))
    (etaf-org-preview-tests--with-mount session
      (let ((text (etaf-org-preview-tests--text)))
        (should (string-match-p "记录 1 · 1:30" text))
        (should-not (string-match-p "抽屉 LOGBOOK" text))))))

(provide 'etaf-org-preview-tests)
;;; etaf-org-preview-tests.el ends here
