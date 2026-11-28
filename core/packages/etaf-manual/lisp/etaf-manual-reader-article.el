;;; etaf-manual-reader-article.el --- Article and example rendering of the manual reader -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; The article layer of the manual reader.  It splits a chapter document into
;; section units, turns definition entries into cards and runnable examples
;; into interactive viewers, and renders everything else through the shared
;; `etaf-ui' markdown renderer.  The example viewer is the document's
;; self-explaining surface: source, live preview and side-by-side modes in one
;; card, with the preview being the real, interactive ETAF View the example
;; builds.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'etaf)
(require 'etaf-ui)
(require 'etaf-manual-reader-style)
(require 'etaf-manual-reader-model)

(declare-function etaf-manual-example-view "etaf-manual" (example))
(declare-function etaf-manual-reader--chapter-cards "etaf-manual-reader-views" (session env))
(declare-function etaf-ui-markdown-view-block "etaf-ui" (block env))
(declare-function etaf-ui-markdown-view-blocks "etaf-ui" (blocks env &optional tight))

(defconst etaf-manual-reader--definition-regexp
  "\\`\\([A-Za-z]+\\): \\([^ \t\n]+\\)\\(?:[ \t]+\\(.*?\\)\\)?[ \t]*\\'"
  "Match the text of a definition heading: KIND, NAME and SIGNATURE.")

(defconst etaf-manual-reader--definition-badges
  '(("Function" . info) ("Macro" . important) ("Variable" . neutral)
    ("Hook" . neutral) ("Error" . danger) ("Component" . success)
    ("Host" . neutral) ("Property" . neutral) ("Style" . neutral)
    ("Token" . warning) ("Syntax" . neutral))
  "Definition kind labels and the badge variant they paint.")

;;;; Sections

