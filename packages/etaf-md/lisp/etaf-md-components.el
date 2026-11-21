;;; etaf-md-components.el --- The site component catalog for etaf-md -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; The second half of the container catalog: the blocks a documentation site
;; writes around its prose rather than inside it.  A hero, an image card, a
;; link card, a package badge, a QR code, a slide deck, a source
;; tree and a package-manager command group share the same machinery as the
;; prose containers in `etaf-md-nodes': one definition per type, a thin view
;; that translates document attributes into existing `etaf-ui' components.
;;
;; Two of them need more than a translation.  `qrcode' asks an external
;; `qrencode' for the module matrix and caches it; `npm-to' rewrites one npm
;; command into the other package managers before showing the group as code
;; tabs.  Neither runs during a render: the QR is filled by
;; `etaf-md-qrcode-request' after a publish, and the rewrite is a pure
;; function of the block's single code fence.

;;; Code:

(require 'cl-lib)
(require 'subr-x)

(require 'etaf-md-node)
(require 'etaf-md-env)
(require 'etaf-ui)

(declare-function etaf-md--tabs-view "etaf-md-nodes" (env &optional page-view label-fn))
(declare-function etaf-md--code-tab-page "etaf-md-nodes" (env page))
(declare-function etaf-md--child-view "etaf-md-nodes" (env child))
(declare-function etaf-md--media-card "etaf-md-views" (url alt env &optional declared-kind))
(declare-function etaf-md-qrcode-view "etaf-md-qrcode" (env))
(declare-function etaf-md-qrcode-cached-p "etaf-md-qrcode" (env))
(declare-function etaf-md-qrcode-available-p "etaf-md-qrcode" ())

;;; ---------------------------------------------------------------------------
;;; Shared pieces
;;; ---------------------------------------------------------------------------

(defun etaf-md--component-card (env title description href extra)
  "Return the card-shaped frame used by the site's cards.
TITLE and DESCRIPTION become the card's named slots, HREF makes the whole
card follow the target, and EXTRA is a list of views painted under it."
  (etaf-view
    (etaf-card :title title
               :description description
               :on-press (when href
                           (lambda () (etaf-md-follow-link env href)))
      (expr (when extra
              (etaf-node 'column (list :width 'stretch :item-gap '(lh 0))
                         extra))))))

(declare-function etaf-md--open-file "etaf-md-model" (path))
(declare-function etaf-md--open-media "etaf-md-model" (session kind path))

(defun etaf-md--component-view-env (env)
  "Return the plist the shared view helpers read, built from ENV's definition.
A definition's environment carries the page services; the views that draw
prose take the plain plist they were written for, so the two are bridged
here once instead of in every card."
  (let ((session (etaf-md-env-session env)))
    (list :theme (etaf-md-env-theme env)
          :palette (etaf-md-env-palette env)
          :width (etaf-md-env-width env)
          :dir (plist-get session :dir)
          :open-url (lambda (url) (etaf-md-follow-link env url))
          :open-media (when session
                        (lambda (kind path)
                          (etaf-md--open-media session kind path)))
          :open-file #'etaf-md--open-file)))

(defun etaf-md--component-image (src alt env)
  "Return SRC as a media card with ALT for ENV.
SRC may be relative to the page; a remote source stays a placeholder that
opens in the browser, the same fallback the prose image uses."
  (etaf-md--media-card src alt (etaf-md--component-view-env env)))

(defun etaf-md--component-ink (env key)
  "Return the theme ink for KEY on ENV's page.
The palette carries the page's own keys; a definition falls back to the same
Theme tokens the rest of the catalog uses, so a component keeps its contrast
in both palettes."
  (let ((palette (etaf-md-env-palette env)))
    (or (etaf-md--palette-value palette key)
        (etaf-md--palette-value palette :ink))))

(defun etaf-md--component-lines (text)
  "Return TEXT split into lines, or nil when it is blank."
  (when (and text (not (string-blank-p text)))
    (split-string text "\n")))

;;; ---------------------------------------------------------------------------
;;; The hero
;;; ---------------------------------------------------------------------------

(defun etaf-md--home-box-view (env)
  "Paint a hero block: an accent title, its summary, and the content."
  (let ((title (etaf-md-attr env :title))
        (description (etaf-md-attr env :description))
        (href (etaf-md-attr env :href))
        (surface (etaf-md-surface env (etaf-md-attr env :background))))
    (etaf-view
      (box :width 'stretch
           :background-color surface
           :border (etaf-md--hairline env)
           :padding '((lh 1) (ch 3))
        (column :width 'stretch :item-gap '(lh 0)
          (expr
           (append
            (when title
              (list (etaf-node 'text
                               (list :color (etaf-md-accent env
                                                            (etaf-md-attr env :accent))
                                     :font-weight 'bold)
                               (list title))))
            (when description
              (list (etaf-node 'text
                               (list :color (etaf-md--component-ink env :muted))
                               (list description))))
            (when href
              (list (etaf-node 'text
                               (list :color (etaf-md-accent env 'primary)
                                     :font-weight 'bold
                                     :role 'link :tab-index 0
                                     :on-press (lambda () (etaf-md-follow-link env href)))
                               (list (format "→ %s" href)))))
            (when (or title description href)
              (list (etaf-node 'text (list :color (etaf-md--component-ink env :faint))
                               (list " "))))
            (list (etaf-md-content env)))))))))

(etaf-md--define-shipped 'home-box
  :name "home-box"
  :summary "首屏大块：标题、摘要、行动链接与正文"
  :attrs '((title       :type string :doc "主标题")
           (description :type string :doc "标题下的摘要")
           (href        :type string :doc "行动链接地址")
           (accent      :type accent :default primary :doc "标题的强调色")
           (background  :type surface :default raised :doc "底色"))
  :view #'etaf-md--home-box-view)

;;; ---------------------------------------------------------------------------
;;; Cards
;;; ---------------------------------------------------------------------------

(etaf-md--define-shipped 'image-card
  :name "image-card"
  :summary "一张带图片的卡片"
  :attrs '((src         :type string :required t :doc "图片路径，相对路径按文档解析")
           (title       :type string :doc "图片下的标题")
           (description :type string :doc "标题下的说明")
           (href        :type string :doc "整张卡片可点，跳到这个地址")
           (width       :type number :doc "图片列数上限，默认 46"))
  :view
  (lambda (env)
    (let* ((src (etaf-md-attr env :src))
           (title (etaf-md-attr env :title))
           (description (etaf-md-attr env :description))
           (href (etaf-md-attr env :href))
           (view-env (etaf-md--component-view-env env))
           (max-columns (min (or (etaf-md-attr env :width) 46)
                             (max 20 (- (etaf-md-env-width env) 4))))
           (grid (etaf-md--media-picture-size src view-env max-columns 14))
           (columns (if grid (car grid) max-columns))
           (body (list 'ch columns))
           (muted (etaf-md--component-ink env :muted)))
      (etaf-view
        (column :width (list 'ch (+ columns 2))
                :cross-align 'start
                :item-gap '(lh 0)
                :background-color (etaf-md-surface env 'raised)
                :border (etaf-md--hairline env)
                :padding '((lh 1) (ch 2))
                :on-press (when href
                            (lambda () (etaf-md-follow-link env href)))
          (expr (list (etaf-md--media-picture src view-env columns 14)))
          (expr (when (or title description)
                  (list (etaf-node 'text nil (list " ")))))
          (expr (when title
                  (list (etaf-node 'box (list :width body)
                                   (list (etaf-node 'text
                                                    (list :font-weight 'bold)
                                                    (list title)))))))
          (expr (when description
                  (list (etaf-node 'box (list :width body)
                                   (list (etaf-node 'text
                                                    (list :color muted)
                                                    (list description))))))))))))

(etaf-md--define-shipped 'link-card
  :name "link-card"
  :summary "一张整块可点的链接卡片"
  :attrs '((href        :type string :required t :doc "跳转地址")
           (title       :type string :required t :doc "卡片标题")
           (description :type string :doc "标题下的说明"))
  :view
  (lambda (env)
    (let ((href (etaf-md-attr env :href))
          (title (etaf-md-attr env :title))
          (description (etaf-md-attr env :description)))
      (etaf-view
        (column :width 'stretch
                :background-color (etaf-md-surface env 'raised)
                :border (etaf-md--hairline env)
                :padding '((lh 1) (ch 2))
                :item-gap '(lh 0)
                :on-press (lambda () (etaf-md-follow-link env href))
          (expr (list (etaf-node 'text (list :font-weight 'bold) (list title))))
          (expr (list (etaf-node 'text nil (list " "))))
          (expr (when description
                  (list (etaf-node 'text
                                   (list :color (etaf-md--component-ink env :muted))
                                   (list description)))))
          (expr (list (etaf-node 'text
                                 (list :color (etaf-md-accent env 'primary)
                                       :role 'link :tab-index 0)
                                 (list (format "→ %s" href))))))))))

(etaf-md--define-shipped 'npm-badge
  :name "npm-badge"
  :summary "一行静态 npm 徽章：名称、版本与下载量"
  :attrs '((name      :type string :required t :doc "包名")
           (version   :type string :doc "版本号，省略就不画")
           (downloads :type string :doc "下载量文字，省略就不画"))
  :view
  (lambda (env)
    (let ((name (etaf-md-attr env :name))
          (version (etaf-md-attr env :version))
          (downloads (etaf-md-attr env :downloads)))
      (etaf-view
        (row :item-gap '(ch 1) :width 'max-content
          (etaf-badge :text "npm" :variant 'info)
          (etaf-badge :text name :variant 'neutral)
          (expr (when version
                  (list (etaf-view
                          (etaf-badge :text (format "v%s" version)
                                      :variant 'success)))))
          (expr (when downloads
                  (list (etaf-view
                          (etaf-badge :text (format "↓ %s" downloads)
                                      :variant 'neutral))))))))))

;;; ---------------------------------------------------------------------------
;;; The QR code
;;; ---------------------------------------------------------------------------

(etaf-md--define-shipped 'qrcode
  :name "qrcode"
  :summary "把一段文本画成可扫描的二维码"
  :attrs '((text  :type string :required t :doc "要编码的文本")
           (title :type string :doc "二维码上方的说明"))
  :view
  (lambda (env)
    (let ((title (etaf-md-attr env :title))
          (drawn (etaf-md-qrcode-cached-p env)))
      (etaf-view
        (column :width 'stretch :cross-align 'center :item-gap '(lh 0)
          (expr (when title
                  (list (etaf-node 'text
                                   (list :color (etaf-md--component-ink env :muted))
                                   (list title)))))
          (expr (when drawn
                  (list (etaf-md-qrcode-view env))))
          (expr (unless drawn
                  (list (etaf-node 'text
                                   (list :color (etaf-md--component-ink env :faint))
                                   (list (if (etaf-md-qrcode-available-p)
                                             "（二维码生成中）"
                                           "（需要 qrencode 才能画出二维码）")))))))))))

(etaf-md--define-shipped 'swiper
  :name "swiper"
  :summary "轮播：一页一页翻，标题或序号组成下面的切换条"
  :accepts '((slide :attrs ((title    :type string :doc "切换条上的文字")
                            (selected :type boolean :default nil :doc "默认停在这一页"))))
  :child-syntax 'markers
  :view
  (lambda (env)
    (let* ((slides (etaf-md-children env))
           (count (length slides))
           (initial (or (cl-position-if
                         (lambda (slide) (etaf-md-attr env :selected slide))
                         slides)
                        0))
           (active (min (or (etaf-md-block-state env :active initial) 0)
                        (max 0 (1- count))))
           (slide (nth active slides))
           (picture (etaf-md--swiper-slide-picture env slide))
           (view-env (etaf-md--component-view-env env)))
      (etaf-view
        (column :width 'stretch :item-gap '(lh 0)
                :border (etaf-md--hairline env)
          (etaf-tabs
           :items (seq-map-indexed
                   (lambda (slide index)
                     (list :key index
                           :label (or (etaf-md-attr env :title slide)
                                      (format "%d/%d" (1+ index) count))))
                   slides)
           :active active
           :framed nil
           :on-change (lambda (key) (etaf-md-set-block-state env :active key)))
          (box :width 'stretch
               :background-color (etaf-md-surface env 'sunken)
               :border-top (etaf-md--hairline env)
               :padding '((lh 1) (ch 2))
            (expr
             (if picture
                 (list (etaf-node 'column
                                  (list :width 'stretch :cross-align 'center)
                                  (list (etaf-md--media-picture
                                         picture view-env
                                         (max 8 (- (etaf-md-env-width env) 8))
                                         12))))
               (list (etaf-md--child-view env slide))))))))))

(defun etaf-md--swiper-slide-picture (env slide)
  "Return SLIDE's single image URL when the slide holds only that picture.
A slide written as one image line is a picture, not a figure: the stage draws
it without a second frame or caption inside itself."
  (let ((children (etaf-md-children env slide)))
    (when (= 1 (length children))
      (let* ((block (etaf-md-node-block (car children))))
        (when (eq (plist-get block :type) 'paragraph)
          (let ((images (seq-filter (lambda (node)
                                      (eq (plist-get node :type) 'image))
                                    (plist-get block :children))))
            (when (= 1 (length images))
              (plist-get (car images) :url))))))))

(defun etaf-md--code-tree-files (env)
  "Return (PATH . NODE) for each file ENV's tree lists."
  (seq-map (lambda (file)
             (cons (or (etaf-md-attr env :title file) "")
                   (car (etaf-md-children env file))))
           (etaf-md-children env)))

(defun etaf-md--code-tree-rows (files)
  "Return display rows for FILES.
A directory is `(dir . NAME)' and appears when it changes; a file is
`(file . (INDEX . NAME))' under it."
  (let ((rows nil) (last 'none))
    (seq-map-indexed
     (lambda (file index)
       (let* ((path (car file))
              (dir (file-name-directory path))
              (name (file-name-nondirectory path)))
         (when (and dir (not (equal dir last)))
           (push (cons 'dir dir) rows)
           (setq last dir))
         (push (cons 'file (cons index name)) rows)))
     files)
    (nreverse rows)))

(defun etaf-md--code-tree-code (env node)
  "Return NODE's code drawn for ENV's tree."
  (when node
    (etaf-ui-markdown-view-block
     ;; The card draws the frame and the language row; the fence contributes
     ;; only its highlighted body, so scrolling moves the code alone.
     (plist-put (plist-put (copy-sequence (etaf-md-node-block node))
                           :frame nil)
                :header nil)
     (etaf-md--component-view-env env))))

(defun etaf-md--code-tree-view (env)
  "Paint a file list beside the selected file's code.
The list and the code are the two panels of one card; the code keeps its
language row fixed above the body that scrolls under it."
  (let* ((files (etaf-md--code-tree-files env))
         (count (length files))
         (active (min (or (etaf-md-block-state env :active 0) 0)
                      (max 0 (1- count))))
         (selected (nth active files))
         (lang (and selected
                    (plist-get (etaf-md-node-block (cdr selected)) :lang)))
         (rows (etaf-md--code-tree-rows files))
         (height (max 4 (or (etaf-md-attr env :height) 18)))
         (total (+ height 1))
         (width (min 40
                     (max 14
                          (+ 7 (seq-max
                                (mapcar (lambda (row)
                                          (if (eq (car row) 'dir)
                                              (length (cdr row))
                                            (+ 2 (length (cdr (cdr row))))))
                                        rows))))))
         (accent (etaf-md-accent env 'primary))
         (accent-soft (or (etaf-md--palette-value (etaf-md-env-palette env)
                                                   :accent-soft)
                          (etaf-md-surface env 'sunken)))
         (muted (etaf-md--component-ink env :muted))
         (faint (etaf-md--component-ink env :faint))
         (scroll-ref
          (let* ((table (plist-get (etaf-md-env-session env) :block-refs))
                 (base (and (hash-table-p table)
                            (gethash (etaf-md--block-identity env) table))))
            (intern (format "%s-scroll" (or base (sxhash (etaf-md--block-identity env))))))))
    (etaf-view
      (row :width 'stretch :item-gap '(ch 1)
        (box :width (list 'ch width)
             :height (list 'lh total)
             :min-height (list 'lh total)
             :max-height (list 'lh total)
             :flex-shrink 0
             :border (etaf-md--hairline env)
             :background-color (etaf-md-surface env 'raised)
             :padding '((lh 1) (ch 1))
          (column :width 'stretch
                  :cross-align 'stretch
                  :item-gap '(lh 0)
            (expr
             (mapcar
              (lambda (row)
                (if (eq (car row) 'dir)
                    (etaf-node 'box
                               (list :width 'stretch
                                     :height (list 'lh 1)
                                     :padding-inline '(ch 1))
                               (list (etaf-node 'text
                                                (list :color faint)
                                                (list (cdr row)))))
                  (let* ((index (car (cdr row)))
                         (name (cdr (cdr row)))
                         (chosen (= index active)))
                    (etaf-node 'box
                               (list :width 'stretch
                                     :height (list 'lh 1)
                                     :padding-inline '(ch 2)
                                     :role 'button :tab-index 0
                                     :on-press (lambda ()
                                                 (etaf-md-set-block-state
                                                  env :active index)))
                               (list (etaf-node 'text
                                                ;; The fill belongs to the name's
                                                ;; own line, not to the box.
                                                (list :background-color (when chosen accent-soft)
                                                      :color (if chosen accent muted)
                                                      :font-weight (when chosen 'bold))
                                                (list name)))))))
              rows))))
        (column :width 'stretch
                :height (list 'lh total)
                :min-height (list 'lh total)
                :max-height (list 'lh total)
                :flex-shrink 0
                :border (etaf-md--hairline env)
                :background-color (or (etaf-md--palette-value
                                       (etaf-md-env-palette env) :code-bg)
                                      (etaf-md--palette-value
                                       (etaf-md-env-palette env) :panel))
          (box :width 'stretch
               :height (list 'lh 1)
               :border-bottom (etaf-md--hairline env)
               :padding-inline '(ch 2)
            (expr (list (etaf-node 'text
                                   (list :color muted)
                                   (list (or lang ""))))))
          (box :width 'stretch
               :height (list 'lh height)
               :min-height (list 'lh height)
               :max-height (list 'lh height)
               :overflow 'scroll
               :tab-index 0
               :ref scroll-ref
               :padding-inline '(ch 1)
               ;; A Host registered for scroll owns the wheel; the keyboard
               ;; moves the same Host, so the page around it stays put.
               :on-scroll (lambda (_offset) nil)
               :on-direction
               (lambda (direction)
                 (when (memq direction '(up down))
                   ;; `etaf-scroll-to' clamps to the content, so the last rows
                   ;; stop at the last rows instead of scrolling past them.
                   (let ((runtime (etaf-runtime-for-buffer (current-buffer))))
                     (etaf-scroll-to runtime scroll-ref
                                     (+ (etaf-scroll-offset runtime scroll-ref)
                                        (if (eq direction 'up) -1 1)))))
                 'handled)
               :aria-label "代码，滚动查看"
            (expr (list (etaf-md--code-tree-code env (cdr selected))))))))))

