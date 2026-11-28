;;; etaf-rss-parse.el --- Feed, OPML and article text for etaf-rss -*- lexical-binding: t; -*-

;; Copyright (C) 2026 ETAF contributors
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; Everything the reader does to foreign text lives here: RSS 2.0, Atom and
;; JSON Feed documents become one article shape, OPML documents become feed
;; lists, article HTML becomes the blocks the reading pane paints, and blocks
;; become display lines of a given width.  All of it is pure: no buffer, no
;; network, no file, so every function is independently testable and the
;; service and model layers stay free of format knowledge.
;;
;; Article shape, used by every layer:
;;
;;   (:id :title :url :author :published :summary :content)
;;
;; ID is stable across refreshes of the same feed, TITLE and SUMMARY are plain
;; text, CONTENT is the article's own HTML (possibly empty), and PUBLISHED is
;; a float time or nil.  Blocks returned by `etaf-rss-render-html' are plists
;; (:kind :text) with KIND one of `heading', `para', `quote', `item', `code',
;; `row', `link' or `separator'; `etaf-rss-wrap-blocks' turns them into one
;; `:key'/`:text'/`:kind' per display line.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'json)
(require 'url)
(require 'url-parse)
(require 'etaf-rss-theme)

(defconst etaf-rss--skip-tags
  '(script style head noscript iframe svg form input button select textarea
    video audio canvas template nav footer header)
  "HTML elements whose text never reaches the reading pane.
Navigation and chrome would only add noise to a story, and a script's source
must never be painted.")

(defconst etaf-rss--block-tags
  '(p div section article main figure figcaption blockquote li ul ol dl dt dd
    h1 h2 h3 h4 h5 h6 pre table tr hr aside details summary)
  "HTML elements that separate the text around them into blocks.")

(defconst etaf-rss--link-limit 30
  "Most links collected from one article.
A link list is a reading aid, not an archive; beyond this the article body
itself carries the rest.")

(defconst etaf-rss--max-content 200000
  "Largest article HTML kept in characters.
Feeds sometimes ship a whole page in `content:encoded'; the cap keeps one
such item from growing the store without bound.")

;;; ---------------------------------------------------------------------------
;;; XML and node helpers
;;; ---------------------------------------------------------------------------

(defun etaf-rss--parse-xml (text)
  "Parse TEXT as XML and return its tree, or nil when it is not XML.
The parse runs in a temporary buffer; malformed documents return nil instead
of signalling, because a caller decides whether that means autodiscovery."
  (condition-case nil
      (with-temp-buffer
        (insert text)
        (libxml-parse-xml-region (point-min) (point-max)))
    (error nil)))

(defun etaf-rss--children (node)
  "Return NODE's children, or nil when it is not an element."
  (and (consp node) (cddr node)))

(defun etaf-rss--find (node name)
  "Return the first child of NODE whose tag is NAME."
  (seq-find (lambda (child) (and (consp child) (eq (car child) name)))
            (etaf-rss--children node)))

(defun etaf-rss--find-all (node name)
  "Return every child of NODE whose tag is NAME."
  (seq-filter (lambda (child) (and (consp child) (eq (car child) name)))
              (etaf-rss--children node)))

(defun etaf-rss--attr (node name)
  "Return attribute NAME of NODE as a string, or nil."
  (let ((pair (assq name (cadr node))))
    (and pair (format "%s" (cdr pair)))))

