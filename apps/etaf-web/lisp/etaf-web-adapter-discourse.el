;;; etaf-web-adapter-discourse.el --- Tier 2 Discourse forum adapter -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; Universal Tier 2 site-archetype adapter for Discourse forums (e.g.
;; emacs-china.org, meta.discourse.org, users.rust-lang.org).  Detects any
;; Discourse instance via `<meta name="generator">' or Discourse bootstrap
;; markers, fetches official public JSON endpoints asynchronously without a
;; browser process, and renders native `etaf-ui' topic list and thread views.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'parse-time)
(require 'subr-x)
(require 'url-parse)
(require 'url-util)
(require 'etaf)
(require 'etaf-ui)
(require 'etaf-web-compile)
(require 'etaf-web-cache)
(require 'etaf-web-adapter)
(require 'etaf-web-router)
(require 'etaf-web-views)

(defvar etaf-web-discourse--known-origins (make-hash-table :test #'equal)
  "Map from detected Discourse origin URL to basic site info plist.")

(defvar etaf-web-discourse--categories-cache (make-hash-table :test #'equal)
  "Map from Discourse origin URL to cached `(:categories LIST :by-id HASH)'.")

(defconst etaf-web-discourse--narrow-breakpoint 84
  "Feed width below which Discourse topic rows fold metadata to line 2.")

(defconst etaf-web-discourse--wide-breakpoint 108
  "Viewport width at or above which the category navigation rail docks left.")

(defconst etaf-web-discourse--default-sidebar-cols 26
  "Default docked navigation rail width in character columns.")

(defconst etaf-web-discourse--min-sidebar-cols 20
  "Minimum docked navigation rail width in character columns.")

;;; ---------------------------------------------------------------------------
;;; URL parsing, detection & formatting helpers
;;; ---------------------------------------------------------------------------

(defun etaf-web-discourse--origin (url)
  "Return `scheme://host[:port]' origin string for HTTP(S) URL, or nil."
  (when (etaf-web--http-url-p url)
    (let* ((parsed (url-generic-parse-url url))
           (scheme (downcase (or (url-type parsed) "")))
           (host (and (url-host parsed) (downcase (url-host parsed))))
           (port (url-port-if-non-default parsed)))
      (when (and (member scheme '("http" "https")) host (not (string-empty-p host)))
        (format "%s://%s%s" scheme host (if port (format ":%d" port) ""))))))

(defun etaf-web-discourse--parse-route (url)
  "Classify Discourse URL into a route plist, or nil when unsupported."
  (when-let* ((origin (etaf-web-discourse--origin url)))
    (let* ((parsed (url-generic-parse-url url))
           (raw-path (or (url-filename parsed) "/"))
           (qpos (string-match "\\?" raw-path))
           (path (if qpos (substring raw-path 0 qpos) raw-path))
           (query (if qpos (substring raw-path (1+ qpos)) ""))
           (clean (if (and (> (length path) 1) (string-suffix-p "/" path))
                      (substring path 0 -1)
                    path)))
      (cond
       ((or (string-empty-p clean) (equal clean "/") (equal clean "/latest"))
        (list :kind 'list :tab 'latest :origin origin))
       ((string-prefix-p "/top" clean)
        (list :kind 'list :tab 'top :origin origin))
       ((equal clean "/categories")
        (list :kind 'list :tab 'categories :origin origin))
       ((string-match "\\`/c/\\(.+\\)/\\([0-9]+\\)\\'" clean)
        (list :kind 'list :tab 'latest :origin origin
              :category-path (match-string 1 clean)
              :category-id (string-to-number (match-string 2 clean))))
       ((string-match "\\`/t/\\(?:[^/]+/\\)?\\([0-9]+\\)\\(?:/\\([0-9]+\\)\\)?\\'" clean)
        (list :kind 'thread :origin origin
              :topic-id (string-to-number (match-string 1 clean))
              :post-number (and (match-string 2 clean)
                                (string-to-number (match-string 2 clean)))))
       ((equal clean "/search")
        (let* ((params (url-parse-query-string query))
               (q (car (cdr (assoc "q" params)))))
          (list :kind 'list :tab 'latest :origin origin
                :search (or q ""))))
       (t nil)))))

(defun etaf-web-discourse--match-url-p (url)
  "Return non-nil when URL belongs to a known Discourse origin and route."
  (when-let* ((origin (etaf-web-discourse--origin url)))
    (and (gethash origin etaf-web-discourse--known-origins)
         (etaf-web-discourse--parse-route url)
         t)))

(defun etaf-web-discourse--match-html-p (url _headers html dom)
  "Return non-nil when HTML/DOM belongs to a Discourse forum on a valid route."
  (when-let* ((origin (etaf-web-discourse--origin url)))
    (when (etaf-web-discourse--parse-route url)
      (let* ((gens (etaf-web--meta-generators dom))
             (gen-hit (cl-some (lambda (g)
                                 (string-prefix-p "discourse" (downcase g)))
                               gens))
             (meta-hit (or gen-hit
                           (and (stringp html)
                                (string-match-p
                                 "name=[\"']discourse_theme_id[\"']\\|content=[\"']Discourse "
                                 html)))))
        (when meta-hit
          (let ((title (or (and dom (let ((tn (etaf-web--find-first
                                               dom (lambda (n) (eq (dom-tag n) 'title)))))
                                      (and tn (etaf-web--clean-text tn))))
                           (car (etaf-web--url-parts origin))))
                (desc (and dom (etaf-web--meta-content dom 'name '("description")))))
            (puthash origin (list :title title :description desc)
                     etaf-web-discourse--known-origins))
          t)))))

(defun etaf-web-discourse--compact-count (n)
  "Format integer N compactly (e.g. 1240 -> \"1.2k\")."
  (let ((num (if (numberp n) n 0)))
    (cond
     ((>= num 10000) (format "%dk" (/ num 1000)))
     ((>= num 1000) (format "%.1fk" (/ (float num) 1000.0)))
     (t (format "%d" num)))))

(defun etaf-web-discourse--relative-time (iso)
  "Format ISO 8601 timestamp string ISO as concise Chinese relative time."
  (if (not (and (stringp iso) (not (string-empty-p iso))))
      ""
    (let ((parsed (ignore-errors (parse-iso8601-time-string iso))))
      (if (not parsed)
          (if (>= (length iso) 10) (substring iso 0 10) iso)
        (let ((delta (max 0 (- (float-time) (float-time parsed)))))
          (cond
           ((< delta 60) "刚刚")
           ((< delta 3600) (format "%d 分钟前" (floor (/ delta 60))))
           ((< delta 86400) (format "%d 小时前" (floor (/ delta 3600))))
           ((< delta 172800) "昨天")
           ((< delta (* 30 86400)) (format "%d 天前" (floor (/ delta 86400))))
           (t (format-time-string "%Y-%m-%d" parsed))))))))

(defun etaf-web-discourse--format-datetime (iso)
  "Format ISO 8601 timestamp ISO as `YYYY-MM-DD HH:MM'."
  (if (not (and (stringp iso) (not (string-empty-p iso))))
      ""
    (let ((parsed (ignore-errors (parse-iso8601-time-string iso))))
      (if parsed
          (format-time-string "%Y-%m-%d %H:%M" parsed)
        (if (>= (length iso) 16)
            (replace-regexp-in-string "T" " " (substring iso 0 16))
          iso)))))

(defun etaf-web-discourse--strip-front-matter (markdown)
  "Remove leading YAML front matter block from MARKDOWN."
  (let ((text (or markdown "")))
    (if (string-match "\\`---\n\\(?:.\\|\n\\)*?\n---\n+" text)
        (substring text (match-end 0))
      text)))

(defun etaf-web-discourse--post-likes (post)
  "Extract like count from Discourse POST alist."
  (let ((summary (alist-get 'actions_summary post))
        (count 0))
    (when (vectorp summary)
      (cl-loop for item across summary
               when (eql (alist-get 'id item) 2)
               do (setq count (or (alist-get 'count item) 0))))
    count))

(defun etaf-web-discourse--category-dot-token (cat-id)
  "Return a subtle theme-derived dot color token for category CAT-ID."
  (pcase (mod (abs (or cat-id 0)) 6)
    (0 (etaf-theme-token :ui-accent "#0969da"))
    (1 (etaf-theme-token :ui-success-fg "#2da44e"))
    (2 (etaf-theme-token :ui-warning-fg "#bf8700"))
    (3 (etaf-theme-token :web-dot-purple "#8250df"))
    (4 (etaf-theme-token :web-dot-teal "#1b7c83"))
    (_ (etaf-theme-token :ui-danger-fg "#cf222e"))))

(defun etaf-web-discourse--clean-cooked (html)
  "Strip Discourse lightbox `.meta' dimension overlays from cooked HTML."
  (replace-regexp-in-string
   "<div class=\"meta\"[^>]*>\\(?:.\\|\n\\)*?</div>"
   ""
   (or html "")))

(defun etaf-web-discourse--border (key fallback &optional px)
  "Build a solid Theme border token of PX pixels for KEY."
  (let ((w (or px 1)))
    (etaf-theme-token key fallback (lambda (c) (list (list 'px w) 'solid c)))))

;;; ---------------------------------------------------------------------------
;;; Async JSON fetching
;;; ---------------------------------------------------------------------------

(defun etaf-web-discourse--fetch-json-async (url callback)
  "Fetch JSON from URL asynchronously; invoke CALLBACK with `(DATA ERR)'."
  (etaf-web--fetch-raw-async
   url
   (lambda (resp err)
     (if err
         (funcall callback nil err)
       (let ((parsed nil)
             (parse-err nil))
         (condition-case perr
             (let* ((raw (decode-coding-string (or (plist-get resp :body-bytes) "") 'utf-8))
                    (trimmed (string-trim raw)))
               (setq parsed (json-parse-string trimmed :object-type 'alist :array-type 'array)))
           (error
            (setq parse-err
                  (list :kind 'parse
                        :message (format "无法解析 Discourse JSON (%s): %s"
                                         url (error-message-string perr))))))
         (if parse-err
             (funcall callback nil parse-err)
           (funcall callback parsed nil)))))
   (etaf-web--effective-timeout)))

(defun etaf-web-discourse--ensure-categories (origin callback)
  "Fetch and cache categories for ORIGIN, invoking CALLBACK with cache plist."
  (if-let* ((cached (gethash origin etaf-web-discourse--categories-cache)))
      (progn
        (funcall callback cached)
        (lambda () nil))
    (etaf-web-discourse--fetch-json-async
     (concat origin "/categories.json")
     (lambda (data _err)
       (let* ((clist (and data (alist-get 'categories (alist-get 'category_list data))))
              (cats (if (vectorp clist) (append clist nil) nil))
              (by-id (make-hash-table :test #'eql)))
         (dolist (cat cats)
           (when-let* ((cid (alist-get 'id cat)))
             (puthash cid cat by-id)))
         (let ((entry (list :categories cats :by-id by-id)))
           (when cats
             (puthash origin entry etaf-web-discourse--categories-cache))
           (funcall callback entry)))))))

;;; ---------------------------------------------------------------------------
;;; Data normalization (List & Thread)
;;; ---------------------------------------------------------------------------

(defun etaf-web-discourse--users-table (data)
  "Build user-id -> username hash table from Discourse JSON DATA."
  (let ((tbl (make-hash-table :test #'eql))
        (users (alist-get 'users data)))
    (when (vectorp users)
      (cl-loop for u across users
               for uid = (alist-get 'id u)
               for uname = (alist-get 'username u)
               when (and uid uname)
               do (puthash uid uname tbl)))
    tbl))

(defun etaf-web-discourse--normalize-tags (raw-tags)
  "Normalize Discourse RAW-TAGS (strings or tag alists) into a string list."
  (when (vectorp raw-tags)
    (delq nil
          (cl-loop for tg across raw-tags
                   collect (cond
                            ((stringp tg) tg)
                            ((listp tg)
                             (or (alist-get 'name tg)
                                 (alist-get 'slug tg)))
                            (t nil))))))

(defun etaf-web-discourse--normalize-topic (topic users-tbl by-id origin)
  "Normalize Discourse TOPIC alist into a clean plist for rendering."
  (let* ((id (alist-get 'id topic))
         (slug (or (alist-get 'slug topic) "topic"))
         (title (or (alist-get 'title topic) (alist-get 'fancy_title topic) "未命名话题"))
         (cat-id (alist-get 'category_id topic))
         (cat (and by-id cat-id (gethash cat-id by-id)))
         (cat-name (and cat (alist-get 'name cat)))
         (posts-count (or (alist-get 'posts_count topic) 1))
         (replies (max 0 (1- posts-count)))
         (views (or (alist-get 'views topic) 0))
         (posters (alist-get 'posters topic))
         (first-poster (and (vectorp posters) (> (length posters) 0)
                            (aref posters 0)))
         (op-id (and first-poster (alist-get 'user_id first-poster)))
         (author (or (and op-id (gethash op-id users-tbl))
                     (alist-get 'last_poster_username topic)
                     ""))
         (last-poster (or (alist-get 'last_poster_username topic) ""))
         (tags (etaf-web-discourse--normalize-tags (alist-get 'tags topic)))
         (activity (or (alist-get 'last_posted_at topic)
                       (alist-get 'bumped_at topic)
                       (alist-get 'created_at topic)
                       "")))
    (list :id id
          :slug slug
          :url (format "%s/t/%s/%d" origin slug id)
          :title title
          :category-id cat-id
          :category-name cat-name
          :replies replies
          :views views
          :author author
          :last-poster last-poster
          :tags tags
          :activity (etaf-web-discourse--relative-time activity))))

(defun etaf-web-discourse--parse-list-payload (data origin by-id)
  "Extract `(:topics LIST :more-url STRING-OR-NIL)' from list/search JSON DATA."
  (let ((users-tbl (etaf-web-discourse--users-table data))
        (tl (alist-get 'topic_list data)))
    (if tl
        (let* ((raw-topics (alist-get 'topics tl))
               (topics (when (vectorp raw-topics)
                         (cl-loop for tp across raw-topics
                                  collect (etaf-web-discourse--normalize-topic
                                           tp users-tbl by-id origin))))
               (more (alist-get 'more_topics_url tl)))
          (list :topics topics
                :more-url (and (stringp more) (not (string-empty-p more)) more)))
      ;; `/search.json' payload carries top-level `topics' and `posts'.
      (let* ((raw-topics (alist-get 'topics data))
             (topics (when (vectorp raw-topics)
                       (cl-loop for tp across raw-topics
                                collect (etaf-web-discourse--normalize-topic
                                         tp users-tbl by-id origin)))))
        (list :topics topics :more-url nil)))))

(defun etaf-web-discourse--endpoint-for-list (origin tab cat-id cat-path query page)
  "Build Discourse JSON endpoint URL for list parameters."
  (cond
   ((and (stringp query) (not (string-blank-p query)))
    (format "%s/search.json?q=%s" origin (url-hexify-string (string-trim query))))
   (cat-id
    (let ((base (if (and (stringp cat-path) (not (string-empty-p cat-path)))
                    (format "%s/c/%s/%d.json" origin cat-path cat-id)
                  (format "%s/c/%d.json" origin cat-id))))
      (if (> page 0) (format "%s?page=%d" base page) base)))
   ((eq tab 'top)
    (if (> page 0) (format "%s/top.json?page=%d" origin page)
      (concat origin "/top.json")))
   ((eq tab 'unanswered)
    (format "%s/latest.json?max_posts=1%s"
            origin (if (> page 0) (format "&page=%d" page) "")))
   (t
    (if (> page 0) (format "%s/latest.json?page=%d" origin page)
      (concat origin "/latest.json")))))

(defun etaf-web-discourse--more-json-url (origin more-url)
  "Convert Discourse `more_topics_url' like `/latest?page=1' to `.json' URL."
  (when (and (stringp more-url) (not (string-empty-p more-url)))
    (let* ((abs (if (string-prefix-p "http" more-url)
                    more-url
                  (concat origin (if (string-prefix-p "/" more-url) "" "/") more-url)))
           (qpos (string-match "\\?" abs)))
      (if qpos
          (let ((base (substring abs 0 qpos))
                (qs (substring abs qpos)))
            (if (string-suffix-p ".json" base)
                abs
              (concat base ".json" qs)))
        (if (string-suffix-p ".json" abs) abs (concat abs ".json"))))))

;;; ---------------------------------------------------------------------------
;;; View rendering: Two-Pane Forum & Airy Topic List (v3)
;;; ---------------------------------------------------------------------------

(defun etaf-web-discourse--render-topic-row (topic idx selected-p narrow navigate)
  "Render one airy editorial Discourse TOPIC row at IDX for WIDE or NARROW."
  (let* ((fg-tok (etaf-theme-token :ui-fg "#1f2328"))
         (muted-tok (etaf-theme-token :ui-muted-fg "#59636e"))
         (dim-tok (etaf-theme-token :ui-disabled-fg "#8c959f"))
         (accent-tok (etaf-theme-token :ui-accent "#0969da"))
         (sel-bg (etaf-theme-token :web-selected-bg "#eef5fc"))
         (hover-bg (etaf-theme-token :web-hover-bg "#f4f7fa"))
         (accent-bar (etaf-web-discourse--border :ui-accent "#0969da" 3))
         (row-border (etaf-web-discourse--border :web-border-soft "#eaeef2" 1))
         (title (plist-get topic :title))
         (cat-name (plist-get topic :category-name))
         (cat-id (plist-get topic :category-id))
         (dot-tok (etaf-web-discourse--category-dot-token cat-id))
         (replies (plist-get topic :replies))
         (views (etaf-web-discourse--compact-count (plist-get topic :views)))
         (activity (plist-get topic :activity))
         (author (plist-get topic :author))
         (last-poster (plist-get topic :last-poster))
         (tags (plist-get topic :tags))
         (people-parts
          (delq nil
                (list (unless (string-empty-p author) (format "@%s" author))
                      (when (and (not (string-empty-p last-poster))
                                 (not (equal last-poster author)))
                        (format "最新回复 @%s" last-poster)))))
         (people-line (mapconcat #'identity people-parts " · "))
         (tag-str (when tags
                    (mapconcat (lambda (tg) (format "#%s" tg))
                               (seq-take tags 3) " ")))
         (url (plist-get topic :url))
         (row-props
          (append
           (list :key (format "topic-%S-%d" (plist-get topic :id) idx)
                 :ref (intern (format "discourse-topic-%d" idx))
                 :width 'stretch
                 :padding-top '(lh 0.5)
                 :padding-bottom '(lh 0.5)
                 :padding-left '(ch 1)
                 :padding-right '(ch 1)
                 :border-bottom row-border
                 :role 'button :tab-index 0 :pointer 'hand
                 :aria-label title
                 :on-press (lambda () (funcall navigate url)))
           (if selected-p
               (list :background-color sel-bg
                     :border-left accent-bar
                     :aria-selected t)
             (list :hover-style (list :background-color hover-bg))))))
    (if narrow
        (etaf-node
         'column (append row-props (list :item-gap '(lh 0)))
         (list
          (etaf-node 'text
                     (list :font-weight (if selected-p 'bold 'normal)
                           :color fg-tok)
                     (list title))
          (etaf-node
           'flex (list :align-items 'center :column-gap '(ch 1) :flex-wrap 'wrap)
           (delq
            nil
            (list
             (when cat-name
               (etaf-ui-icon 'dot :set 'svg :min-width 1 :color dot-tok))
             (when cat-name
               (etaf-node 'text (list :color muted-tok) (list cat-name)))
             (unless (string-empty-p author)
               (etaf-node 'text (list :color dim-tok) (list (format "· @%s" author))))
             (when tag-str
               (etaf-node 'text (list :color (if selected-p accent-tok muted-tok))
                          (list tag-str)))
             (etaf-node 'text (list :color dim-tok)
                        (list (mapconcat
                               #'identity
                               (delq nil
                                     (list (format "· 回复 %d" replies)
                                           (format "浏览 %s" views)
                                           (unless (string-empty-p activity) activity)))
                               " · "))))))))
      (etaf-node
       'flex (append row-props (list :align-items 'center :column-gap '(ch 2)))
       (list
        (etaf-node
         'column (list :flex-grow 1 :flex-basis '(ch 0) :min-width '(ch 26)
                       :item-gap '(lh 0))
         (delq nil
               (list
                (etaf-node 'text
                           (list :font-weight (if selected-p 'bold 'normal)
                                 :color fg-tok)
                           (list title))
                (when (or (not (string-empty-p people-line)) tag-str)
                  (etaf-node
                   'flex (list :align-items 'center :column-gap '(ch 1) :flex-wrap 'wrap)
                   (delq nil
                         (list
                          (unless (string-empty-p people-line)
                            (etaf-node 'text (list :color (if selected-p muted-tok dim-tok))
                                       (list people-line)))
                          (when (and (not (string-empty-p people-line)) tag-str)
                            (etaf-node 'text (list :color dim-tok) (list "·")))
                          (when tag-str
                            (etaf-node 'text
                                       (list :color (if selected-p accent-tok muted-tok))
                                       (list tag-str))))))))))
        ;; Category: delicate vector dot + calm muted label (zero loud solid pill!)
        (etaf-node
         'flex (list :width '(ch 18) :flex-shrink 0 :align-items 'center :column-gap '(ch 1))
         (if cat-name
             (list (etaf-node 'box (list :flex-shrink 0)
                              (list (etaf-ui-icon 'dot :set 'svg :min-width 2 :color dot-tok)))
                   (etaf-node 'box (list :flex-grow 1 :flex-basis '(ch 0)
                                         :min-width '(ch 0) :overflow 'hidden)
                              (list (etaf-node 'text (list :color muted-tok)
                                               (list (truncate-string-to-width
                                                      cat-name 14 0 nil "…"))))))
           (list (etaf-node 'text (list :color dim-tok) (list "—")))))
        ;; Right-aligned numeric metrics group
        (etaf-node
         'flex (list :flex-shrink 0 :align-items 'center :column-gap '(ch 1))
         (list
          (etaf-node
           'box (list :width '(ch 6) :flex-shrink 0 :text-align 'right)
           (list (etaf-node 'text
                            (list :font-weight 'bold :color fg-tok)
                            (list (format "%d" replies)))))
          (etaf-node
           'box (list :width '(ch 7) :flex-shrink 0 :text-align 'right)
           (list (etaf-node 'text (list :color muted-tok) (list views))))
          (etaf-node
           'box (list :width '(ch 11) :flex-shrink 0 :text-align 'right)
           (list (etaf-node 'text (list :color dim-tok) (list activity)))))))))))

(defun etaf-web-discourse--render-categories-grid (cats origin navigate)
  "Render clean frameless Discourse CATS overview list."
  (let ((fg-tok (etaf-theme-token :ui-fg "#1f2328"))
        (muted-tok (etaf-theme-token :ui-muted-fg "#59636e"))
        (dim-tok (etaf-theme-token :ui-disabled-fg "#8c959f"))
        (border-soft (etaf-web-discourse--border :web-border-soft "#eaeef2" 1))
        (hover-bg (etaf-theme-token :web-hover-bg "#f4f7fa")))
    (if (null cats)
        (etaf-view (etaf-empty :title "暂无分类数据"
                               :description "该论坛未公开分类目录。"))
      (etaf-node
       'column (list :width 'stretch :item-gap '(lh 0))
       (mapcar
        (lambda (cat)
          (let* ((cid (alist-get 'id cat))
                 (slug (or (alist-get 'slug cat) "category"))
                 (name (or (alist-get 'name cat) slug))
                 (desc (string-trim (or (alist-get 'description_text cat) "")))
                 (count (or (alist-get 'topic_count cat) 0))
                 (week (or (alist-get 'topics_week cat) 0))
                 (dot-tok (etaf-web-discourse--category-dot-token cid))
                 (target (format "%s/c/%s/%d" origin slug cid)))
            (etaf-node
             'flex
             (list :key (format "cat-%S" cid)
                   :width 'stretch :align-items 'center :column-gap '(ch 2)
                   :padding-top '(lh 0.5)
                   :padding-bottom '(lh 0.5)
                   :padding-left '(ch 1)
                   :padding-right '(ch 1)
                   :border-bottom border-soft
                   :hover-style (list :background-color hover-bg)
                   :role 'button :tab-index 0 :pointer 'hand
                   :aria-label name
                   :on-press (lambda () (funcall navigate target)))
             (list
              (etaf-node
               'column (list :flex-grow 1 :flex-basis '(ch 0) :min-width '(ch 16)
                             :item-gap '(lh 0))
               (delq nil
                     (list
                      (etaf-node 'flex (list :align-items 'center :column-gap '(ch 1))
                                 (list (etaf-ui-icon 'dot :set 'svg :min-width 2 :color dot-tok)
                                       (etaf-node 'text (list :font-weight 'bold :color fg-tok)
                                                  (list name))))
                      (unless (string-empty-p desc)
                        (etaf-node 'text (list :color muted-tok)
                                   (list (truncate-string-to-width desc 92 0 nil "…")))))))
              (etaf-node
               'box (list :flex-shrink 0)
               (list (etaf-node 'text (list :color dim-tok)
                                (list (format "话题 %s · 本周 %d"
                                              (etaf-web-discourse--compact-count count)
                                              week)))))))))
        cats)))))

(defun etaf-web-discourse--render-nav-item (key ref label active-p on-press
                                                icon-name &optional icon-color
                                                count-str panel-cols)
  "Render one inset Swiss-grid navigation row for sidebar or drawer.
Uses a fixed 2ch leading `etaf-ui-icon' gutter so view icons and category dots
align along one vertical axis."
  (let* ((fg-tok (etaf-theme-token :ui-fg "#1f2328"))
         (muted-tok (etaf-theme-token :ui-muted-fg "#59636e"))
         (dim-tok (etaf-theme-token :ui-disabled-fg "#8c959f"))
         (accent-tok (etaf-theme-token :ui-accent "#0969da"))
         (sel-bg (etaf-theme-token :web-selected-bg "#eef5fc"))
         (hover-bg (etaf-theme-token :web-hover-bg "#f4f7fa"))
         (accent-bar (etaf-web-discourse--border :ui-accent "#0969da" 2))
         (is-cat (eq icon-name 'dot))
         (glyph-color (cond
                       (icon-color icon-color)
                       (active-p accent-tok)
                       (t dim-tok)))
         (reserve (+ 7 (if count-str (+ 2 (string-width count-str)) 0)))
         (budget (max 8 (- (or panel-cols 26) reserve)))
         (disp (if (> (string-width label) budget)
                   (truncate-string-to-width label budget 0 nil "…")
                 label)))
    (etaf-node
     'flex
     (append
      (list :key key
            :width 'stretch
            :height '(lh 1)
            :align-items 'center
            :column-gap '(ch 1)
            :padding-left '(ch 1)
            :padding-right '(ch 1)
            :role 'button :tab-index 0 :pointer 'hand
            :aria-label label
            :help-echo label
            :on-press on-press)
      (when ref (list :ref ref))
      (if active-p
          (list :background-color sel-bg
                :border-left accent-bar
                :aria-selected t)
        (list :hover-style (list :background-color hover-bg))))
     (delq
      nil
      (list
       (etaf-node 'box (list :width '(ch 2) :flex-shrink 0)
                  (list (etaf-ui-icon icon-name :set 'svg :min-width 2
                                      :color glyph-color)))
       (etaf-node 'box (list :flex-grow 1 :flex-basis '(ch 0)
                             :min-width '(ch 0) :overflow 'hidden)
                  (list (etaf-node 'text
                                   (list :color (if active-p
                                                    (if is-cat fg-tok accent-tok)
                                                  muted-tok)
                                         :font-weight (if active-p 'bold 'normal))
                                   (list disp))))
       (when (and count-str (not (string-empty-p count-str)))
         (etaf-node 'box (list :flex-shrink 0)
                    (list (etaf-node 'text
                                     (list :color (if active-p muted-tok dim-tok))
                                     (list count-str))))))))))

(defun etaf-web-discourse--render-nav-panel (st panel-cols in-drawer)
  "Render seamless same-canvas left navigation rail for ST."
  (let* ((tab (etaf-value (plist-get st :tab)))
         (cat-id (etaf-value (plist-get st :category-id)))
         (cats (etaf-value (plist-get st :categories)))
         (site-title (or (plist-get st :site-title) (plist-get st :origin)))
         (site-desc (plist-get st :site-desc))
         (on-tab (plist-get st :on-tab))
         (on-category (plist-get st :on-category))
         (on-toggle-sidebar (plist-get st :on-toggle-sidebar))
         (drawer-open (plist-get st :drawer-open-ref))
         (fg-tok (etaf-theme-token :ui-fg "#1f2328"))
         (dim-tok (etaf-theme-token :ui-disabled-fg "#8c959f"))
         (hover-bg (etaf-theme-token :web-hover-bg "#f4f7fa"))
         (border-soft (etaf-web-discourse--border :web-border-soft "#eaeef2" 1))
         (pick-tab (lambda (k)
                     (lambda ()
                       (etaf-set-value drawer-open nil)
                       (funcall on-tab k))))
         (pick-cat (lambda (cid slug)
                     (lambda ()
                       (etaf-set-value drawer-open nil)
                       (funcall on-category cid slug))))
         (shown-cats (seq-take cats 24))
         (nav-body
          (etaf-node
           'column (list :width 'stretch :item-gap '(lh 0) :focus-group 'vertical)
           (append
            (list
             (etaf-node 'box (list :width 'stretch
                                   :padding-left '(ch 1)
                                   :padding-right '(ch 1)
                                   :padding-bottom '(lh 0))
                        (list (etaf-node 'text (list :font-weight 'bold :color dim-tok)
                                         (list "发现"))))
             (etaf-web-discourse--render-nav-item
              'nav-latest 'discourse-tab-latest "最新话题"
              (and (eq tab 'latest) (null cat-id))
              (funcall pick-tab 'latest) 'clock nil nil panel-cols)
             (etaf-web-discourse--render-nav-item
              'nav-top 'discourse-tab-top "热门讨论"
              (and (eq tab 'top) (null cat-id))
              (funcall pick-tab 'top) 'star nil nil panel-cols)
             (etaf-web-discourse--render-nav-item
              'nav-unanswered 'discourse-tab-unanswered "未回复"
              (and (eq tab 'unanswered) (null cat-id))
              (funcall pick-tab 'unanswered) 'reply nil nil panel-cols)
             (etaf-web-discourse--render-nav-item
              'nav-categories 'discourse-tab-categories "全部分类"
              (eq tab 'categories)
              (funcall pick-tab 'categories) 'list nil nil panel-cols))
            (when shown-cats
              (append
               (list
                ;; Inset quiet hairline divider (respects 2ch rail margins)
                (etaf-node 'box (list :width 'stretch
                                      :padding-left '(ch 1)
                                      :padding-right '(ch 1))
                           (list (etaf-node 'box (list :width 'stretch
                                                       :height '(lh 1)
                                                       :border-bottom border-soft)
                                            nil)))
                (etaf-node 'flex (list :width 'stretch
                                       :align-items 'center
                                       :justify-content 'space-between
                                       :padding-top '(lh 1)
                                       :padding-left '(ch 1)
                                       :padding-right '(ch 1))
                           (list
                            (etaf-node 'text (list :font-weight 'bold :color dim-tok)
                                       (list "分类"))
                            (etaf-node 'text (list :color dim-tok)
                                       (list (format "%d" (length shown-cats)))))))
               (mapcar
                (lambda (cat)
                  (let* ((cid (alist-get 'id cat))
                         (slug (or (alist-get 'slug cat) ""))
                         (name (or (alist-get 'name cat) slug))
                         (count (or (alist-get 'topic_count cat) 0))
                         (cnt-str (when (> count 0)
                                    (etaf-web-discourse--compact-count count))))
                    (etaf-web-discourse--render-nav-item
                     (format "rail-cat-%S" cid) nil name
                     (eql cid cat-id)
                     (funcall pick-cat cid slug)
                     'dot (etaf-web-discourse--category-dot-token cid)
                     cnt-str panel-cols)))
                shown-cats)))))))
    (etaf-node
     'flex (list :flex-direction 'column
                 :width 'stretch
                 :height (if in-drawer 'auto 'stretch)
                 :min-height '(lh 0)
                 :overflow (if in-drawer 'visible 'hidden))
     (delq
      nil
      (list
       ;; Site Identity header (2ch horizontal margins, icon collapse button)
       (unless in-drawer
         (etaf-node
          'column (list :width 'stretch :flex-shrink 0
                        :padding-top '(lh 1)
                        :padding-bottom '(lh 1)
                        :padding-left '(ch 2)
                        :padding-right '(ch 2)
                        :item-gap '(lh 0))
          (delq
           nil
           (list
            (etaf-node
             'flex (list :width 'stretch :align-items 'center
                         :justify-content 'space-between
                         :column-gap '(ch 1))
             (list
              (etaf-node 'box (list :flex-grow 1 :flex-basis '(ch 0)
                                    :min-width '(ch 0) :overflow 'hidden)
                         (list (etaf-node 'text (list :font-weight 'bold :color fg-tok)
                                          (list (truncate-string-to-width
                                                 site-title (max 10 (- panel-cols 7)) 0 nil "…")))))
              (etaf-node 'box (list :flex-shrink 0
                                    :hover-style (list :background-color hover-bg))
                         (list (etaf-ui-icon 'sidebar :set 'svg :min-width 2
                                             :color dim-tok
                                             :aria-label "折叠侧栏"
                                             :help-echo "折叠导航栏 (s)"
                                             :on-press on-toggle-sidebar)))))
            (when (and (stringp site-desc) (not (string-empty-p site-desc)))
              (etaf-node 'text (list :color dim-tok)
                         (list (truncate-string-to-width
                                site-desc (max 12 (- panel-cols 4)) 0 nil "…"))))))))
       ;; Scrollable views + categories list (1ch outer + 1ch inner = exact 2ch axis)
       (if in-drawer
           (etaf-node 'box (list :width 'stretch
                                 :padding-left '(ch 1) :padding-right '(ch 1))
                      (list nav-body))
         (etaf-node
          'box (list :ref 'discourse-sidebar-scroll
                     :width 'stretch
                     :flex-grow 1
                     :flex-basis '(lh 0)
                     :min-height '(lh 0)
                     :overflow 'scroll
                     :role 'region
                     :tab-index 0
                     :aria-label "论坛导航")
          (list (etaf-node 'column (list :width 'stretch :height 'auto
                                         :padding-left '(ch 1)
                                         :padding-right '(ch 1)
                                         :padding-bottom '(lh 1))
                           (list nav-body)))))
       ;; Quiet borderless footer (merges peacefully above Emacs mode-line)
       (unless in-drawer
         (etaf-node
          'flex (list :width 'stretch :flex-shrink 0
                      :align-items 'center :justify-content 'space-between
                      :padding-top '(lh 0.5)
                      :padding-bottom '(lh 0.5)
                      :padding-left '(ch 2)
                      :padding-right '(ch 2))
          (delq
           nil
           (list
            (etaf-node 'text (list :color dim-tok) (list "s 折叠"))
            (when (>= panel-cols 20)
              (etaf-node 'text (list :color dim-tok) (list "[ / ] 调宽"))))))))))))

(defun etaf-web-discourse--active-heading (tab cat-id by-id)
  "Return human heading string for active Discourse TAB and CAT-ID."
  (cond
   ((and cat-id by-id (gethash cat-id by-id))
    (or (alist-get 'name (gethash cat-id by-id)) "分类"))
   ((eq tab 'top) "热门讨论")
   ((eq tab 'unanswered) "未回复")
   ((eq tab 'categories) "全部分类")
   (t "最新话题")))

(defun etaf-web-discourse--render-list-view (st rctx)
  "Render full-height two-pane Discourse topic list Page Controller ST."
  (let* ((vw (max 44 (or (plist-get rctx :width) 96)))
         (cw (max 1.0 (float (or (plist-get rctx :char-width)
                                 (car (etaf-web--cell-metrics))))))
         (vw-px (or (plist-get rctx :width-px) (round (* vw cw))))
         (narrow-pane (< vw etaf-web-discourse--wide-breakpoint))
         (collapsed (etaf-value (plist-get st :collapsed-ref)))
         (dock-sidebar (and (not narrow-pane) (not collapsed)))
         (drawer-open (plist-get st :drawer-open-ref))
         (sidebar-width-ref (plist-get st :sidebar-width-ref))
         (min-px (round (* etaf-web-discourse--min-sidebar-cols cw)))
         (max-px (max (+ min-px (round (* 6 cw))) (round (* 0.36 vw-px))))
         (default-cols (max etaf-web-discourse--default-sidebar-cols
                            (min 34 (round (* 0.17 vw)))))
         (default-px (round (* default-cols cw)))
         (clamped-px (max min-px (min (or (etaf-value sidebar-width-ref) default-px) max-px)))
         (sidebar-cols (max etaf-web-discourse--min-sidebar-cols
                            (round (/ (float clamped-px) cw))))
         (right-cols (if dock-sidebar (max 44 (- vw sidebar-cols 1)) vw))
         (narrow-rows (< right-cols etaf-web-discourse--narrow-breakpoint))
         (pad-h (cond (narrow-rows 1) ((>= right-cols 124) 4) (t 2)))
         (container-w (min 144 (max 40 (- right-cols (* 2 pad-h) 2))))
         (tab (etaf-value (plist-get st :tab)))
         (cat-id (etaf-value (plist-get st :category-id)))
         (topics (etaf-value (plist-get st :topics)))
         (cats (etaf-value (plist-get st :categories)))
         (by-id (plist-get st :by-id))
         (selected-idx (or (etaf-value (plist-get st :selected)) 0))
         (loading-more (etaf-value (plist-get st :loading-more)))
         (more-url (etaf-value (plist-get st :more-url)))
         (page-num (or (etaf-value (plist-get st :page-num)) 1))
         (active-search (etaf-value (plist-get st :active-search)))
         (query-ref (plist-get st :query-ref))
         (origin (plist-get st :origin))
         (navigate (plist-get st :navigate))
         (on-search (plist-get st :on-search))
         (on-more (plist-get st :on-more))
         (on-toggle-sidebar (plist-get st :on-toggle-sidebar))
         (heading (etaf-web-discourse--active-heading tab cat-id by-id))
         (fg-tok (etaf-theme-token :ui-fg "#1f2328"))
         (dim-tok (etaf-theme-token :ui-disabled-fg "#8c959f"))
         (accent-tok (etaf-theme-token :ui-accent "#0969da"))
         (border-soft (etaf-web-discourse--border :web-border-soft "#eaeef2" 1))
         (feed-pane
          (etaf-node
           'box
           (list :key 'discourse-feed-pane
                 :ref 'web-scroll :id "web-scroll"
                 :width '(ch 0)
                 :flex-grow 1
                 :flex-basis '(ch 0)
                 :min-width '(ch 0)
                 :height 'stretch
                 :min-height '(lh 0)
                 :overflow 'scroll
                 :role 'region
                 :tab-index 0
                 :aria-label "论坛话题列表")
           (list
            (etaf-node
             'column (list :width 'stretch :height 'auto :cross-align 'center
                           :padding (list (list 'lh 1) (list 'ch pad-h)))
             (list
              (etaf-node
               'column (list :width (list 'ch container-w) :item-gap '(lh 1))
               (delq
                nil
                (list
                 ;; Single clean header row: (optional ≡ 分类) + Heading + count left; flat search right
                 (etaf-node
                  'flex (list :width 'stretch :align-items 'center
                              :justify-content 'space-between
                              :column-gap '(ch 2) :row-gap '(lh 1) :flex-wrap 'wrap)
                  (list
                   (etaf-node
                    'flex (list :align-items 'center :column-gap '(ch 1) :flex-wrap 'wrap)
                    (delq
                     nil
                     (list
                      (unless dock-sidebar
                        (etaf-view
                         (etaf-button :label "≡ 分类"
                                      :variant 'ghost
                                      :color accent-tok
                                      :padding '((lh 0) (ch 1))
                                      :help-echo "打开论坛导航栏 (s)"
                                      :on-press on-toggle-sidebar)))
                      (unless dock-sidebar
                        (etaf-node 'text (list :color dim-tok) (list "│")))
                      (etaf-node 'text (list :font-weight 'bold :color fg-tok)
                                 (list heading))
                      (unless (eq tab 'categories)
                        (etaf-node 'text (list :color dim-tok)
                                   (list (format "· %d 条" (length topics))))))))
                   (etaf-node
                    'box (list :width (if narrow-rows 'stretch '(ch 30)) :flex-shrink 0)
                    (list
                     (etaf-web--plain-input-view
                      :bind query-ref
                      :ref 'discourse-search-input
                      :label "搜索话题"
                      :icon 'search
                      :width 'stretch
                      :placeholder "搜索话题或关键词…"
                      :on-submit on-search
                      :on-clear (lambda () (funcall on-search "")))))))
                 ;; Active search indicator
                 (when (and (stringp active-search) (not (string-empty-p active-search)))
                   (etaf-node
                    'flex (list :width 'stretch :align-items 'center :column-gap '(ch 2))
                    (list
                     (etaf-node 'text (list :color accent-tok)
                                (list (format "搜索结果：%s（%d 条）" active-search (length topics))))
                     (etaf-view
                      (etaf-button :label "清除搜索" :variant 'ghost
                                   :padding '((lh 0) (ch 1))
                                   :on-press (lambda () (funcall on-search "")))))))
                 ;; Main feed: Categories overview OR Topic rows
                 (if (eq tab 'categories)
                     (etaf-web-discourse--render-categories-grid cats origin navigate)
                   (etaf-node
                    'column (list :width 'stretch :item-gap '(lh 0))
                    (delq
                     nil
                     (append
                      ;; Minimal single-bottom-hairline column header on wide feeds
                      (unless narrow-rows
                        (list
                         (etaf-node
                          'flex (list :width 'stretch :column-gap '(ch 2)
                                      :padding-bottom '(lh 0.5)
                                      :padding-left '(ch 1)
                                      :padding-right '(ch 1)
                                      :border-bottom border-soft)
                          (list
                           (etaf-node 'box (list :flex-grow 1 :flex-basis '(ch 0))
                                      (list (etaf-node 'text (list :color dim-tok) (list "话题"))))
                           (etaf-node 'box (list :width '(ch 18) :flex-shrink 0)
                                      (list (etaf-node 'text (list :color dim-tok) (list "分类"))))
                           (etaf-node
                            'flex (list :flex-shrink 0 :align-items 'center :column-gap '(ch 1))
                            (list
                             (etaf-node 'box (list :width '(ch 6) :flex-shrink 0 :text-align 'right)
                                        (list (etaf-node 'text (list :color dim-tok) (list "回复"))))
                             (etaf-node 'box (list :width '(ch 7) :flex-shrink 0 :text-align 'right)
                                        (list (etaf-node 'text (list :color dim-tok) (list "浏览"))))
                             (etaf-node 'box (list :width '(ch 11) :flex-shrink 0 :text-align 'right)
                                        (list (etaf-node 'text (list :color dim-tok) (list "活跃"))))))))))
                      (if topics
                          (cl-loop for tp in topics
                                   for idx from 0
                                   collect (etaf-web-discourse--render-topic-row
                                            tp idx (eql idx selected-idx) narrow-rows navigate))
                        (list
                         (etaf-view
                          (etaf-empty :title "没有找到话题"
                                      :description "换个关键词或分类再试试。"))))))))
                 ;; Subtle footer pagination + key hints
                 (unless (eq tab 'categories)
                   (etaf-node
                    'flex (list :width 'stretch :align-items 'center
                                :justify-content 'space-between
                                :column-gap '(ch 2) :row-gap '(lh 1) :flex-wrap 'wrap
                                :padding-top '(lh 0.5))
                    (delq
                     nil
                     (list
                      (etaf-node
                       'flex (list :align-items 'center :column-gap '(ch 2))
                       (delq
                        nil
                        (list
                         (etaf-node 'text (list :color dim-tok)
                                    (list (format "第 %d 页 · 已载入 %d 条"
                                                  page-num (length topics))))
                         (when more-url
                           (etaf-view
                            (etaf-button
                             :label (if loading-more "加载中…" "加载更多 →")
                             :variant 'secondary
                             :disabled (and loading-more t)
                             :ref 'discourse-load-more
                             :padding '((lh 0) (ch 1))
                             :on-press on-more))))))
                      (unless narrow-rows
                        (etaf-node 'text (list :color dim-tok)
                                   (list "n/p 移动 · RET 进帖 · / 搜索 · s 侧栏"))))))))))))))))
    (etaf-node
     'flex (list :flex-direction 'column
                 :width 'stretch
                 :height 'stretch
                 :flex-grow 1
                 :flex-basis '(lh 0)
                 :min-height '(lh 0)
                 :overflow 'hidden)
     (list
      (etaf-node
       'flex (list :flex-direction 'row
                   :width 'stretch
                   :height 'stretch
                   :flex-grow 1
                   :flex-basis '(lh 0)
                   :min-height '(lh 0)
                   :overflow 'hidden)
       (delq
        nil
        (list
         (when dock-sidebar
           (etaf-node
            'flex (list :key 'discourse-sidebar-pane
                        :flex-direction 'column
                        :width (list 'px clamped-px)
                        :flex-shrink 0
                        :height 'stretch
                        :min-height '(lh 0)
                        :overflow 'hidden)
            (list (etaf-web-discourse--render-nav-panel st sidebar-cols nil))))
         (when dock-sidebar
           (etaf-node
            'box (list :key 'discourse-resizer-slot :height 'stretch :flex-shrink 0)
            (list
             (etaf-view
              (etaf-pane-resizer
               :ref 'discourse-pane-resizer
               :size clamped-px
               :min min-px
               :max max-px
               :on-change (lambda (next-px)
                            (etaf-set-value sidebar-width-ref next-px)))))))
         feed-pane)))
      (etaf-view
       (etaf-drawer
        :open (and (not dock-sidebar) (etaf-value drawer-open))
        :title (or (plist-get st :site-title) "论坛分类")
        :placement 'left
        :width '(ch 32)
        :modal t
        :on-close (lambda () (etaf-set-value drawer-open nil))
        (expr (etaf-web-discourse--render-nav-panel st 26 t))))))))

;;; ---------------------------------------------------------------------------
;;; View rendering: Editorial Stream Thread View (v3)
;;; ---------------------------------------------------------------------------

(defun etaf-web-discourse--compile-post-entry (post origin &optional rewriter)
  "Convert Discourse POST alist into a render-ready plist with parsed Markdown.
Uses fragment mode so embedded `<aside class=\"onebox\">' or `<aside
class=\"quote\">' cards never hijack main-content extraction, and records
remote image URLs for asynchronous background download."
  (let* ((pnum (or (alist-get 'post_number post) 1))
         (uname (or (alist-get 'username post) "anonymous"))
         (created (etaf-web-discourse--format-datetime (alist-get 'created_at post)))
         (likes (etaf-web-discourse--post-likes post))
         (replies (or (alist-get 'reply_count post) 0))
         (cooked (etaf-web-discourse--clean-cooked (alist-get 'cooked post)))
         (md-raw (condition-case nil
                     (plist-get (etaf-web--compile
                                 cooked :base-url origin
                                 :image-rewriter rewriter :fragment t)
                                :markdown)
                   (error "")))
         (body-md (string-trim (etaf-web-discourse--strip-front-matter md-raw)))
         (img-urls (etaf-web--remote-image-references body-md))
         (doc (etaf-web--parse-embedded-markdown
               (if (string-empty-p body-md) "（空楼层）" body-md))))
    (list :id (alist-get 'id post)
          :number pnum
          :username uname
          :created created
          :likes likes
          :replies replies
          :image-urls img-urls
          :doc doc)))

(defun etaf-web-discourse--render-post-card (entry open-external open-link url theme max-cols &optional page-dir)
  "Render one Discourse post ENTRY: soft-tinted OP card or frameless reply."
  (let* ((pnum (plist-get entry :number))
         (op-p (eql pnum 1))
         (uname (plist-get entry :username))
         (created (plist-get entry :created))
         (likes (plist-get entry :likes))
         (replies (plist-get entry :replies))
         (doc (plist-get entry :doc))
         (fg-tok (etaf-theme-token :ui-fg "#1f2328"))
         (muted-tok (etaf-theme-token :ui-muted-fg "#59636e"))
         (dim-tok (etaf-theme-token :ui-disabled-fg "#8c959f"))
         (accent-tok (etaf-theme-token :ui-accent "#0969da"))
         (op-bg (etaf-theme-token :web-op-bg "#f7f9fc"))
         (sel-bg (etaf-theme-token :web-selected-bg "#eef5fc"))
         (border-soft (etaf-web-discourse--border :web-border-soft "#eaeef2" 1))
         (accent-bar (etaf-web-discourse--border :ui-accent "#0969da" 3))
         (stats (mapconcat
                 #'identity
                 (delq nil
                       (list (when (> likes 0) (format "♥ %d" likes))
                             (when (> replies 0) (format "回复 %d" replies))))
                 "   ·   ")))
    (etaf-node
     'column
     (append
      (list :key (format "post-%S" (or (plist-get entry :id) pnum))
            :width 'stretch
            :item-gap '(lh 1))
      (if op-p
          (list :background-color op-bg
                :border-left accent-bar
                :padding '((lh 1) (ch 2)))
        (list :padding-top '(lh 1)
              :padding-bottom '(lh 1)
              :border-bottom border-soft)))
     (delq
      nil
      (list
       ;; Header row
       (etaf-node
        'flex (list :width 'stretch :align-items 'center
                    :justify-content 'space-between)
        (list
         (etaf-node
          'flex (list :align-items 'center :column-gap '(ch 1) :flex-wrap 'wrap)
          (delq nil
                (list
                 (etaf-node 'text (list :font-weight 'bold
                                        :color (if op-p accent-tok fg-tok))
                            (list (format "@%s" uname)))
                 (when op-p
                   (etaf-node 'box (list :background-color sel-bg
                                         :padding '((lh 0) (ch 1)))
                              (list (etaf-node 'text (list :font-weight 'bold :color accent-tok)
                                               (list "楼主")))))
                 (etaf-node 'text (list :color dim-tok) (list created)))))
         (etaf-node 'box (list :flex-shrink 0)
                    (list (etaf-node 'text (list :color dim-tok)
                                     (list (format "#%d" pnum)))))))
       ;; Post embedded Markdown body (flush inside reading column)
       (etaf-web--render-markdown-blocks
        doc
        :theme-mode theme
        :dir page-dir
        :open-link open-link
        :line-grid t
        :max-cols (max 30 (- max-cols (if op-p 4 0))))
       ;; Footer stats / reply handoff
       (when (or op-p (not (string-empty-p stats)))
         (etaf-node
          'flex (list :width 'stretch :align-items 'center
                      :justify-content 'space-between)
          (list
           (etaf-node 'text (list :color muted-tok) (list stats))
           (if op-p
               (etaf-view
                (etaf-button
                 :label "在浏览器回复 (o)"
                 :variant 'ghost
                 :color accent-tok
                 :padding '((lh 0) (ch 0))
                 :on-press (lambda () (funcall open-external url))))
             (etaf-node 'text nil (list "")))))))))))

(defun etaf-web-discourse--render-thread-view (st rctx)
  "Render editorial Discourse thread Page Controller ST for RCTX."
  (let* ((vw (max 44 (or (plist-get rctx :width) 96)))
         (theme (or (plist-get rctx :theme) 'auto))
         (narrow (< vw etaf-web-discourse--narrow-breakpoint))
         (cap (or (etaf-value (plist-get st :measure-ref)) 86))
         (measure (if narrow (- vw 4) (min cap (- vw 6))))
         (title (plist-get st :title))
         (origin (plist-get st :origin))
         (url (plist-get st :url))
         (cat-name (plist-get st :category-name))
         (cat-url (plist-get st :category-url))
         (tags (plist-get st :tags))
         (created (plist-get st :created))
         (views (plist-get st :views))
         (posts-count (plist-get st :posts-count))
         (posts (etaf-value (plist-get st :posts)))
         (_media-rev (etaf-value (plist-get st :media-rev)))
         (page-dir (plist-get st :page-dir))
         (remaining (or (etaf-value (plist-get st :remaining)) 0))
         (loading-more (etaf-value (plist-get st :loading-more)))
         (navigate (plist-get st :navigate))
         (open-external (plist-get st :open-external))
         (open-link (plist-get st :open-link))
         (on-more (plist-get st :on-more))
         (fg-tok (etaf-theme-token :ui-fg "#1f2328"))
         (muted-tok (etaf-theme-token :ui-muted-fg "#59636e"))
         (dim-tok (etaf-theme-token :ui-disabled-fg "#8c959f"))
         (accent-tok (etaf-theme-token :ui-accent "#0969da"))
         (border-soft (etaf-web-discourse--border :web-border-soft "#eaeef2" 1))
         (meta-sub (mapconcat
                    #'identity
                    (delq nil
                          (list (when tags
                                  (mapconcat (lambda (tg) (format "#%s" tg))
                                             (seq-take tags 5) " "))
                                (when (and (stringp created) (not (string-empty-p created)))
                                  (format "创建于 %s" created))
                                "n/p 跳楼 · u 返回"))
                    "  ·  ")))
    (etaf-node
     'column (list :width 'stretch :cross-align 'center
                   :padding (if narrow '((lh 1) (ch 1)) '((lh 1) (ch 3))))
     (list
      (etaf-node
       'column (list :width (list 'ch measure) :item-gap '(lh 1))
       (delq
        nil
        (list
         ;; Breadcrumb + counters
         (etaf-node
          'flex (list :width 'stretch :align-items 'center
                      :justify-content 'space-between
                      :column-gap '(ch 2) :flex-wrap 'wrap)
          (list
           (etaf-node
            'flex (list :align-items 'center :column-gap '(ch 1))
            (delq nil
                  (list
                   (etaf-view
                    (etaf-button
                     :label "← 返回话题列表"
                     :variant 'ghost
                     :color accent-tok
                     :ref 'discourse-back-list
                     :padding '((lh 0) (ch 0))
                     :on-press (lambda () (funcall navigate (concat origin "/")))))
                   (when cat-name
                     (etaf-node 'text (list :color dim-tok) (list "/")))
                   (when cat-name
                     (etaf-view
                      (etaf-button
                       :label cat-name
                       :variant 'ghost
                       :color muted-tok
                       :padding '((lh 0) (ch 0))
                       :on-press (lambda ()
                                   (when cat-url (funcall navigate cat-url)))))))))
           (etaf-node 'text (list :color dim-tok)
                      (list (format "%d 楼 · %s 浏览"
                                    (or posts-count (length posts))
                                    (etaf-web-discourse--compact-count views))))))
         ;; Topic Title + quiet metadata + soft bottom rule
         (etaf-node
          'column (list :width 'stretch :item-gap '(lh 0)
                        :padding-bottom '(lh 1)
                        :border-bottom border-soft)
          (list
           (etaf-node 'text (list :font-weight 'bold :color fg-tok)
                      (list (or title "话题")))
           (etaf-node 'text (list :color dim-tok) (list meta-sub))))
         ;; Post stream
         (etaf-node
          'column (list :width 'stretch :item-gap '(lh 0))
          (mapcar (lambda (entry)
                    (etaf-web-discourse--render-post-card
                     entry open-external open-link url theme measure page-dir))
                  posts))
         ;; Load more bar
         (etaf-node
          'flex (list :width 'stretch :align-items 'center
                      :justify-content 'space-between
                      :padding-top '(lh 0.5))
          (list
           (if (> remaining 0)
               (etaf-view
                (etaf-button
                 :label (if loading-more
                            "加载楼层中…"
                          (format "加载后续 %d 楼 →" remaining))
                 :variant 'secondary
                 :disabled (and loading-more t)
                 :ref 'discourse-load-more-posts
                 :padding '((lh 0) (ch 1))
                 :on-press on-more))
             (etaf-node 'text (list :color dim-tok)
                        (list (format "已显示全部 %d 楼" (length posts)))))
           (etaf-view
            (etaf-button
             :label "在浏览器回复 (o)"
             :variant 'ghost
             :color accent-tok
             :padding '((lh 0) (ch 0))
             :on-press (lambda () (funcall open-external url)))))))))))))

;;; ---------------------------------------------------------------------------
;;; Openers (List & Thread) + Registration
;;; ---------------------------------------------------------------------------

(defun etaf-web-discourse--open-list (ctx route)
  "Open a Discourse topic list view for CTX and ROUTE; return canceller."
  (let* ((origin (plist-get route :origin))
         (site-info (gethash origin etaf-web-discourse--known-origins))
         (site-title (or (plist-get site-info :title)
                         (car (etaf-web--url-parts origin))))
         (site-desc (plist-get site-info :description))
         (init-tab (or (plist-get route :tab) 'latest))
         (init-cat-id (plist-get route :category-id))
         (init-cat-path (plist-get route :category-path))
         (init-search (plist-get route :search))
         (navigate (plist-get ctx :navigate))
         (focus-input (plist-get ctx :focus-input))
         (buf (plist-get ctx :buffer))
         (sidebar-width-ref (or (plist-get ctx :sidebar-width-px)
                                (etaf-ref nil :name 'discourse-sidebar-width)))
         (collapsed-ref (etaf-ref nil :name 'discourse-collapsed))
         (drawer-open-ref (etaf-ref nil :name 'discourse-drawer-open))
         (on-stage (plist-get ctx :on-stage))
         (on-ready (plist-get ctx :on-ready))
         (on-error (plist-get ctx :on-error))
         (cancels nil)
         (disposed nil)
         (ready-sent nil)
         (window-metrics
          (lambda ()
            (let* ((win (and (buffer-live-p buf) (get-buffer-window buf t)))
                   (live (window-live-p win))
                   (w (if live (window-body-width win) 96))
                   (cell-w (car (etaf-web--cell-metrics)))
                   (px (if live (window-body-width win t) (* w cell-w)))
                   (cw (if (and live (> w 0) (> px 0))
                           (/ (float px) w)
                         (float cell-w))))
              (list w px cw))))
         (toggle-sidebar
          (lambda ()
            (interactive)
            (let ((vw (nth 0 (funcall window-metrics))))
              (if (< vw etaf-web-discourse--wide-breakpoint)
                  (etaf-set-value drawer-open-ref (not (etaf-value drawer-open-ref)))
                (etaf-set-value collapsed-ref (not (etaf-value collapsed-ref)))))))
         (step-sidebar
          (lambda (delta-cols)
            (let* ((m (funcall window-metrics))
                   (vw (nth 0 m))
                   (vw-px (nth 1 m))
                   (cw (nth 2 m))
                   (min-px (round (* etaf-web-discourse--min-sidebar-cols cw)))
                   (max-px (max (+ min-px (round (* 6 cw))) (round (* 0.36 vw-px))))
                   (default-cols (max etaf-web-discourse--default-sidebar-cols
                                      (min 34 (round (* 0.17 vw)))))
                   (cur (or (etaf-value sidebar-width-ref)
                            (round (* default-cols cw))))
                   (next (max min-px (min max-px (+ cur (round (* delta-cols cw)))))))
              (when (>= vw etaf-web-discourse--wide-breakpoint)
                (etaf-set-value collapsed-ref nil)
                (etaf-set-value sidebar-width-ref next)
                (message "侧栏宽度: %d 列" (round (/ (float next) cw)))))))
         (st (list :origin origin
                   :site-title site-title
                   :site-desc site-desc
                   :navigate navigate
                   :sidebar-width-ref sidebar-width-ref
                   :collapsed-ref collapsed-ref
                   :drawer-open-ref drawer-open-ref
                   :on-toggle-sidebar toggle-sidebar
                   :tab (etaf-ref init-tab :name 'discourse-tab)
                   :category-id (etaf-ref init-cat-id :name 'discourse-cat)
                   :category-path init-cat-path
                   :categories (etaf-ref nil :name 'discourse-cats)
                   :by-id (make-hash-table :test #'eql)
                   :topics (etaf-ref nil :name 'discourse-topics)
                   :selected (etaf-ref 0 :name 'discourse-selected)
                   :query-ref (etaf-ref (or init-search "") :name 'discourse-query)
                   :active-search (etaf-ref (or init-search "") :name 'discourse-active-search)
                   :more-url (etaf-ref nil :name 'discourse-more-url)
                   :page-num (etaf-ref 1 :name 'discourse-page-num)
                   :loading-more (etaf-ref nil :name 'discourse-loading-more))))
    (cl-labels
        ((track (c) (when (functionp c) (push c cancels)))
         (cancel-all ()
           (dolist (fn cancels) (ignore-errors (funcall fn)))
           (setq cancels nil))
         (select-delta (delta)
           (let* ((topics (etaf-value (plist-get st :topics)))
                  (len (length topics)))
             (when (> len 0)
               (let ((next (max 0 (min (1- len)
                                       (+ (or (etaf-value (plist-get st :selected)) 0)
                                          delta)))))
                 (etaf-set-value (plist-get st :selected) next)
                 (when-let* ((rt (and (buffer-live-p buf)
                                      (etaf-runtime-for-buffer buf))))
                   (etaf-runtime-flush rt)
                   (ignore-errors
                     (etaf-focus rt (intern (format "discourse-topic-%d" next)))))))))
         (commit-ready ()
           (unless (or disposed ready-sent)
             (setq ready-sent t)
             (funcall
              on-ready
              (list :title site-title
                    :mode-label "Discourse"
                    :own-scroll t
                    :render (lambda (rctx)
                              (etaf-web-discourse--render-list-view st rctx))
                    :keys (list (list "/" (lambda ()
                                            (interactive)
                                            (funcall focus-input 'discourse-search-input))
                                      "搜索话题")
                                (list "s" toggle-sidebar "切换论坛导航栏")
                                (list "[" (lambda () (interactive) (funcall step-sidebar -4))
                                      "缩窄侧栏")
                                (list "]" (lambda () (interactive) (funcall step-sidebar 4))
                                      "加宽侧栏")
                                (list "n" (lambda () (interactive) (select-delta 1))
                                      "下一话题")
                                (list "p" (lambda () (interactive) (select-delta -1))
                                      "上一话题"))
                    :on-headings
                    (lambda (_buf) nil)
                    :on-reload
                    (lambda () (load-list (etaf-value (plist-get st :tab))
                                          (etaf-value (plist-get st :category-id))
                                          (plist-get st :category-path)
                                          (etaf-value (plist-get st :active-search))))
                    :dispose (lambda ()
                               (setq disposed t)
                               (cancel-all))))))
         (load-list (tab cat-id cat-path query)
           (let ((endpoint (etaf-web-discourse--endpoint-for-list
                            origin tab cat-id cat-path query 0)))
             (when (and on-stage (not ready-sent))
               (funcall on-stage 'adapter "Discourse" 0.65))
             (track
              (etaf-web-discourse--fetch-json-async
               endpoint
               (lambda (data err)
                 (unless disposed
                   (if err
                       (if ready-sent
                           (message "%s" (or (plist-get err :message) "加载失败"))
                         (funcall on-error err))
                     (let ((parsed (etaf-web-discourse--parse-list-payload
                                    data origin (plist-get st :by-id))))
                       (etaf-batch
                         (etaf-set-value (plist-get st :tab) tab)
                         (etaf-set-value (plist-get st :category-id) cat-id)
                         (etaf-set-value (plist-get st :active-search) (or query ""))
                         (etaf-set-value (plist-get st :topics) (plist-get parsed :topics))
                         (etaf-set-value (plist-get st :more-url) (plist-get parsed :more-url))
                         (etaf-set-value (plist-get st :selected) 0)
                         (etaf-set-value (plist-get st :page-num) 1)
                         (etaf-set-value (plist-get st :loading-more) nil))
                       (plist-put st :category-path cat-path)
                       (commit-ready)))))))))
         (load-more ()
           (let ((more (etaf-value (plist-get st :more-url))))
             (when (and more (not (etaf-value (plist-get st :loading-more))))
               (etaf-set-value (plist-get st :loading-more) t)
               (track
                (etaf-web-discourse--fetch-json-async
                 (etaf-web-discourse--more-json-url origin more)
                 (lambda (data err)
                   (unless disposed
                     (etaf-set-value (plist-get st :loading-more) nil)
                     (if err
                         (message "加载更多失败：%s" (or (plist-get err :message) ""))
                       (let* ((parsed (etaf-web-discourse--parse-list-payload
                                       data origin (plist-get st :by-id)))
                              (cur (etaf-value (plist-get st :topics)))
                              (seen (make-hash-table :test #'eql))
                              (merged nil))
                         (dolist (tp cur)
                           (puthash (plist-get tp :id) t seen)
                           (push tp merged))
                         (dolist (tp (plist-get parsed :topics))
                           (unless (gethash (plist-get tp :id) seen)
                             (puthash (plist-get tp :id) t seen)
                             (push tp merged)))
                         (etaf-batch
                           (etaf-set-value (plist-get st :topics) (nreverse merged))
                           (etaf-set-value (plist-get st :more-url) (plist-get parsed :more-url))
                           (etaf-set-value (plist-get st :page-num)
                                           (1+ (or (etaf-value (plist-get st :page-num)) 1))))))))))))))
      (plist-put st :on-tab
                 (lambda (next-tab)
                   (if (eq next-tab 'categories)
                       (etaf-set-value (plist-get st :tab) 'categories)
                     (load-list next-tab nil nil ""))))
      (plist-put st :on-category
                 (lambda (cid slug)
                   (load-list 'latest cid slug "")))
      (plist-put st :on-search
                 (lambda (text)
                   (let ((q (string-trim (or text ""))))
                     (etaf-set-value (plist-get st :query-ref) q)
                     (load-list (etaf-value (plist-get st :tab))
                                (if (string-empty-p q) (etaf-value (plist-get st :category-id)) nil)
                                (if (string-empty-p q) (plist-get st :category-path) nil)
                                q))))
      (plist-put st :on-more #'load-more)
      (plist-put st :select-delta #'select-delta)
      ;; Kick off categories + initial list in parallel.
      (track
       (etaf-web-discourse--ensure-categories
        origin
        (lambda (centry)
          (unless disposed
            (plist-put st :by-id (plist-get centry :by-id))
            (etaf-set-value (plist-get st :categories) (plist-get centry :categories))
            (if (eq init-tab 'categories)
                (commit-ready)
              (load-list init-tab init-cat-id init-cat-path init-search)))))))
    (lambda ()
      (setq disposed t)
      (dolist (fn cancels) (ignore-errors (funcall fn)))
      (setq cancels nil))))

(defun etaf-web-discourse--open-thread (ctx route)
  "Open a Discourse thread view for CTX and ROUTE; return canceller."
  (let* ((origin (plist-get route :origin))
         (topic-id (plist-get route :topic-id))
         (url (plist-get ctx :url))
         (buf (plist-get ctx :buffer))
         (page-dir (etaf-web--page-dir url))
         (navigate (plist-get ctx :navigate))
         (open-external (plist-get ctx :open-external))
         (open-link (plist-get ctx :open-link))
         (on-stage (plist-get ctx :on-stage))
         (on-ready (plist-get ctx :on-ready))
         (on-error (plist-get ctx :on-error))
         (cancels nil)
         (disposed nil)
         (measure-ref (etaf-ref 86 :name 'discourse-thread-measure))
         (media-rev (etaf-ref 0 :name 'discourse-media-rev))
         (st (list :origin origin
                   :url url
                   :page-dir page-dir
                   :topic-id topic-id
                   :navigate navigate
                   :open-external open-external
                   :open-link open-link
                   :measure-ref measure-ref
                   :media-rev media-rev
                   :posts (etaf-ref nil :name 'discourse-posts)
                   :remaining (etaf-ref 0 :name 'discourse-remaining)
                   :loading-more (etaf-ref nil :name 'discourse-thread-more)
                   :stream-ids nil
                   :loaded-ids (make-hash-table :test #'eql))))
    (cl-labels
        ((track (c) (when (functionp c) (push c cancels)))
         (cancel-all ()
           (dolist (fn cancels) (ignore-errors (funcall fn)))
           (setq cancels nil))
         (download-post-images (entries)
           (let ((urls (cl-loop for en in entries
                                append (plist-get en :image-urls))))
             (when (and urls etaf-web-download-images)
               (track
                (etaf-web--download-images-async
                 page-dir urls
                 (lambda ()
                   (unless disposed
                     (etaf-set-value media-rev (1+ (or (etaf-value media-rev) 0)))
                     (when-let* ((rt (and (buffer-live-p buf)
                                          (etaf-runtime-for-buffer buf))))
                       (ignore-errors (etaf-runtime-flush rt)))))
                 url)))))
         (missing-ids ()
           (let ((loaded (plist-get st :loaded-ids)))
             (cl-remove-if (lambda (id) (gethash id loaded))
                           (plist-get st :stream-ids))))
         (load-more-posts ()
           (let ((todo (seq-take (missing-ids) 20)))
             (when (and todo (not (etaf-value (plist-get st :loading-more))))
               (etaf-set-value (plist-get st :loading-more) t)
               (let ((qs (mapconcat (lambda (id) (format "post_ids[]=%d" id))
                                    todo "&")))
                 (track
                  (etaf-web-discourse--fetch-json-async
                   (format "%s/t/%d/posts.json?%s" origin topic-id qs)
                   (lambda (data err)
                     (unless disposed
                       (etaf-set-value (plist-get st :loading-more) nil)
                       (if err
                           (message "加载后续楼层失败：%s"
                                    (or (plist-get err :message) ""))
                         (let* ((raw (alist-get 'posts (alist-get 'post_stream data)))
                                (loaded (plist-get st :loaded-ids))
                                (rewriter (etaf-web--make-local-image-rewriter page-dir))
                                (added
                                 (when (vectorp raw)
                                   (cl-loop for p across raw
                                            for pid = (alist-get 'id p)
                                            unless (gethash pid loaded)
                                            do (puthash pid t loaded)
                                            and collect (etaf-web-discourse--compile-post-entry
                                                         p origin rewriter))))
                                (all (append (etaf-value (plist-get st :posts)) added)))
                           (etaf-batch
                             (etaf-set-value (plist-get st :posts) all)
                             (etaf-set-value (plist-get st :remaining)
                                             (length (missing-ids))))
                           (download-post-images added))))))))))))
      (plist-put st :on-more #'load-more-posts)
      (when on-stage (funcall on-stage 'adapter "Discourse" 0.60))
      (track
       (etaf-web-discourse--ensure-categories
        origin
        (lambda (centry)
          (unless disposed
            (track
             (etaf-web-discourse--fetch-json-async
              (format "%s/t/%d.json" origin topic-id)
              (lambda (data err)
                (unless disposed
                  (if err
                      (funcall on-error err)
                    (let* ((title (or (alist-get 'title data) "话题"))
                           (cat-id (alist-get 'category_id data))
                           (by-id (plist-get centry :by-id))
                           (cat (and by-id cat-id (gethash cat-id by-id)))
                           (cat-name (and cat (alist-get 'name cat)))
                           (cat-slug (and cat (alist-get 'slug cat)))
                           (cat-url (and cat-id cat-slug
                                         (format "%s/c/%s/%d" origin cat-slug cat-id)))
                           (tags (etaf-web-discourse--normalize-tags
                                  (alist-get 'tags data)))
                           (ps (alist-get 'post_stream data))
                           (raw-stream (alist-get 'stream ps))
                           (stream-ids (if (vectorp raw-stream) (append raw-stream nil) nil))
                           (raw-posts (alist-get 'posts ps))
                           (loaded (plist-get st :loaded-ids))
                           (rewriter (etaf-web--make-local-image-rewriter page-dir))
                           (entries
                            (when (vectorp raw-posts)
                              (cl-loop for p across raw-posts
                                       for pid = (alist-get 'id p)
                                       do (puthash pid t loaded)
                                       collect (etaf-web-discourse--compile-post-entry
                                                p origin rewriter)))))
                      (plist-put st :title title)
                      (plist-put st :category-name cat-name)
                      (plist-put st :category-url cat-url)
                      (plist-put st :tags tags)
                      (plist-put st :created
                                 (let ((c (alist-get 'created_at data)))
                                   (if (and (stringp c) (>= (length c) 10))
                                       (substring c 0 10)
                                     "")))
                      (plist-put st :views (or (alist-get 'views data) 0))
                      (plist-put st :posts-count (or (alist-get 'posts_count data)
                                                     (length entries)))
                      (plist-put st :stream-ids stream-ids)
                      (etaf-batch
                        (etaf-set-value (plist-get st :posts) entries)
                        (etaf-set-value (plist-get st :remaining) (length (missing-ids))))
                      (download-post-images entries)
                      (funcall
                       on-ready
                       (list :title title
                             :mode-label "Discourse"
                             :render (lambda (rctx)
                                       (etaf-web-discourse--render-thread-view st rctx))
                             :keys (list (list "u"
                                               (lambda ()
                                                 (interactive)
                                                 (funcall navigate (concat origin "/")))
                                               "返回话题列表"))
                             :on-width (lambda (delta)
                                         (let* ((cur (or (etaf-value measure-ref) 92))
                                                (next (max 56 (min 120 (+ cur delta)))))
                                           (etaf-set-value measure-ref next)
                                           next))
                             :on-headings
                             (lambda (buf)
                               (when (buffer-live-p buf)
                                 (with-current-buffer buf
                                   (save-excursion
                                     (goto-char (point-min))
                                     (cl-loop for en in (etaf-value (plist-get st :posts))
                                              for idx from 0
                                              for tag = (format "#%d" (plist-get en :number))
                                              for pos = (when (search-forward tag nil t)
                                                          (line-beginning-position))
                                              when pos
                                              collect (list idx
                                                            (format "%s @%s" tag
                                                                    (plist-get en :username))
                                                            pos))))))
                             :dispose (lambda ()
                                        (setq disposed t)
                                        (cancel-all)))))))))))))))
    (lambda ()
      (setq disposed t)
      (dolist (fn cancels) (ignore-errors (funcall fn)))
      (setq cancels nil))))

(defun etaf-web-discourse--open (ctx)
  "Entry point for Discourse Tier 2 adapter given load context CTX."
  (let ((route (etaf-web-discourse--parse-route (plist-get ctx :url))))
    (pcase (plist-get route :kind)
      ('list (etaf-web-discourse--open-list ctx route))
      ('thread (etaf-web-discourse--open-thread ctx route))
      (_ 'fallback))))

(etaf-web-register-adapter
 :name 'discourse
 :label "Discourse"
 :priority 40
 :match-url #'etaf-web-discourse--match-url-p
 :match-html #'etaf-web-discourse--match-html-p
 :open #'etaf-web-discourse--open)

(provide 'etaf-web-adapter-discourse)
;;; etaf-web-adapter-discourse.el ends here