(defun etaf-manual-reader--sections (blocks)
  "Split BLOCKS into (HEAD . SECTIONS).
HEAD holds the blocks before the first level-2 or level-3 heading (the
chapter title among them).  SECTIONS is a list of (INDEX . BLOCKS) in
document order, where INDEX counts the chapter's section nodes."
  (let (head sections (current nil) (index -1))
    (dolist (block blocks)
      (if (and (eq (plist-get block :type) 'heading)
               (memq (plist-get block :level) '(2 3)))
          (progn
            (when current
              (push (cons index (nreverse current)) sections))
            (setq current (list block))
            (cl-incf index))
        (if current
            (push block current)
          (push block head))))
    (when current
      (push (cons index (nreverse current)) sections))
    (cons (nreverse head) (nreverse sections))))

(defun etaf-manual-reader--heading-text (block)
  "Return BLOCK's plain heading text."
  (string-trim
   (mapconcat (lambda (node)
                (or (plist-get node :text) ""))
              (plist-get block :children)
              "")))

;;;; Rendering environment

(defun etaf-manual-reader--doc-env (env)
  "Return ENV adapted for the shared markdown renderer."
  (list :palette (plist-get env :palette)
        :features (plist-get env :markdown-features)
        :open-link (plist-get env :open-link)
        :footnote-jump (plist-get env :footnote-jump)
        :render-code-block #'etaf-manual-reader--render-code-block
        :code-link (when-let* ((reader (plist-get env :reader)))
                     (etaf-manual-reader--code-link-callback reader))
        :reader (plist-get env :reader)
        :line-grid t))

(defun etaf-manual-reader--code-link-callback (session)
  "Return SESSION's code-span linking callback.
A code span whose text names a definition entry links to that entry, so
RET and a click over the span open the definition."
  (let ((table (etaf-manual-reader--definition-table session)))
    (lambda (text)
      (when (gethash text table)
        (cons (format "manual-symbol:%s" text)
              (format "查看定义：%s" text))))))

(defun etaf-manual-reader--code-pane (env text &optional language)
  "Return the source pane for TEXT with optional LANGUAGE tag.
The tag sits on the pane's first line, right-aligned, so the pane needs no
caption row of its own."
  (etaf-node 'column
             (list :width 'stretch
                   :item-gap '(lh 0)
                   :background-color (etaf-manual-reader--color env :code-bg)
                   :box-sizing 'border-box
                   :padding-top (if language '(lh 0) '(lh 1))
                   :padding-bottom '(lh 1)
                   :padding-left '(ch 2)
                   :padding-right '(ch 2))
             (append
              (when language
                (list (etaf-node 'flex
                                 (list :width 'stretch :justify-content 'flex-end)
                                 (list (etaf-manual-reader--label env language)))))
              (list (etaf-node 'box
                               (list :width 'stretch :wrap-mode 'char)
                               (list (etaf-node 'text
                                                (list :font-family (etaf-manual-reader--mono-family)
                                                      :color (etaf-manual-reader--color env :ink))
                                                (list text))))))))

;;;; Example viewer

(defun etaf-manual-reader--run-example (example result &optional code)
  "Evaluate EXAMPLE, with CODE when given, into RESULT as View or error."
  (let ((example (if (and code (not (equal code (plist-get example :code))))
                     (plist-put (copy-sequence example) :code code)
                   example)))
    (condition-case error
        (etaf-set-value result (list :view (etaf-manual-example-view example)))
      (error (etaf-set-value result (list :error (error-message-string error)))))))

(defun etaf-manual-reader--example-code (session example)
  "Return EXAMPLE's current source in SESSION: its draft when edited."
  (or (cdr (assoc (plist-get example :id)
                  (etaf-value (etaf-manual-reader--ref session :drafts))))
      (plist-get example :code)))

(defun etaf-manual-reader--submit-example (session example result code)
  "Store CODE as EXAMPLE's draft in SESSION and run it into RESULT."
  (let* ((id (plist-get example :id))
         (ref (etaf-manual-reader--ref session :drafts)))
    (etaf-set-value ref (cons (cons id code)
                              (assoc-delete-all id (etaf-value ref) #'equal))))
  (etaf-manual-reader--run-example example result code))

(defun etaf-manual-reader--example-editor (session example result code env)
  "Return EXAMPLE's native editing surface in SESSION, backed by RESULT.
C-c C-c submits the field text: it becomes the example's draft and the
example reruns in place."
  (etaf-node 'column
             (list :width 'stretch :item-gap '(lh 0))
             (list
              (etaf-node 'flex
                         (list :width 'stretch :justify-content 'flex-end)
                         (list (etaf-manual-reader--label env "C-c C-c 运行")))
              (etaf-node 'box
                         (list :width 'stretch
                               :font-family (etaf-manual-reader--mono-family))
                         (list (etaf-node 'etaf-text-input
                                          (list :value code
                                                :rows (max 4 (1+ (cl-count ?\n code)))
                                                :variant 'plain
                                                :ref (intern (format "etaf-manual-example-edit-%s"
                                                                     (plist-get example :id)))
                                                :on-submit
                                                (lambda (text)
                                                  (etaf-manual-reader--submit-example
                                                   session example result text)))
                                          nil))))))

(defun etaf-manual-reader--example-preview (example result code)
  "Return the preview surface of EXAMPLE with CODE backed by RESULT."
  (let ((outcome (etaf-value result)))
    (cond
     ((plist-get outcome :view)
      (etaf-node 'box
                 (list :width 'stretch :box-sizing 'border-box
                       :min-height '(lh 4)
                       :padding '((lh 1) (ch 2)))
                 (list (plist-get outcome :view))))
     ((plist-get outcome :error)
      (etaf-node 'etaf-alert
                 (list :title "示例运行失败"
                       :message (plist-get outcome :error)
                       :variant 'danger)
                 nil))
     (t
      (etaf-node 'etaf-empty
                 (list :title "尚未运行"
                       :description "运行示例，这里会出现真实的 ETAF 界面。"
                       :action-label "▶ 运行"
                       :on-action (lambda ()
                                    (etaf-manual-reader--run-example example result code)))
                 nil)))))

(etaf-define-component etaf-manual-reader--example
    (&key example env)
  "Render one runnable EXAMPLE with source, preview and split modes.
The toolbar edits the source: a submitted text becomes the example's draft,
reruns it in place and is what `etaf-manual-reader-code-at' copies."
  :bindings ((mode (etaf-ref "preview" :name 'etaf-manual-example-mode))
             (result (etaf-ref nil :name 'etaf-manual-example-result)))
  :render
  (let* ((session (plist-get env :reader))
         (selected (etaf-value mode))
         (id (plist-get example :id))
         (editing (and session
                       (equal id (etaf-value (etaf-manual-reader--ref session :editing)))))
         ;; Editing always shows the editor beside the preview.
         (current (if editing "split" selected))
         (run-ref (intern (format "etaf-manual-example-run-%s" id)))
         (stop-ref (intern (format "etaf-manual-example-stop-%s" id)))
         (source (if session
                     (etaf-manual-reader--example-code session example)
                   (plist-get example :code)))
         (language (or (plist-get example :language) "elisp"))
         (code (if (and editing session)
                   (etaf-manual-reader--example-editor session example result source env)
                 (etaf-manual-reader--code-pane env source language)))
         (preview (etaf-manual-reader--example-preview example result source))
         (running (etaf-value result))
         (toolbar
          (etaf-node 'flex
                     (list :width 'stretch
                           :flex-direction 'row
                           :flex-wrap 'wrap
                           :justify-content 'space-between
                           :background-color (etaf-manual-reader--color env :panel2)
                           :border-bottom (etaf-manual-reader--border env)
                           :box-sizing 'border-box
                           :padding '((lh 0) (ch 1))
                           :column-gap '(ch 2)
                           :row-gap '(lh 0)
                           :align-items 'center)
                     (list
                      ;; Title and view tabs; the action buttons wrap below them
                      ;; as a group when the article is narrow, never inside a
                      ;; button.
                      (etaf-node 'flex
                                 (list :flex-direction 'row
                                       :align-items 'center
                                       :column-gap '(ch 2)
                                       :min-width '(px 0))
                                 (list
                                  (etaf-manual-reader--label
                                   env (format "示例 · %s" (plist-get example :id)))
                                  ;; The Tabs strip stretches to its own row; a
                                  ;; max-content wrapper keeps that row's width
                                  ;; out of the toolbar's wrap decision.
                                  (etaf-node 'box
                                             (list :width 'max-content :flex-shrink 0)
                                             (list
                                              (etaf-node 'etaf-tabs
                                                         (list :items (list (list :key "source" :label "源码"
                                                                                  :ref (intern (format "etaf-manual-example-source-%s" id)))
                                                                            (list :key "preview" :label "预览"
                                                                                  :ref (intern (format "etaf-manual-example-preview-%s" id)))
                                                                            (list :key "split" :label "并排"
                                                                                  :ref (intern (format "etaf-manual-example-split-%s" id))))
                                                               :active current
                                                               :variant 'underline
                                                               :width 'max-content
                                                               :on-change (lambda (key) (etaf-set-value mode key)))
                                                         nil)))))
                      (etaf-node 'flex
                                 (list :flex-direction 'row
                                       :align-items 'center
                                       :column-gap '(ch 2)
                                       :flex-shrink 0)
                                 (list
                                  (when session
                                    (etaf-node 'etaf-button
                                               (list :ref (intern (format "etaf-manual-example-edit-button-%s" id))
                                                     :label (if editing "完成" "编辑")
                                                     :variant 'ghost
                                                     :on-press (lambda ()
                                                                 (etaf-set-value
                                                                  (etaf-manual-reader--ref session :editing)
                                                                  (unless editing id))))
                                               nil))
                                  (etaf-node 'etaf-button
                                             (list :ref run-ref
                                                   :label "▶ 运行"
                                                   :variant 'primary
                                                   :on-press (lambda ()
                                                               (etaf-manual-reader--run-example
                                                                example result source)))
                                             nil)
                                  ;; The stop control keeps its slot while idle so
                                  ;; starting an example never changes the
                                  ;; toolbar's width or height.
                                  (etaf-node 'etaf-button
                                             (list :ref stop-ref
                                                   :label "■ 停止"
                                                   :variant 'ghost
                                                   :disabled (not running)
                                                   :on-press (lambda () (etaf-set-value result nil)))
                                             nil))))))
         (content
          (pcase current
            ("source" (list code))
            ("preview" (list (etaf-node 'box
                                       (list :width 'stretch
                                             :box-sizing 'border-box
                                             :padding '((lh 1) (ch 2)))
                                       (list preview))))
            (_ (list
                (etaf-node 'flex
                           (list :width 'stretch
                                 :flex-wrap 'wrap
                                 :align-items 'flex-start
                                 :gap '((lh 1) (ch 2)))
                           (list
                            (etaf-node 'column
                                       (list :flex-grow 1 :flex-basis '(ch 40)
                                             :min-width '(ch 32)
                                             :item-gap '(lh 0))
                                       (list
                                        (etaf-manual-reader--label env "源码")
                                        code))
                            (etaf-node 'column
                                       (list :flex-grow 1 :flex-basis '(ch 40)
                                             :min-width '(ch 32)
                                             :item-gap '(lh 0))
                                       (list
                                        (etaf-manual-reader--label env "预览")
                                        preview)))))))))
    (etaf-node 'column
               (list :ref (intern (format "etaf-manual-example-%s" id))
                     :width 'stretch
                     :background-color (etaf-manual-reader--color env :panel)
                     :border (etaf-manual-reader--border env)
                     :box-sizing 'border-box
                     :item-gap '(lh 0)
                     :tab-index 0
                     :on-focus-enter (lambda ()
                                       (when session
                                         (etaf-set-value
                                          (etaf-manual-reader--ref session :focus)
                                          (list :example id)))))
               (list toolbar
                     (etaf-node 'column
                                (list :width 'stretch :item-gap '(lh 0))
                                content)))))

(defun etaf-manual-reader--example-viewer (example env)
  "Return the viewer View for EXAMPLE in ENV."
  (etaf-node 'etaf-manual-reader--example
             (list :example example :env env)
             nil))

;;;; Inline figures

(defun etaf-manual-reader--figure-outcome (figure)
  "Evaluate FIGURE once and return (:view VIEW) or (:error MESSAGE)."
  (condition-case error
      (list :view (etaf-manual-example-view figure))
    (error (list :error (error-message-string error)))))

(etaf-define-component etaf-manual-reader--figure (&key figure env)
  "Render a static FIGURE from the manual inline, without run controls.
The figure is evaluated once when its View is created; a failure shows an
alert in place of the rendered View, so one broken figure cannot break the
chapter."
  :bindings ((outcome (etaf-ref nil :name 'etaf-manual-figure-outcome)))
  :setup
  (etaf-set-value outcome (etaf-manual-reader--figure-outcome figure))
  :render
  (let ((label (format "图 · %s" (or (plist-get figure :caption)
                                     (plist-get figure :id))))
        (result (etaf-value outcome)))
    (etaf-node 'column
               (list :ref (intern (format "etaf-manual-figure-%s"
                                          (plist-get figure :id)))
                     :width 'stretch
                     :box-sizing 'border-box
                     :background-color (etaf-manual-reader--color env :panel)
                     :border (etaf-manual-reader--border env)
                     :item-gap '(lh 0))
               (list
                (etaf-node 'flex
                           (list :width 'stretch
                                 :box-sizing 'border-box
                                 :padding '((lh 0) (ch 1))
                                 :background-color (etaf-manual-reader--color env :panel2)
                                 :border-bottom (etaf-manual-reader--border env)
                                 :align-items 'center)
                           (list (etaf-manual-reader--label env label)))
                (etaf-node 'box
                           (list :width 'stretch
                                 :box-sizing 'border-box
                                 :min-height '(lh 2)
                                 :padding '((lh 1) (ch 2)))
                           (list (if-let* ((view (plist-get result :view)))
                                     view
                                   (etaf-node 'etaf-alert
                                              (list :title "插图渲染失败"
                                                    :message (plist-get result :error)
                                                    :variant 'danger)
                                              nil))))))))

(defun etaf-manual-reader--figure-viewer (figure env)
  "Return the composed figure View for FIGURE in ENV."
  (etaf-node 'etaf-manual-reader--figure (list :figure figure :env env) nil))

;;;; Code blocks

(defun etaf-manual-reader--render-code-block (block env)
  "Return the reader's View for a static fenced BLOCK in ENV.
The block is focusable, so `w' copies it, and its header carries a copy
button beside the language tag."
  (let* ((reader (plist-get env :reader))
         (text (or (plist-get block :text) ""))
         (language (plist-get block :lang))
         (mono (etaf-manual-reader--mono-family)))
    (etaf-node 'box
               (list :width 'stretch
                     :box-sizing 'border-box
                     :background-color (etaf-manual-reader--color env :code-bg)
                     :border (etaf-manual-reader--border env)
                     :padding '((lh 1) (ch 2))
                     :tab-index 0
                     :hover-style (etaf-manual-reader--hover env)
                     :on-focus-enter (lambda ()
                                       (when reader
                                         (etaf-set-value
                                          (etaf-manual-reader--ref reader :focus)
                                          (list :code text)))))
               (list
                (etaf-node 'flex
                           (list :width 'stretch
                                 :justify-content 'space-between
                                 :align-items 'center)
                           (list
                            (if language
                                (etaf-manual-reader--label env language)
                              (etaf-node 'box nil nil))
                            (etaf-node 'etaf-button
                                       (list :label "复制"
                                             :variant 'ghost
                                             :on-press
                                             (lambda ()
                                               (kill-new text)
                                               (when reader
                                                 (etaf-manual-reader-message
                                                  reader "已复制代码"))))
                                       nil)))
                (etaf-node 'box
                           (list :width 'stretch :wrap-mode 'char
                                 :font-family mono
                                 :color (etaf-manual-reader--color env :ink))
                           (list (etaf-node 'text nil (list text))))))))

;;;; Example and code targeting

(defun etaf-manual-reader--example-by-id (session id)
  "Return SESSION's current chapter example with ID, or nil."
  (cl-find id (etaf-manual-reader--chapter-examples session)
           :key (lambda (example) (plist-get example :id)) :test #'equal))

(defun etaf-manual-reader--focused-example (session)
  "Return SESSION's example that most recently held focus, or nil."
  (when-let* ((id (plist-get (etaf-manual-reader--read session :focus) :example)))
    (etaf-manual-reader--example-by-id session id)))

(defun etaf-manual-reader--section-blocks (session)
  "Return the blocks of SESSION's current section."
  (let* ((document (etaf-manual-reader-document session))
         (split (etaf-manual-reader--chapter-cache
                 session 'sections
                 (lambda () (etaf-manual-reader--sections (plist-get document :children)))))
         (node (etaf-manual-reader--read session :node)))
    (if node (cdr (nth node (cdr split))) (car split))))

(defun etaf-manual-reader--section-example (session)
  "Return the first runnable example of SESSION's current section, or nil."
  (let ((table (etaf-manual-reader--example-table session)))
    (cl-loop for block in (etaf-manual-reader--section-blocks session)
             when (etaf-manual-reader--run-block-p block)
             thereis (gethash block table))))

(defun etaf-manual-reader--section-code (session)
  "Return the source of the first code block of SESSION's current section."
  (let ((table (etaf-manual-reader--example-table session)))
    (cl-loop for block in (etaf-manual-reader--section-blocks session)
             when (eq (plist-get block :type) 'code-block)
             thereis (if-let* ((example (gethash block table)))
                       (etaf-manual-reader--example-code session example)
                     (plist-get block :text)))))

(defun etaf-manual-reader--example-at (session)
  "Return the example of SESSION to edit, or nil.
Prefer the example that most recently held focus, then the first runnable
example of the current section."
  (or (etaf-manual-reader--focused-example session)
      (etaf-manual-reader--section-example session)))

(defun etaf-manual-reader--code-at (session)
  "Return the code text SESSION's reading position points at, or nil.
Prefer the focused code block, then the focused example's source, then the
first code block of the current section."
  (let ((focus (etaf-manual-reader--read session :focus)))
    (cond
     ((plist-get focus :code) (plist-get focus :code))
     ((plist-get focus :example)
      (when-let* ((example (etaf-manual-reader--example-by-id
                            session (plist-get focus :example))))
        (etaf-manual-reader--example-code session example)))
     (t (etaf-manual-reader--section-code session)))))

;;;; Definition cards

(defun etaf-manual-reader--definition-parts (heading)
  "Return (KIND NAME SIGNATURE) from a level-4 definition HEADING, or nil."
  (let ((text (etaf-manual-reader--heading-text heading)))
    (when (string-match etaf-manual-reader--definition-regexp text)
      (list (match-string 1 text)
            (match-string 2 text)
            (or (match-string 3 text) "")))))

(defun etaf-manual-reader--definition-card (definition-heading blocks env)
  "Return the card View for a definition entry.
DEFINITION-HEADING is the level-4 heading block and BLOCKS its body blocks."
  (pcase-let* ((`(,kind ,name ,signature)
                (etaf-manual-reader--definition-parts definition-heading))
               (badge (or (cdr (assoc kind etaf-manual-reader--definition-badges))
                          'neutral))
               (ref (intern (format "etaf-manual-definition-%s" name))))
    (etaf-node 'box
               (list :ref ref
                     :width 'stretch
                     :background-color (etaf-manual-reader--color env :panel)
                     :border-left (list '(px 3) 'solid
                                        (etaf-manual-reader--color env :accent))
                     :box-sizing 'border-box
                     :padding etaf-manual-reader--card-pad)
               (append
                (list
                 (etaf-node 'row
                            (list :width 'stretch
                                  :item-gap '(ch 2)
                                  :cross-align 'center)
                            (list
                             (etaf-node 'etaf-badge
                                        (list :text kind :variant badge)
                                        nil)
                             (etaf-node 'text
                                        (list :font-weight 'bold
                                              :color (etaf-manual-reader--color env :heading))
                                        (list name)))))
                (when (and signature (not (string-empty-p signature)))
                  (list (etaf-node 'text
                                   (list :font-family (etaf-manual-reader--mono-family)
                                         :color (etaf-manual-reader--color env :muted))
                                   (list signature))))
                (when blocks
                  (list (etaf-manual-reader--spacer)))
                (etaf-manual-reader--body-views blocks env)))))

(defun etaf-manual-reader--body-views (blocks env)
  "Return the Views of a definition's body BLOCKS in ENV.
Static blocks keep the markdown rhythm; a runnable example becomes its
viewer, separated from its neighbors by one blank line."
  (let (views static)
    (cl-flet ((flush ()
                (when static
                  (when views (push (etaf-manual-reader--spacer) views))
                  (dolist (view (etaf-ui-markdown-view-blocks
                                 (nreverse static)
                                 (etaf-manual-reader--doc-env env)))
                    (push view views))
                  (setq static nil))))
      (dolist (block blocks)
        (cond
         ((etaf-manual-reader--block-example block env)
          (flush)
          (when views (push (etaf-manual-reader--spacer) views))
          (push (etaf-manual-reader--example-viewer
                 (etaf-manual-reader--block-example block env) env)
                views))
         ((etaf-manual-reader--block-figure block env)
          (flush)
          (when views (push (etaf-manual-reader--spacer) views))
          (push (etaf-manual-reader--figure-viewer
                 (etaf-manual-reader--block-figure block env) env)
                views))
         (t (push block static))))
      (flush))
    (nreverse views)))

;;;; Article flow

(defun etaf-manual-reader--run-block-p (block)
  "Return non-nil when BLOCK is a runnable `elisp :run' code block."
  (and (eq (plist-get block :type) 'code-block)
       (equal (plist-get block :lang) "elisp")
       (member ":run" (split-string (or (plist-get block :info) "")))))

(defun etaf-manual-reader--figure-block-p (block)
  "Return non-nil when BLOCK is an inline `elisp :figure' code block."
  (and (eq (plist-get block :type) 'code-block)
       (equal (plist-get block :lang) "elisp")
       (member ":figure" (split-string (or (plist-get block :info) "")))))

(defun etaf-manual-reader--figure-table (session)
  "Return SESSION's current chapter table from `:figure' blocks to figures.
The Nth figure block of the document is the chapter's Nth figure; the
table is built once per chapter and language and compared by identity."
  (etaf-manual-reader--chapter-cache
   session 'figures
   (lambda ()
     (let ((table (make-hash-table :test #'eq))
           (figures (etaf-manual-reader--chapter-figures session)))
       (dolist (block (plist-get (etaf-manual-reader-document session) :children))
         (when (and figures (etaf-manual-reader--figure-block-p block))
           (puthash block (pop figures) table)))
       table))))

(defun etaf-manual-reader--example-table (session)
  "Return SESSION's current chapter table from run blocks to examples.
The Nth runnable block of the document is the chapter's Nth example; the
table is built once per chapter and language and compared by identity."
  (etaf-manual-reader--chapter-cache
   session 'examples
   (lambda ()
     (let ((table (make-hash-table :test 'eq))
           (examples (etaf-manual-reader--chapter-examples session)))
       (dolist (block (plist-get (etaf-manual-reader-document session) :children))
         (when (and examples (etaf-manual-reader--run-block-p block))
           (puthash block (pop examples) table)))
       table))))

(defun etaf-manual-reader--block-example (block env)
  "Return the runnable example BLOCK presents in ENV, or nil."
  (when-let* ((table (plist-get env :examples)))
    (gethash block table)))

(defun etaf-manual-reader--block-figure (block env)
  "Return the inline figure BLOCK presents in ENV, or nil."
  (when-let* ((table (plist-get env :figures)))
    (gethash block table)))

(defun etaf-manual-reader--ordinary-view (block env)
  "Return the View for an ordinary BLOCK in ENV, or its viewer."
  (cond
   ((etaf-manual-reader--block-example block env)
    (etaf-manual-reader--example-viewer
     (etaf-manual-reader--block-example block env) env))
   ((etaf-manual-reader--block-figure block env)
    (etaf-manual-reader--figure-viewer
     (etaf-manual-reader--block-figure block env) env))
   (t (etaf-ui-markdown-view-block block (etaf-manual-reader--doc-env env)))))

(defun etaf-manual-reader--render-blocks (blocks env)
  "Render BLOCKS in ENV with definition cards and example viewers."
  (let (nodes)
    (while blocks
      (let ((block (pop blocks)))
        (if (and (eq (plist-get block :type) 'heading)
                 (= (plist-get block :level) 4)
                 (etaf-manual-reader--definition-parts block))
            (let (body)
              (while (and blocks
                          (not (eq (plist-get (car blocks) :type) 'heading)))
                (push (pop blocks) body))
              (push (etaf-manual-reader--definition-card
                     block (nreverse body) env)
                    nodes))
          (let ((view (etaf-manual-reader--ordinary-view block env)))
            (when view (push view nodes))))))
    (nreverse nodes)))

(defun etaf-manual-reader--section-view (blocks env)
  "Return the section View for BLOCKS.
The View carries the scroll anchor of its first heading so navigation can
bring it to the top of the article scroller."
  (let* ((heading (car blocks))
         (anchor (plist-get heading :id))
         (ref (and anchor (intern (format "etaf-manual-node-%s" anchor)))))
    (etaf-node 'column
               (append (list :width 'stretch :item-gap '(lh 1))
                       (when ref (list :ref ref)))
               (etaf-manual-reader--render-blocks blocks env))))

(etaf-define-component etaf-manual-reader--section
    (&key blocks env)
  "Render one section's BLOCKS in ENV as its own update boundary.
Extending a progressively rendered chapter adds sections without
rebuilding the ones already shown."
  :render
  (etaf-manual-reader--section-view blocks env))

(defun etaf-manual-reader--chapter-head-view (blocks env number)
  "Render the chapter title and lead BLOCKS in ENV.
NUMBER is the chapter number shown before the title.  The lead blocks
follow as separate Views so the article's one-line rhythm spaces them."
  (let ((nodes nil) (title nil))
    (dolist (block blocks)
      (if (and (eq (plist-get block :type) 'heading)
               (= (plist-get block :level) 1))
          (setq title (etaf-manual-reader--heading-text block))
        (push block nodes)))
    (append
     (when title
       (list (etaf-manual-reader--chapter-heading env number title)))
     (delq nil (mapcar (lambda (block)
                         (etaf-manual-reader--ordinary-view block env))
                       (nreverse nodes))))))

(defun etaf-manual-reader--chapter-cache (session kind build)
  "Return SESSION's KIND value for the current chapter, made by BUILD once.
Section components compare list props by identity, so chapter data passed
to them is built once per chapter and language."
  (let ((key (list kind (etaf-manual-reader--read session :language)
                   (etaf-manual-reader--read session :chapter)))
        (cache (plist-get session :documents)))
    (or (gethash key cache)
        (puthash key (funcall build) cache))))

(defun etaf-manual-reader--article-env (session env document)
  "Return ENV extended with DOCUMENT's markdown features and examples.
The extension is the same object while ENV is, so unchanged sections keep
their props."
  (let ((last (etaf-manual-reader--chapter-cache session 'env (lambda () (list nil)))))
    (if (eq (car last) env)
        (cdr last)
      (setcar last env)
      (setcdr last (append env (list :markdown-features (plist-get document :features)
                                     :examples (etaf-manual-reader--example-table session)
                                     :figures (etaf-manual-reader--figure-table session)))))))

(cl-defun etaf-manual-reader--article (&key session env)
  "Return the article column View of SESSION's current chapter in ENV."
  (let* ((document (etaf-manual-reader-document session))
         (blocks (plist-get document :children))
         (split (etaf-manual-reader--chapter-cache
                 session 'sections
                 (lambda () (etaf-manual-reader--sections blocks))))
         (head (car split))
         (extent (etaf-manual-reader--read session :extent))
         (sections (if extent (seq-take (cdr split) extent) (cdr split)))
         (complete (or (null extent) (>= extent (length (cdr split)))))
         (cards (when complete (etaf-manual-reader--chapter-cards session env)))
         (env (etaf-manual-reader--article-env session env document))
         (part (etaf-manual-reader--part session))
         (number (plist-get (etaf-manual-reader--chapter session) :number))
         (lead (etaf-manual-reader--chapter-head-view head env number))
         (body nil)
         (previous-empty nil))
    (dolist (section sections)
      (when body
        ;; An empty section (a heading with no body before the next
        ;; heading) keeps its following heading close instead of a full
        ;; section gap.
        (push (etaf-manual-reader--spacer (if previous-empty 1 2)) body))
      (push (etaf-node 'etaf-manual-reader--section
                       (list :blocks (cdr section) :env env)
                       nil)
            body)
      (setq previous-empty (null (cdr (cdr section)))))
    (etaf-node 'column
               (list :width 'stretch
                     :max-width (list 'ch (etaf-manual-reader--measure env))
                     :padding '((lh 1) (ch 3))
                     :item-gap '(lh 1)
                     :color (etaf-manual-reader--color env :ink))
               (append
                (when part
                  (list (etaf-manual-reader--label
                         env (format "%s · %s"
                                     (or (plist-get part :number) "")
                                     (or (plist-get part :title) "")))))
                lead
                (list (etaf-node 'column
                                 (list :width 'stretch :item-gap '(lh 0))
                                 (nreverse body)))
                (when cards
                  (list (etaf-manual-reader--spacer) cards))))))

(etaf-define-component etaf-manual-reader--article-view
    (&key session env)
  "Render SESSION's current chapter in ENV as its own update boundary.
The render reads only the chapter, language, theme and extent sources, so
moving between sections or recording history leaves the chapter View
untouched."
  :render
  (etaf-manual-reader--article :session session :env env))

(provide 'etaf-manual-reader-article)
;;; etaf-manual-reader-article.el ends here