(defun etaf-rss--texts (node)
  "Concatenate the text of NODE and all of its descendants."
  (cond ((stringp node) node)
        ((consp node) (mapconcat #'etaf-rss--texts (etaf-rss--children node) ""))
        (t "")))

(defun etaf-rss--child-text (node name)
  "Return the concatenated text of NODE's NAME child, or nil when absent."
  (let ((child (etaf-rss--find node name)))
    (when child
      (string-trim (etaf-rss--texts child)))))

(defun etaf-rss--blank (value)
  "Return VALUE as a trimmed string, or an empty string."
  (cond ((null value) "")
        ((numberp value) (number-to-string value))
        ((stringp value) (string-trim value))
        (t "")))

(defun etaf-rss--alias (node names)
  "Return the text of the first child of NODE tagged with any of NAMES."
  (seq-some (lambda (name) (etaf-rss--child-text node name)) names))

;;; ---------------------------------------------------------------------------
;;; Feed parsing
;;; ---------------------------------------------------------------------------

(defun etaf-rss-parse-feed (text &optional url)
  "Parse feed document TEXT and return (:title :site :description :articles).
RSS 2.0, RSS 1.0 (RDF), Atom and JSON Feed are supported; URL names the
document and is only used to resolve an article identity when the feed has
none.  A document that is none of these signals `etaf-rss-error'.

Each article is (:id :title :url :author :published :summary :content) as
documented in the Commentary.  The call is pure: it reads no file and does no
network, so callers parse stored text as well as fresh replies."
  (let* ((text (string-trim (string-remove-prefix "\uFEFF" (or text "")))))
    (cond
     ((string-empty-p text)
      (signal 'etaf-rss-error '("订阅内容为空")))
     ((or (string-prefix-p "{" text) (string-prefix-p "[" text))
      (etaf-rss--parse-json-feed text url))
     (t
      (let ((tree (etaf-rss--parse-xml text)))
        (unless tree
          (signal 'etaf-rss-error '("无法解析的订阅格式（不是 XML 或 JSON）")))
        (pcase (car tree)
          ('rss (etaf-rss--parse-rss (etaf-rss--find tree 'channel) url))
          ('RDF (etaf-rss--parse-rdf tree url))
          ('feed (etaf-rss--parse-atom tree url))
          (tag (signal 'etaf-rss-error
                       (list (format "无法识别的订阅根元素：%s" tag))))))))))

(defun etaf-rss--parse-rss (channel url)
  "Parse RSS CHANNEL into the feed shape; URL names the document."
  (unless channel
    (signal 'etaf-rss-error '("RSS 文档缺少 channel 元素")))
  (let* ((site (or (etaf-rss--child-text channel 'link) ""))
         (title (or (etaf-rss--child-text channel 'title) ""))
         (articles (mapcar (lambda (item)
                             (etaf-rss--article
                              :feed-url url
                              :identity (or (etaf-rss--child-text item 'guid)
                                            (etaf-rss--child-text item 'link)
                                            (etaf-rss--child-text item 'title))
                              :title (or (etaf-rss--child-text item 'title) "")
                              :url (or (etaf-rss--child-text item 'link) "")
                              :author (or (etaf-rss--alias item '(creator author)) "")
                              :published (etaf-rss-parse-time
                                          (or (etaf-rss--child-text item 'pubDate)
                                              (etaf-rss--child-text item 'date)))
                              :summary-html (or (etaf-rss--child-text item 'description) "")
                              :content-html (or (etaf-rss--child-text item 'encoded) "")))
                           (etaf-rss--find-all channel 'item))))
    (list :title (if (string-empty-p title) (etaf-rss--host-title url) title)
          :site site
          :description (or (etaf-rss--child-text channel 'description) "")
          :articles articles)))

(defun etaf-rss--parse-rdf (tree url)
  "Parse an RSS 1.0 (RDF) document TREE; URL names the document."
  (let ((channel (etaf-rss--find tree 'channel)))
    (etaf-rss--parse-rss
     (if channel channel tree)
     url)))

(defun etaf-rss--parse-atom (feed url)
  "Parse an Atom FEED into the feed shape; URL names the document."
  (let* ((site (or (etaf-rss--atom-link feed) ""))
         (title (or (etaf-rss--child-text feed 'title) ""))
         (articles
          (mapcar
           (lambda (entry)
             (let* ((identity (or (etaf-rss--child-text entry 'id)
                                  (etaf-rss--atom-link entry)
                                  (etaf-rss--child-text entry 'title)))
                    (summary-html (or (etaf-rss--child-text entry 'summary) ""))
                    (content (etaf-rss--find entry 'content)))
               (etaf-rss--article
                :feed-url url
                :identity identity
                :title (or (etaf-rss--child-text entry 'title) "")
                :url (or (etaf-rss--atom-link entry) "")
                :author (or (etaf-rss--child-text
                             (or (etaf-rss--find entry 'author) entry) 'name) "")
                :published (etaf-rss-parse-time
                            (or (etaf-rss--child-text entry 'published)
                                (etaf-rss--child-text entry 'updated)))
                :summary-html summary-html
                :content-html (cond (content (etaf-rss--texts content))
                                    (t summary-html)))))
           (etaf-rss--find-all feed 'entry))))
    (list :title (if (string-empty-p title) (etaf-rss--host-title url) title)
          :site site
          :description (or (etaf-rss--child-text feed 'subtitle) "")
          :articles articles)))

(defun etaf-rss--atom-link (node)
  "Return NODE's alternate link URL, or its first link URL."
  (let* ((links (etaf-rss--find-all node 'link))
         (alternate (seq-find (lambda (link)
                                (member (etaf-rss--attr link 'rel) '(nil "alternate")))
                              links)))
    (or (and alternate (etaf-rss--attr alternate 'href))
        (and (car links) (etaf-rss--attr (car links) 'href)))))

(defun etaf-rss--parse-json-feed (text url)
  "Parse JSON Feed TEXT into the feed shape; URL names the document.
TEXT may be a single feed or an array of feeds; the first one is used."
  (let* ((data (condition-case nil
                   (json-parse-string text :object-type 'alist
                                      :false-object :false :null-object nil)
                 (error (signal 'etaf-rss-error '("无法解析的 JSON 订阅")))))
         (data (if (vectorp data) (aref data 0) data)))
    (unless (listp data)
      (signal 'etaf-rss-error '("JSON 订阅不是对象")))
    (let ((items (or (alist-get 'items data) []))
          (title (etaf-rss--blank (alist-get 'title data))))
      (list :title (if (string-empty-p title) (etaf-rss--host-title url) title)
            :site (etaf-rss--blank (alist-get 'home_page_url data))
            :description (etaf-rss--blank (alist-get 'description data))
            :articles
            (mapcar
             (lambda (item)
               (let* ((authors (alist-get 'authors item))
                      (author (or (etaf-rss--blank
                                   (alist-get 'name (alist-get 'author item)))
                                  (and (vectorp authors) (> (length authors) 0)
                                       (etaf-rss--blank
                                        (alist-get 'name (aref authors 0))))
                                  ""))
                      (content-html (etaf-rss--blank (alist-get 'content_html item)))
                      (content-text (etaf-rss--blank (alist-get 'content_text item))))
                 (etaf-rss--article
                  :feed-url url
                  :identity (or (etaf-rss--blank (alist-get 'id item))
                                (etaf-rss--blank (alist-get 'url item))
                                (etaf-rss--blank (alist-get 'title item)))
                  :title (etaf-rss--blank (alist-get 'title item))
                  :url (or (etaf-rss--blank (alist-get 'url item))
                           (etaf-rss--blank (alist-get 'external_url item)))
                  :author author
                  :published (etaf-rss-parse-time
                              (or (alist-get 'date_published item)
                                  (alist-get 'date_modified item)))
                  :summary-html (or (etaf-rss--blank (alist-get 'summary item))
                                    content-text)
                  :content-html (if (string-empty-p content-html)
                                    content-text
                                  content-html))))
             (append items nil))))))

(defun etaf-rss--article (&rest values)
  "Build one article record from VALUES, filling the shape's defaults.
`:summary-html' and `:content-html' are rendered to plain text and HTML; the
result is the documented (:id :title :url :author :published :summary
:content) placeholder."
  (let* ((identity (or (etaf-rss--blank (plist-get values :identity)) ""))
         (feed-url (or (plist-get values :feed-url) ""))
         (summary-html (or (plist-get values :summary-html) ""))
         (content-html (or (plist-get values :content-html) ""))
         (content (if (string-empty-p content-html) summary-html content-html))
         (summary-text (string-trim (etaf-rss-plain-text summary-html))))
    (list :id (etaf-rss-article-id feed-url identity)
          :title (string-trim (etaf-rss--blank (plist-get values :title)))
          :url (etaf-rss--blank (plist-get values :url))
          :author (string-trim (etaf-rss--blank (plist-get values :author)))
          :published (plist-get values :published)
          :summary (etaf-rss--clip
                    (if (string-empty-p summary-text)
                        (etaf-rss-plain-text content)
                      summary-text)
                    400)
          :content (substring content 0 (min (length content)
                                             etaf-rss--max-content)))))

(defun etaf-rss-article-id (feed-url identity)
  "Return the stable article ID of IDENTITY in FEED-URL.
The pair is hashed, so the same item keeps its ID across refreshes and its
read and starred state survives."
  (sha1 (format "%s\n%s" (or feed-url "") (or identity ""))))

(defun etaf-rss--host-title (url)
  "Return a readable title derived from URL, for a feed that has none."
  (if (or (null url) (string-empty-p url))
      "未命名订阅"
    (let* ((host (url-host (url-generic-parse-url url))))
      (or host url))))

(defun etaf-rss-html-title (html)
  "Return the <title> of an HTML document, trimmed, or nil.
Used when autodiscovery reads a site page to find its feed."
  (when (and html (string-match-p "<\\s-*[Tt][Ii][Tt][Ll][Ee]" html))
    (when (string-match
           "<\\s-*[Tt][Ii][Tt][Ll][Ee][^>]*>\\([^<]*\\)</\\s-*[Tt][Ii][Tt][Ll][Ee]\\s-*>" html)
      (let ((title (string-trim (replace-regexp-in-string
                                 "\\s-+" " " (match-string 1 html)))))
        (unless (string-empty-p title) title)))))

(defun etaf-rss-html-feed-links (html &optional base-url)
  "Return feed URLs advertised by an HTML page.
The document is scanned for `<link rel=\\\"alternate\\\">' elements whose
type names RSS, Atom or JSON Feed (and for a bare `application/atom+xml' or
`application/rss+xml' href).  Relative hrefs resolve against BASE-URL; the
order of the document is kept and duplicates are dropped."
  (let ((urls nil)
        (point 0)
        (case-fold-search t))
    (while (string-match
            "<\\s-*[Ll][Ii][Nn][Kk]\\s-+\\([^>]*\\)>" html point)
      (setq point (match-end 0))
      (let* ((attributes (match-string 1 html))
             (href (and (string-match "\\(?:^\\|\\s-\\)[Hh][Rr][Ee][Ff]\\s-*=\\s-*\\(\"[^\"]*\"\\|'[^']*'\\|[^ \t>]+\\)"
                                      attributes)
                        (string-trim (string-trim (match-string 1 attributes)
                                                  "\"" "\"")
                                     "'" "'")))
             (rel (and (string-match "\\(?:^\\|\\s-\\)[Rr][Ee][Ll]\\s-*=\\s-*\\(\"[^\"]*\"\\|'[^']*'\\)"
                                     attributes)
                       (downcase (string-trim (match-string 1 attributes) "\"" "\""))))
             (type (and (string-match "\\(?:^\\|\\s-\\)[Tt][Yy][Pp][Ee]\\s-*=\\s-*\\(\"[^\"]*\"\\|'[^']*'\\)"
                                      attributes)
                        (downcase (string-trim (match-string 1 attributes) "\"" "\"")))))
        (when (and href
                   (or (string-empty-p (or rel ""))
                       (string-match-p "alternate" rel))
                   (string-match-p "\\(rss\\|atom\\|json\\)" (or type "")))
          (push (if (string-match-p "\\`https?://" href)
                    href
                  (and base-url (url-expand-file-name href base-url)))
                urls))))
    (delete-dups (delq nil (nreverse urls)))))

