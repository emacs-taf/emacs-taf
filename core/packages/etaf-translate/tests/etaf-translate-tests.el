;;; etaf-translate-tests.el --- Public API acceptance tests for etaf-translate -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Public-API behavior suite validating every architectural pillar of
;; `etaf-translate': rich inline extraction/restoration, smart exclusions,
;; cached instant mode/style switching, live reactive commit survival,
;; batching/error-retry/cancellation, declarative rules + L2 cache + provider
;; extension points, and real `etaf-ui-markdown' document rendering.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'etaf)
(require 'etaf-ui)
(require 'etaf-doc)
(require 'etaf-translate)

(defun etaf-translate-test--buffer-text (runtime)
  "Return RUNTIME's rendered buffer text without text properties."
  (with-current-buffer (etaf-runtime-buffer runtime)
    (buffer-substring-no-properties (point-min) (point-max))))

(defmacro etaf-translate-test--with-mount (spec &rest body)
  "Mount VIEW in a fresh buffer, bind RUNTIME, run BODY, and clean up."
  (declare (indent 1))
  (let ((var (car spec))
        (view (cadr spec))
        (opts (caddr spec)))
    `(let ((buf (generate-new-buffer " *etaf-translate-test*"))
           (,var nil))
       (unwind-protect
           (progn
             (etaf-mount buf ,view ,opts)
             (setq ,var (etaf-runtime-for-buffer buf))
             (with-current-buffer buf
               ,@body))
         (when (buffer-live-p buf)
           (when-let* ((rt (etaf-runtime-for-buffer buf)))
             (ignore-errors (etaf-translate-disable rt))
             (ignore-errors (etaf-unmount rt)))
           (kill-buffer buf))))))

(defmacro etaf-translate-test--with-engine (name spec &rest body)
  "Register temporary engine NAME with SPEC for BODY, then unregister it."
  (declare (indent 2))
  `(progn
     (etaf-translate-register-engine ,name ,@spec)
     (unwind-protect
         (progn ,@body)
       (etaf-translate-unregister-engine ,name))))

(ert-deftest etaf-translate-rich-inline-preserves-links-code-and-malformed-fallback ()
  "Paragraph extraction preserves inline code atoms, clickable links, and survives bad tags."
  (let ((link-clicks 0)
        (seen-inputs nil))
    (etaf-translate-test--with-engine
        'test-rich
        (:supports-batch t
         :translate
         (lambda (req on-done _on-error)
           (let ((units (plist-get req :units)))
             (setq seen-inputs (append seen-inputs units))
             (funcall
              on-done
              (mapcar
               (lambda (u)
                 (cond
                  ((string-search "Read the" u)
                   ;; Reorder text around <1> link and ⟦c0⟧ inline code atom.
                   "请先阅读<1>ETAF 手册</1>再执行 ⟦c0⟧ 命令。")
                  (t
                   ;; Simulate malformed stray tag from an LLM.
                   "这是一段<99>退化译文。")))
               units)))
           nil))
      (etaf-translate-test--with-mount
          (runtime
           (etaf-view
            (column :width 'stretch :item-gap '(lh 1)
              (box :width 'stretch :wrap-mode 'word
                (text "Read the ")
                (text :role 'link :color "#2563eb" :text-decoration-line '(underline)
                      :on-press (lambda () (cl-incf link-clicks))
                      "ETAF Manual")
                (text " before running ")
                (text :font-family "Menlo" :background-color "#eeeeee" "make check")
                (text "."))
              (box :width 'stretch :wrap-mode 'word
                (text "Fallback paragraph with ")
                (text :font-weight 'bold "emphasis")
                (text "."))))
           '(:viewport-width 720 :viewport-height 24))
        (let ((cache (etaf-translate-cache-create)))
          (etaf-translate-enable runtime :engine 'test-rich :cache cache)
          ;; Verify inline code was protected as an atomic placeholder ⟦c0⟧.
          (should (cl-some (lambda (s)
                             (and (string-search "<1>ETAF Manual</1>" s)
                                  (string-search "⟦c0⟧" s)
                                  (not (string-search "make check" s))))
                           seen-inputs))
          (let ((text (etaf-translate-test--buffer-text runtime)))
            ;; Both original and translation visible in bilingual-stacked mode.
            (should (string-match-p "Read the ETAF Manual" text))
            ;; Boundary space keeps CJK prose cleanly separated from Latin link text!
            (should (string-match-p "请先阅读 ETAF 手册" text))
            (should (string-match-p "make check" text))
            ;; Plain runs surrounding the link must NOT inherit link underline/role!
            (with-current-buffer (etaf-runtime-buffer runtime)
              (goto-char (point-min))
              (should (search-forward "请先阅读" nil t))
              (let ((face (get-text-property (match-beginning 0) 'face)))
                (should-not (and (listp face) (plist-get face :underline)))))
            ;; Malformed <99> tag was stripped cleanly without losing text.
            (should (string-match-p "这是一段退化译文。" text))
            (should-not (string-match-p "<99>" text)))
          ;; Switch to replace mode: original text replaced, link stays clickable!
          (etaf-translate-set-mode 'replace runtime)
          (let ((replaced (etaf-translate-test--buffer-text runtime)))
            (should (string-match-p "请先阅读 ETAF 手册" replaced))
            (should (string-match-p "make check" replaced))
            (should-not (string-match-p "before running" replaced)))
          ;; Activate the translated link in the buffer and verify original callback fires!
          (with-current-buffer (etaf-runtime-buffer runtime)
            (goto-char (point-min))
            (should (search-forward "ETAF 手册" nil t))
            (goto-char (match-beginning 0))
            (etaf-activate runtime))
          (should (= 1 link-clicks)))))))

(ert-deftest etaf-translate-exclusions-and-scope-control ()
  "Content scope skips :translate no, code blocks, UI buttons and target-language text."
  (let ((translated-inputs nil))
    (etaf-translate-test--with-engine
        'test-filter
        (:supports-batch t
         :translate
         (lambda (req on-done _on-error)
           (let ((units (plist-get req :units)))
             (setq translated-inputs (append translated-inputs units))
             (funcall on-done
                      (mapcar (lambda (s) (concat "译:" s)) units)))
           nil))
      (etaf-translate-test--with-mount
          (runtime
           (etaf-view
            (column :width 'stretch :item-gap '(lh 1)
              (box :role 'button :width 'stretch :height '(lh 1) :overflow 'hidden
                (text "Settings Toolbar Action"))
              (box :translate 'no :width 'stretch
                (text "Explicitly excluded paragraph text."))
              (box :width 'stretch :wrap-mode 'char
                (text "defun etaf-mount (buffer view)"))
              (box :width 'stretch :wrap-mode 'word
                (text "这段已经是中文正文，不应该被重复翻译。"))
              (box :width 'stretch :wrap-mode 'word
                (text "This English paragraph should be translated."))))
           '(:viewport-width 720 :viewport-height 24))
        (let ((cache (etaf-translate-cache-create)))
          (etaf-translate-enable runtime :engine 'test-filter :scope 'content
                                 :target-lang "zh-CN" :cache cache)
          (should (equal translated-inputs
                         '("This English paragraph should be translated.")))
          ;; Switching to `full' scope includes the button label (and replaces
          ;; safely inside its constrained single-line container).
          (setq translated-inputs nil)
          (etaf-translate-set-scope 'full runtime)
          (should (member "Settings Toolbar Action" translated-inputs))
          (let ((full-text (etaf-translate-test--buffer-text runtime)))
            (should (string-match-p "译:Settings Toolbar Action" full-text))
            ;; `:translate no' still stays untouched even in `full' scope!
            (should-not (string-match-p "译:Explicitly excluded" full-text))))))))

(ert-deftest etaf-translate-instant-mode-style-cycling-uses-cache ()
  "Cycling bilingual-stacked, replace and styles hits L1 cache with zero extra calls."
  (let ((engine-calls 0))
    (etaf-translate-test--with-engine
        'test-cache-cycle
        (:supports-batch t
         :translate
         (lambda (req on-done _on-error)
           (cl-incf engine-calls)
           (funcall on-done
                    (mapcar (lambda (s) (format "【中文】%s" s))
                            (plist-get req :units)))
           nil))
      (etaf-translate-test--with-mount
          (runtime
           (etaf-view
            (column :width 'stretch :item-gap '(lh 1)
              (box :width 'stretch :wrap-mode 'word
                (text "Universal translation over retained boxes."))))
           '(:viewport-width 1100 :viewport-height 24))
        (let ((cache (etaf-translate-cache-create)))
          (etaf-translate-enable runtime :engine 'test-cache-cycle :cache cache)
          (should (= 1 engine-calls))
          (should (eq (plist-get (etaf-translate-status runtime) :mode) 'bilingual-stacked))
          (should (string-match-p "【中文】Universal" (etaf-translate-test--buffer-text runtime)))
          ;; Switch styles and cycle all modes: engine call count MUST remain 1!
          (etaf-translate-set-style 'muted runtime)
          (etaf-translate-set-style 'tinted runtime)
          (should-error (etaf-translate-set-mode 'bilingual-beside runtime)
                        :type 'etaf-translate-error)
          (etaf-translate-mode-cycle runtime)
          (should (eq (plist-get (etaf-translate-status runtime) :mode) 'replace))
          (let ((rep (etaf-translate-test--buffer-text runtime)))
            (should (string-match-p "【中文】Universal" rep)))
          (should (= 1 engine-calls))
          ;; Final cycle turns translation off and restores exact original.
          (etaf-translate-mode-cycle runtime)
          (should-not (plist-get (etaf-translate-status runtime) :active))
          (let ((orig (etaf-translate-test--buffer-text runtime)))
            (should (string-match-p "Universal translation over retained boxes\\." orig))
            (should-not (string-match-p "【中文】" orig)))
          ;; Interactive calls emit clear echo-area status messages for each mode.
          (let ((msgs nil)
                (etaf-translate-default-engine 'test-cache-cycle)
                (etaf-translate-enable-disk-cache nil))
            (cl-letf (((symbol-function 'message)
                       (lambda (fmt &rest args)
                         (push (apply #'format fmt args) msgs))))
              (call-interactively #'etaf-translate-mode-cycle)
              (call-interactively #'etaf-translate-mode-cycle)
              (call-interactively #'etaf-translate-mode-cycle))
            (setq msgs (nreverse msgs))
            (should (= 3 (length msgs)))
            (should (string-match-p "双语对照" (nth 0 msgs)))
            (should (string-match-p "原地替换" (nth 1 msgs)))
            (should (string-match-p "已关闭" (nth 2 msgs)))))))))

(ert-deftest etaf-translate-survives-live-reactive-commits-incrementally ()
  "Dynamic commits re-translate only added or edited paragraphs without re-translating unchanged ones."
  (let ((items (etaf-ref '("First stable paragraph." "Second editable paragraph.")))
        (calls nil)
        (etaf-translate-commit-debounce 0))
    (etaf-translate-test--with-engine
        'test-live
        (:supports-batch t
         :translate
         (lambda (req on-done _on-error)
           (let ((units (plist-get req :units)))
             (setq calls (append calls units))
             (funcall on-done
                      (mapcar (lambda (s) (concat "译文:" s)) units)))
           nil))
      (etaf-translate-test--with-mount
          (runtime
           (lambda ()
             (etaf-view
              (column :width 'stretch :item-gap '(lh 1)
                (box :for (item (etaf-value items)) :key item
                     :width 'stretch :wrap-mode 'word
                  (text (expr item))))))
           '(:viewport-width 720 :viewport-height 24))
        (let ((cache (etaf-translate-cache-create)))
          (etaf-translate-enable runtime :engine 'test-live :cache cache)
          (should (= 2 (length calls)))
          ;; Append a third paragraph: ONLY the new paragraph hits the engine!
          (setq calls nil)
          (etaf-set-value items
                          '("First stable paragraph."
                            "Second editable paragraph."
                            "Third newly added paragraph."))
          (should (equal calls '("Third newly added paragraph.")))
          (let ((text (etaf-translate-test--buffer-text runtime)))
            (should (string-match-p "译文:First stable paragraph\\." text))
            (should (string-match-p "译文:Third newly added paragraph\\." text)))
          ;; Remove the first paragraph: its companion disappears cleanly.
          (etaf-set-value items '("Second editable paragraph."
                                  "Third newly added paragraph."))
          (let ((after-del (etaf-translate-test--buffer-text runtime)))
            (should-not (string-match-p "First stable" after-del))
            (should (string-match-p "译文:Second editable paragraph\\." after-del))))))))

(ert-deftest etaf-translate-async-cancellation-and-error-retry ()
  "Disabling cancels in-flight async requests and ignores late replies; failed units recover on retry."
  (let ((cancelled 0)
        (late-done nil)
        (should-fail t))
    (etaf-translate-test--with-engine
        'test-async
        (:supports-batch nil
         :translate
         (lambda (req on-done on-error)
           (let ((u (car (plist-get req :units))))
             (cond
              ((string-search "Slow" u)
               (setq late-done on-done)
               (lambda () (cl-incf cancelled)))
              (should-fail
               (funcall on-error "Simulated timeout")
               nil)
              (t
               (funcall on-done (list "重试成功译文"))
               nil)))))
      (etaf-translate-test--with-mount
          (runtime
           (etaf-view
            (column :width 'stretch :item-gap '(lh 1)
              (box :width 'stretch :wrap-mode 'word
                (text "Slow async paragraph pending."))))
           '(:viewport-width 720 :viewport-height 24))
        (let ((cache (etaf-translate-cache-create)))
          (etaf-translate-enable runtime :engine 'test-async :cache cache)
          ;; Shows subtle loading indicator while pending.
          (should (string-match-p "译文中…" (etaf-translate-test--buffer-text runtime)))
          (should (= 1 (plist-get (etaf-translate-status runtime) :pending)))
          ;; Disable cancels in-flight request; late completion is ignored.
          (etaf-translate-disable runtime)
          (should (= 1 cancelled))
          (when late-done (funcall late-done '("迟到译文")))
          (should-not (string-match-p "迟到译文" (etaf-translate-test--buffer-text runtime)))))
      ;; Error & interactive retry check.
      (etaf-translate-test--with-mount
          (runtime
           (etaf-view
            (column :width 'stretch :item-gap '(lh 1)
              (box :width 'stretch :wrap-mode 'word
                (text "Transient failing paragraph."))))
           '(:viewport-width 720 :viewport-height 24))
        (let ((cache (etaf-translate-cache-create)))
          (etaf-translate-enable runtime :engine 'test-async :cache cache)
          (should (= 1 (plist-get (etaf-translate-status runtime) :failed)))
          (should (string-match-p "翻译失败" (etaf-translate-test--buffer-text runtime)))
          ;; Now allow retry to succeed and activate the retry button!
          (setq should-fail nil)
          (with-current-buffer (etaf-runtime-buffer runtime)
            (goto-char (point-min))
            (should (search-forward "翻译失败" nil t))
            (goto-char (match-beginning 0))
            (etaf-activate runtime))
          (should (= 0 (plist-get (etaf-translate-status runtime) :failed)))
          (should (string-match-p "重试成功译文"
                                  (etaf-translate-test--buffer-text runtime))))))))

(ert-deftest etaf-translate-rules-l2-cache-and-provider-extensibility ()
  "Declarative auto-translate rules, L2 cache persistence and virtualized providers integrate cleanly."
  (let ((l2-store (make-hash-table :test #'equal))
        (l2-puts 0)
        (l2-gets 0)
        (engine-hits 0)
        (provider-applied nil)
        (provider-cleared nil)
        (etaf-translate-enable-disk-cache nil)
        (etaf-translate-state-file nil))
    (unwind-protect
        (etaf-translate-test--with-engine
            'test-ext
            (:supports-batch t
             :translate
             (lambda (req on-done _on-error)
               (cl-incf engine-hits)
               (funcall on-done
                        (mapcar (lambda (s) (concat "L2:" s))
                                (plist-get req :units)))
               nil))
          ;; 1. Test L2 persistence backend read/write through.
          (let* ((persist (list :get (lambda (k) (cl-incf l2-gets) (gethash k l2-store))
                                :put (lambda (k v) (cl-incf l2-puts) (puthash k v l2-store))
                                :clear (lambda () (clrhash l2-store))))
                 (cache1 (etaf-translate-cache-create :persistence persist))
                 (cache2 (etaf-translate-cache-create :persistence persist)))
            (etaf-translate-test--with-mount
                (runtime (etaf-view (column (box :width 'stretch (text "Persistent sentence.")))))
              (etaf-translate-enable runtime :engine 'test-ext :cache cache1)
              (should (= 1 engine-hits))
              (should (= 1 l2-puts)))
            ;; Fresh L1 cache backed by the same L2 store resolves with ZERO engine calls!
            (etaf-translate-test--with-mount
                (runtime (etaf-view (column (box :width 'stretch (text "Persistent sentence.")))))
              (etaf-translate-enable runtime :engine 'test-ext :cache cache2)
              (should (= 1 engine-hits))
              (should (>= l2-gets 1))
              (should (string-match-p "L2:Persistent sentence\\."
                                      (etaf-translate-test--buffer-text runtime)))))
          ;; 2. Test declarative auto-translate rule on mount (zero minor mode needed).
          (should-not (fboundp 'etaf-translate-global-mode))
          (etaf-translate-register-rule
           'test-auto-rule
           :priority 1
           :buffer-regexp "\\*etaf-translate-auto-buf\\*"
           :mode 'replace
           :engine 'test-ext
           :auto-translate t)
          (let ((buf (get-buffer-create "*etaf-translate-auto-buf*")))
            (unwind-protect
                (progn
                  (etaf-mount buf (etaf-view (column (box :width 'stretch (text "Auto translated page.")))))
                  (let* ((rt (etaf-runtime-for-buffer buf))
                         (st (etaf-translate-status rt)))
                    (should (plist-get st :active))
                    (should (eq (plist-get st :mode) 'replace))
                    (should (string-match-p "L2:Auto translated page\\."
                                            (etaf-translate-test--buffer-text rt)))))
              (when (buffer-live-p buf)
                (when-let* ((rt (etaf-runtime-for-buffer buf)))
                  (ignore-errors (etaf-unmount rt)))
                (kill-buffer buf))))
          ;; 3. Test virtualized provider adapter protocol.
          (etaf-translate-register-provider
           'test-virt
           :match (lambda (_rt buf) (string= (buffer-name buf) "*etaf-translate-virt*"))
           :extract (lambda (_rt _policy)
                      (list (etaf-translate-make-unit
                             :id 1 :text "Virtual block")))
           :apply (lambda (_rt _unit tr mode _style)
                    (push (cons mode tr) provider-applied))
           :clear (lambda (_rt) (setq provider-cleared t)))
          (let ((buf (get-buffer-create "*etaf-translate-virt*")))
            (unwind-protect
                (progn
                  (etaf-mount buf (etaf-view (column (text "line 1"))))
                  (let ((rt (etaf-runtime-for-buffer buf)))
                    (etaf-translate-enable rt :engine 'test-ext
                                           :cache (etaf-translate-cache-create))
                    (should (equal provider-applied '((bilingual-stacked . "L2:Virtual block"))))
                    (etaf-translate-disable rt)
                    (should provider-cleared)))
              (when (buffer-live-p buf)
                (when-let* ((rt (etaf-runtime-for-buffer buf)))
                  (ignore-errors (etaf-unmount rt)))
                (kill-buffer buf)))))
      (etaf-translate-unregister-rule 'test-auto-rule)
      (etaf-translate-unregister-provider 'test-virt))))

(ert-deftest etaf-translate-real-markdown-document-with-table-and-code ()
  "End-to-end translation on a real `etaf-ui-markdown' document preserves tables and skips fenced code."
  (let* ((md (concat
              "# Getting Started\n\n"
              "ETAF renders declarative Views with **incremental** layout and `ebox` caching.\n\n"
              "> Note that blockquotes keep their left bar around both languages.\n\n"
              "```elisp\n"
              "(etaf-mount \"*demo*\" view)\n"
              "```\n\n"
              "| Layer | Responsibility |\n"
              "| --- | --- |\n"
              "| ECSS | Selector cascade |\n"
              "| ETAF | Reactive Views |\n"))
         (doc (etaf-ui-markdown-parse md))
         (blocks (plist-get doc :children))
         (palette '((:ink . "#1e293b") (:heading . "#0f172a") (:muted . "#64748b")
                    (:accent . "#2563eb") (:accent-soft . "#dbeafe")
                    (:panel . "#f8fafc") (:panel2 . "#f1f5f9")
                    (:border . "#cbd5e1") (:quote-bg . "#f8fafc")
                    (:quote-bar . "#94a3b8") (:table-header . "#f1f5f9")
                    (:table-stripe . "#f1f5f9") (:heading-rule . "#e2e8f0")))
         (env (list :palette palette :background "#ffffff"))
         (view (etaf-node 'column '(:width stretch :item-gap (lh 0))
                          (etaf-ui-markdown-view-blocks blocks env)))
         (seen nil))
    (etaf-translate-test--with-engine
        'test-md
        (:supports-batch t
         :translate
         (lambda (req on-done _on-error)
           (let ((units (plist-get req :units)))
             (setq seen (append seen units))
             (funcall on-done
                      (mapcar (lambda (s) (concat "译：" s)) units)))
           nil))
      (etaf-translate-test--with-mount
          (runtime view '(:viewport-width 800 :viewport-height 40))
        (let ((cache (etaf-translate-cache-create)))
          (etaf-translate-enable runtime :engine 'test-md :cache cache)
          (let ((rendered (etaf-translate-test--buffer-text runtime)))
            ;; Headings, paragraphs, blockquotes and table cells were translated.
            (should (string-match-p "译：Getting Started" rendered))
            (should (string-match-p "译：ETAF renders declarative Views" rendered))
            (should (string-match-p "译：Note that blockquotes" rendered))
            (should (string-match-p "译：Selector cascade" rendered))
            ;; Inline code `ebox` stayed atomic and visible.
            (should (string-match-p "ebox" rendered))
            ;; Fenced code block was NOT translated!
            (should-not (cl-some (lambda (s) (string-search "etaf-mount" s)) seen))
            (should (string-match-p "(etaf-mount" rendered)))
          ;; Clean restore leaves zero translated text behind.
          (etaf-translate-disable runtime)
          (should-not (string-match-p "译："
                                      (etaf-translate-test--buffer-text runtime))))))))

(ert-deftest etaf-translate-overflow-scroll-viewport-lazy-promotion ()
  "Scrolling an :overflow scroll container promotes deferred paragraphs without ghost loading."
  (let* ((rows (cl-loop for i from 1 to 40
                        collect (format "Paragraph %02d explains retained ETAF layout." i)))
         (seen nil)
         (pending-callbacks nil)
         (etaf-translate-prefetch-lines 4)
         (etaf-translate-scroll-debounce 0)
         (etaf-translate-max-concurrency 4))
    (etaf-translate-test--with-engine
        'test-scroll
        (:supports-batch t
         :translate
         (lambda (req on-done _on-error)
           (let ((units (plist-get req :units)))
             (setq seen (append seen units))
             (push (cons units on-done) pending-callbacks))
           nil))
      (etaf-translate-test--with-mount
          (runtime
           (etaf-view
            (column :width 'stretch :height '(lh 8) :overflow 'scroll :ref 'scroller
              (box :for (row rows) :key row :width 'stretch :wrap-mode 'word
                (text (expr row)))))
           '(:viewport-width 640 :viewport-height 8))
        (let ((cache (etaf-translate-cache-create)))
          (etaf-translate-enable runtime :engine 'test-scroll :cache cache)
          ;; Only visible + small prefetch band should be dispatched; far rows stay deferred!
          (let ((st (etaf-translate-status runtime)))
            (should (= 40 (plist-get st :total)))
            (should (> (plist-get st :deferred) 20))
            (should-not (cl-some (lambda (s) (string-search "Paragraph 40" s)) seen)))
          ;; Resolve the initial visible batches.
          (while pending-callbacks
            (let* ((entry (pop pending-callbacks))
                   (units (car entry))
                   (cb (cdr entry)))
              (funcall cb (mapcar (lambda (s) (concat "译:" s)) units))))
          (should (> (plist-get (etaf-translate-status runtime) :translated) 0))
          (should (> (plist-get (etaf-translate-status runtime) :deferred) 20))
          ;; Scroll the :overflow scroll container to the bottom: deferred bottom rows promote!
          (etaf-scroll-to runtime 'scroller 'end)
          (should (cl-some (lambda (s) (string-search "Paragraph 40" s)) seen))
          (while pending-callbacks
            (let* ((entry (pop pending-callbacks))
                   (units (car entry))
                   (cb (cdr entry)))
              (funcall cb (mapcar (lambda (s) (concat "译:" s)) units))))
          (let ((bottom-text (etaf-translate-test--buffer-text runtime)))
            (should (string-match-p "译:Paragraph 33" bottom-text))
            (should-not (string-match-p "译文中…" bottom-text)))
          ;; Reaching the grown bottom shows Paragraph 40 already translated.
          (etaf-scroll-to runtime 'scroller 'end)
          (let ((very-end (etaf-translate-test--buffer-text runtime)))
            (should (string-match-p "译:Paragraph 40" very-end))
            (should-not (string-match-p "译文中…" very-end))))))))

(ert-deftest etaf-translate-streaming-incremental-delivery-and-partial-retry ()
  "Streaming :on-unit-done paints finished units immediately and auto-retries only missing units."
  (let* ((call-sizes nil)
         (attempts 0)
         (etaf-translate-auto-retry-count 1)
         (etaf-translate-batch-max-units 4))
    (etaf-translate-test--with-engine
        'test-stream
        (:supports-batch t
         :translate
         (lambda (req on-done on-error)
           (let ((units (plist-get req :units))
                 (on-unit (plist-get req :on-unit-done)))
             (cl-incf attempts)
             (push (length units) call-sizes)
             (if (= attempts 1)
                 ;; Stream unit 0 immediately, then fail asynchronously before unit 1!
                 (progn
                   (when (functionp on-unit)
                     (funcall on-unit 0 "流式第一段译文"))
                   (let ((tm (run-at-time 0.02 nil
                                          (lambda ()
                                            (funcall on-error "Transient stream drop")))))
                     (lambda () (cancel-timer tm))))
               ;; Solo retry succeeds cleanly for unit 1.
               (funcall on-done (mapcar (lambda (_u) "自动重试第二段译文") units))
               nil))))
      (etaf-translate-test--with-mount
          (runtime
           (etaf-view
            (column :width 'stretch :item-gap '(lh 1)
              (box :width 'stretch :wrap-mode 'word
                (text "First streaming paragraph."))
              (box :width 'stretch :wrap-mode 'word
                (text "Second resilient paragraph."))))
           '(:viewport-width 720 :viewport-height 24))
        (let ((cache (etaf-translate-cache-create)))
          (etaf-translate-enable runtime :engine 'test-stream :cache cache)
          ;; Unit 0 is ALREADY rendered while unit 1 is still in flight!
          (let ((mid (etaf-translate-test--buffer-text runtime)))
            (should (string-match-p "流式第一段译文" mid))
            (should (string-match-p "译文中…" mid))
            (should (= 1 (plist-get (etaf-translate-status runtime) :translated))))
          ;; Wait for the async drop + automatic 0.5s solo retry to settle.
          (let ((deadline (+ (float-time) 2.5)))
            (while (and (< (float-time) deadline)
                        (< (plist-get (etaf-translate-status runtime) :translated) 2))
              (accept-process-output nil 0.05)))
          (let ((st (etaf-translate-status runtime))
                (done (etaf-translate-test--buffer-text runtime)))
            (should (= 2 (plist-get st :translated)))
            (should (= 0 (plist-get st :failed)))
            (should (equal (nreverse call-sizes) '(2 1)))
            (should (string-match-p "流式第一段译文" done))
            (should (string-match-p "自动重试第二段译文" done))))))))

(ert-deftest etaf-translate-skips-technical-lists-and-suppresses-identical-companions ()
  "Comma-separated package lists are skipped and unchanged translations omit duplicate bars."
  (let ((seen nil))
    (etaf-translate-test--with-engine
        'test-dedup
        (:supports-batch t
         :translate
         (lambda (req on-done _on-error)
           (let ((units (plist-get req :units)))
             (setq seen (append seen units))
             (funcall on-done
                      (mapcar (lambda (s)
                                (if (string= (string-trim s) "SQLite")
                                    "SQLite"
                                  (concat "译:" s)))
                              units)))
           nil))
      (etaf-translate-test--with-mount
          (runtime
           (etaf-view
            (column :width 'stretch :item-gap '(lh 1)
              (box :width 'stretch (text "etaf, etaf-ui"))
              (box :width 'stretch (text "SQLite"))
              (box :width 'stretch (text "Floating panels for ETAF views."))))
           '(:viewport-width 720 :viewport-height 24))
        (let ((cache (etaf-translate-cache-create)))
          (etaf-translate-enable runtime :engine 'test-dedup :cache cache)
          ;; Package list was skipped before hitting the engine.
          (should-not (member "etaf, etaf-ui" seen))
          ;; Brand name SQLite returned unchanged -> counted translated, zero duplicate line!
          (let* ((buf-text (etaf-translate-test--buffer-text runtime))
                 (first-pos (string-search "SQLite" buf-text))
                 (second-pos (and first-pos (string-search "SQLite" buf-text (1+ first-pos)))))
            (should first-pos)
            (should-not second-pos)
            (should-not (string-match-p "译文中…" buf-text))
            (should (string-match-p "译:Floating panels" buf-text))))))))

(ert-deftest etaf-translate-sqlite-l2-cache-and-persisted-site-rules ()
  "SQLite L2 cache survives fresh L1 creation and site rules/glossary persist to disk."
  (let* ((tmp-dir (make-temp-file "etaf-tr-store-" t))
         (db-file (expand-file-name "cache.sqlite" tmp-dir))
         (state-file (expand-file-name "state.eld" tmp-dir))
         (etaf-translate-state-file state-file)
         (saved-glossary (copy-sequence etaf-translate-glossary))
         (hits 0))
    (unwind-protect
        (etaf-translate-test--with-engine
            'test-sqlite
            (:supports-batch t
             :translate
             (lambda (req on-done _on-error)
               (cl-incf hits)
               (funcall on-done
                        (mapcar (lambda (s) (concat "SQL:" s))
                                (plist-get req :units)))
               nil))
          ;; 1. Verify SQLite L2 persistence (when build has native SQLite).
          (let ((persist (etaf-translate-sqlite-persistence db-file 30 500)))
            (when persist
              (unwind-protect
                  (let ((c1 (etaf-translate-cache-create :persistence persist))
                        (c2 (etaf-translate-cache-create :persistence persist)))
                    (etaf-translate-test--with-mount
                        (runtime (etaf-view (column (box :width 'stretch
                                                      (text "Persisted across restarts.")))))
                      (etaf-translate-enable runtime :engine 'test-sqlite :cache c1)
                      (should (= 1 hits)))
                    ;; Fresh L1 cache reads directly from SQLite with 0 engine calls!
                    (etaf-translate-test--with-mount
                        (runtime (etaf-view (column (box :width 'stretch
                                                      (text "Persisted across restarts.")))))
                      (etaf-translate-enable runtime :engine 'test-sqlite :cache c2)
                      (should (= 1 hits))
                      (should (string-match-p "SQL:Persisted across restarts\\."
                                              (etaf-translate-test--buffer-text runtime)))
                      (let ((st (etaf-translate-cache-stats c2)))
                        (should (eq (plist-get st :l2-backend) 'sqlite))
                        (should (>= (plist-get st :l2-entries) 1))
                        (should (>= (plist-get st :l2-hits) 1))
                        (should (integerp (etaf-translate-cache-prune c2))))))
                (when-let* ((closer (plist-get persist :close)))
                  (funcall closer)))))
          ;; 2. Verify remembered site rules, glossary and sparse panel preferences persistence.
          (etaf-translate-remember-site "docs.example.org" 'auto)
          (etaf-translate-add-glossary-term "RetainedTree" "保留树" t)
          (should (file-readable-p state-file))
          (should (assoc "RetainedTree" etaf-translate-glossary))
          (should (cl-some (lambda (r)
                             (equal (plist-get (cdr r) :domain) "docs.example.org"))
                           (etaf-translate-rules)))
          ;; Panel clicks persist sparse :prefs to state-file; transient mode-cycle does not.
          (let ((etaf-translate-use-posframe nil)
                (etaf-translate-enable-disk-cache nil))
            (etaf-translate-test--with-mount
                (rt1 (etaf-view (column (box :width 'stretch (text "Persist panel preferences.")))))
              (etaf-translate-enable rt1 :engine 'test-sqlite :cache (etaf-translate-cache-create))
              (let ((pbuf (etaf-translate-panel rt1)))
                (unwind-protect
                    (let* ((prt (etaf-runtime-for-buffer pbuf))
                           (find-btn
                            (lambda (label)
                              (cl-labels
                                  ((walk (nodes)
                                     (cl-loop for n in nodes
                                              for props = (plist-get n :props)
                                              for hit = (if (and (eq (plist-get props :role) 'button)
                                                                 (equal (plist-get props :aria-label) label))
                                                            n
                                                          (walk (plist-get n :children)))
                                              when hit return hit)))
                                (walk (etaf-runtime-host-tree prt))))))
                      (etaf-runtime-trigger-host-press
                       prt (plist-get (funcall find-btn "极简") :id)))
                  (etaf-translate-panel-close)))
              ;; Transient mode-cycle switches to replace without overwriting persisted :mode.
              (etaf-translate-mode-cycle rt1))
            ;; Verify disk file recorded ONLY :style muted (sparse) and NOT :mode or :engine.
            (let ((saved (with-temp-buffer
                           (insert-file-contents state-file)
                           (read (current-buffer)))))
              (should (equal (plist-get saved :prefs) '(:style muted))))
            ;; Fresh Runtime inherits persisted :style muted while keeping default :mode.
            (etaf-translate-test--with-mount
                (rt2 (etaf-view (column (box :width 'stretch (text "Second fresh page.")))))
              (let ((st (etaf-translate-status rt2)))
                (should (eq (plist-get st :style) 'muted))
                (should (eq (plist-get st :mode) etaf-translate-default-mode)))))
          (etaf-translate-forget-site "docs.example.org")
          (etaf-translate-remove-glossary-term "RetainedTree" t)
          (should-not (assoc "RetainedTree" etaf-translate-glossary)))
      (setq etaf-translate-glossary saved-glossary)
      (ignore-errors (delete-directory tmp-dir t)))))

(ert-deftest etaf-translate-profiles-context-and-fallback-engine ()
  "Named profiles pass document context/style and cascade to fallback engine on error."
  (let ((seen-context nil)
        (seen-style nil)
        (fallback-hits 0)
        (etaf-translate-state-file nil)
        (etaf-translate-auto-retry-count 0))
    ;; Built-in engines include OpenAI, Anthropic, DeepL, Google, CLI and Function.
    (let ((names (mapcar (lambda (e) (plist-get e :name)) (etaf-translate-engines))))
      (dolist (expected '(openai anthropic deepl google command function))
        (should (memq expected names))))
    (etaf-translate-test--with-engine
        'test-primary-fail
        (:supports-batch t
         :translate
         (lambda (req _on-done on-error)
           (setq seen-context (plist-get req :context)
                 seen-style (plist-get req :prompt-style))
           (funcall on-error "Simulated primary outage")
           nil))
      (etaf-translate-test--with-engine
          'test-backup-ok
          (:supports-batch t
           :translate
           (lambda (req on-done _on-error)
             (cl-incf fallback-hits)
             (funcall on-done
                      (mapcar (lambda (u) (concat "备:" u))
                              (plist-get req :units)))
             nil))
        (etaf-translate-register-profile
         'test-academic-prof
         :engine 'test-primary-fail
         :label "Academic Primary"
         :prompt-style 'academic
         :fallback 'test-backup-ok)
        (unwind-protect
            (etaf-translate-test--with-mount
                (runtime
                 (etaf-view
                  (column :width 'stretch :item-gap '(lh 1)
                    (box :role 'heading :width 'stretch
                      (text :font-weight 'bold "Retained Architecture"))
                    (box :width 'stretch :wrap-mode 'word
                      (text "Fallback keeps reading uninterrupted."))))
                 '(:viewport-width 720 :viewport-height 24))
              (should (cl-some (lambda (p) (eq (plist-get p :name) 'test-academic-prof))
                               (etaf-translate-profiles)))
              (etaf-translate-enable runtime :engine 'test-academic-prof
                                     :cache (etaf-translate-cache-create))
              (should (equal (plist-get seen-context :title) "Retained Architecture"))
              (should (eq seen-style 'academic))
              (should (> fallback-hits 0))
              (let ((st (etaf-translate-status runtime))
                    (txt (etaf-translate-test--buffer-text runtime)))
                (should (= 0 (plist-get st :failed)))
                (should (= 2 (plist-get st :translated)))
                (should (string-match-p "备:Fallback keeps reading" txt))))
          (etaf-translate-unregister-profile 'test-academic-prof))))))

(ert-deftest etaf-translate-minimal-panel-pure-popup-and-3-styles ()
  "Exactly 5 interactive commands, 3 editorial styles, slim panel and pure-translation popup work cleanly."
  (let ((etaf-translate-use-posframe nil)
        (etaf-translate-state-file nil)
        (etaf-translate-enable-disk-cache nil)
        (seen-popup-inputs nil))
    ;; Enforce the 5-command interactive surface contract strictly (including
    ;; private `--' symbols so no internal minor mode ever leaks into M-x).
    (let ((cmds nil))
      (mapatoms (lambda (sym)
                  (let ((name (symbol-name sym)))
                    (when (and (string-prefix-p "etaf-translate-" name)
                               (commandp sym))
                      (push sym cmds)))))
      (should (equal (sort cmds #'string<)
                     '(etaf-translate-at-point
                       etaf-translate-mode-cycle
                       etaf-translate-panel
                       etaf-translate-paragraph
                       etaf-translate-toggle))))
    (etaf-translate-test--with-engine
        'test-ui-eng
        (:supports-batch t
         :translate
         (lambda (req on-done _on-error)
           (let ((units (plist-get req :units)))
             (setq seen-popup-inputs (append seen-popup-inputs units))
             (funcall on-done
                      (mapcar (lambda (s)
                                (cond
                                 ((string= s "workspace") "工作区")
                                 ((string-search "First wrapped line" s)
                                  "这是一段纯净的中文译文结果。")
                                 (t (concat "译文：" s))))
                              units)))
           nil))
      (etaf-translate-test--with-mount
          (runtime
           (etaf-view
            (column :width 'stretch :item-gap '(lh 1)
              (box :width 'stretch :wrap-mode 'word
                (text "Panel and popup verification sentence."))))
           '(:viewport-width 800 :viewport-height 24))
        (etaf-translate-enable runtime :engine 'test-ui-eng
                               :cache (etaf-translate-cache-create))
        ;; Cycle through all 3 supported styles; removed styles signal error.
        (dolist (st '(left-bar muted tinted))
          (etaf-translate-set-style st runtime)
          (should (eq (plist-get (etaf-translate-status runtime) :style) st)))
        (should-error (etaf-translate-set-style 'dashed runtime) :type 'etaf-translate-error)
        (should-error (etaf-translate-set-style 'quote runtime) :type 'etaf-translate-error)
        ;; Replace mode attaches original sentence on :help-echo for hover peek.
        (etaf-translate-set-mode 'replace runtime)
        (with-current-buffer (etaf-runtime-buffer runtime)
          (goto-char (point-min))
          (should (search-forward "译文：Panel" nil t))
          (should (equal (get-text-property (match-beginning 0) 'help-echo)
                         "Panel and popup verification sentence.")))
        ;; Slim 6-row control panel mounts, hides dropped controls, updates
        ;; highlights reactively on press, and toggles closed on repeat call.
        (let ((panel-buf (etaf-translate-panel runtime)))
          (unwind-protect
              (progn
                (should (buffer-live-p panel-buf))
                (let* ((prt (etaf-runtime-for-buffer panel-buf))
                       (find-btn
                        (lambda (label)
                          (cl-labels
                              ((walk (nodes)
                                 (cl-loop for n in nodes
                                          for props = (plist-get n :props)
                                          for hit = (if (and (eq (plist-get props :role) 'button)
                                                             (equal (plist-get props :aria-label) label))
                                                        n
                                                      (walk (plist-get n :children)))
                                          when hit return hit)))
                            (walk (etaf-runtime-host-tree prt)))))
                       (selected-p
                        (lambda (label)
                          (let ((btn (funcall find-btn label)))
                            (and btn (plist-get (plist-get btn :props) :aria-selected)))))
                       (ptxt (with-current-buffer panel-buf
                               (buffer-substring-no-properties (point-min) (point-max)))))
                  (should (string-match-p "沉浸式翻译" ptxt))
                  (should (string-match-p "双语对照" ptxt))
                  (should (string-match-p "原地替换" ptxt))
                  (should-not (string-match-p "左右对照" ptxt))
                  (should (string-match-p "细线" ptxt))
                  (should (string-match-p "极简" ptxt))
                  (should (string-match-p "轻底" ptxt))
                  (should-not (string-match-p "隔线" ptxt))
                  (should-not (string-match-p "引文" ptxt))
                  (should-not (string-match-p "导出 Markdown" ptxt))
                  (should-not (string-match-p "术语表" ptxt))
                  (should-not (string-match-p "清理缓存" ptxt))
                  ;; Initially in `replace' + `tinted'.
                  (should (funcall selected-p "原地替换"))
                  (should-not (funcall selected-p "双语对照"))
                  (should (funcall selected-p "轻底"))
                  (should-not (funcall selected-p "极简"))
                  ;; Press `双语对照' and verify selection highlight moves reactively.
                  (etaf-runtime-trigger-host-press
                   prt (plist-get (funcall find-btn "双语对照") :id))
                  (should (funcall selected-p "双语对照"))
                  (should-not (funcall selected-p "原地替换"))
                  ;; Press `极简' and verify highlight moves reactively.
                  (etaf-runtime-trigger-host-press
                   prt (plist-get (funcall find-btn "极简") :id))
                  (should (funcall selected-p "极简"))
                  (should-not (funcall selected-p "轻底"))
                  ;; Press `恢复原文 (t)' and verify panel updates to inactive state.
                  (etaf-runtime-trigger-host-press
                   prt (plist-get (funcall find-btn "恢复原文 (t)") :id))
                  (should (funcall find-btn "翻译当前页 (t)"))
                  (should-not (funcall find-btn "恢复原文 (t)")))
                ;; Calling again for the same runtime toggles the panel closed.
                (should-not (etaf-translate-panel runtime))
                (should-not (buffer-live-p panel-buf)))
            (etaf-translate-panel-close)))
        ;; Pure-translation popup: active region joins hard wraps and never repeats original.
        (setq seen-popup-inputs nil)
        (with-temp-buffer
          (insert "First wrapped line\nsecond wrapped line.\n\nThe workspace owns commands.")
          (let ((transient-mark-mode t))
            (set-mark (point-min))
            (goto-char (+ (point-min) 39))
            (activate-mark)
            (let ((pop-buf (etaf-translate-at-point nil 'test-ui-eng)))
              (unwind-protect
                  (progn
                    (should (buffer-live-p pop-buf))
                    (should (member "First wrapped line second wrapped line." seen-popup-inputs))
                    (let ((qtxt (with-current-buffer pop-buf
                                  (buffer-substring-no-properties (point-min) (point-max)))))
                      (should (string-match-p "这是一段纯净的中文译文结果。" qtxt))
                      ;; Original text must NOT be repeated inside the popup!
                      (should-not (string-match-p "First wrapped line" qtxt))
                      (should (string-match-p "复制 (c)" qtxt))
                      (should (string-match-p "换引擎 (e)" qtxt))
                      (should-not (string-match-p "加入术语表" qtxt))))
                (etaf-translate-popup-close))))
          ;; Without an active region, translates only the word at point (never whole paragraph).
          (deactivate-mark)
          (setq seen-popup-inputs nil)
          (goto-char (point-min))
          (should (search-forward "work" nil t))
          (let ((pop-buf (etaf-translate-at-point nil 'test-ui-eng)))
            (unwind-protect
                (progn
                  (should (equal seen-popup-inputs '("workspace")))
                  (let ((qtxt (with-current-buffer pop-buf
                                (buffer-substring-no-properties (point-min) (point-max)))))
                    (should (string-match-p "工作区" qtxt))
                    (should-not (string-match-p "workspace" qtxt))))
              (etaf-translate-popup-close))))))))

(ert-deftest etaf-translate-latex-math-protection-and-paragraph-toggle ()
  "LaTeX formulas stay atomic while prices translate normally; paragraph toggles cleanly."
  (let ((seen nil)
        (etaf-translate-enable-disk-cache nil)
        (etaf-translate-state-file nil))
    (etaf-translate-test--with-engine
        'test-math
        (:supports-batch t
         :translate
         (lambda (req on-done _on-error)
           (let ((units (plist-get req :units)))
             (setq seen (append seen units))
             (funcall on-done
                      (mapcar (lambda (s)
                                (cond
                                 ((string-search "Energy satisfies" s)
                                  "物理学中能量满足 ⟦c0⟧ 与 ⟦c1⟧。")
                                 ((string-search "costs $100" s)
                                  "今天需要花费 $100 和 $200。")
                                 (t (concat "译:" s))))
                              units)))
           nil))
      (etaf-translate-test--with-mount
          (runtime
           (etaf-view
            (column :width 'stretch :item-gap '(lh 1)
              (box :width 'stretch :wrap-mode 'word
                (text "Energy satisfies $E = mc^2$ and $\\alpha + \\beta = 1$ in physics."))
              (box :width 'stretch :wrap-mode 'word
                (text "It costs $100 and $200 today."))))
           '(:viewport-width 800 :viewport-height 24))
        (etaf-translate-enable runtime :engine 'test-math
                               :cache (etaf-translate-cache-create))
        ;; Math expressions were atomized into ⟦c0⟧/⟦c1⟧, while currency stayed raw!
        (should (cl-some (lambda (s)
                           (and (string-search "⟦c0⟧" s)
                                (string-search "⟦c1⟧" s)
                                (not (string-search "mc^2" s))))
                         seen))
        (should (cl-some (lambda (s) (string-search "$100 and $200" s)) seen))
        (let ((txt (etaf-translate-test--buffer-text runtime)))
          (should (string-match-p "\\$E = mc\\^2\\$" txt))
          (should (string-match-p "今天需要花费 \\$100 和 \\$200" txt)))
        ;; Disable whole page, then verify bidirectional single-paragraph toggle!
        (etaf-translate-disable runtime)
        (with-current-buffer (etaf-runtime-buffer runtime)
          (goto-char (point-min))
          (let ((etaf-translate-default-engine 'test-math))
            (should (integerp (etaf-translate-paragraph runtime)))
            (should (string-match-p "物理学中能量满足"
                                    (etaf-translate-test--buffer-text runtime)))
            ;; Calling again on the same paragraph restores it!
            (should-not (etaf-translate-paragraph runtime))
            (should-not (string-match-p "物理学中能量满足"
                                        (etaf-translate-test--buffer-text runtime)))))
        ;; In an ordinary (non-ETAF) Emacs buffer, `etaf-translate-paragraph'
        ;; translates the full wrapped paragraph at point in the quick popup.
        (let ((etaf-translate-default-engine 'test-math)
              (etaf-translate-use-posframe nil))
          (setq seen nil)
          (with-temp-buffer
            (insert "First line of a normal buffer\nparagraph with wrapped prose.\n\nSecond paragraph.")
            (goto-char (point-min))
            (forward-word 2)
            (let ((pop-buf (etaf-translate-paragraph)))
              (unwind-protect
                  (progn
                    (should (buffer-live-p pop-buf))
                    (should (member "First line of a normal buffer paragraph with wrapped prose."
                                    seen))
                    (let ((qtxt (with-current-buffer pop-buf
                                  (buffer-substring-no-properties (point-min) (point-max)))))
                      (should (string-match-p "译:First line of a normal buffer" qtxt))))
                (etaf-translate-popup-close)))))))))

(ert-deftest etaf-translate-etaf-reader-provider-and-page-switch ()
  "Built-in etaf-reader provider merges pre-wrapped lines into logical paragraphs and handles page turns."
  (let* ((page-lines (etaf-ref
                      '("First wrapped line of a"
                        "logical English paragraph."
                        " "
                        "Second short paragraph.")))
         (seen nil)
         (etaf-translate-commit-debounce 0)
         (etaf-translate-state-file nil))
    (etaf-translate-test--with-engine
        'test-reader
        (:supports-batch t
         :translate
         (lambda (req on-done _on-error)
           (let ((units (plist-get req :units)))
             (setq seen (append seen units))
             (funcall on-done
                      (mapcar (lambda (s) (concat "书译：" s)) units)))
           nil))
      (etaf-translate-test--with-mount
          (runtime
           (lambda ()
             (let ((ls (etaf-value page-lines)))
               (etaf-view
                (column :width 'stretch
                  (box :for (pair (cl-loop for l in ls for i from 0 collect (cons i l)))
                       :key (car pair)
                       :id (format "reader-line-%d" (car pair))
                       :width 'stretch :height '(lh 1) :overflow 'hidden :wrap-mode 'none
                    (text (expr (cdr pair))))))))
           '(:viewport-width 640 :viewport-height 24))
        (etaf-translate-enable runtime :engine 'test-reader
                               :cache (etaf-translate-cache-create))
        ;; Wrapped lines 0+1 were joined into ONE logical paragraph before translation!
        (should (member "First wrapped line of a logical English paragraph." seen))
        (should (member "Second short paragraph." seen))
        (let ((txt (etaf-translate-test--buffer-text runtime)))
          (should (string-match-p "书译：First wrapped line of a logical English paragraph\\." txt))
          (should (string-match-p "书译：Second short paragraph\\." txt)))
        ;; Simulate turning to next page: new logical paragraph translates cleanly.
        (setq seen nil)
        (etaf-set-value page-lines '("Next page opening sentence." " " " "))
        (should (member "Next page opening sentence." seen))
        (should (string-match-p "书译：Next page opening sentence\\."
                                (etaf-translate-test--buffer-text runtime)))
        (etaf-translate-disable runtime)
        (should-not (string-match-p "书译：" (etaf-translate-test--buffer-text runtime)))))))

(ert-deftest etaf-translate-maillist-logical-paragraphs ()
  "Built-in maillist provider joins 72-col wrapped lines and quotes into logical paragraphs and skips sidebar/diff/signature."
  (let ((seen nil)
        (etaf-translate-state-file nil)
        (etaf-translate-enable-disk-cache nil)
        (buf (generate-new-buffer "*maillist*")))
    (unwind-protect
        (etaf-translate-test--with-engine
            'test-ml
            (:supports-batch t
             :translate
             (lambda (req on-done _on-error)
               (let ((units (plist-get req :units)))
                 (setq seen (append seen units))
                 (funcall on-done
                          (mapcar (lambda (s) (concat "邮译：" s)) units)))
               nil))
          (etaf-mount
           buf
           (etaf-view
            (flex :flex-direction 'row :width 'stretch :height '(lh 30)
              ;; Left thread sidebar (MUST NOT be translated).
              (column :width '(ch 30) :flex-shrink 0
                (box :role 'button :width 'stretch
                  (text "Sidebar thread item should stay untranslated")))
              ;; Right maillist reader region.
              (flex :flex-direction 'column :flex-grow 1 :width 'stretch
                    :region '(:id reader :label "邮件正文")
                (column :width 'stretch :flex-shrink 0 :item-gap '(lh 0)
                  (etaf-label :text "[NonGNU ELPA] New package: tvwall" :variant 'heading)
                  (box :height '(lh 1)))
                (column :width 'stretch :flex-grow 1 :overflow 'scroll
                        :role 'region :aria-label "邮件正文" :item-gap '(lh 0)
                  (column :width 'stretch :item-gap '(lh 0)
                    ;; Message body lines container (:padding-left '(ch 3)).
                    (column :width 'stretch :item-gap '(lh 0) :padding-left '(ch 3)
                      ;; 3-line wrapped quote block
                      (column :width 'stretch :item-gap '(lh 0)
                        (box :width 'stretch :background-color "#2c3940"
                             :border-left '((px 2) solid "#546e7a") :padding-left '(ch 1)
                          (etaf-label :text "> First wrapped line of quoted" :variant 'muted)))
                      (column :width 'stretch :item-gap '(lh 0)
                        (box :width 'stretch :background-color "#2c3940"
                             :border-left '((px 2) solid "#546e7a") :padding-left '(ch 1)
                          (etaf-label :text "> argument in this discussion." :variant 'muted)))
                      (column :width 'stretch :item-gap '(lh 0)
                        (box :width 'stretch :background-color "#2c3940"
                             :border-left '((px 2) solid "#546e7a") :padding-left '(ch 1)
                          (etaf-label :text ">" :variant 'muted)))
                      (column :width 'stretch :item-gap '(lh 0)
                        (box :width 'stretch :background-color "#2c3940"
                             :border-left '((px 2) solid "#546e7a") :padding-left '(ch 1)
                          (etaf-label :text "> Second quoted sentence." :variant 'muted)))
                      ;; Blank spacer
                      (column :width 'stretch :item-gap '(lh 0)
                        (box :height '(lh 1)))
                      ;; 2-line wrapped prose paragraph
                      (column :width 'stretch :item-gap '(lh 0)
                        (flex :width 'stretch
                          (etaf-label :text "First of all, the submitter themselves has")))
                      (column :width 'stretch :item-gap '(lh 0)
                        (flex :width 'stretch
                          (etaf-label :text "retracted their proposal cleanly.")))
                      ;; Blank spacer
                      (column :width 'stretch :item-gap '(lh 0)
                        (box :height '(lh 1)))
                      ;; Patch diff line (must be skipped)
                      (column :width 'stretch :item-gap '(lh 0)
                        (flex :width 'stretch :background-color "#1d3b2b"
                          (etaf-label :text "+ (defun patched-fn () t)")))
                      ;; Signature block (must be skipped)
                      (column :width 'stretch :item-gap '(lh 0)
                        (flex :width 'stretch (etaf-label :text "-- ")))
                      (column :width 'stretch :item-gap '(lh 0)
                        (flex :width 'stretch (etaf-label :text "Best regards, Maintainer")))))))))
           '(:viewport-width 960 :viewport-height 30))
          (let ((rt (etaf-runtime-for-buffer buf)))
            (etaf-translate-enable rt :engine 'test-ml
                                   :cache (etaf-translate-cache-create))
            ;; Exactly 4 logical units: heading + 2 quote paragraphs + 1 prose paragraph!
            (should (= 4 (length seen)))
            (should (member "[NonGNU ELPA] New package: tvwall" seen))
            (should (member "First wrapped line of quoted argument in this discussion." seen))
            (should (member "Second quoted sentence." seen))
            (should (member "First of all, the submitter themselves has retracted their proposal cleanly." seen))
            ;; Sidebar, diff and signature were NEVER sent to the engine.
            (should-not (cl-some (lambda (u) (string-search "Sidebar" u)) seen))
            (should-not (cl-some (lambda (u) (string-search "patched-fn" u)) seen))
            (should-not (cl-some (lambda (u) (string-search "Best regards" u)) seen))
            ;; Rendered text has full-paragraph translation once, never line-by-line or "| >".
            (let ((txt (etaf-translate-test--buffer-text rt)))
              (should (string-search "邮译：First of all, the submitter themselves has retracted their proposal cleanly." txt))
              (should (string-search "邮译：First wrapped line of quoted argument in this discussion." txt))
              (should-not (string-search "邮译：>" txt)))
            ;; Replace mode hides wrapped prefix line and renders full paragraph once.
            (etaf-translate-set-mode 'replace rt)
            (let ((rtxt (etaf-translate-test--buffer-text rt)))
              (should (string-search "邮译：First of all, the submitter themselves has retracted their proposal cleanly." rtxt))
              (should-not (string-search "First of all, the submitter themselves has\n" rtxt)))
            ;; Switching back to bilingual-stacked restores wrapped original lines cleanly.
            (etaf-translate-set-mode 'bilingual-stacked rt)
            (let ((btxt (etaf-translate-test--buffer-text rt)))
              (should (string-search "First of all, the submitter themselves has" btxt))
              (should (string-search "retracted their proposal cleanly." btxt)))
            (etaf-translate-disable rt)
            (should-not (string-search "邮译：" (etaf-translate-test--buffer-text rt)))))
      (when (buffer-live-p buf)
        (when-let* ((rt (etaf-runtime-for-buffer buf)))
          (ignore-errors (etaf-unmount rt)))
        (kill-buffer buf)))))

(provide 'etaf-translate-tests)
;;; etaf-translate-tests.el ends here