(etaf-md--define-shipped 'code-tree
  :name "code-tree"
  :summary "左边文件列表，右边选中文件的代码"
  :attrs '((height :type number :doc "代码区行数，超出可滚动，默认 18"))
  :accepts '((file :attrs ((title :type string :required t :doc "文件路径"))))
  :child-syntax 'markers
  :view #'etaf-md--code-tree-view)

;;; ---------------------------------------------------------------------------
;;; npm commands in every package manager
;;; ---------------------------------------------------------------------------

(defconst etaf-md--npm-to-managers
  '((npm . "npm") (pnpm . "pnpm") (yarn . "yarn") (bun . "bun") (deno . "deno"))
  "Package managers `npm-to' can write, in their default order.")

(defun etaf-md--npm-to-rewrite (command manager)
  "Return an npm COMMAND written for MANAGER.
Only the commands the site lists are rewritten; anything else is copied
unchanged, so a mixed script keeps its shape.  The rewrite never inspects
the match data of its caller."
  (save-match-data
    (let* ((no-args (string-match-p "\\`npm +install *\\'" command))
           (install (string-match "\\`npm +\\(?:install\\|i\\|add\\) +\\(.+\\)\\'" command))
           (run (string-match "\\`npm +\\(?:run-script\\|run\\) +\\(.+\\)\\'" command))
           (remove (string-match "\\`npm +\\(?:uninstall\\|remove\\|rm\\|un\\|unlink\\|r\\) +\\(.+\\)\\'" command))
           (create (string-match "\\`npm +create +\\(.+\\)\\'" command))
           (init (string-match-p "\\`npm +init *\\'" command))
           (ci (string-match-p "\\`npm +ci *\\'" command))
           (npx (string-match "\\`npx +\\(.+\\)\\'" command)))
      (cond
       (no-args (pcase manager
                  ('yarn "yarn") ('pnpm "pnpm install")
                  ('bun "bun install") ('deno "deno install")
                  (_ "npm install")))
       (install (let ((args (match-string 1 command)))
                  (pcase manager
                    ('yarn (format "yarn add %s" args))
                    ('pnpm (format "pnpm add %s" args))
                    ('bun (format "bun add %s" args))
                    ('deno (format "deno add %s" args))
                    (_ command))))
       (run (let ((script (match-string 1 command)))
              (pcase manager
                ('yarn (format "yarn %s" script))
                ('pnpm (format "pnpm %s" script))
                ('bun (format "bun run %s" script))
                ('deno (format "deno task %s" script))
                (_ command))))
       (remove (let ((args (match-string 1 command)))
                 (pcase manager
                   ('yarn (format "yarn remove %s" args))
                   ('pnpm (format "pnpm remove %s" args))
                   ('bun (format "bun remove %s" args))
                   ('deno (format "deno remove %s" args))
                   (_ command))))
       (create (let ((args (match-string 1 command)))
                 (pcase manager
                   ('yarn (format "yarn create %s" args))
                   ('pnpm (format "pnpm create %s" args))
                   ('bun (format "bun create %s" args))
                   ('deno (format "deno create %s" args))
                   (_ command))))
       (init (pcase manager
               ('yarn "yarn init") ('pnpm "pnpm init")
               ('bun "bun init") ('deno "deno init")
               (_ "npm init")))
       (ci (pcase manager
             ('yarn "yarn install --immutable")
             ('pnpm "pnpm install --frozen-lockfile")
             ('bun "bun install --frozen-lockfile")
             ('deno "deno install --frozen")
             (_ command)))
       (npx (let ((args (match-string 1 command)))
              (pcase manager
                ('yarn (format "yarn dlx %s" args))
                ('pnpm (format "pnpm dlx %s" args))
                ('bun (format "bunx %s" args))
                ('deno (format "deno run %s" args))
                (_ command))))
       (t command)))))

(defun etaf-md--npm-to-script (text manager)
  "Return the shell TEXT rewritten for MANAGER, command by command."
  (mapconcat
   (lambda (line)
     (mapconcat (lambda (part) (etaf-md--npm-to-rewrite part manager))
                (split-string line "&&" nil " ")
                "&&"))
   (split-string text "\n")
   "\n"))

(defun etaf-md--npm-to-view (env)
  "Paint one npm command as the package managers' code tabs.
The block holds a single fence; the selected manager's rewritten command is
shown under a strip that names every manager the `tabs' attribute lists."
  (let* ((children (etaf-md-children env))
         (block (and children (etaf-md-node-block (car children))))
         ;; A fence's text can carry the blank line that separated it from
         ;; the fence marker; trimming keeps every command card's first and
         ;; last row a command instead of an empty line.
         (source (string-trim (or (plist-get block :text) "")))
         (requested (or (etaf-md-attr env :tabs) "npm,pnpm,yarn,bun,deno"))
         (managers (seq-filter
                    (lambda (name) (assoc name etaf-md--npm-to-managers))
                    (mapcar #'intern (split-string requested "," t "[ \t]+"))))
         (managers (or managers (mapcar #'car etaf-md--npm-to-managers)))
         (active (min (or (etaf-md-block-state env :active 0) 0)
                      (max 0 (1- (length managers)))))
         (manager (nth active managers))
         (synthetic (list :type 'code-block
                          :lang (or (plist-get block :lang) "sh")
                          ;; The strip already names the tool, and the card
                          ;; already draws the frame: the fence adds neither a
                          ;; language row nor a second border.
                          :header nil
                          :frame nil
                          :text (etaf-md--npm-to-script source manager))))
    (etaf-view
      (column :width 'stretch :item-gap '(lh 0)
              :border (etaf-md--hairline env)
              :background-color (etaf-md-surface env 'raised)
        (etaf-tabs
         :items (seq-map-indexed
                 (lambda (name index)
                   (list :key index
                         :label (cdr (assoc name etaf-md--npm-to-managers))))
                 managers)
         :active active
         :framed nil
         :on-change (lambda (key) (etaf-md-set-block-state env :active key)))
        ;; The fence pads itself half a line above and below; one blank line
        ;; is the whole gap the card should keep around its code.
        (box :width 'stretch :padding '((lh 0) (ch 0))
             :border-top (etaf-md--hairline env)
          (expr (etaf-ui-markdown-view-block
                 synthetic
                 (list :theme (etaf-md-env-theme env)
                       :palette (etaf-md-env-palette env)
                       :width (etaf-md-env-width env)))))))))

(etaf-md--define-shipped 'npm-to
  :name "npm-to"
  :summary "写一条 npm 命令，换成各包管理器的写法"
  :attrs '((tabs :type string :doc "要显示的包管理器，逗号分隔"))
  :view #'etaf-md--npm-to-view)

(provide 'etaf-md-components)

;;; etaf-md-components.el ends here