;;; ---------------------------------------------------------------------------
;;; OPML
;;; ---------------------------------------------------------------------------

(defun etaf-rss-parse-opml (text)
  "Parse OPML document TEXT and return its subscriptions.
Each entry is (:title :url :folder); FOLDER is the name of the nearest
enclosing outline without an `xmlUrl', or \"\" at the top level.  Outlines
that advertise a feed but are themselves folders are also walked."
  (let ((tree (etaf-rss--parse-xml text)))
    (unless (and tree (eq (car tree) 'opml))
      (signal 'etaf-rss-error '("不是有效的 OPML 文件")))
    (let ((entries nil))
      (cl-labels ((walk (node folder)
                    (dolist (child (etaf-rss--children node))
                      (when (consp child)
                        (if (eq (car child) 'outline)
                            (let* ((url (or (etaf-rss--attr child 'xmlUrl)
                                            (etaf-rss--attr child 'xmlurl)))
                                   (title (or (etaf-rss--attr child 'title)
                                              (etaf-rss--attr child 'text)
                                              "")))
                              (if (and url (not (string-empty-p url)))
                                  (push (list :title (string-trim title)
                                              :url (string-trim url)
                                              :folder folder)
                                        entries)
                                (walk child (if (string-empty-p (string-trim title))
                                                folder
                                              (string-trim title)))))
                          (walk child folder))))))
        (walk tree ""))
      (nreverse entries))))

;;; ---------------------------------------------------------------------------
;;; Times and text
;;; ---------------------------------------------------------------------------

(defun etaf-rss-parse-time (value)
  "Return VALUE as a float time, or nil when it carries no date.
RFC 822 (`Mon, 02 Oct 2023 15:04:05 GMT'), ISO 8601 and plain
`YYYY-MM-DD[ HH:MM[:SS]]' are accepted; an unparseable value returns nil
instead of signalling, so one bad item never fails a whole feed."
  (cond
   ((numberp value) (float value))
   ((not (stringp value)) nil)
   ((string-empty-p (string-trim value)) nil)
   (t
    (let* ((text (string-trim value))
           (normalized (replace-regexp-in-string
                        "\\`\\([0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]\\)[Tt]"
                        "\\1 " text))
           (normalized (replace-regexp-in-string
                        "\\(Z\\|[+-][0-9][0-9]:?[0-9][0-9]\\)\\'" "" normalized)))
      (or (ignore-errors (float-time (date-to-time text)))
          (ignore-errors (float-time (encode-time (parse-time-string text))))
          (ignore-errors (float-time (encode-time (parse-time-string normalized))))
          (ignore-errors (float-time (date-to-time normalized))))))))

