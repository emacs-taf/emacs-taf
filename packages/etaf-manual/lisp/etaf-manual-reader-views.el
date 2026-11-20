;;; etaf-manual-reader-views.el --- Shell and navigation of the manual reader -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; The application shell of the manual reader: header with the brand,
;; breadcrumb and language switch; the navigation column with
;; the three-level outline; the scrolling article column; and the key-hint
;; footer.  The shell composes the article layer of
;; `etaf-manual-reader-article' and the design system of
;; `etaf-manual-reader-style'.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'etaf)
(require 'etaf-ui)
(require 'etaf-manual-reader-style)
(require 'etaf-manual-reader-model)
(require 'etaf-manual-reader-article)

(defconst etaf-manual-reader--article-ref 'etaf-manual-article-column
  "Host reference of the scrolling article column.")

(defconst etaf-manual-reader--overview-ref 'etaf-manual-overview-column
  "Host reference of the narrow-screen overview column.")

(defconst etaf-manual-reader--nav-current-ref 'etaf-manual-nav-current
  "Host reference of the navigation row of the reading position.")

;;;; Environment and scrolling

(defvar etaf-manual-reader--envs (make-hash-table :test 'eq :weakness 'key)
  "SESSION to its last (INPUTS . ENVIRONMENT).")

(defun etaf-manual-reader--env (session &optional viewport rows)
  "Return the rendering environment of SESSION.
VIEWPORT, when known, is the frame width in character cells and ROWS the
frame height in lines."
  (let* ((theme (etaf-manual-reader--resolved
                 (etaf-manual-reader--read session :theme)))
         (key (list theme viewport rows))
         (last (gethash session etaf-manual-reader--envs)))
    ;; Components compare list props by identity, so an unchanged
    ;; environment must be the same object for the article to skip renders.
    (if (equal (car last) key)
        (cdr last)
      (cdr (puthash session
                    (cons key
                          (list :palette (etaf-manual-reader-palette theme)
                                :theme theme
                                :viewport viewport
                                :rows rows
                                :reader session
                                :open-link (car (etaf-manual-reader--env-callbacks session))
                                :footnote-jump (cdr (etaf-manual-reader--env-callbacks session))))
                    etaf-manual-reader--envs)))))


(defvar etaf-manual-reader--callbacks (make-hash-table :test 'eq :weakness 'key)
  "SESSION to its (OPEN-LINK . FOOTNOTE-JUMP) environment callbacks.")

(defun etaf-manual-reader--env-callbacks (session)
  "Return SESSION's link callbacks, created once.
Equal environments across renders let the article component skip renders
that change nothing it shows."
  (or (gethash session etaf-manual-reader--callbacks)
      (puthash session
               (cons (lambda (url) (etaf-manual-reader-follow session url))
                     (lambda (label)
                       (etaf-manual-reader-message
                        session (format "脚注 %s" label))))
               etaf-manual-reader--callbacks)))

(defun etaf-manual-reader--runtime (session)
  "Return SESSION's mounted runtime, or nil."
  (when-let* ((buffer (plist-get session :buffer)))
    (and (buffer-live-p buffer)
         (etaf-runtime-for-buffer buffer))))

(defun etaf-manual-reader--scroll-to-node (session)
  "Scroll SESSION's article so its current section starts at the top.
The navigation column follows by the least distance that shows the row of
the reading position."
  (when-let* ((runtime (etaf-manual-reader--runtime session)))
    (ignore-errors
      (etaf-scroll-into-view runtime etaf-manual-reader--nav-current-ref))
    (let ((node (etaf-manual-reader--read session :node)))
      (if node
          (let* ((anchor (plist-get (etaf-manual-reader--node-at session node)
                                    :anchor))
                 (ref (and anchor
                           (intern (format "etaf-manual-node-%s" anchor)))))
            (when ref
              (ignore-errors (etaf-scroll-into-view runtime ref 'start))))
        (ignore-errors (etaf-scroll-to runtime etaf-manual-reader--article-ref 0))))))

(defun etaf-manual-reader--after-navigation (session)
  "Scroll SESSION after the pending render settles and remember its place."
  (run-at-time 0 nil #'etaf-manual-reader--scroll-to-node session)
  (etaf-manual-reader--schedule-remember session))

(defun etaf-manual-reader--scroll-to-definition (session name)
  "Scroll SESSION's article to the definition card of NAME."
  (when-let* ((runtime (etaf-manual-reader--runtime session)))
    (let ((ref (intern (format "etaf-manual-definition-%s" name))))
      (ignore-errors (etaf-scroll-into-view runtime ref 'start)))))

(defun etaf-manual-reader-scroll-to-definition (session name)
  "Scroll SESSION's article to the definition card of NAME, after rendering."
  (etaf-manual-reader-reveal-definition session name)
  (run-at-time 0 nil #'etaf-manual-reader--scroll-to-definition session name))

;;;; Header

(defun etaf-manual-reader--language-options (&optional compact)
  "Return the language switch options, shortened when COMPACT."
  (if compact
      '(("zh-CN" . "中") ("en" . "EN"))
    '(("zh-CN" . "中文") ("en" . "EN"))))

(defun etaf-manual-reader--switch-language (session language)
  "Switch SESSION to LANGUAGE and report it."
  (condition-case error
      (progn
        (etaf-manual-reader-set-language session language)
        (etaf-manual-reader-message
         session (format "已切换到%s" (if (equal language "zh-CN") "中文" "英文"))))
    (error (etaf-manual-reader-message
            session (error-message-string error)))))

(defun etaf-manual-reader--breadcrumb (session env compact)
  "Return SESSION's reading trail in ENV: part, chapter and section.
COMPACT keeps only the chapter and section."
  (let* ((part (etaf-manual-reader--part session))
         (chapter (etaf-manual-reader--read session :chapter))
         (node (etaf-manual-reader--node-at
                session (etaf-manual-reader--read session :node)))
         (crumbs (delq nil
                       (list (and (not compact) part
                                  (cons (plist-get part :title) :muted))
                             (cons (etaf-manual-reader--chapter-title session chapter)
                                   (if node :muted :ink))
                             (and node (cons (plist-get node :title) :ink)))))
         (nodes nil))
    (dolist (crumb crumbs)
      (when nodes
        (push (etaf-manual-reader--icon env 'chevron-right :faint) nodes))
      (push (etaf-node 'text
                       (list :color (etaf-manual-reader--color env (cdr crumb)))
                       (list (car crumb)))
            nodes))
    (etaf-node 'row
               (list :item-gap '(ch 1) :cross-align 'center
                     :min-width '(px 0) :overflow 'hidden)
               (nreverse nodes))))

(defun etaf-manual-reader--header-view (session env)
  "Return the header View of SESSION in ENV."
  (let* ((language (etaf-manual-reader--read session :language))
         (wide (etaf-manual-reader--wide-p env))
         (compact (etaf-manual-reader--compact-p env))
         (chrome (etaf-manual-reader--chrome
                  env
                  (list
                   (etaf-manual-reader--brand env (if compact "手册" "ETAF 手册"))
                   (etaf-manual-reader--breadcrumb session env compact)
                   (etaf-node 'box
                              (list :flex-grow 1 :flex-basis '(px 0)
                                    :min-width '(px 0))
                              nil)
                   (when (not wide)
                     (etaf-node 'etaf-button
                                (list :label (if (etaf-manual-reader--read session :toc)
                                                 "返回正文"
                                               "目录")
                                      :variant 'secondary
                                      :on-press (lambda ()
                                                  (etaf-set-value
                                                   (etaf-manual-reader--ref session :toc)
                                                   (not (etaf-manual-reader--read session :toc)))))
                                nil))
                   (etaf-node 'etaf-segmented
                              (list :value language
                                    :options (etaf-manual-reader--language-options compact)
                                    :on-change (lambda (code)
                                                 (etaf-manual-reader--switch-language session code)))
                              nil)))))
    (etaf-node 'box
               (list :ref 'etaf-manual-header
                     :width 'stretch
                     :box-sizing 'border-box)
               (list chrome))))

;;;; Navigation column

(defun etaf-manual-reader--sidebar-row (session env row)
  "Return one clickable navigation ROW of SESSION in ENV.
ROW is a plist with `:number', `:label', `:chapter', `:node', `:level',
`:current' and `:current-node'.  The number sits in a fixed gutter and the
label wraps beside it, so a long title keeps its hanging indent; a
level-3 section widens the gutter and marks it with a dot."
  (let* ((label (plist-get row :label))
         (chapter (plist-get row :chapter))
         (node (plist-get row :node))
         (level (plist-get row :level))
         (current (plist-get row :current))
         (current-node (plist-get row :current-node))
         (chapter-row (eql level 0))
         (selected (if chapter-row
                       (and current (null (etaf-manual-reader--read session :node)))
                     current-node))
         (color (cond (selected (etaf-manual-reader--color env :accent))
                      ((and chapter-row current) (etaf-manual-reader--color env :heading))
                      (chapter-row (etaf-manual-reader--color env :ink))
                      (t (etaf-manual-reader--color env :muted)))))
    (etaf-node 'row
               (append
                (when selected (list :ref etaf-manual-reader--nav-current-ref))
                (list :width 'stretch
                     :box-sizing 'border-box
                     :padding '((lh 0) (ch 1))
                     :item-gap '(ch 1)
                     :background-color (cond (selected (etaf-manual-reader--color env :sidebar-current))
                                             ((and chapter-row current)
                                              (etaf-manual-reader--color env :panel))
                                             (t nil))
                     :border-left (list '(px 3) 'solid
                                        (if (and chapter-row current)
                                            (etaf-manual-reader--color env :accent)
                                          (etaf-manual-reader--color env :sidebar)))
                     :color color
                     :font-weight (if (or selected (and chapter-row current)) 'bold nil)
                     :pointer 'hand
                     ;; The reading position keeps its own selected surface;
                     ;; hover belongs to rows that are not already active.
                     :hover-style (unless (and chapter-row current)
                                    (etaf-manual-reader--hover env))
                     :role 'button
                     :tab-index 0
                     :help-echo label
                     :on-press (lambda ()
                                 (etaf-manual-reader-goto session chapter node)
                                 (etaf-manual-reader--after-navigation session))))
               (list (etaf-node 'box
                                (list :width (if (eql level 3) '(ch 5) '(ch 3))
                                      :flex-shrink 0
                                      :text-align 'right
                                      :color (if (or selected (and chapter-row current))
                                                 (etaf-manual-reader--color env :accent)
                                               (etaf-manual-reader--color env :faint)))
                                (list (etaf-node 'text nil
                                                 (list (if (eql level 3)
                                                           "·"
                                                         (format "%s" (or (plist-get row :number) "")))))))
                     (etaf-node 'box
                                (list :flex-grow 1 :flex-basis '(px 0)
                                      :min-width '(px 0) :wrap-mode 'word)
                                (list (etaf-node 'text nil (list label))))))))

(defun etaf-manual-reader--sidebar-rows (session env &optional sections)
  "Return the navigation rows of SESSION in ENV.
The rows list every part and chapter.  With SECTIONS, the current
chapter's sections follow it; the narrow-screen overview asks for them
when no on-this-page column is shown, while the wide navigation column
leaves page navigation to that column."
  (let ((rows nil) (first t))
    (dolist (part (etaf-manual-reader-toc session))
      (unless first
        (push (etaf-manual-reader--spacer) rows))
      (setq first nil)
      (push (etaf-node 'box
                       (list :width 'stretch
                             :box-sizing 'border-box
                             :padding '((lh 0) (ch 2))
                             :color (etaf-manual-reader--color env :faint))
                       (list (etaf-node 'text
                                        (list :font-weight 'bold)
                                        (list (format "%s  %s"
                                                      (plist-get part :number)
                                                      (plist-get part :title))))))
            rows)
      (dolist (chapter (plist-get part :chapters))
        (push (etaf-manual-reader--sidebar-row
               session env
               (list :number (plist-get chapter :number)
                     :label (plist-get chapter :title)
                     :chapter (plist-get chapter :id)
                     :node nil
                     :level 0
                     :current (plist-get chapter :current)))
              rows)
        (when (and sections (plist-get chapter :current))
          (dolist (node (plist-get chapter :nodes))
            (push (etaf-manual-reader--sidebar-row
                   session env
                   (list :label (plist-get node :title)
                         :chapter (plist-get chapter :id)
                         :node (plist-get node :index)
                         :level (plist-get node :level)
                         :current (plist-get chapter :current)
                         :current-node (plist-get node :current)))
                  rows)))))
    (nreverse rows)))

(defun etaf-manual-reader--sidebar (session env)
  "Return the navigation column View of SESSION in ENV."
  (etaf-node 'column
             (list :width (list 'ch (etaf-manual-reader--sidebar-width env))
                   :height 'stretch
                   :flex-shrink 0
                   :overflow 'scroll
                   :box-sizing 'border-box
                   :background-color (etaf-manual-reader--color env :sidebar)
                   :padding '((lh 1) (ch 1))
                   :item-gap '(lh 0)
                   :ref 'etaf-manual-nav-column)
             (etaf-manual-reader--sidebar-rows session env)))

(defun etaf-manual-reader--overview (session env)
  "Return the narrow-screen overview panel of SESSION in ENV.
Without an on-this-page column the overview carries the current chapter's
sections too, so page navigation stays reachable on a narrow frame."
  (etaf-node 'column
             (list :width 'stretch
                   :height 'stretch
                   :overflow 'scroll
                   :box-sizing 'border-box
                   :background-color (etaf-manual-reader--color env :bg)
                   :padding '((lh 1) (ch 2))
                   :item-gap '(lh 0)
                   :ref etaf-manual-reader--overview-ref)
             (etaf-manual-reader--sidebar-rows session env t)))

;;;; On-this-page column

(defun etaf-manual-reader--char-width ()
  "Return the character width the reader's canvas draws.
`ch' resolves against the canvas's own face, so a divider's pixels and the
column count it reports come from one cell."
  (max 1 (or (plist-get (ignore-errors (etaf-display-metrics)) :char-width)
             (frame-char-width))))

(defun etaf-manual-reader--column-pixels (columns)
  "Return COLUMNS character cells as pixels on the reader's canvas."
  (* (etaf-manual-reader--char-width) columns))

(defun etaf-manual-reader--resizer (session env kind)
  "Return the draggable divider resizing KIND in ENV.
KIND is `sidebar' for the navigation column or `outline' for the
on-this-page column; the divider reports candidate widths in pixels and
SESSION clamps the column it accepts."
  (let ((sidebar (eq kind 'sidebar))
        (cell (etaf-manual-reader--char-width)))
    (etaf-node 'etaf-pane-resizer
               (list :ref (if sidebar 'etaf-manual-sidebar-resizer
                            'etaf-manual-outline-resizer)
                     :size (etaf-manual-reader--column-pixels
                            (if sidebar (etaf-manual-reader--sidebar-width env)
                              (etaf-manual-reader--outline-width env)))
                     :side (if sidebar 'right 'left)
                     :line (etaf-manual-reader--color env :border)
                     :background (etaf-manual-reader--color env :bg)
                     :on-change (lambda (pixels)
                                  (if sidebar
                                      (etaf-manual-reader-set-sidebar-width
                                       session (/ pixels cell))
                                    (etaf-manual-reader-set-outline-width
                                     session (/ pixels cell)))))
               nil)))

(defun etaf-manual-reader--outline-row (session env node)
  "Return one on-this-page ROW of NODE in ENV.
A level-3 section indents under its level-2 parent; the reading position
carries the accent color, a tinted surface and an accent bar."
  (let* ((level (plist-get node :level))
         (index (plist-get node :index))
         (current (plist-get node :current))
         (title (plist-get node :title)))
    (etaf-node 'box
               (list :width 'stretch
                     :wrap-mode 'word
                     :box-sizing 'border-box
                     :padding-top '(lh 0)
                     :padding-bottom '(lh 0)
                     :padding-left (if (eql level 3) '(ch 4) '(ch 2))
                     :padding-right '(ch 1)
                     :border-left
                     (list '(px 2) 'solid
                           (if current
                               (etaf-manual-reader--color env :accent)
                             (etaf-manual-reader--color env :bg)))
                     :background-color (when current
                                         (etaf-manual-reader--color env :sidebar-current))
                     :color (cond (current (etaf-manual-reader--color env :accent))
                                  ((eql level 3) (etaf-manual-reader--color env :muted))
                                  (t (etaf-manual-reader--color env :ink)))
                     :font-weight (if (and current (eql level 2)) 'bold nil)
                     :role 'button
                     :tab-index 0
                     :pointer 'hand
                     :hover-style (unless current (etaf-manual-reader--hover env))
                     :help-echo title
                     :on-press (lambda ()
                                 (etaf-manual-reader-goto session
                                                          (etaf-manual-reader--read session :chapter)
                                                          index)
                                 (etaf-manual-reader--after-navigation session)))
               (list (etaf-node 'text nil (list title))))))

(defun etaf-manual-reader--outline (session env)
  "Return the on-this-page column View of SESSION in ENV."
  (let ((current (etaf-manual-reader--read session :node)))
    (etaf-node 'column
               (list :width (list 'ch (etaf-manual-reader--outline-width env))
                     :height 'stretch
                     :flex-shrink 0
                     :overflow 'scroll
                     :box-sizing 'border-box
                     :border-left (etaf-manual-reader--border env)
                     :padding '((lh 1) (ch 0))
                     :item-gap '(lh 0)
                     :ref 'etaf-manual-page-outline)
               (append
                (list (etaf-node 'box
                                 (list :width 'stretch
                                       :box-sizing 'border-box
                                       :padding-left '(ch 2)
                                       :padding-right '(ch 1)
                                       :padding-bottom '(lh 0)
                                       :border-bottom (etaf-manual-reader--border env))
                                 (list (etaf-node 'text
                                                  (list :font-weight 'bold
                                                        :color (etaf-manual-reader--color env :faint))
                                                  (list "本页"))))
                      (etaf-manual-reader--spacer))
                (cl-loop for node in (etaf-manual-reader--nodes session)
                         for index from 0
                         collect (etaf-manual-reader--outline-row
                                  session env
                                  (list :title (plist-get node :title)
                                        :level (plist-get node :level)
                                        :index index
                                        :current (eql index current))))))))

;;;; Chapter cards

(defun etaf-manual-reader--chapter-card (session env id direction)
  "Return the previous/next chapter card for ID in ENV.
DIRECTION is `previous' or `next'; the card opens the neighbour chapter."
  (let* ((title (etaf-manual-reader--chapter-title session id))
         (label (if (eq direction 'previous) "上一章" "下一章"))
         (align (if (eq direction 'previous) 'right 'left)))
        (etaf-node 'row
               (list :ref (if (eq direction 'previous)
                              'etaf-manual-chapter-previous
                            'etaf-manual-chapter-next)
                     :flex-grow 1 :flex-basis '(px 0) :min-width '(px 0)
                     :box-sizing 'border-box
                     :background-color (etaf-manual-reader--color env :panel)
                     :border (etaf-manual-reader--border env)
                     :padding etaf-manual-reader--card-pad
                     :item-gap '(ch 2)
                     :cross-align 'center
                     :role 'button :tab-index 0 :pointer 'hand
                     :hover-style (etaf-manual-reader--hover env)
                     :help-echo title
                     :on-press (lambda ()
                                 (etaf-manual-reader-goto session id)
                                 (etaf-manual-reader--after-navigation session)))
               (append
                (when (eq direction 'previous)
                  (list (etaf-manual-reader--icon env 'chevron-left :faint)))
                (list (etaf-node 'box
                                 (list :flex-grow 1 :flex-basis '(px 0)
                                       :min-width '(px 0)
                                       :text-align align)
                                 (list (etaf-manual-reader--label env (concat label " "))
                                       (etaf-node 'text
                                                  (list :color (etaf-manual-reader--color
                                                                env :heading))
                                                  (list title)))))
                (when (eq direction 'next)
                  (list (etaf-manual-reader--icon env 'chevron-right :faint)))))))

(defun etaf-manual-reader--chapter-cards (session env)
  "Return the previous/next chapter cards of SESSION in ENV, or nil."
  (let* ((index (etaf-manual-reader--chapter-index session))
         (previous (etaf-manual-reader--chapter-at session (1- index)))
         (next (etaf-manual-reader--chapter-at session (1+ index))))
    (when (or previous next)
      (etaf-node 'row
                 (list :width 'stretch :item-gap '(ch 2) :cross-align 'stretch)
                 (append
                  (when previous
                    (list (etaf-manual-reader--chapter-card session env previous 'previous)))
                  (when next
                    (list (etaf-manual-reader--chapter-card session env next 'next))))))))

;;;; Article column

(defun etaf-manual-reader--article-column (session env &optional columns)
  "Return the scrolling article column View of SESSION in ENV.
COLUMNS states the column's width in canvas cells when the caller knows how
much the side panels leave; the article then centres inside that box, so the
remainder is split between both sides instead of collecting on the right."
  (etaf-node 'column
             (list :ref etaf-manual-reader--article-ref
                   :width (if columns (list 'ch columns) 'stretch)
                   :height 'stretch
                   :flex-grow 1
                   :flex-basis '(px 0)
                   :min-width '(px 0)
                   :overflow 'scroll
                   :cross-align 'center
                   :background-color (etaf-manual-reader--color env :bg))
             (list (etaf-node 'etaf-manual-reader--article-view
                              (list :session session :env env)
                              nil))))

;;;; Footer

(defun etaf-manual-reader--position-label (session)
  "Return the reading position label of SESSION."
  (let* ((state (etaf-manual-reader-state session))
         (node (plist-get state :node))
         (nodes (plist-get state :nodes)))
    (format "第 %s/%s 章%s" (1+ (plist-get state :position)) (plist-get state :chapters)
            (if node (format " · 第 %s/%s 节" (1+ node) (length nodes)) ""))))

(defun etaf-manual-reader--footer-hints (env)
  "Return the key hints the footer shows in ENV."
  (if (etaf-manual-reader--compact-p env)
      '(("n/p" . "节") ("/" . "搜索") ("i" . "跳转") ("?" . "按键"))
    '(("n/p" . "上下节") ("[ ]" . "上下章") ("u" . "上级")
      ("/" . "搜索") ("i" . "跳转") ("?" . "全部按键"))))

(defun etaf-manual-reader--footer (session env)
  "Return the footer View of SESSION in ENV: the reading position or the
latest message on the left, the most useful keys on the right."
  (let ((message (etaf-manual-reader--read session :message)))
    (etaf-node 'box
               (list :ref 'etaf-manual-footer
                     :width 'stretch :box-sizing 'border-box
                     :background-color (etaf-manual-reader--color env :panel))
               (list
                (etaf-manual-reader--chrome
                 env
                 (list
                  (if (and message (not (string-empty-p message)))
                      (etaf-manual-reader--state-line env message :accent)
                    (etaf-manual-reader--state-line
                     env (etaf-manual-reader--position-label session)))
                  (etaf-node 'box
                             (list :flex-grow 1 :flex-basis '(px 0) :min-width '(px 0))
                             nil)
                  (etaf-manual-reader--key-hints
                   env (etaf-manual-reader--footer-hints env))))))))

;;;; Shell

(defun etaf-manual-reader--shell (session env &optional keys)
  "Return the complete application View of SESSION in ENV.
KEYS is the page Host's `:keys' table, so `?' lists the reader's keys."
  (let* ((wide (etaf-manual-reader--wide-p env))
         (toc (and (not wide) (etaf-manual-reader--read session :toc)))
         ;; The side panels and the two draggable dividers are whole cells, so
         ;; the wide layout spends the rest on the article and centres the
         ;; measure inside it; leaving the remainder to one side would grow
         ;; with the window.
         (columns (etaf-manual-reader--viewport-columns env))
         (outline (and (etaf-manual-reader--outline-p env)
                       (etaf-manual-reader--outline-width env)))
         (sidebar (and wide (etaf-manual-reader--sidebar-width env)))
         (free (and columns
                    (max etaf-manual-reader--measure-min
                         (- columns (or sidebar 0) (or outline 0)
                            (if sidebar 1 0) (if outline 1 0)))))
         (article (etaf-manual-reader--article-column session env free))
         (body (if toc
                   (etaf-node 'column
                              (list :width 'stretch :height 'stretch
                                    :flex-grow 1 :flex-basis '(px 0)
                                    :min-width '(px 0))
                              (list (etaf-manual-reader--overview session env)))
                 (etaf-node 'flex
                            (list :width 'stretch :height 'stretch
                                  :flex-direction 'row
                                  :align-items 'stretch
                                  :min-height '(lh 0))
                            (append
                             (when wide
                               (list (etaf-manual-reader--sidebar session env)
                                     (etaf-manual-reader--resizer
                                      session env 'sidebar)))
                             (list article)
                             (when (etaf-manual-reader--outline-p env)
                               (list (etaf-manual-reader--resizer
                                      session env 'outline)
                                     (etaf-manual-reader--outline session env))))))))
    (etaf-manual-reader--page
     env
     (list (etaf-manual-reader--header-view session env)
           (etaf-node 'flex
                      (list :ref 'etaf-manual-body
                            :flex-direction 'row
                            :align-items 'stretch
                            :gap '((lh 0) (ch 0))
                            :width 'stretch
                            :flex-grow 1 :flex-basis '(px 0)
                            :min-height '(lh 0)
                            :overflow 'hidden)
                      (list body))
           (etaf-manual-reader--footer session env))
     ;; Reserve one row: a graphical frame may reserve its last text row for
     ;; window chrome while the runtime still counts it as available.  A
     ;; headless mount reports no height, so it renders the whole article
     ;; instead of a window-sized slice, which keeps batch tests complete.
     (list 'lh (if (plist-get env :rows)
                   (max 12 (1- (plist-get env :rows)))
                 500))
     keys)))

(provide 'etaf-manual-reader-views)
;;; etaf-manual-reader-views.el ends here
