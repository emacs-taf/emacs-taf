;;; etaf-manual-reader.el --- The ETAF manual reader application -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; The application entry of the manual reader: the mounted Component, the
;; buffer and keymap, and the commands that drive `etaf-manual-reader-model'.
;; A reader session is a headless value; this module gives it a buffer and
;; the interactive commands, and `etaf-manual-lookup' opens the manual at a
;; symbol's definition entry from anywhere in Emacs.
;;
;; Public entry points are recorded in the `etaf-manual' Commentary.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'etaf)
(require 'etaf-ui)
(require 'etaf-manual-reader-model)
(require 'etaf-manual-reader-style)
(require 'etaf-manual-reader-views)

(declare-function etaf-manual-book "etaf-manual" (&optional language))
(declare-function etaf-manual-definition "etaf-manual" (name &optional kind language))

(defvar-local etaf-manual-reader--session nil
  "Manual reader session shown by the current buffer's runtime.")

;;;; Component

(etaf-define-component etaf-manual-reader-app (&key session)
  "Render the mounted manual reader for SESSION and own its lifecycle.
SESSION must come from `etaf-manual-reader-create'.  Mounting provides the
palette for its subtree; every displayed value is read from the session's
reactive sources, so a chapter change, a language switch or a theme switch
repaints the reader without a remount."
  :bindings ((reader (or session
                         (signal 'etaf-manual-error
                                 '("etaf-manual-reader-app needs the :session from `etaf-manual-reader-create'"))))
             (theme (etaf-manual-reader--ref reader :theme))
             (tokens (etaf-computed
                      (lambda ()
                        (etaf-manual-reader-theme-tokens (etaf-value theme)))
                      :name 'etaf-manual-reader-theme-tokens)))
  :setup
  (progn
    (etaf-theme-provide tokens)
    ;; One appearance state for the reader and the panel that frames it: the
    ;; title bar's switch writes the session's palette mode, `T' writes the
    ;; same cell, and both the reading surface and the panel's chrome paint
    ;; from it.  A host that frames the reader declares the modes too.
    (when-let* ((surface (etaf-surface-host)))
      (etaf-surface-declare surface :theme tokens :mode theme
                            :modes etaf-manual-reader--theme-modes))
    ;; The reader's commands find their session in the buffer they run in.
    ;; `etaf-manual-open' records it itself, but a panel or a desktop host
    ;; mounts the same View without it, and the keys there must reach this
    ;; session instead of reporting that the buffer is not a reader.
    (etaf-on-mounted
     (lambda ()
       (when-let* ((runtime (etaf-current-runtime))
                   (buffer (and runtime (etaf-runtime-buffer runtime))))
         (when (buffer-live-p buffer)
           ;; The session records the buffer it renders into, which is what
           ;; scrolling, progressive rendering and remembering read; a host
           ;; other than `etaf-manual-open' must set it too.
           (plist-put reader :buffer buffer)
           (with-current-buffer buffer
             (setq-local etaf-manual-reader--session reader))))))
    (etaf-on-unmounted
     (lambda ()
       (when-let* ((runtime (etaf-current-runtime))
                   (buffer (and runtime (etaf-runtime-buffer runtime))))
         (when (buffer-live-p buffer)
           (with-current-buffer buffer
             (when (eq etaf-manual-reader--session reader)
               (kill-local-variable 'etaf-manual-reader--session))))
         (when (eq (plist-get reader :buffer) buffer)
           (plist-put reader :buffer nil))
         ;; A mount renders the whole chapter again, so the next mount of a
         ;; kept-alive session is complete instead of resuming a partial
         ;; extent that no buffer is growing any more.
         (etaf-manual-reader--write reader :extent nil)))))
  :render
  ;; A headless mount (batch or a hidden buffer) reports a zero viewport, so
  ;; only positive measurements are trusted; the renderer then keeps its
  ;; wide layout and a default page height.
  (let* ((viewport (etaf-viewport))
         ;; The framework reports the canvas's own columns, so the reader fits
         ;; its panels with the cell the page is drawn in.
         (columns (and viewport (numberp (car viewport)) (> (car viewport) 0)
                       (max 20 (or (ignore-errors (etaf-canvas-columns)) 20))))
         (rows (and viewport (numberp (cdr viewport)) (> (cdr viewport) 0)
                    (cdr viewport))))
    (etaf-manual-reader--shell reader (etaf-manual-reader--env reader columns rows)
                              (etaf-manual-reader--key-entries))))

(defun etaf-manual-reader-view (session)
  "Return the application View of SESSION.
Use it to embed the reader in your own `etaf-mount' call; prefer
`etaf-manual-open' to also get a buffer, a keymap and window metrics."
  (etaf-view (etaf-manual-reader-app :session session)))

;;;; Buffer and commands

;;;###autoload
(defun etaf-manual-reader-session (&optional buffer)
  "Return the reader session mounted in BUFFER-OR-NAME, or nil.
BUFFER-OR-NAME defaults to the current buffer.  Every host that mounts
`etaf-manual-reader-view' records its session in the buffer it renders into,
so the reader's commands and their Host keys find the session they act on.
A buffer without a mounted reader returns nil."
  (let ((buffer (get-buffer (or buffer (current-buffer)))))
    (and (buffer-live-p buffer)
         (buffer-local-value 'etaf-manual-reader--session buffer))))

(defun etaf-manual-reader--current ()
  "Return the session of the current buffer."
  (or (etaf-manual-reader-session)
      (user-error "当前缓冲区不是 ETAF 手册阅读器")))

(defun etaf-manual-reader--display (session name)
  "Mount SESSION in the buffer NAME and return that buffer."
  (let ((buffer (get-buffer-create name)))
    (plist-put session :buffer buffer)
    (etaf-manual-reader--reveal
     session (or (etaf-manual-reader--read session :node) 0) t)
    (with-current-buffer buffer
      (etaf-manual-reader-mode)
      (setq-local etaf-manual-reader--session session)
      (add-hook 'kill-buffer-hook #'etaf-manual-reader--remember-on-kill nil t)
      (setq-local truncate-lines t)
      ;; The reader is a document surface: Ebox repaints the canvas in place
      ;; while scrolling, so a buffer caret would look like it jumps between
      ;; contents.  Hide it; editing fields raise their own bar cursor.
      (setq-local cursor-type nil)
      (setq-local scroll-preserve-screen-position t)
      ;; The reader owns every column it paints; a sub-cell rounding
      ;; remainder must not surface as Emacs's truncation glyph.
      (setq-local buffer-display-table
                  (let ((table (copy-sequence (or standard-display-table
                                                  (make-display-table)))))
                    (set-display-table-slot table 'truncation ?\s)
                    table)))
    ;; The reader is a whole-window application: replace the selected
    ;; window instead of splitting it.
    (pop-to-buffer buffer '(display-buffer-same-window))
    (etaf-mount buffer (etaf-manual-reader-view session))
    (etaf-runtime-flush (etaf-runtime-for-buffer buffer))
    (etaf-manual-reader--scroll-to-node session)
    buffer))

(defun etaf-manual-open (&optional chapter)
  "Open the ETAF manual reader and return its buffer.
CHAPTER names the starting chapter identifier; interactively the manual
opens at the remembered reading position when there is one, otherwise at
its first chapter."
  (interactive)
  (let ((session (etaf-manual-reader-create :chapter chapter)))
    (unless chapter
      (etaf-manual-reader-restore session))
    (etaf-manual-reader--display session "*ETAF 手册*")))

(defun etaf-manual-reader--remember-on-kill ()
  "Remember the reading position of the reader buffer being killed."
  (when etaf-manual-reader--session
    (etaf-manual-reader-remember etaf-manual-reader--session)))

(defun etaf-manual-close ()
  "Unmount and kill the current manual reader buffer."
  (interactive)
  (let ((session (etaf-manual-reader--current))
        (buffer (current-buffer)))
    (etaf-manual-reader-remember session)
    (when-let* ((runtime (etaf-runtime-for-buffer buffer)))
      (etaf-unmount runtime))
    (plist-put session :buffer nil)
    (when (buffer-live-p buffer)
      (kill-buffer buffer))))

(defun etaf-manual-reader--reusable-session ()
  "Return an existing reader session, or nil."
  (cl-loop for buffer in (buffer-list)
           for session = (and (buffer-live-p buffer)
                              (buffer-local-value 'etaf-manual-reader--session buffer))
           when session return session))

(defun etaf-manual-reader--definition-names (&optional language)
  "Return the manual's definition entry names in LANGUAGE."
  (let ((names nil)
        (seen (make-hash-table :test #'eq)))
    (dolist (chapter (plist-get (etaf-manual-book language) :chapters))
      (dolist (definition (plist-get chapter :definitions))
        (let ((name (plist-get definition :name)))
          (unless (gethash name seen)
            (puthash name t seen)
            (push name names)))))
    (nreverse names)))

(defun etaf-manual-lookup (symbol &optional kind)
  "Open the manual at the definition entry of SYMBOL.
KIND restricts the entry to one definition kind.  Interactively the symbol
at point is used when it has a definition entry; otherwise the command
reads a name with completion.  A symbol without an entry signals a
`user-error'.  With an open reader the same buffer is reused."
  (interactive
   (let* ((at (thing-at-point 'symbol t))
          (session (etaf-manual-reader--reusable-session))
          (language (and session (etaf-manual-reader--read session :language)))
          (name (and at (intern at))))
     (list (if (and name (etaf-manual-definition name nil language))
               name
             (intern (completing-read
                      "符号: "
                      (mapcar #'symbol-name
                              (etaf-manual-reader--definition-names language))
                      nil t nil nil (and at (list at)))))
           nil)))
  (let ((definition (etaf-manual-definition symbol kind)))
    (unless definition
      (user-error "手册里没有 %s 的定义" symbol))
    (let* ((session (or (etaf-manual-reader--reusable-session)
                        (etaf-manual-reader-create)))
           (buffer (or (etaf-manual-reader--buffer session)
                       (etaf-manual-reader--display session "*ETAF 手册*"))))
      (etaf-manual-reader-goto
       session (plist-get definition :chapter)
       (etaf-manual-reader--node-for-line session (plist-get definition :line)
                                          (plist-get definition :chapter)))
      (pop-to-buffer buffer)
      (etaf-manual-reader-scroll-to-definition session symbol))))

(defun etaf-manual-reader--buffer (session)
  "Return SESSION's live buffer, or nil."
  (when-let* ((buffer (plist-get session :buffer)))
    (and (buffer-live-p buffer) buffer)))

(defun etaf-manual-reader-index ()
  "Choose a chapter, section, definition entry or index term and jump to it."
  (interactive)
  (let* ((session (etaf-manual-reader--current))
         (targets (etaf-manual-reader-jump-targets session))
         (choice (completing-read "跳转: " (mapcar #'car targets) nil t))
         (target (cdr (assoc choice targets))))
    (when target
      (etaf-manual-reader-goto session (plist-get target :chapter)
                               (plist-get target :node))
      (when-let* ((anchor (plist-get target :anchor)))
        (etaf-manual-reader--goto-anchor session anchor))
      (etaf-manual-reader--after-navigation session)
      (when-let* ((name (plist-get target :definition)))
        (etaf-manual-reader-scroll-to-definition session name))
      (etaf-manual-reader-message session (format "已跳转：%s" choice)))))

;;;; Search

(defun etaf-manual-reader--search-status (session)
  "Return a status line for SESSION's current search result."
  (pcase-let* ((search (etaf-manual-reader--read session :search))
               (index (plist-get search :index))
               (count (length (plist-get search :matches)))
               (state (etaf-manual-reader-state session)))
    (format "「%s」第 %d/%d 个结果 · %s"
            (plist-get search :query) (1+ index) count
            (if-let* ((node-title (plist-get state :node-title)))
                (format "%s › %s" (plist-get state :chapter-title) node-title)
              (plist-get state :chapter-title)))))

(defun etaf-manual-reader--scroll-to-search-match (session)
  "Scroll SESSION to the definition entry of its current search result."
  (when-let* ((match (etaf-manual-reader-search-match session))
              (name (plist-get match :definition)))
    (etaf-manual-reader-scroll-to-definition session name)))

(defun etaf-manual-reader-search-command (&optional query)
  "Search the manual for QUERY and move to the first matching section."
  (interactive)
  (let ((session (etaf-manual-reader--current)))
    (condition-case error
        (let* ((previous (plist-get (etaf-manual-reader--read session :search) :query))
               (query (or query
                          (read-string (if previous
                                           (format "搜索（默认 %s）: " previous)
                                         "搜索: ")
                                       nil nil previous)))
               (count (etaf-manual-reader-search session query)))
          (if (> count 0)
              (progn
                (etaf-manual-reader--after-navigation session)
                (etaf-manual-reader--scroll-to-search-match session)
                (etaf-manual-reader-message session
                                             (etaf-manual-reader--search-status session)))
            (etaf-manual-reader-message session (format "找不到 \"%s\"" query))))
      (user-error (etaf-manual-reader--report error)))))

(defun etaf-manual-reader-search-next-command ()
  "Move to the next search result, asking for a query when none is active."
  (interactive)
  (let ((session (etaf-manual-reader--current)))
    (if (null (plist-get (etaf-manual-reader--read session :search) :matches))
        (call-interactively #'etaf-manual-reader-search-command)
      (condition-case error
          (progn
            (etaf-manual-reader-search-next session)
            (etaf-manual-reader--after-navigation session)
            (etaf-manual-reader--scroll-to-search-match session)
            (etaf-manual-reader-message session (etaf-manual-reader--search-status session)))
        (user-error (etaf-manual-reader--report error))))))

(defun etaf-manual-reader-search-previous-command ()
  "Move to the previous search result."
  (interactive)
  (let ((session (etaf-manual-reader--current)))
    (if (null (plist-get (etaf-manual-reader--read session :search) :matches))
        (call-interactively #'etaf-manual-reader-search-command)
      (condition-case error
          (progn
            (etaf-manual-reader-search-previous session)
            (etaf-manual-reader--after-navigation session)
            (etaf-manual-reader--scroll-to-search-match session)
            (etaf-manual-reader-message session (etaf-manual-reader--search-status session)))
        (user-error (etaf-manual-reader--report error))))))

;;;; Examples and code

(defun etaf-manual-reader-edit-example-command ()
  "Edit the example at the reading position; C-c C-c reruns it."
  (interactive)
  (let* ((session (etaf-manual-reader--current))
         (example (etaf-manual-reader--example-at session)))
    (if (null example)
        (etaf-manual-reader-message session "本节没有可编辑的示例")
      (let ((id (plist-get example :id)))
        (etaf-manual-reader--write session :editing id)
        (when-let* ((runtime (etaf-manual-reader--runtime session)))
          (run-at-time 0 nil
                       (lambda (runtime ref)
                         (ignore-errors (etaf-text-input-begin runtime ref)))
                       runtime
                       (intern (format "etaf-manual-example-edit-%s" id))))))))

(defun etaf-manual-reader-copy-code-command ()
  "Copy the code at the reading position to the kill ring."
  (interactive)
  (let* ((session (etaf-manual-reader--current))
         (code (etaf-manual-reader--code-at session)))
    (if (and (stringp code) (not (string-empty-p code)))
        (progn
          (kill-new code)
          (etaf-manual-reader-message session "已复制代码"))
      (etaf-manual-reader-message session "本节没有可复制的代码"))))

;;;; Interactive commands

(defun etaf-manual-reader--report (error)
  "Report ERROR in the reader status area."
  (etaf-manual-reader-message (etaf-manual-reader--current)
                              (error-message-string error)))

(defun etaf-manual-reader-next-command ()
  "Move to the next section."
  (interactive)
  (let ((session (etaf-manual-reader--current)))
    (condition-case error
        (progn (etaf-manual-reader-next session)
               (etaf-manual-reader--after-navigation session))
      (user-error (etaf-manual-reader--report error)))))

(defun etaf-manual-reader-previous-command ()
  "Move to the previous section."
  (interactive)
  (let ((session (etaf-manual-reader--current)))
    (condition-case error
        (progn (etaf-manual-reader-previous session)
               (etaf-manual-reader--after-navigation session))
      (user-error (etaf-manual-reader--report error)))))

(defun etaf-manual-reader-up-command ()
  "Move one level up in the outline."
  (interactive)
  (let ((session (etaf-manual-reader--current)))
    (condition-case error
        (progn (etaf-manual-reader-up session)
               (etaf-manual-reader--after-navigation session))
      (user-error (etaf-manual-reader--report error)))))

(defun etaf-manual-reader-back-command ()
  "Return to the previous reading position."
  (interactive)
  (let ((session (etaf-manual-reader--current)))
    (condition-case error
        (progn (etaf-manual-reader-back session)
               (etaf-manual-reader--after-navigation session))
      (user-error (etaf-manual-reader--report error)))))

(defun etaf-manual-reader-forward-command ()
  "Move to the next reading position."
  (interactive)
  (let ((session (etaf-manual-reader--current)))
    (condition-case error
        (progn (etaf-manual-reader-forward session)
               (etaf-manual-reader--after-navigation session))
      (user-error (etaf-manual-reader--report error)))))

(defun etaf-manual-reader-next-chapter-command ()
  "Move to the next chapter."
  (interactive)
  (let ((session (etaf-manual-reader--current)))
    (condition-case error
        (progn (etaf-manual-reader-next-chapter session)
               (etaf-manual-reader--after-navigation session))
      (user-error (etaf-manual-reader--report error)))))

(defun etaf-manual-reader-previous-chapter-command ()
  "Move to the previous chapter."
  (interactive)
  (let ((session (etaf-manual-reader--current)))
    (condition-case error
        (progn (etaf-manual-reader-previous-chapter session)
               (etaf-manual-reader--after-navigation session))
      (user-error (etaf-manual-reader--report error)))))

(defun etaf-manual-reader-switch-language-command ()
  "Switch the reader between Chinese and English."
  (interactive)
  (let* ((session (etaf-manual-reader--current))
         (language (etaf-manual-reader--read session :language)))
    (etaf-manual-reader--switch-language
     session (if (equal language "zh-CN") "en" "zh-CN"))
    (etaf-manual-reader--after-navigation session)))

(defun etaf-manual-reader-toggle-theme-command ()
  "Switch the reader between the light and dark palettes."
  (interactive)
  (let* ((session (etaf-manual-reader--current))
         (theme (etaf-manual-reader-toggle-theme session)))
    (message "外观：%s" (or (cdr (assq theme etaf-manual-reader--theme-modes))
                          (symbol-name theme)))))

;;;; Keys

(defconst etaf-manual-reader--bindings
  '(("n" etaf-manual-reader-next-command "下一节")
    ("p" etaf-manual-reader-previous-command "上一节")
    ("u" etaf-manual-reader-up-command "上一级")
    ("l" etaf-manual-reader-back-command "后退")
    ("r" etaf-manual-reader-forward-command "前进")
    ("[" etaf-manual-reader-previous-chapter-command "上一章")
    ("]" etaf-manual-reader-next-chapter-command "下一章")
    ("/" etaf-manual-reader-search-command "搜索")
    ("M-n" etaf-manual-reader-search-next-command "下一处")
    ("M-p" etaf-manual-reader-search-previous-command "上一处")
    ("e" etaf-manual-reader-edit-example-command "编辑示例")
    ("w" etaf-manual-reader-copy-code-command "复制代码")
    ("g" etaf-manual-reader-switch-language-command "中英文切换")
    ("i" etaf-manual-reader-index "跳转")
    ("t" etaf-manual-reader-toggle-theme-command "外观：亮/随/暗")
    ("q" etaf-manual-close "退出阅读器"))
  "Reader keys as (KEY COMMAND LABEL).
The buffer's mode map and the page Host's `:keys' both come from this table,
so `?''s ETAF key help lists exactly the keys the reader binds.")

(defun etaf-manual-reader--key-entries ()
  "Return the reader's `:keys' entries for the page Host.
`l' is omitted under the Vim direction scheme: the framework owns the letter
as a direction key there, and a Host binding would be a render error."
  (mapcar (lambda (entry) (list (nth 0 entry) (nth 1 entry) (nth 2 entry)))
          (if (eq etaf-direction-scheme 'vim)
              (cl-remove "l" etaf-manual-reader--bindings
                         :key #'car :test #'equal)
            etaf-manual-reader--bindings)))

(defvar etaf-manual-reader-mode-map
  (let ((map (make-sparse-keymap)))
    (dolist (entry etaf-manual-reader--bindings)
      (define-key map (kbd (car entry)) (nth 1 entry)))
    map)
  "Keymap of a buffer opened by `etaf-manual-open'.
The mounted page Host also carries the same table as `:keys', so the keys
work when the reader View is embedded, `?' lists them with their labels in
the ETAF key help, and the framework keeps `TAB', `RET', the arrows,
`M-g', Escape and `?'.")

(define-derived-mode etaf-manual-reader-mode special-mode "ETAF手册"
  "Major mode of an ETAF manual reader buffer.
\\{etaf-manual-reader-mode-map}")

(provide 'etaf-manual-reader)
;;; etaf-manual-reader.el ends here