(defun etaf-rss-format-time (time)
  "Return TIME as a sortable `YYYY-MM-DD HH:MM' string, or an empty string."
  (if (null time)
      ""
    (format-time-string "%Y-%m-%d %H:%M" (seconds-to-time time))))

(defun etaf-rss-relative-time (time &optional now)
  "Return TIME as a short relative string against NOW (default the clock).
`刚刚', `N 分钟前', `N 小时前', `昨天 HH:MM', `N 天前' and finally
`YYYY-MM-DD' are used, so a list row stays narrow and still informative."
  (if (null time)
      ""
    (let* ((now (or now (float-time)))
           (seconds (max 0 (- now time))))
      (cond
       ((< seconds 90) "刚刚")
       ((< seconds 3600) (format "%d 分钟前" (max 1 (round (/ seconds 60.0)))))
       ((< seconds 86400) (format "%d 小时前" (max 1 (round (/ seconds 3600.0)))))
       ((< seconds (* 2 86400)) (format "昨天 %s" (format-time-string "%H:%M" (seconds-to-time time))))
       ((< seconds (* 7 86400)) (format "%d 天前" (floor (/ seconds 86400))))
       ((equal (format-time-string "%Y" (seconds-to-time time))
               (format-time-string "%Y" (seconds-to-time now)))
        (format-time-string "%m-%d" (seconds-to-time time)))
       (t (format-time-string "%Y-%m-%d" (seconds-to-time time)))))))

(defun etaf-rss--clip (text width)
  "Return TEXT clipped to WIDTH columns with an ellipsis when it was cut."
  (let ((text (or text "")))
    (if (string-empty-p text)
        ""
      (truncate-string-to-width text width nil nil "…"))))

(defun etaf-rss--collapse-space (text)
  "Return TEXT with every whitespace run collapsed to one space."
  (string-trim (replace-regexp-in-string "[ \t\r\n\f]+" " " (or text ""))))

;;; ---------------------------------------------------------------------------
;;; HTML to blocks
;;; ---------------------------------------------------------------------------

(defun etaf-rss--html-tree (html)
  "Parse HTML and return its tree, or nil when it cannot be parsed."
  (condition-case nil
      (with-temp-buffer
        (insert (or html ""))
        (libxml-parse-html-region (point-min) (point-max)))
    (error nil)))

(defun etaf-rss-render-html (html)
  "Render article HTML into reading blocks.
The result is a list of (:kind :text) plists; link blocks carry :url as well.
Block kinds are `heading', `para', `quote', `item', `code', `row', `link' and
`separator'.  Scripts, styles and site chrome are dropped; images become a
short `[图]' marker; links keep their text in place and are collected at the
end under a headings-`链接' section (at most `etaf-rss--link-limit').
Plain text that is not HTML is returned as one paragraph."
  (let ((tree (etaf-rss--html-tree (or html ""))))
    (if (null tree)
        (let ((text (etaf-rss--collapse-space (or html ""))))
          (if (string-empty-p text) nil (list (list :kind 'para :text text))))
      (let ((blocks nil) (inline nil) (links nil))
        (cl-labels
            ((flush (&optional kind)
               (let ((text (etaf-rss--collapse-space (apply #'concat (nreverse inline)))))
                 (setq inline nil)
                 (unless (string-empty-p text)
                   (push (list :kind (or kind 'para) :text text) blocks))))
             (raw-text (node)
               ;; Preformatted content keeps its own line structure.
               (cond ((stringp node) node)
                     ((consp node)
                      (mapconcat #'raw-text (etaf-rss--children node) "\n"))
                     (t "")))
             (walk-children (node)
               (dolist (child (etaf-rss--children node))
                 (walk child)))
             (walk (node)
               (cond
                ((stringp node)
                 (push node inline))
                ((consp node)
                 (let ((tag (car node)))
                   (cond
                    ((memq tag etaf-rss--skip-tags) nil)
                    ((eq tag 'br) (push "\n" inline))
                    ((eq tag 'hr)
                     (flush)
                     (push (list :kind 'separator :text "") blocks))
                    ((eq tag 'img)
                     (let ((alt (etaf-rss--attr node 'alt)))
                       (push (if (and alt (not (string-empty-p alt)))
                                 (format "[图：%s]" alt)
                               "[图]")
                             inline)))
                    ((eq tag 'pre)
                     (flush)
                     (let ((text (string-trim (raw-text node))))
                       (unless (string-empty-p text)
                         (push (list :kind 'code :text text) blocks))))
                    ((memq tag '(h1 h2 h3 h4 h5 h6))
                     (flush)
                     (walk-children node)
                     (flush 'heading))
                    ((eq tag 'blockquote)
                     (flush)
                     (walk-children node)
                     (flush 'quote))
                    ((eq tag 'li)
                     (flush)
                     (walk-children node)
                     (flush 'item))
                    ((eq tag 'tr)
                     (flush)
                     (dolist (cell (append (etaf-rss--find-all node 'td)
                                           (etaf-rss--find-all node 'th)))
                       (walk-children cell)
                       (push "  " inline))
                     (flush 'row))
                    ((eq tag 'a)
                     (let ((href (etaf-rss--attr node 'href))
                           (text (etaf-rss--collapse-space (etaf-rss--texts node))))
                       (when (and href (not (string-empty-p text))
                                  (string-match-p "\\`\\(https?\\|mailto\\):" href))
                         (let ((pair (assoc href links)))
                           (if pair
                               (unless (member text (cdr pair))
                                 (setcdr pair (append (cdr pair) (list text))))
                             (push (cons href (list text)) links))))
                       (walk-children node)))
                    ((memq tag '(p div section article main figure figcaption aside
                                 details summary))
                     (flush)
                     (walk-children node)
                     (flush 'para))
                    (t (walk-children node))))))))
          (walk tree)
          (flush)
          (let ((links (seq-take (nreverse links) etaf-rss--link-limit)))
            (when links
              (push (list :kind 'separator :text "") blocks)
              (push (list :kind 'heading :text "链接") blocks)
              (dolist (pair links)
                (push (list :kind 'link
                            :text (string-join (cdr pair) " · ")
                            :url (car pair))
                      blocks))))
          (nreverse blocks))))))

(defun etaf-rss-plain-text (html)
  "Return HTML as one plain-text string, or an empty string."
  (if (or (null html) (string-empty-p html))
      ""
    (string-join
     (delq nil
           (mapcar (lambda (block)
                     (let ((text (string-trim (or (plist-get block :text) ""))))
                       (unless (string-empty-p text) text)))
                   (etaf-rss-render-html html)))
     " ")))

;;; ---------------------------------------------------------------------------
;;; Wrapping
;;; ---------------------------------------------------------------------------

(defun etaf-rss--wrap-segment (text columns)
  "Wrap one newline-free TEXT into lines of at most COLUMNS columns.
A space is a break opportunity; a token wider than the whole line is broken
between characters, so CJK text and long URLs never clip."
  (let ((columns (max 4 columns))
        (length (length text))
        (start 0)
        (index 0)
        (width 0)
        (last-space nil)
        (lines nil))
    (while (< index length)
      (let* ((char (aref text index))
             (char-width (char-width char)))
        (when (memq char '(?\s ?\t))
          (setq last-space index))
        (when (and (> (+ width char-width) columns)
                   (> index start))
          (let ((break (and last-space
                            (> last-space start)
                            (<= last-space index)
                            last-space)))
            (if break
                (progn
                  (push (substring text start break) lines)
                  (setq start (1+ break)
                        ;; 已经扫过的尾段属于新行，宽度要接上而不是归零，
                        ;; 否则新行会少算宽度、超出列宽。
                        width (string-width (substring text (1+ break) index))
                        last-space nil))
              (push (substring text start index) lines)
              (setq start index
                    width 0
                    last-space nil))))
        (unless (memq char '(?\s ?\t))
          (setq width (+ width char-width)))
        (setq index (1+ index))))
    (push (substring text start) lines)
    (nreverse lines)))

(defun etaf-rss-wrap-blocks (blocks columns)
  "Wrap reading BLOCKS into display lines of at most COLUMNS columns.
The result is a list of (:key :text :kind) plists with sequential keys; a
`blank' line separates consecutive blocks, headings get two, so prose reads
in paragraphs instead of one wall of text.  Item blocks are prefixed with a
dot; every other kind keeps its text.  The pane only slices this list, so a
large article wraps once and scrolling never measures text again."
  (let ((lines nil)
        (key 0)
        (previous nil)
        (columns (max 8 columns)))
    (cl-labels ((add (kind text)
                  (push (list :key (cl-incf key) :text text :kind kind) lines)))
      (dolist (block blocks)
        (let* ((kind (or (plist-get block :kind) 'para))
               (text (replace-regexp-in-string
                      "\t" "    " (string-trim (or (plist-get block :text) "")))))
          (unless (string-empty-p text)
            (let ((gap (cond ((null previous) 0)
                             ((or (eq kind 'heading) (eq previous 'heading)) 2)
                             (t 1))))
              (dotimes (_ gap) (add 'blank "")))
            (let* ((prefix (if (eq kind 'item) "· " ""))
                   (pieces (mapcan (lambda (segment)
                                     (etaf-rss--wrap-segment
                                      segment (max 4 (- columns (length prefix)))))
                                   (split-string text "\n")))
                   (first t))
              (dolist (piece pieces)
                (add kind (if first (concat prefix piece) piece))
                (setq first nil)))
            (setq previous kind))))
      ;; A trailing blank would waste the last row of the pane.
      (when (and lines (eq (plist-get (car lines) :kind) 'blank))
        (pop lines))
      (nreverse lines))))

(provide 'etaf-rss-parse)
;;; etaf-rss-parse.el ends here
