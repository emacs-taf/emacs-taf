;;; etaf-web-compile.el --- Pure HTML to etaf-md compiler -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; Pure HTML-to-`etaf-md' compiler built on Emacs's built-in libxml HTML
;; parser.  Performs zero network or filesystem I/O: takes an HTML string,
;; sanitizes unsafe elements/attributes/schemes, extracts document metadata and
;; primary content, and emits normalized YAML front matter, Markdown and `:::'
;; containers compatible with `etaf-md'.

;;; Code:

(require 'cl-lib)
(require 'dom)
(require 'subr-x)
(require 'url-expand)
(require 'url-parse)
(require 'url-vars)

(define-error 'etaf-web-error "ETAF Web error")

(defconst etaf-web--compiler-version "9"
  "Version tag folded into page cache keys.")

(defconst etaf-web--drop-tags
  '(script style noscript iframe object embed template svg)
  "HTML element tags discarded completely during sanitization.")

(defconst etaf-web--boilerplate-tags
  '(nav footer aside)
  "Landmark tags removed when pruning non-article chrome.")

(defconst etaf-web--boilerplate-roles
  '("navigation" "banner" "contentinfo" "complementary" "search")
  "ARIA roles removed when pruning non-article chrome.")

(defconst etaf-web--boilerplate-token-regexp
  (concat
   "\\`\\(?:"
   "nav\\|navbar\\|navigation\\|nav-panel\\|navpanel\\|node-nav\\|"
   "menu\\|menubar\\|breadcrumb\\|breadcrumbs\\|crumb\\|crumbs\\|"
   "footer\\|site-footer\\|page-footer\\|site-header\\|topbar\\|top-bar\\|"
   "sidebar\\|side-bar\\|aside\\|widget\\|widgets\\|"
   "comment\\|comments\\|comment-list\\|disqus\\|respond\\|"
   "share\\|sharing\\|social\\|social-share\\|share-buttons\\|"
   "ad\\|ads\\|advert\\|advertisement\\|banner\\|promo\\|sponsor\\|sponsored\\|"
   "subscribe\\|subscription\\|newsletter\\|signup\\|sign-up\\|"
   "related\\|related-posts\\|related-articles\\|recommended\\|recommend\\|"
   "cookie\\|cookie-banner\\|popup\\|modal\\|pagination\\|pager\\|"
   "toc\\|table-of-contents"
   "\\)\\'")
  "Class or id tokens identifying non-article page chrome.")

(defconst etaf-web--content-hint-regexp
  "\\`\\(?:article\\|post\\|entry\\|content\\|prose\\|markdown\\|story\\|main\\|doc\\|docs\\|wiki\\|body\\)\\'"
  "Class or id tokens suggesting primary article content.")

(defconst etaf-web--block-tags
  '(address article aside blockquote dd details div dl dt fieldset figcaption
    figure footer form h1 h2 h3 h4 h5 h6 header hgroup hr li main nav ol p pre
    section summary table tbody td tfoot th thead tr ul)
  "HTML tags treated as block-level elements.")

(defconst etaf-web--decodable-image-types
  '("image/png" "image/jpeg" "image/jpg" "image/gif" "image/webp" "image/bmp")
  "MIME types considered directly decodable in Emacs.")

(defconst etaf-web--decodable-image-exts
  '("png" "jpg" "jpeg" "gif" "webp" "bmp")
  "File extensions considered directly decodable in Emacs.")

;;; ---------------------------------------------------------------------------
;;; Pre-parse normalization & DOM helpers
;;; ---------------------------------------------------------------------------

(defun etaf-web--normalize-details-open ()
  "Rewrite bare boolean `open' attributes on `<details ...>' in current buffer.
Emacs's libxml HTML4 parser drops the HTML5 boolean `open' attribute unless it
carries an explicit value, so `<details open>' becomes `<details open=\"open\">'
while keeping quoted strings intact."
  (save-excursion
    (goto-char (point-min))
    (let ((case-fold-search t))
      (while (re-search-forward "<details\\b" nil t)
        (let ((pos (point))
              (in-quote nil)
              (done nil))
          (while (and (not done) (< pos (point-max)))
            (let ((ch (char-after pos)))
              (cond
               (in-quote
                (when (eq ch in-quote)
                  (setq in-quote nil))
                (setq pos (1+ pos)))
               ((memq ch '(?\" ?'))
                (setq in-quote ch
                      pos (1+ pos)))
               ((eq ch ?>)
                (setq done t))
               ((and (memq ch '(?\s ?\t ?\n ?\r))
                     (save-excursion
                       (goto-char pos)
                       (looking-at "\\([ \t\n\r]+open\\)[ \t\n\r/>]")))
                (goto-char (match-end 1))
                (insert "=\"open\"")
                (setq pos (point)))
               (t (setq pos (1+ pos)))))))))))

(defun etaf-web--parse-html (html)
  "Parse HTML string into a DOM tree using built-in libxml."
  (unless (stringp html)
    (signal 'etaf-web-error '("HTML input must be a string")))
  (unless (and (fboundp 'libxml-available-p) (libxml-available-p))
    (signal 'etaf-web-error '("Emacs was built without libxml HTML support")))
  (with-temp-buffer
    (insert html)
    (etaf-web--normalize-details-open)
    (libxml-parse-html-region (point-min) (point-max))))

(defun etaf-web--node-p (node)
  "Return non-nil when NODE is a DOM element cons `(TAG ATTRS . CHILDREN)'."
  (and (consp node) (symbolp (car node))))

(defun etaf-web--attr (node name)
  "Return string value of attribute NAME on DOM NODE, or nil."
  (when (etaf-web--node-p node)
    (let ((cell (assq name (dom-attributes node))))
      (when cell (or (cdr cell) "")))))

(defun etaf-web--class-tokens (node)
  "Return lowercased class and id tokens of DOM NODE."
  (when (etaf-web--node-p node)
    (let ((class (or (etaf-web--attr node 'class) ""))
          (id (or (etaf-web--attr node 'id) "")))
      (append (split-string (downcase class) "[ \t\n\r]+" t)
              (unless (string-empty-p id)
                (list (downcase (string-trim id))))))))

(defun etaf-web--class-list (node)
  "Return lowercased class list of DOM NODE."
  (when (etaf-web--node-p node)
    (split-string (downcase (or (etaf-web--attr node 'class) ""))
                  "[ \t\n\r]+" t)))

(defun etaf-web--collapse-ws (text)
  "Collapse ASCII whitespace runs in TEXT to single spaces."
  (replace-regexp-in-string "[ \t\n\r]+" " " (or text "")))

(defun etaf-web--plain-text (node)
  "Return normalized plain text inside DOM NODE."
  (cond
   ((stringp node) node)
   ((etaf-web--node-p node)
    (if (eq (dom-tag node) 'br)
        " "
      (mapconcat #'etaf-web--plain-text (dom-children node) "")))
   (t "")))

(defun etaf-web--clean-text (node)
  "Return trimmed, whitespace-collapsed plain text of DOM NODE."
  (string-trim (etaf-web--collapse-ws (etaf-web--plain-text node))))

;;; ---------------------------------------------------------------------------
;;; URL safety & resolution
;;; ---------------------------------------------------------------------------

(defun etaf-web--dangerous-url-p (url)
  "Return non-nil when URL uses a disallowed executable or HTML scheme."
  (when (stringp url)
    (let ((clean (downcase
                  (replace-regexp-in-string
                   "[\x00-\x20\x7f]+" "" url))))
      (or (string-prefix-p "javascript:" clean)
          (string-prefix-p "vbscript:" clean)
          (string-prefix-p "data:text/html" clean)
          (string-prefix-p "data:application/xhtml" clean)))))

(defun etaf-web--resolve-url (url base-url)
  "Resolve URL against BASE-URL, keeping `#anchor' and dropping unsafe URLs."
  (let ((trimmed (and (stringp url) (string-trim url))))
    (cond
     ((or (null trimmed) (string-empty-p trimmed)) nil)
     ((etaf-web--dangerous-url-p trimmed) nil)
     ((string-prefix-p "#" trimmed) trimmed)
     ((string-match-p "\\`[a-zA-Z][a-zA-Z0-9+.-]+:" trimmed) trimmed)
     ((and (stringp base-url) (not (string-empty-p (string-trim base-url))))
      (let ((url-show-status nil)
            (url-proxy-services nil))
        (url-expand-file-name trimmed base-url)))
     (t trimmed))))

;;; ---------------------------------------------------------------------------
;;; Sanitization
;;; ---------------------------------------------------------------------------

(defun etaf-web--sanitize-attrs (attrs)
  "Return ATTRS with event handlers (`on*') and dangerous URLs stripped."
  (let ((result nil))
    (dolist (pair attrs)
      (let* ((key (car pair))
             (name (downcase (symbol-name key)))
             (val (cdr pair)))
        (cond
         ((string-prefix-p "on" name) nil)
         ((and (member name '("href" "src" "srcset" "action" "formaction"))
               (stringp val)
               (etaf-web--dangerous-url-p val))
          nil)
         (t (push pair result)))))
    (nreverse result)))

(defun etaf-web--permalink-anchor-p (node)
  "Return non-nil when DOM NODE is a heading/section permalink marker."
  (when (and (etaf-web--node-p node) (eq (dom-tag node) 'a))
    (let* ((href (string-trim (or (etaf-web--attr node 'href) "")))
           (text (etaf-web--clean-text node))
           (classes (etaf-web--class-list node)))
      (and (string-prefix-p "#" href)
           (or (string-match-p "\\`[¶§#🔗]+\\'" text)
               (and (<= (length text) 4)
                    (cl-some (lambda (c)
                               (member c '("copiable-link" "headerlink"
                                           "header-anchor" "anchor-link"
                                           "permalink" "hash-link")))
                             classes)))))))

(defun etaf-web--sanitize-dom (node)
  "Return a sanitized copy of DOM NODE, or nil when NODE must be dropped."
  (cond
   ((stringp node) node)
   ((not (etaf-web--node-p node)) nil)
   (t
    (let ((tag (dom-tag node)))
      (cond
       ((memq tag etaf-web--drop-tags) nil)
       ((eq tag 'comment) nil)
       ((and (eq tag 'a)
             (etaf-web--dangerous-url-p (etaf-web--attr node 'href)))
        nil)
       ((etaf-web--permalink-anchor-p node) nil)
       (t
        (let ((attrs (etaf-web--sanitize-attrs (dom-attributes node)))
              (children (delq nil (mapcar #'etaf-web--sanitize-dom
                                          (dom-children node)))))
          (cons tag (cons attrs children)))))))))

;;; ---------------------------------------------------------------------------
;;; Front-matter metadata extraction
;;; ---------------------------------------------------------------------------

(defun etaf-web--find-first (node pred)
  "Return the first DOM element in NODE matching PRED, depth-first."
  (when (etaf-web--node-p node)
    (if (funcall pred node)
        node
      (cl-loop for child in (dom-children node)
               for found = (etaf-web--find-first child pred)
               when found return found))))

(defun etaf-web--find-all (node pred)
  "Return all DOM elements in NODE matching PRED in document order."
  (let ((acc nil))
    (cl-labels ((walk (n)
                  (when (etaf-web--node-p n)
                    (when (funcall pred n)
                      (push n acc))
                    (dolist (child (dom-children n))
                      (walk child)))))
      (walk node))
    (nreverse acc)))

(defun etaf-web--meta-content (dom attr-name values)
  "Return first non-empty `content' on `<meta>' whose ATTR-NAME is in VALUES."
  (let ((targets (mapcar #'downcase values)))
    (cl-loop for meta in (etaf-web--find-all
                          dom (lambda (n) (eq (dom-tag n) 'meta)))
             for key = (etaf-web--attr meta attr-name)
             for val = (etaf-web--attr meta 'content)
             when (and key val
                       (member (downcase (string-trim key)) targets)
                       (not (string-empty-p (string-trim val))))
             return (string-trim (etaf-web--collapse-ws val)))))

(defun etaf-web--normalize-date (raw)
  "Normalize ISO 8601 or numeric date RAW to `YYYY-MM-DD' when unambiguous.
Recognizes `YYYY-MM-DD[T ...]', `YYYY/M/D[ ...]', `YYYY.M.D[ ...]' and
year-month `YYYY-MM' / `YYYY/M' (normalized to `YYYY-MM-01').  Unrecognized
strings stay untouched."
  (when (stringp raw)
    (let ((s (string-trim (etaf-web--collapse-ws raw))))
      (cond
       ((string-empty-p s) nil)
       ((string-match
         "\\`\\([0-9]\\{4\\}\\)[-/.]\\([0-9]\\{1,2\\}\\)[-/.]\\([0-9]\\{1,2\\}\\)\\(?:[T ].*\\)?\\'"
         s)
        (let ((y (string-to-number (match-string 1 s)))
              (m (string-to-number (match-string 2 s)))
              (d (string-to-number (match-string 3 s))))
          (if (and (<= 1 m 12) (<= 1 d 31))
              (format "%04d-%02d-%02d" y m d)
            s)))
       ((string-match "\\`\\([0-9]\\{4\\}\\)[-/.]\\([0-9]\\{1,2\\}\\)\\'" s)
        (let ((y (string-to-number (match-string 1 s)))
              (m (string-to-number (match-string 2 s))))
          (if (<= 1 m 12)
              (format "%04d-%02d-01" y m)
            s)))
       (t s)))))

(defun etaf-web--extract-meta (dom main-node base-url)
  "Extract metadata alist from DOM and MAIN-NODE using BASE-URL."
  (let* ((og-title (or (etaf-web--meta-content dom 'property '("og:title"))
                       (etaf-web--meta-content dom 'name '("og:title" "twitter:title"))))
         (title-node (etaf-web--find-first dom (lambda (n) (eq (dom-tag n) 'title))))
         (h1-node (etaf-web--find-first main-node (lambda (n) (eq (dom-tag n) 'h1))))
         (title (or og-title
                    (let ((s (and title-node (etaf-web--clean-text title-node))))
                      (and s (not (string-empty-p s)) s))
                    (let ((s (and h1-node (etaf-web--clean-text h1-node))))
                      (and s (not (string-empty-p s)) s))))
         (canonical-node (etaf-web--find-first
                          dom (lambda (n)
                                (and (eq (dom-tag n) 'link)
                                     (equal (downcase
                                             (string-trim
                                              (or (etaf-web--attr n 'rel) "")))
                                            "canonical")))))
         (raw-url (or (and canonical-node (etaf-web--attr canonical-node 'href))
                      (etaf-web--meta-content dom 'property '("og:url"))
                      base-url))
         (url (and raw-url (etaf-web--resolve-url raw-url base-url)))
         (author-node (etaf-web--find-first
                       main-node
                       (lambda (n)
                         (and (eq (dom-tag n) 'a)
                              (member "author"
                                      (split-string
                                       (downcase (or (etaf-web--attr n 'rel) ""))
                                       "[ \t]+" t))))))
         (author (or (etaf-web--meta-content
                      dom 'name '("author" "dc.creator" "dcterms.creator"))
                     (etaf-web--meta-content dom 'property '("article:author"))
                     (let ((s (and author-node (etaf-web--clean-text author-node))))
                       (and s (not (string-empty-p s)) s))))
         (time-node (etaf-web--find-first
                     main-node (lambda (n) (eq (dom-tag n) 'time))))
         (date (etaf-web--normalize-date
                (or (etaf-web--meta-content
                     dom 'property '("article:published_time" "og:updated_time"))
                    (etaf-web--meta-content
                     dom 'name '("date" "pubdate" "publish-date" "dc.date"))
                    (when time-node
                      (let ((dt (or (etaf-web--attr time-node 'datetime)
                                    (etaf-web--clean-text time-node))))
                        (and dt (not (string-empty-p (string-trim dt)))
                             (string-trim (etaf-web--collapse-ws dt))))))))
         (site (or (etaf-web--meta-content dom 'property '("og:site_name"))
                   (etaf-web--meta-content dom 'name '("application-name" "site_name"))))
         (pairs nil))
    (dolist (item (list (cons "title" title)
                        (cons "url" url)
                        (cons "author" author)
                        (cons "date" date)
                        (cons "site" site)))
      (when (and (cdr item) (not (string-empty-p (cdr item))))
        (push item pairs)))
    (nreverse pairs)))

(defun etaf-web--yaml-scalar (value)
  "Format VALUE as a single-line YAML scalar for front matter."
  (let ((clean (string-trim (etaf-web--collapse-ws value))))
    (if (string-match-p "\\`[\"'[{>|*&!%@`]\\|: \\| #" clean)
        (format "\"%s\""
                (replace-regexp-in-string
                 "\"" "\\\\\""
                 (replace-regexp-in-string "\\\\" "\\\\\\\\" clean)))
      clean)))

(defun etaf-web--format-front-matter (meta)
  "Render metadata alist META as a YAML front matter block, or nil."
  (when meta
    (concat "---\n"
            (mapconcat (lambda (pair)
                         (format "%s: %s"
                                 (car pair)
                                 (etaf-web--yaml-scalar (cdr pair))))
                       meta "\n")
            "\n---")))

;;; ---------------------------------------------------------------------------
;;; Callout & footnote recognition
;;; ---------------------------------------------------------------------------

(defun etaf-web--callout-kind (node)
  "Return callout container name symbol for DOM NODE, or nil.
Recognizes `role=\"note|alert\"' and common docs callout/admonition classes."
  (when (and (etaf-web--node-p node)
             (memq (dom-tag node) '(div section aside blockquote p)))
    (let* ((role (downcase (string-trim (or (etaf-web--attr node 'role) ""))))
           (classes (etaf-web--class-list node))
           (has-marker
            (cl-some (lambda (c)
                       (or (member c '("admonition" "callout" "alert" "hint"
                                       "custom-block" "markdown-alert"))
                           (string-prefix-p "admonition-" c)
                           (string-prefix-p "callout-" c)
                           (string-prefix-p "alert-" c)
                           (string-prefix-p "alert--" c)
                           (string-prefix-p "markdown-alert-" c)
                           (string-prefix-p "theme-admonition" c)))
                     classes))
           (kind
            (cl-loop for c in classes
                     for matched =
                     (cond
                      ((member c '("danger" "error" "alert-danger" "alert--danger"
                                   "admonition-danger" "callout-danger"
                                   "markdown-alert-danger"))
                       'danger)
                      ((member c '("caution" "alert-caution" "alert--caution"
                                   "admonition-caution" "callout-caution"
                                   "markdown-alert-caution"))
                       'caution)
                      ((member c '("warning" "warn" "attention"
                                   "alert-warning" "alert--warning"
                                   "admonition-warning" "callout-warning"
                                   "markdown-alert-warning"))
                       'warning)
                      ((member c '("important" "alert-important" "alert--important"
                                   "admonition-important" "callout-important"
                                   "markdown-alert-important"))
                       'important)
                      ((member c '("tip" "hint" "success"
                                   "alert-tip" "alert--tip"
                                   "alert-success" "alert--success"
                                   "admonition-tip" "callout-tip"
                                   "markdown-alert-tip"))
                       'tip)
                      ((member c '("note" "info"
                                   "alert-note" "alert--note"
                                   "alert-info" "alert--info"
                                   "admonition-note" "admonition-info"
                                   "callout-note" "markdown-alert-note"))
                       'note))
                     when matched return matched)))
      (cond
       ((equal role "alert") (or kind 'warning))
       ((equal role "note") (or kind 'note))
       ((and has-marker kind) kind)
       (has-marker 'note)
       (t nil)))))

(defun etaf-web--footnote-container-p (node)
  "Return non-nil when DOM NODE is a footnote list/section container."
  (when (etaf-web--node-p node)
    (let ((role (downcase (string-trim (or (etaf-web--attr node 'role) ""))))
          (tokens (etaf-web--class-tokens node)))
      (or (member role '("doc-endnotes" "doc-footnotes"))
          (cl-some (lambda (tok)
                     (string-match-p "footnote\\|endnote" tok))
                   tokens)))))

;;; ---------------------------------------------------------------------------
;;; Layout container classification helpers
;;; ---------------------------------------------------------------------------

(defconst etaf-web--card-grid-token-regexp
  (concat
   "\\(?:\\`\\|[-_]\\)\\(?:"
   "cards?\\|tiles?\\|grid\\|features?\\|catalog\\|gallery\\|showcase"
   "\\)\\(?:\\'\\|[-_]\\)")
  "Word-bounded class/id tokens suggesting a card-grid container.")

(defconst etaf-web--tabs-token-regexp
  "\\(?:\\`\\|[-_]\\)\\(?:tabs\\|tab-list\\|tablist\\|code-tabs\\)\\(?:\\'\\|[-_]\\)"
  "Word-bounded class/id tokens suggesting a tabbed container.")

(defconst etaf-web--tablist-token-regexp
  "\\(?:\\`\\|[-_]\\)\\(?:tab-list\\|tablist\\|tabs-nav\\|tab-bar\\)\\(?:\\'\\|[-_]\\)"
  "Word-bounded class/id tokens identifying a tab trigger strip.")

(defconst etaf-web--tabpanel-token-regexp
  "\\(?:\\`\\|[-_]\\)\\(?:tabpanel\\|tab-panel\\|tab-pane\\)\\(?:\\'\\|[-_]\\)"
  "Word-bounded class/id tokens identifying a tab panel.")

(defconst etaf-web--steps-token-regexp
  "\\(?:\\`\\|[-_]\\)\\(?:steps\\|stepper\\|how-it-works\\)\\(?:\\'\\|[-_]\\)"
  "Word-bounded class/id tokens identifying a steps container.")

(defconst etaf-web--timeline-token-regexp
  "\\(?:\\`\\|[-_]\\)timeline\\(?:\\'\\|[-_]\\)"
  "Word-bounded class/id tokens identifying a timeline container.")

(defun etaf-web--element-children (node)
  "Return direct DOM element children of NODE."
  (when (etaf-web--node-p node)
    (cl-remove-if-not #'etaf-web--node-p (dom-children node))))

(defun etaf-web--significant-children (node)
  "Return direct children of NODE excluding whitespace-only strings."
  (when (etaf-web--node-p node)
    (cl-remove-if (lambda (c) (and (stringp c) (string-blank-p c)))
                  (dom-children node))))

(defun etaf-web--sole-media-child (node)
  "Return the sole `<img>' or `<picture>' child of NODE, or nil."
  (let ((sig (etaf-web--significant-children node)))
    (when (and (= (length sig) 1)
               (etaf-web--node-p (car sig))
               (memq (dom-tag (car sig)) '(img picture)))
      (car sig))))

(defun etaf-web--grid-style-p (node)
  "Return non-nil when NODE's inline `style' declares CSS Grid columns."
  (let ((style (etaf-web--attr node 'style)))
    (and (stringp style)
         (string-match-p "grid-template-columns" (downcase style)))))

(defun etaf-web--card-grid-class-p (node)
  "Return non-nil when NODE carries a card-grid class/id or CSS Grid style."
  (when (and (etaf-web--node-p node)
             (memq (dom-tag node) '(div section ul ol)))
    (or (etaf-web--grid-style-p node)
        (cl-some (lambda (tok)
                   (string-match-p etaf-web--card-grid-token-regexp tok))
                 (etaf-web--class-tokens node)))))

(defun etaf-web--tablist-node-p (node)
  "Return non-nil when NODE is a tab trigger strip (`role=tablist' or class)."
  (when (etaf-web--node-p node)
    (let ((role (downcase (string-trim (or (etaf-web--attr node 'role) "")))))
      (or (equal role "tablist")
          (cl-some (lambda (tok)
                     (string-match-p etaf-web--tablist-token-regexp tok))
                   (etaf-web--class-tokens node))))))

(defun etaf-web--tabpanel-node-p (node)
  "Return non-nil when NODE is a tab content panel (`role=tabpanel' or class)."
  (when (etaf-web--node-p node)
    (let ((role (downcase (string-trim (or (etaf-web--attr node 'role) "")))))
      (or (equal role "tabpanel")
          (cl-some (lambda (tok)
                     (string-match-p etaf-web--tabpanel-token-regexp tok))
                   (etaf-web--class-tokens node))))))

(defun etaf-web--tabs-class-p (node)
  "Return non-nil when NODE has a tabs container class/id."
  (when (and (etaf-web--node-p node)
             (memq (dom-tag node) '(div section)))
    (cl-some (lambda (tok)
               (string-match-p etaf-web--tabs-token-regexp tok))
             (etaf-web--class-tokens node))))

(defun etaf-web--steps-class-p (node)
  "Return non-nil when NODE has a steps/stepper/how-it-works class/id."
  (when (and (etaf-web--node-p node)
             (memq (dom-tag node) '(div section ol ul)))
    (cl-some (lambda (tok)
               (string-match-p etaf-web--steps-token-regexp tok))
             (etaf-web--class-tokens node))))

(defun etaf-web--timeline-class-p (node)
  "Return non-nil when NODE has a timeline class/id."
  (when (and (etaf-web--node-p node)
             (memq (dom-tag node) '(div section ol ul)))
    (cl-some (lambda (tok)
               (string-match-p etaf-web--timeline-token-regexp tok))
             (etaf-web--class-tokens node))))

;;; ---------------------------------------------------------------------------
;;; Boilerplate pruning & main-content extraction
;;; ---------------------------------------------------------------------------

(defun etaf-web--contains-landmark-p (node)
  "Return non-nil when NODE contains an `<article>' or `<main>' descendant."
  (and (etaf-web--node-p node)
       (cl-some (lambda (child)
                  (and (etaf-web--node-p child)
                       (or (memq (dom-tag child) '(article main))
                           (equal (downcase (or (etaf-web--attr child 'role) ""))
                                  "main")
                           (etaf-web--contains-landmark-p child))))
                (dom-children node))))

(defun etaf-web--has-block-child-p (node)
  "Return non-nil when DOM NODE has any block-level descendant."
  (and (etaf-web--node-p node)
       (cl-some (lambda (child)
                  (and (etaf-web--node-p child)
                       (or (memq (dom-tag child) etaf-web--block-tags)
                           (etaf-web--has-block-child-p child))))
                (dom-children node))))

(defun etaf-web--non-link-text (node)
  "Return plain text inside DOM NODE excluding text inside `<a>' elements."
  (cond
   ((stringp node) node)
   ((not (etaf-web--node-p node)) "")
   ((eq (dom-tag node) 'a) "")
   (t (mapconcat #'etaf-web--non-link-text (dom-children node) ""))))

(defun etaf-web--bracket-nav-line-p (node)
  "Return non-nil when NODE is a line of bracketed nav links like `[Contents]'."
  (when (and (etaf-web--node-p node)
             (memq (dom-tag node) '(p div span))
             (not (etaf-web--has-block-child-p node)))
    (let* ((text (etaf-web--clean-text node))
           (links (etaf-web--find-all node (lambda (n) (eq (dom-tag n) 'a))))
           (non-link (string-trim (etaf-web--collapse-ws
                                   (etaf-web--non-link-text node)))))
      (and (>= (length links) 1)
           (<= (length text) 160)
           (string-match-p
            "\\`\\(?:\\[[[:alnum:] _-]+\\][ \t|·/,-]*\\)+\\'"
            text)
           (string-match-p "\\`[][ \t|·/,-]*\\'" non-link)))))

(defun etaf-web--makeinfo-nav-block-p (node)
  "Return non-nil when DOM NODE is a makeinfo/texinfo navigation paragraph."
  (when (and (etaf-web--node-p node)
             (memq (dom-tag node) '(p div span))
             (not (etaf-web--has-block-child-p node)))
    (let ((text (etaf-web--clean-text node))
          (case-fold-search nil))
      (and (<= (length text) 400)
           (or (and (string-match-p "\\`\\(?:Next\\|Previous\\|Up\\):[ \t]" text)
                    (etaf-web--find-first node (lambda (n) (eq (dom-tag n) 'a)))
                    (or (string-match-p "\\b\\(?:Next\\|Previous\\|Up\\):[ \t]"
                                        text 1)
                        (string-match-p "\\[\\(?:Contents\\|Index\\|Top\\)\\]"
                                        text)
                        (etaf-web--find-first
                         node
                         (lambda (n)
                           (and (eq (dom-tag n) 'a)
                                (member (downcase (or (etaf-web--attr n 'rel) ""))
                                        '("next" "prev" "previous" "up"
                                          "contents" "index")))))))
               (etaf-web--bracket-nav-line-p node))))))

(defun etaf-web--breadcrumb-block-p (node)
  "Return non-nil when DOM NODE is a short breadcrumb trail of links."
  (when (and (etaf-web--node-p node)
             (memq (dom-tag node) '(p div))
             (not (etaf-web--has-block-child-p node)))
    (let* ((links (etaf-web--find-all node (lambda (n) (eq (dom-tag n) 'a))))
           (text (etaf-web--clean-text node))
           (non-link (string-trim (etaf-web--collapse-ws
                                   (etaf-web--non-link-text node)))))
      (and (> (length links) 2)
           (<= (length text) 160)
           (not (string-empty-p non-link))
           (or (and (string-match-p "\\`[ \t>/›»·|]+\\'" non-link)
                    (string-match-p "[>/›»]" non-link))
               (and (string-match "\\`\\([ \t>/›»·|]+\\)\\([^>/›»]+\\)\\'"
                                  non-link)
                    (>= (length (replace-regexp-in-string
                                 "[^>/›»]" "" (match-string 1 non-link)))
                        2)
                    (<= (length (string-trim (match-string 2 non-link))) 40)))))))

(defun etaf-web--decorative-anchor-block-p (node)
  "Return non-nil when NODE is a short block of only in-page `#anchor' link(s)."
  (when (and (etaf-web--node-p node)
             (memq (dom-tag node) '(p div))
             (not (etaf-web--has-block-child-p node)))
    (let* ((links (etaf-web--find-all node (lambda (n) (eq (dom-tag n) 'a))))
           (text (etaf-web--clean-text node))
           (non-link (string-trim (etaf-web--collapse-ws
                                   (etaf-web--non-link-text node)))))
      (and links
           (not (string-empty-p text))
           (<= (length text) 10)
           (cl-every (lambda (a)
                       (let ((href (string-trim (or (etaf-web--attr a 'href) ""))))
                         (string-prefix-p "#" href)))
                     links)
           (not (string-match-p "[[:alnum:]\u4e00-\u9fff]" non-link))))))

(defconst etaf-web--noise-container-substr-regexp
  (concat
   "breadcrumb\\|crumbs?\\|share\\|social\\|related\\|recommend\\|"
   "statement\\|disclaimer\\|app-download\\|download-app\\|down[-_]app\\|"
   "comment\\|ad-tips\\|ad-box\\|ad-wrap")
  "Class or id substrings identifying non-article chrome containers.")

(defconst etaf-web--noise-tag-token-regexp
  "\\(?:\\`\\|[-_]\\)\\(?:tags?\\|keywords?\\)\\(?:\\'\\|[-_]\\)"
  "Class or id word-bounded pattern for tag/keyword containers.")

(defconst etaf-web--noise-section-heading-regexp
  (concat
   "\\`\\(?:"
   "相关文章\\|相关阅读\\|相关推荐\\|延伸阅读\\|推荐阅读\\|精彩推荐\\|"
   "猜你喜欢\\|你可能还喜欢\\|热门推荐\\|热点推荐\\|"
   "关键词\\|标签\\|文章标签\\|"
   "分享\\|分享到\\|分享本文\\|"
   "声明\\|广告声明\\|免责声明\\|版权声明\\|"
   "related articles?\\|related posts?\\|related reading\\|"
   "recommended\\|recommended reading\\|you may also like\\|"
   "tags?\\|keywords?\\|share\\|share this\\|disclaimer"
   "\\)[：:]*\\'")
  "Heading titles whose entire section is dropped as site noise.")

(defun etaf-web--noise-heading-level (node)
  "Return heading level (2..4) when NODE is a noise-section heading, else nil."
  (when (and (etaf-web--node-p node) (memq (dom-tag node) '(h2 h3 h4)))
    (let ((text (downcase (etaf-web--clean-text node))))
      (when (string-match-p etaf-web--noise-section-heading-regexp text)
        (string-to-number (substring (symbol-name (dom-tag node)) 1))))))

(defun etaf-web--heading-level (node)
  "Return heading level (1..6) for DOM NODE, or nil."
  (when (and (etaf-web--node-p node)
             (memq (dom-tag node) '(h1 h2 h3 h4 h5 h6)))
    (string-to-number (substring (symbol-name (dom-tag node)) 1))))

(defun etaf-web--noise-section-container-p (node)
  "Return non-nil when section/div NODE opens directly with a noise heading."
  (when (and (etaf-web--node-p node)
             (memq (dom-tag node) '(section div)))
    (let ((first (etaf-web--first-content-block node)))
      (and first (etaf-web--noise-heading-level first) t))))

(defun etaf-web--button-only-block-p (node)
  "Return non-nil when block NODE contains only `<button>' UI controls."
  (when (and (etaf-web--node-p node)
             (memq (dom-tag node) '(div p)))
    (let ((significant (cl-remove-if
                        (lambda (c) (and (stringp c) (string-blank-p c)))
                        (dom-children node))))
      (and significant
           (cl-every (lambda (c)
                       (and (etaf-web--node-p c) (eq (dom-tag c) 'button)))
                     significant)))))

(defun etaf-web--action-noise-block-p (node)
  "Return non-nil when leaf block NODE is a disclaimer or pure action prompt."
  (when (and (etaf-web--node-p node)
             (memq (dom-tag node) '(p div a))
             (not (etaf-web--has-block-child-p node)))
    (let ((text (etaf-web--clean-text node))
          (case-fold-search t))
      (cond
       ((string-empty-p text) nil)
       ;; Legal / ad disclaimer boilerplate paragraph.
       ((and (<= (length text) 220)
             (string-match-p "\\`\\(?:广告声明\\|免责声明\\|版权声明\\)[：:]" text))
        t)
       ;; Short keyword/tag metadata strip (e.g. `关键词：Steam').
       ((and (<= (length text) 80)
             (string-match-p "\\`\\(?:关键词\\|标签\\|tags?\\|keywords?\\)[：:]" text)
             (or (etaf-web--find-first node (lambda (n) (eq (dom-tag n) 'a)))
                 (and (<= (length text) 40)
                      (not (string-match-p "。" text)))))
        t)
       ;; Short pure-action lines: download app, check-in, subscribe, complain, fix.
       ((and (<= (length text) 40)
             (not (string-match-p "。." text))
             (or (string-match-p "下载.*\\(?:app\\|客户端\\|应用\\)" text)
                 (string-match-p "签到.*\\(?:金币\\|积分\\|豪礼\\|领\\|赚\\)" text)
                 (and (<= (length text) 24)
                      (string-match-p
                       "\\`\\(?:点击\\|立即\\|免费\\|我要\\)?\\(?:投诉\\|举报\\|纠错\\|订阅\\|签到\\|分享到?\\)"
                       text))))
        t)
       (t nil)))))

(defun etaf-web--link-heavy-block-p (node)
  "Return non-nil when paragraph/list NODE has >= 3 links and minimal prose."
  (when (and (etaf-web--node-p node)
             (or (memq (dom-tag node) '(ul ol))
                 (and (memq (dom-tag node) '(p div))
                      (not (etaf-web--has-block-child-p node))))
             (not (etaf-web--find-first
                   node (lambda (n) (memq (dom-tag n) '(pre table code))))))
    (let* ((links (etaf-web--find-all node (lambda (n) (eq (dom-tag n) 'a))))
           (text (etaf-web--clean-text node))
           (total-no-ws (length (replace-regexp-in-string "[ \t\n\r]+" "" text)))
           (link-len (etaf-web--link-text-length node))
           (non-link-raw (etaf-web--non-link-text node))
           (non-link-words (replace-regexp-in-string
                            "[^[:alnum:]\u4e00-\u9fff]+" "" non-link-raw)))
      (and (>= (length links) 3)
           (> total-no-ws 0)
           (>= (/ (float link-len) total-no-ws) 0.85)
           (<= (length non-link-words) 15)))))

(defun etaf-web--nav-chrome-p (node)
  "Return non-nil when DOM NODE is nav chrome whose adjacent `<hr>' is noise."
  (when (etaf-web--node-p node)
    (let ((tag (dom-tag node))
          (role (downcase (string-trim (or (etaf-web--attr node 'role) ""))))
          (tokens (etaf-web--class-tokens node)))
      (or (eq tag 'nav)
          (equal role "navigation")
          (cl-some (lambda (tok)
                     (string-match-p
                      "\\`\\(?:nav\\|navbar\\|navigation\\|nav-panel\\|navpanel\\|node-nav\\)\\'"
                      tok))
                   tokens)
          (etaf-web--makeinfo-nav-block-p node)
          (etaf-web--breadcrumb-block-p node)))))

(defun etaf-web--interactive-form-p (node)
  "Return non-nil when `<form>' NODE is a short interactive UI widget.
Prunes search boxes, login forms and vote polls while leaving full-page
wrapper forms (e.g. ASP.NET WebForms) intact."
  (when (and (etaf-web--node-p node)
             (eq (dom-tag node) 'form)
             (not (etaf-web--contains-landmark-p node)))
    (and (<= (length (etaf-web--clean-text node)) 600)
         (not (etaf-web--find-first
               node (lambda (n) (memq (dom-tag n) '(pre table h1)))))
         (etaf-web--find-first
          node (lambda (n) (memq (dom-tag n) '(input select textarea button)))))))

(defun etaf-web--boilerplate-node-p (node inside-primary)
  "Return non-nil when DOM NODE should be pruned as page chrome.
INSIDE-PRIMARY is non-nil once traversal is inside the chosen article/main."
  (when (etaf-web--node-p node)
    (let* ((tag (dom-tag node))
           (block-like (memq tag etaf-web--block-tags))
           (role (downcase (string-trim (or (etaf-web--attr node 'role) ""))))
           (aria-label (downcase (string-trim (or (etaf-web--attr node 'aria-label) ""))))
           (tokens (etaf-web--class-tokens node))
           (hidden (or (assq 'hidden (dom-attributes node))
                       (equal (downcase (or (etaf-web--attr node 'aria-hidden) ""))
                              "true")))
           (layout-widget (or (etaf-web--tablist-node-p node)
                              (etaf-web--tabpanel-node-p node)
                              (etaf-web--tabs-class-p node)
                              (etaf-web--steps-class-p node)
                              (etaf-web--timeline-class-p node)
                              (etaf-web--card-grid-class-p node))))
      (cond
       ((memq tag '(html body article main)) nil)
       ((etaf-web--callout-kind node) nil)
       ((etaf-web--footnote-container-p node) nil)
       ;; Tab controls and inactive `hidden' tabpanels belong to document UI.
       ((member role '("tablist" "tab" "tabpanel")) nil)
       ((etaf-web--tabpanel-node-p node) nil)
       ((etaf-web--contains-landmark-p node) nil)
       (hidden t)
       ((memq tag etaf-web--boilerplate-tags) t)
       ((and (eq tag 'header) (not inside-primary)) t)
       ((member role etaf-web--boilerplate-roles) t)
       ((string-match-p "breadcrumb\\|crumbs?" aria-label) t)
       ((cl-some (lambda (tok)
                   (or (and block-like
                            (or (string-match-p etaf-web--boilerplate-token-regexp tok)
                                (string-match-p etaf-web--noise-tag-token-regexp tok)))
                       (string-match-p etaf-web--noise-container-substr-regexp tok)))
                 tokens)
        t)
       (layout-widget nil)
       ((etaf-web--interactive-form-p node) t)
       ((etaf-web--button-only-block-p node) t)
       ((etaf-web--noise-section-container-p node) t)
       ((etaf-web--makeinfo-nav-block-p node) t)
       ((etaf-web--breadcrumb-block-p node) t)
       ((etaf-web--decorative-anchor-block-p node) t)
       ((etaf-web--action-noise-block-p node) t)
       ((etaf-web--link-heavy-block-p node) t)
       (t nil)))))

(defun etaf-web--next-nonblank-node (nodes)
  "Return first non-blank DOM node in NODES, or nil."
  (cl-find-if (lambda (n)
                (not (and (stringp n) (string-blank-p n))))
              nodes))

(defun etaf-web--drop-trailing-orphan-heading (kept next-level)
  "Drop a trailing heading in reversed KEPT if NEXT-LEVEL closes its section.
NEXT-LEVEL is nil at end of parent, or the heading level of the next heading.
Only called when a pruned sibling directly emptied that heading's section."
  (let ((scan kept))
    (while (and scan (stringp (car scan)) (string-blank-p (car scan)))
      (setq scan (cdr scan)))
    (let ((lvl (and scan (etaf-web--heading-level (car scan)))))
      (if (and lvl (>= lvl 2) (or (null next-level) (<= next-level lvl)))
          (cdr scan)
        kept))))

(defun etaf-web--prune-boilerplate (node &optional inside-primary)
  "Return a copy of NODE with navigation, sidebars, footers and ads removed.
Drops `<hr>' immediately adjacent to pruned nav chrome, drops noise-titled
sections (`h2'–`h4') up to the next peer or higher heading, and removes
headings whose following body was completely pruned away."
  (cond
   ((stringp node) node)
   ((not (etaf-web--node-p node)) nil)
   ((etaf-web--boilerplate-node-p node inside-primary) nil)
   (t
    (let* ((tag (dom-tag node))
           (primary (or inside-primary (memq tag '(article main))))
           (kept nil)
           (prev-was-nav nil)
           (pruned-after-heading nil)
           (skip-section-level nil)
           (rest (dom-children node)))
      (while rest
        (let ((child (pop rest)))
          (cond
           (skip-section-level
            (let ((lvl (etaf-web--heading-level child)))
              (if (and lvl (<= lvl skip-section-level))
                  (progn
                    (setq skip-section-level nil)
                    (push child rest))
                nil)))
           ((and (stringp child) (string-blank-p child))
            (push child kept))
           ((etaf-web--noise-heading-level child)
            (when pruned-after-heading
              (setq kept (etaf-web--drop-trailing-orphan-heading
                          kept (etaf-web--noise-heading-level child))
                    pruned-after-heading nil))
            (setq skip-section-level (etaf-web--noise-heading-level child)
                  prev-was-nav nil))
           ((etaf-web--boilerplate-node-p child primary)
            (setq prev-was-nav (etaf-web--nav-chrome-p child)
                  pruned-after-heading t))
           ((and (etaf-web--node-p child)
                 (eq (dom-tag child) 'hr)
                 (or prev-was-nav
                     (let ((next (etaf-web--next-nonblank-node rest)))
                       (and next
                            (etaf-web--boilerplate-node-p next primary)
                            (etaf-web--nav-chrome-p next)))))
            (setq prev-was-nav nil))
           (t
            (when-let* ((lvl (etaf-web--heading-level child)))
              (when pruned-after-heading
                (setq kept (etaf-web--drop-trailing-orphan-heading kept lvl))))
            (setq prev-was-nav nil)
            (let ((pruned (etaf-web--prune-boilerplate child primary)))
              (if (and pruned
                       (or (not (etaf-web--node-p pruned))
                           (not (memq (dom-tag pruned) '(div section ul ol dl)))
                           (not (string-empty-p (etaf-web--clean-text pruned)))
                           (etaf-web--find-first
                            pruned (lambda (n)
                                     (memq (dom-tag n)
                                           '(img picture hr input))))))
                  (progn
                    (setq pruned-after-heading nil)
                    (push pruned kept))
                (setq pruned-after-heading t)))))))
      (when pruned-after-heading
        (setq kept (etaf-web--drop-trailing-orphan-heading kept nil)))
      (cons tag (cons (dom-attributes node) (nreverse kept)))))))

(defun etaf-web--link-text-length (node)
  "Return total character count of text inside `<a>' elements under NODE."
  (cond
   ((stringp node) 0)
   ((not (etaf-web--node-p node)) 0)
   ((eq (dom-tag node) 'a) (length (etaf-web--clean-text node)))
   (t (cl-loop for child in (dom-children node)
               sum (etaf-web--link-text-length child)))))

(defun etaf-web--non-link-length (node)
  "Return non-link plain-text character count under DOM NODE."
  (max 0 (- (length (etaf-web--clean-text node))
            (etaf-web--link-text-length node))))

(defun etaf-web--link-density (node)
  "Return fraction of plain text inside `<a>' links under NODE (0.0..1.0)."
  (let ((total (length (etaf-web--clean-text node))))
    (if (> total 0)
        (min 1.0 (/ (float (etaf-web--link-text-length node)) total))
      0.0)))

(defun etaf-web--direct-inline-text (node)
  "Return plain text owned directly by NODE (excluding child block elements)."
  (let ((parts nil))
    (cl-labels
        ((walk (n)
           (cond
            ((stringp n) (push n parts))
            ((not (etaf-web--node-p n)) nil)
            ((eq (dom-tag n) 'br) (push " " parts))
            ((memq (dom-tag n) etaf-web--block-tags) nil)
            (t (dolist (c (dom-children n)) (walk c))))))
      (dolist (c (dom-children node)) (walk c)))
    (string-trim (etaf-web--collapse-ws (mapconcat #'identity (nreverse parts) "")))))

(defun etaf-web--punct-count (text)
  "Count sentence and clause punctuation marks in TEXT (ASCII and CJK)."
  (let ((count 0)
        (pos 0))
    (while (string-match "[,.;:!?，。；：！？、]" text pos)
      (setq count (1+ count)
            pos (match-end 0)))
    count))

(defun etaf-web--content-unit-score (node)
  "Return bottom-up textual richness score for leaf content unit NODE, or nil.
Scores `<p>', `<pre>', `<blockquote>' and block cells (`<div>', `<td>', `<li>')
that directly hold substantive prose, using punctuation density, length and
continuous link-density damping with zero class/id assumptions."
  (when (etaf-web--node-p node)
    (let* ((tag (dom-tag node))
           (text (cond
                  ((memq tag '(p pre blockquote)) (etaf-web--clean-text node))
                  ((memq tag '(div td li)) (etaf-web--direct-inline-text node))
                  (t nil))))
      (when (and text (>= (length (replace-regexp-in-string "[ \t\n\r]+" "" text)) 25))
        (let* ((total (length text))
               (link-len (if (memq tag '(p pre blockquote))
                             (etaf-web--link-text-length node)
                           (cl-loop for c in (dom-children node)
                                    when (and (etaf-web--node-p c)
                                              (not (memq (dom-tag c) etaf-web--block-tags)))
                                    sum (etaf-web--link-text-length c))))
               (non-link (max 0 (- total link-len)))
               (link-ratio (if (> total 0) (min 1.0 (/ (float link-len) total)) 0.0))
               (punct (etaf-web--punct-count text))
               (base (+ 1.0 (min 15.0 (float punct))
                        (min 8.0 (/ (float non-link) 60.0)))))
          (* base (max 0.1 (- 1.0 link-ratio))))))))

(defun etaf-web--pick-main-candidate (root)
  "Select the primary content container under pruned ROOT via bottom-up scoring.
Propagates leaf content-unit scores upward with geometric distance decay and
applies continuous `(1 - link-density)' scaling, without site-specific class
or id bonuses."
  (let ((scores (make-hash-table :test #'eq))
        (candidates nil))
    (cl-labels
        ((walk (node ancestors)
           (when (etaf-web--node-p node)
             (when-let* ((unit-score (etaf-web--content-unit-score node)))
               ;; Credit the node itself if it is a container (`td'/`div'),
               ;; plus its enclosing container ancestors with distance decay.
               (let ((targets (if (memq (dom-tag node) '(div section main article td))
                                  (cons node ancestors)
                                ancestors))
                     (depth 0))
                 (dolist (anc targets)
                   (when (and (<= depth 5)
                              (memq (dom-tag anc) '(div section main article td body)))
                     (let ((weight (cond
                                    ((= depth 0) 1.0)
                                    ((= depth 1) 0.9)
                                    ((= depth 2) 0.75)
                                    ((= depth 3) 0.4)
                                    (t (/ 1.0 (* 2.0 depth))))))
                       (unless (gethash anc scores)
                         (push anc candidates))
                       (puthash anc (+ (gethash anc scores 0.0)
                                       (* unit-score weight))
                                scores)))
                   (when (memq (dom-tag anc) '(div section main article td body))
                     (setq depth (1+ depth))))))
             (let ((next-anc (cons node ancestors)))
               (dolist (child (dom-children node))
                 (walk child next-anc))))))
      (walk root nil))
    (let ((best root)
          (best-score -1.0))
      (dolist (cand candidates)
        (let* ((raw (gethash cand scores 0.0))
               (final (* raw (max 0.1 (- 1.0 (etaf-web--link-density cand))))))
          (when (> final best-score)
            (setq best cand
                  best-score final))))
      best)))

(defun etaf-web--tighten-main-node (node)
  "Descend from NODE into a dominant content child when siblings are chrome.
Unwraps single-child wrappers and sheds header/sidebar siblings whenever one
child container holds >= 75% of NODE's non-link prose without shedding direct
prose siblings, purely from DOM structure and link density."
  (let ((cur node)
        (keep-going t))
    (while keep-going
      (setq keep-going nil)
      (when (and (etaf-web--node-p cur)
                 (not (eq (dom-tag cur) 'article)))
        (let* ((elems (etaf-web--element-children cur))
               (total-nl (etaf-web--non-link-length cur))
               (cur-ld (etaf-web--link-density cur))
               (best-child nil)
               (best-nl -1))
          (dolist (c elems)
            (when (memq (dom-tag c) '(div section main article td tbody tr table))
              (let ((nl (etaf-web--non-link-length c)))
                (when (> nl best-nl)
                  (setq best-child c best-nl nl)))))
          (when (and best-child (> total-nl 0))
            (let* ((siblings (cl-remove best-child elems :count 1 :test #'eq))
                   (sib-text-len (cl-loop for s in siblings
                                          sum (length (etaf-web--clean-text s))))
                   (sib-link-len (cl-loop for s in siblings
                                          sum (etaf-web--link-text-length s)))
                   (sib-ld (if (> sib-text-len 0)
                               (/ (float sib-link-len) sib-text-len)
                             0.0))
                   (sib-has-prose
                    (cl-some (lambda (s)
                               (and (memq (dom-tag s) '(p h1 pre blockquote figure))
                                    (>= (length (etaf-web--clean-text s)) 30)))
                             siblings))
                   (sib-has-media
                    (cl-some (lambda (s)
                               (etaf-web--find-first
                                s (lambda (n) (memq (dom-tag n) '(img picture)))))
                             siblings))
                   (sib-has-form
                    (cl-some (lambda (s)
                               (etaf-web--find-first
                                s (lambda (n) (memq (dom-tag n) '(form input select)))))
                             siblings))
                   (share (/ (float best-nl) total-nl))
                   (child-ld (etaf-web--link-density best-child))
                   (transparent
                    (and (>= share 0.96)
                         (< sib-text-len 20)
                         (not sib-has-media)))
                   (chrome-shed
                    (and (memq (dom-tag best-child) '(div section main article td))
                         (>= best-nl 200)
                         (>= share 0.75)
                         (not sib-has-prose)
                         (<= child-ld (+ cur-ld 0.03))
                         (or (>= sib-ld 0.30)
                             (<= (- total-nl best-nl) (* 0.15 total-nl))
                             sib-has-form))))
              (when (or transparent chrome-shed)
                (setq cur best-child
                      keep-going t)))))))
    cur))

(defun etaf-web--extract-main (dom)
  "Return (MAIN . FOOTNOTE-ROOTS) extracted from sanitized DOM.
Prefers a dominant `<article>' or `<main>' landmark when present, otherwise
uses bottom-up Readability content scoring, then tightens wrappers to drop
sidebar and header chrome."
  (let* ((body (or (etaf-web--find-first dom (lambda (n) (eq (dom-tag n) 'body)))
                   dom))
         (articles (etaf-web--find-all body (lambda (n) (eq (dom-tag n) 'article))))
         (mains (etaf-web--find-all
                 body (lambda (n)
                        (or (eq (dom-tag n) 'main)
                            (equal (downcase (or (etaf-web--attr n 'role) ""))
                                   "main")))))
         (pruned-body (etaf-web--prune-boilerplate body nil))
         (fn-roots (etaf-web--find-all pruned-body #'etaf-web--footnote-container-p))
         (pruned-main (and mains (etaf-web--prune-boilerplate (car mains) t)))
         (main-len (if pruned-main (length (etaf-web--clean-text pruned-main)) 0))
         (body-len (length (etaf-web--clean-text pruned-body)))
         (best-art nil)
         (best-art-len -1))
    (dolist (art articles)
      (let* ((pruned (etaf-web--prune-boilerplate art t))
             (len (length (etaf-web--clean-text pruned))))
        (when (> len best-art-len)
          (setq best-art pruned best-art-len len))))
    (let* ((picked
            (cond
             ((and best-art pruned-main)
              (if (or (= (length articles) 1)
                      (>= best-art-len (* 0.6 main-len)))
                  best-art
                pruned-main))
             (best-art
              (if (or (= (length articles) 1)
                      (>= best-art-len (* 0.5 body-len)))
                  best-art
                (etaf-web--pick-main-candidate pruned-body)))
             (pruned-main pruned-main)
             (t
              (etaf-web--pick-main-candidate pruned-body))))
           (chosen (if (eq picked best-art)
                       picked
                     (etaf-web--tighten-main-node (or picked pruned-body)))))
      (cons (or chosen pruned-body) fn-roots))))

;;; ---------------------------------------------------------------------------
;;; Footnote collection & stripping
;;; ---------------------------------------------------------------------------

(defun etaf-web--footnote-backref-p (node)
  "Return non-nil when DOM NODE is a footnote back-reference link."
  (when (and (etaf-web--node-p node) (eq (dom-tag node) 'a))
    (let ((role (downcase (or (etaf-web--attr node 'role) "")))
          (classes (etaf-web--class-list node))
          (text (etaf-web--clean-text node)))
      (or (member role '("doc-backlink"))
          (cl-some (lambda (c) (string-match-p "backref\\|reversefootnote" c))
                   classes)
          (string-match-p "\\`[↩↵↑^]+\\'" text)))))

(defun etaf-web--strip-backrefs (node)
  "Return copy of DOM NODE without footnote back-reference links."
  (cond
   ((stringp node) node)
   ((not (etaf-web--node-p node)) nil)
   ((etaf-web--footnote-backref-p node) nil)
   (t
    (cons (dom-tag node)
          (cons (dom-attributes node)
                (delq nil (mapcar #'etaf-web--strip-backrefs
                                  (dom-children node))))))))

(defun etaf-web--collect-footnote-defs (main-node fn-roots)
  "Return hash table mapping footnote anchor ID to raw DOM children."
  (let ((table (make-hash-table :test #'equal))
        (containers (append (etaf-web--find-all
                             main-node #'etaf-web--footnote-container-p)
                            fn-roots)))
    (dolist (container containers)
      (dolist (item (etaf-web--find-all
                     container (lambda (n) (memq (dom-tag n) '(li div p)))))
        (let ((id (etaf-web--attr item 'id)))
          (when (and id (not (string-empty-p id)) (not (gethash id table)))
            (puthash id (etaf-web--strip-backrefs item) table)))))
    ;; Also pick up `<li id="fn...">` anywhere in MAIN-NODE even without wrapper.
    (dolist (item (etaf-web--find-all
                   main-node
                   (lambda (n)
                     (and (eq (dom-tag n) 'li)
                          (let ((id (or (etaf-web--attr n 'id) "")))
                            (string-match-p "\\`\\(?:fn\\|footnote\\|endnote\\)"
                                            (downcase id)))))))
      (let ((id (etaf-web--attr item 'id)))
        (unless (gethash id table)
          (puthash id (etaf-web--strip-backrefs item) table))))
    table))

;;; ---------------------------------------------------------------------------
;;; Compilation context & inline emission
;;; ---------------------------------------------------------------------------

(cl-defstruct (etaf-web--ctx (:constructor etaf-web--ctx-create))
  "Compilation state threaded through DOM emission."
  base-url
  image-rewriter
  doc-title        ; front-matter title for alt deduplication
  skip-heading     ; DOM node of leading h1 duplicating front matter title
  heading-ids      ; hash-table: html-id -> etaf-md heading slug
  fn-defs          ; hash-table: id -> DOM node
  fn-order         ; list of referenced ids (reversed while collecting)
  fn-numbers       ; hash-table: id -> 1-based integer
  in-card)         ; non-nil while emitting inside a `:::card' body

(defun etaf-web--title-candidates (title)
  "Return TITLE and progressively site-suffix-stripped candidate prefixes."
  (when (and (stringp title) (not (string-blank-p title)))
    (let* ((cur (string-trim (etaf-web--collapse-ws title)))
           (cands (list cur))
           (keep-going t))
      (while keep-going
        (let ((next
               (cond
                ((string-match "\\`\\(.+?\\)[ \t]+[-—–|·][ \t]+[^-—–|·]+\\'" cur)
                 (string-trim (match-string 1 cur)))
                ((string-match "\\`\\(.+?\\)_[^_]+\\'" cur)
                 (string-trim (match-string 1 cur)))
                (t nil))))
          (if (and next (not (string-empty-p next)) (not (equal next cur)))
              (progn
                (push next cands)
                (setq cur next))
            (setq keep-going nil))))
      (nreverse cands))))

(defun etaf-web--heading-matches-title-p (heading title)
  "Return non-nil when HEADING duplicates TITLE (exact, suffix-stripped or prefix)."
  (when (and (stringp heading) (stringp title))
    (let* ((h (string-trim (etaf-web--collapse-ws heading)))
           (cands (etaf-web--title-candidates title)))
      (and (not (string-empty-p h))
           cands
           (or (member h cands)
               (and (>= (length h) 2)
                    (cl-some (lambda (cand) (string-prefix-p h cand))
                             cands)))))))

(defun etaf-web--first-content-block (node)
  "Return the first substantive content block DOM node inside NODE, or nil."
  (cond
   ((stringp node)
    (unless (string-blank-p node) node))
   ((not (etaf-web--node-p node)) nil)
   ((etaf-web--footnote-container-p node) nil)
   ((etaf-web--callout-kind node) node)
   (t
    (pcase (dom-tag node)
      ((or 'div 'section 'article 'main 'header 'body 'html 'hgroup 'address 'fieldset)
       (cl-loop for child in (dom-children node)
                for found = (etaf-web--first-content-block child)
                when found return found))
      ('p
       (when (or (not (string-blank-p (etaf-web--plain-text node)))
                 (etaf-web--find-first node
                                       (lambda (n)
                                         (memq (dom-tag n) '(img picture)))))
         node))
      ((or 'h1 'h2 'h3 'h4 'h5 'h6)
       (unless (string-blank-p (etaf-web--plain-text node)) node))
      ((or 'hr 'figure 'details 'table 'pre 'ul 'ol 'dl 'blockquote) node)
      (_ (unless (string-blank-p (etaf-web--plain-text node)) node))))))

(defun etaf-web--leading-duplicate-h1 (main-node title)
  "Return MAIN-NODE's first content block if it is an `<h1>' matching TITLE."
  (when (and (stringp title) (not (string-empty-p title)))
    (let ((first (etaf-web--first-content-block main-node)))
      (when (and (etaf-web--node-p first)
                 (eq (dom-tag first) 'h1)
                 (etaf-web--heading-matches-title-p
                  (etaf-web--clean-text first) title))
        first))))

(defun etaf-web--heading-slug (text)
  "Return the anchor slug `etaf-md' generates for heading TEXT."
  (let ((slug (downcase (string-trim (or text "")))))
    (setq slug (replace-regexp-in-string "[^[:alnum:]\u4e00-\u9fff]+" "-" slug))
    (setq slug (replace-regexp-in-string "\\`-+\\|-+\\'" "" slug))
    (if (string-empty-p slug) "section" slug)))

(defun etaf-web--collect-heading-ids (main-node &optional skip-heading)
  "Map HTML heading `id' attributes under MAIN-NODE to `etaf-md' anchor slugs.
SKIP-HEADING, when non-nil, is omitted because it will not be emitted."
  (let ((table (make-hash-table :test #'equal))
        (seen (make-hash-table :test #'equal))
        (used (make-hash-table :test #'equal)))
    (dolist (node (etaf-web--find-all
                   main-node
                   (lambda (n) (memq (dom-tag n) '(h1 h2 h3 h4 h5 h6)))))
      (unless (eq node skip-heading)
        (let ((text (etaf-web--clean-text node)))
          (unless (string-empty-p text)
            (let* ((base (etaf-web--heading-slug text))
                   (count (1+ (or (gethash base seen) 0)))
                   (slug (if (= count 1) base (format "%s-%d" base count))))
              (while (gethash slug used)
                (setq count (1+ count)
                      slug (format "%s-%d" base count)))
              (puthash base count seen)
              (puthash slug t used)
              (when-let* ((id (etaf-web--attr node 'id))
                          ((not (string-empty-p id))))
                (puthash id slug table))
              (dolist (anchor (etaf-web--find-all
                               node (lambda (n) (eq (dom-tag n) 'a))))
                (when-let* ((aid (or (etaf-web--attr anchor 'id)
                                     (etaf-web--attr anchor 'name)))
                            ((not (string-empty-p aid))))
                  (puthash aid slug table))))))))
    table))

(defun etaf-web--register-footnote (ctx id)
  "Return the 1-based footnote number for ID in CTX, or nil if undefined."
  (when (and id (gethash id (etaf-web--ctx-fn-defs ctx)))
    (or (gethash id (etaf-web--ctx-fn-numbers ctx))
        (let ((num (1+ (hash-table-count (etaf-web--ctx-fn-numbers ctx)))))
          (puthash id num (etaf-web--ctx-fn-numbers ctx))
          (push id (etaf-web--ctx-fn-order ctx))
          num))))

(defun etaf-web--inline-code (raw)
  "Wrap RAW string in a CommonMark code span using longest-backtick + 1."
  (let ((text (replace-regexp-in-string "\r?\n" " " (or raw "")))
        (max-run 0)
        (pos 0))
    (while (string-match "`+" text pos)
      (setq max-run (max max-run (- (match-end 0) (match-beginning 0)))
            pos (match-end 0)))
    (let* ((fence (make-string (1+ max-run) ?`))
           (needs-pad (and (not (string-empty-p text))
                           (or (eq (aref text 0) ?`)
                               (eq (aref text (1- (length text))) ?`)
                               (and (eq (aref text 0) ?\s)
                                    (eq (aref text (1- (length text))) ?\s)
                                    (not (string-blank-p text)))))))
      (if needs-pad
          (concat fence " " text " " fence)
        (concat fence text fence)))))

(defun etaf-web--wrap-inline (marker text)
  "Wrap TEXT with MARKER keeping leading/trailing spaces outside MARKER."
  (if (or (null text) (string-blank-p text))
      ""
    (let* ((lead (if (string-match "\\`[ \t]+" text) (match-string 0 text) ""))
           (trail (if (string-match "[ \t]+\\'" text) (match-string 0 text) ""))
           (core (string-trim text)))
      (if (string-empty-p core)
          ""
        (concat lead marker core marker trail)))))

(defun etaf-web--escape-link-label (text)
  "Escape raw square brackets in link/image alt label TEXT."
  (replace-regexp-in-string
   "\\([][]\\)" "\\\\\\1" (or text "")))

(defun etaf-web--format-link-dest (url)
  "Format URL for Markdown `(...)' destination."
  (if (string-match-p "[ \t()<>]" url)
      (format "<%s>" (replace-regexp-in-string "[<>]" "" url))
    url))

(defconst etaf-web--lazy-img-attrs
  '(data-src data-original data-lazy-src data-actualsrc data-original-src data-url)
  "Ordered lazy-load image attributes checked before `src'.")

(defun etaf-web--valid-img-url (raw)
  "Return trimmed RAW when it is a non-empty, non-`data:', safe image URL."
  (when (stringp raw)
    (let ((trimmed (string-trim raw)))
      (when (and (not (string-empty-p trimmed))
                 (not (string-prefix-p "data:" (downcase trimmed)))
                 (not (etaf-web--dangerous-url-p trimmed)))
        trimmed))))

(defun etaf-web--parse-srcset-best (srcset)
  "Return the highest-width/density URL candidate from HTML SRCSET, or nil.
Handles width descriptors such as `url 1200w' and density descriptors `2x'
while tolerating commas inside URL query parameters."
  (when (and (stringp srcset) (not (string-blank-p srcset)))
    (let ((pos 0)
          (len (length srcset))
          (best-url nil)
          (best-kind nil) ; `w' > `x' > nil
          (best-val -1.0))
      (while (< pos len)
        ;; Skip leading whitespace and commas.
        (while (and (< pos len) (memq (aref srcset pos) '(?\s ?\t ?\n ?\r ?,)))
          (setq pos (1+ pos)))
        (when (< pos len)
          ;; Read URL token up to whitespace.
          (let ((start pos))
            (while (and (< pos len)
                        (not (memq (aref srcset pos) '(?\s ?\t ?\n ?\r))))
              (setq pos (1+ pos)))
            (let* ((token (substring srcset start pos))
                   (ends-comma (string-suffix-p "," token))
                   (url (if ends-comma (substring token 0 -1) token))
                   (kind nil)
                   (val 0.0))
              (unless ends-comma
                ;; Skip whitespace and inspect optional descriptor up to comma.
                (while (and (< pos len) (memq (aref srcset pos) '(?\s ?\t ?\n ?\r)))
                  (setq pos (1+ pos)))
                (let ((dstart pos))
                  (while (and (< pos len) (not (eq (aref srcset pos) ?,)))
                    (setq pos (1+ pos)))
                  (let ((desc (string-trim (substring srcset dstart pos))))
                    (cond
                     ((string-match "\\`\\([0-9]+\\(?:\\.[0-9]+\\)?\\)[wW]\\'" desc)
                      (setq kind 'w val (string-to-number (match-string 1 desc))))
                     ((string-match "\\`\\([0-9]+\\(?:\\.[0-9]+\\)?\\)[xX]\\'" desc)
                      (setq kind 'x val (string-to-number (match-string 1 desc)))))))
                (when (and (< pos len) (eq (aref srcset pos) ?,))
                  (setq pos (1+ pos))))
              (when (etaf-web--valid-img-url url)
                (let ((better
                       (cond
                        ((null best-url) t)
                        ((and (eq kind 'w) (not (eq best-kind 'w))) t)
                        ((and (eq kind best-kind) (> val best-val)) t)
                        ((and (eq kind 'x) (null best-kind) (> val 0.0)) t)
                        (t nil))))
                  (when better
                    (setq best-url url
                          best-kind kind
                          best-val val))))))))
      best-url)))

(defun etaf-web--img-raw-url (img-node)
  "Extract best raw image URL from `<img>' IMG-NODE using lazy-load priority."
  (when (etaf-web--node-p img-node)
    (or (cl-loop for attr in etaf-web--lazy-img-attrs
                 for val = (etaf-web--valid-img-url (etaf-web--attr img-node attr))
                 when val return val)
        (etaf-web--parse-srcset-best (etaf-web--attr img-node 'data-srcset))
        (etaf-web--parse-srcset-best (etaf-web--attr img-node 'srcset))
        (etaf-web--valid-img-url (etaf-web--attr img-node 'src)))))

(defun etaf-web--clean-image-alt (alt ctx)
  "Return ALT cleaned for Markdown, dropping overlong or title-duplicate text."
  (let ((clean (string-trim (etaf-web--collapse-ws (or alt ""))))
        (doc-title (and ctx (etaf-web--ctx-doc-title ctx))))
    (cond
     ((string-empty-p clean) "")
     ((> (length clean) 60) "")
     ((and doc-title
           (member clean (etaf-web--title-candidates doc-title)))
      "")
     (t clean))))

(defun etaf-web--decodable-source-p (source-node url)
  "Return non-nil when `<source>' node SOURCE-NODE with URL is decodable."
  (let* ((mime (downcase (string-trim (or (etaf-web--attr source-node 'type) ""))))
         (clean-url (car (split-string (or url "") "[?#]")))
         (ext (downcase (or (file-name-extension clean-url) ""))))
    (cond
     ((not (string-empty-p mime))
      (member mime etaf-web--decodable-image-types))
     ((not (string-empty-p ext))
      (member ext etaf-web--decodable-image-exts))
     (t t))))

(defun etaf-web--parse-css-px (raw)
  "Return positive integer pixel value parsed from HTML/CSS RAW, or nil.
Accepts numeric values (`\"52\"', `\"52px\"', `\"52.5px\"'); rejects percentages
and relative units (`%`, `em`, `rem`, `auto')."
  (when (and (stringp raw)
             (string-match "\\`[ \t]*\\([0-9]+\\(?:\\.[0-9]+\\)?\\)\\(?:px\\)?[ \t]*\\'"
                           (downcase raw)))
    (let ((num (round (string-to-number (match-string 1 raw)))))
      (when (> num 0) num))))

(defun etaf-web--style-prop-px (style prop)
  "Return positive pixel number for CSS PROP in inline STYLE string, or nil."
  (when (and (stringp style) (not (string-blank-p style)))
    (let ((case-fold-search t))
      (when (string-match
             (format "\\(?:\\`\\|[; \t]\\)%s[ \t]*:[ \t]*\\([^;!]+\\)" prop)
             style)
        (etaf-web--parse-css-px (match-string 1 style))))))

(defun etaf-web--extract-img-dims (img-node)
  "Return `(WIDTH . HEIGHT)' CSS pixel bounds declared on IMG-NODE.
Reads HTML `width'/`height' attributes and inline CSS `width'/`height'/
`max-width'/`max-height'.  When only `max-*' bounds are declared, returns a
single-axis cap so downstream layout preserves natural aspect ratio."
  (when (etaf-web--node-p img-node)
    (let* ((style (etaf-web--attr img-node 'style))
           (aw (etaf-web--parse-css-px (etaf-web--attr img-node 'width)))
           (ah (etaf-web--parse-css-px (etaf-web--attr img-node 'height)))
           (sw (etaf-web--style-prop-px style "width"))
           (sh (etaf-web--style-prop-px style "height"))
           (mw (etaf-web--style-prop-px style "max-width"))
           (mh (etaf-web--style-prop-px style "max-height"))
           (w (or sw aw))
           (h (or sh ah)))
      (when (and w mw) (setq w (min w mw)))
      (when (and h mh) (setq h (min h mh)))
      (cond
       ((or w h) (cons w h))
       (mw (cons mw nil))
       (mh (cons nil mh))
       (t (cons nil nil))))))

(defun etaf-web--html-escape-attr (value)
  "Escape VALUE for a double-quoted HTML attribute."
  (let ((s (replace-regexp-in-string "&" "&amp;" (or value ""))))
    (setq s (replace-regexp-in-string "\"" "&quot;" s))
    (setq s (replace-regexp-in-string "<" "&lt;" s))
    (replace-regexp-in-string ">" "&gt;" s)))

(defun etaf-web--format-block-img (info &optional alt-override)
  "Format image INFO plist as Markdown or sized HTML `<img>' block.
Emits `<img src=... alt=... width=... height=...>' when HTML declared a
bounded size (<= 480 px), so icons, avatars and Retina thumbnails render
at their page size instead of their larger intrinsic file dimensions."
  (let* ((url (plist-get info :url))
         (alt (if alt-override alt-override (or (plist-get info :alt) "")))
         (w (plist-get info :width))
         (h (plist-get info :height)))
    (if (or (and w (<= w 480)) (and h (<= h 480)))
        (concat "<img src=\"" (etaf-web--html-escape-attr url) "\""
                " alt=\"" (etaf-web--html-escape-attr alt) "\""
                (when w (format " width=\"%d\"" w))
                (when h (format " height=\"%d\"" h))
                ">")
      (format "![%s](%s)"
              (etaf-web--escape-link-label alt)
              (etaf-web--format-link-dest url)))))

(defun etaf-web--extract-img-info (node ctx)
  "Return plist `(:url :alt :width :height)' for `<img>'/`<picture>', or nil.
Drops tracking pixels (declared <= 4 px in width or height)."
  (let* ((img (if (eq (dom-tag node) 'picture)
                  (etaf-web--find-first node (lambda (n) (eq (dom-tag n) 'img)))
                node))
         (dims (etaf-web--extract-img-dims img))
         (w (car dims))
         (h (cdr dims)))
    (unless (or (and w (<= w 4)) (and h (<= h 4)))
      (let* ((raw-url
              (if (eq (dom-tag node) 'picture)
                  (or (cl-loop for child in (dom-children node)
                               when (and (etaf-web--node-p child)
                                         (eq (dom-tag child) 'source))
                               for candidate =
                               (or (etaf-web--parse-srcset-best
                                    (etaf-web--attr child 'data-srcset))
                                   (etaf-web--parse-srcset-best
                                    (etaf-web--attr child 'srcset))
                                   (cl-loop for attr in etaf-web--lazy-img-attrs
                                            for v = (etaf-web--valid-img-url
                                                     (etaf-web--attr child attr))
                                            when v return v)
                                   (etaf-web--valid-img-url
                                    (etaf-web--attr child 'src)))
                               when (and candidate
                                         (etaf-web--decodable-source-p child candidate))
                               return candidate)
                      (etaf-web--img-raw-url img))
                (etaf-web--img-raw-url node)))
             (resolved (and raw-url
                            (etaf-web--resolve-url raw-url (etaf-web--ctx-base-url ctx))))
             (final-url (if (and resolved (etaf-web--ctx-image-rewriter ctx))
                            (or (funcall (etaf-web--ctx-image-rewriter ctx) resolved)
                                resolved)
                          resolved))
             (alt (etaf-web--clean-image-alt
                   (or (and img (etaf-web--attr img 'alt))
                       (and img (etaf-web--attr img 'title))
                       "")
                   ctx)))
        (when final-url
          (list :url final-url :alt alt :width w :height h))))))

(defun etaf-web--footnote-ref-id (node)
  "Return referenced footnote anchor id if NODE is a footnote ref, else nil."
  (when (etaf-web--node-p node)
    (let* ((link (cond
                  ((eq (dom-tag node) 'a) node)
                  ((eq (dom-tag node) 'sup)
                   (let ((significant
                          (cl-remove-if
                           (lambda (c) (and (stringp c) (string-blank-p c)))
                           (dom-children node))))
                     (when (and (= 1 (length significant))
                                (etaf-web--node-p (car significant))
                                (eq (dom-tag (car significant)) 'a))
                       (car significant))))
                  (t nil)))
           (href (and link (string-trim (or (etaf-web--attr link 'href) "")))))
      (when (and href (string-prefix-p "#" href) (> (length href) 1))
        (let ((id (substring href 1)))
          (when (or (eq (dom-tag node) 'sup)
                    (equal (downcase (or (etaf-web--attr link 'role) ""))
                           "doc-noteref")
                    (cl-some (lambda (c) (string-match-p "footnote" c))
                             (etaf-web--class-list link)))
            id))))))

(defconst etaf-web--attaching-punct-regexp
  "\\`\\(?:[，。；：、！？）】》]\\|[],.;:!?)]\\(?:\\'\\|[^a-zA-Z0-9]\\)\\)"
  "Punctuation prefix that must not take a synthetic preceding space.")

(defun etaf-web--implicit-inline-sep-p (prev-node prev-piece node piece)
  "Return non-nil when minified siblings PREV-NODE and NODE need a space.
Applies only to directly adjacent hyperlinks (`<a><a>') or `<span>' siblings
with distinct non-empty CSS classes whose boundary is word-to-word."
  (when (and (etaf-web--node-p prev-node)
             (etaf-web--node-p node)
             (not (string-empty-p prev-piece))
             (not (string-empty-p piece))
             (not (string-match-p "[([“‘（【《]\\'" prev-piece))
             (not (string-match-p etaf-web--attaching-punct-regexp piece)))
    (let ((t1 (dom-tag prev-node))
          (t2 (dom-tag node)))
      (or (and (eq t1 'a) (eq t2 'a))
          (and (eq t1 'span) (eq t2 'span)
               (>= (length prev-piece) 2)
               (let ((c1 (etaf-web--class-list prev-node))
                     (c2 (etaf-web--class-list node)))
                 (and c1 c2 (not (equal c1 c2)))))))))

(defun etaf-web--cjk-char-p (ch)
  "Return non-nil when CH is a CJK ideograph."
  (and (stringp ch) (string-match-p "[\u3400-\u4dbf\u4e00-\u9fff\uf900-\ufaff]" ch)))

(defun etaf-web--latin-char-p (ch)
  "Return non-nil when CH is a Latin letter or a digit."
  (and (stringp ch) (string-match-p "[A-Za-z0-9]" ch)))

(defun etaf-web--cjk-boundary-space-p (left right)
  "Return non-nil when LEFT and RIGHT meet as scripts that need a space.
A Chinese character next to a Latin letter or digit takes one separating
space, including when the two live in different inline elements."
  (let ((l (and (stringp left) (> (length left) 0) (substring left -1)))
        (r (and (stringp right) (> (length right) 0) (substring right 0 1))))
    (or (and (etaf-web--cjk-char-p l) (etaf-web--latin-char-p r))
        (and (etaf-web--latin-char-p l) (etaf-web--cjk-char-p r)))))

(defun etaf-web--emit-inlines (nodes ctx)
  "Compile list of inline DOM NODES under CTX into a Markdown inline string.
Preserves single spaces across inter-sibling source whitespace (including
newlines and tabs), avoids adding space before punctuation or inside code
spans, keeps `<br>' hard breaks intact, and separates minified adjacent links
or distinctly classed spans."
  (let ((parts nil)
        (had-leading-ws nil)
        (pending-space nil)
        (after-break nil)
        (prev-node nil)
        (prev-piece nil))
    (cl-flet
        ((emit-piece (node piece lead-ws trail-ws)
           (when lead-ws
             (if parts
                 (setq pending-space t)
               (setq had-leading-ws t)))
           (unless (string-empty-p piece)
             (let* ((implicit (and (not pending-space)
                                   (not after-break)
                                   parts
                                   (etaf-web--implicit-inline-sep-p
                                    prev-node prev-piece node piece)))
                    (cjk (and (not pending-space)
                              (not after-break)
                              parts
                              (etaf-web--cjk-boundary-space-p prev-piece piece))))
               (when (and parts (not after-break)
                          (or (and pending-space
                                   (not (string-match-p
                                         etaf-web--attaching-punct-regexp
                                         piece)))
                              implicit cjk))
                 (push " " parts)))
             (push piece parts)
             (setq prev-node node
                   prev-piece piece
                   after-break (string-suffix-p "\n" piece)
                   pending-space nil))
           (when trail-ws
             (if parts
                 (setq pending-space t)
               (setq had-leading-ws t)))))
      (dolist (node nodes)
        (cond
         ((stringp node)
          (cond
           ((string-empty-p node) nil)
           ((string-blank-p node)
            (if parts
                (setq pending-space t)
              (setq had-leading-ws t)))
           (t
            (let* ((collapsed (etaf-web--collapse-ws node))
                   (lead-ws (string-prefix-p " " collapsed))
                   (trail-ws (string-suffix-p " " collapsed))
                   (core (string-trim collapsed " +" " +")))
              (emit-piece node core lead-ws trail-ws)))))
         ((not (etaf-web--node-p node)) nil)
         ((eq (dom-tag node) 'br)
          (setq pending-space nil)
          (cond
           ((and parts (equal (car parts) "\n\n")) nil)
           ((and parts (equal (car parts) "\\\n"))
            (setcar parts "\n\n")
            (setq prev-node node
                  prev-piece "\n\n"
                  after-break t))
           (t
            (push "\\\n" parts)
            (setq prev-node node
                  prev-piece "\\\n"
                  after-break t))))
         ((eq (dom-tag node) 'code)
          (let ((code (etaf-web--inline-code (etaf-web--plain-text node))))
            (emit-piece node code nil nil)))
         (t
          (let ((raw (etaf-web--emit-inline node ctx)))
            (unless (string-empty-p raw)
              (let* ((lead-ws (string-match-p "\\`[ \t]" raw))
                     (trail-ws (string-match-p "[ \t]\\'" raw))
                     (core (string-trim raw "[ \t]+" "[ \t]+")))
                (emit-piece node core lead-ws trail-ws))))))))
    (let ((joined (mapconcat #'identity (nreverse parts) "")))
      (cond
       ((string-empty-p joined)
        (if (or had-leading-ws pending-space) " " ""))
       (t
        (concat (if had-leading-ws " " "")
                (replace-regexp-in-string "[ \t]+\n" "\n" joined)
                (if (and pending-space (not after-break)) " " "")))))))

(defun etaf-web--emit-inline (node ctx)
  "Compile a single inline DOM NODE under CTX into Markdown text."
  (cond
   ((stringp node)
    (etaf-web--collapse-ws node))
   ((not (etaf-web--node-p node)) "")
   (t
    (pcase (dom-tag node)
      ('br "\\\n")
      ((or 'em 'i)
       (etaf-web--wrap-inline "*" (etaf-web--emit-inlines (dom-children node) ctx)))
      ((or 'strong 'b)
       (etaf-web--wrap-inline "**" (etaf-web--emit-inlines (dom-children node) ctx)))
      ((or 'del 's 'strike)
       (etaf-web--wrap-inline "~~" (etaf-web--emit-inlines (dom-children node) ctx)))
      ('mark
       (etaf-web--wrap-inline "==" (etaf-web--emit-inlines (dom-children node) ctx)))
      ('code
       (etaf-web--inline-code (etaf-web--plain-text node)))
      ('kbd
       (let ((label (etaf-web--clean-text node)))
         (cond
          ((string-empty-p label) "")
          ((string-match-p "[][]" label) (etaf-web--inline-code label))
          (t (format ":kbd[%s]"
                     (replace-regexp-in-string "[ \t]*\\+[ \t]*" "+" label))))))
      ('sub
       (etaf-web--wrap-inline "~" (etaf-web--emit-inlines (dom-children node) ctx)))
      ('sup
       (let* ((fn-id (etaf-web--footnote-ref-id node))
              (fn-num (and fn-id (etaf-web--register-footnote ctx fn-id))))
         (if fn-num
             (format "[^%d]" fn-num)
           (etaf-web--wrap-inline
            "^" (etaf-web--emit-inlines (dom-children node) ctx)))))
      ('a
       (let* ((fn-id (etaf-web--footnote-ref-id node))
              (fn-num (and fn-id (etaf-web--register-footnote ctx fn-id))))
         (if fn-num
             (format "[^%d]" fn-num)
           (let* ((raw-href (etaf-web--attr node 'href))
                  (href (etaf-web--resolve-url raw-href (etaf-web--ctx-base-url ctx)))
                  (href (if (and href (string-prefix-p "#" href))
                            (if-let* ((mapped (and (etaf-web--ctx-heading-ids ctx)
                                                   (gethash (substring href 1)
                                                            (etaf-web--ctx-heading-ids ctx)))))
                                (concat "#" mapped)
                              href)
                          href))
                  (sole-img (etaf-web--sole-media-child node)))
             (if (and sole-img
                      (or (assq 'data-lightbox (dom-attributes node))
                          (let ((raw-img (etaf-web--img-raw-url
                                          (if (eq (dom-tag sole-img) 'picture)
                                              (etaf-web--find-first
                                               sole-img (lambda (n) (eq (dom-tag n) 'img)))
                                            sole-img))))
                            (and raw-img href
                                 (equal href (etaf-web--resolve-url
                                              raw-img (etaf-web--ctx-base-url ctx)))))))
                 (etaf-web--emit-inline sole-img ctx)
               (let* ((raw-body (etaf-web--emit-inlines (dom-children node) ctx))
                      (lead (if (string-match "\\`[ \t]+" raw-body)
                                (match-string 0 raw-body) ""))
                      (trail (if (string-match "[ \t]+\\'" raw-body)
                                 (match-string 0 raw-body) ""))
                      (body (string-trim raw-body)))
                 (cond
                  ((and raw-href (etaf-web--dangerous-url-p raw-href)) "")
                  ((null href) raw-body)
                  ((string-empty-p body)
                   (let ((title (string-trim (or (etaf-web--attr node 'title) ""))))
                     (if (string-empty-p title)
                         ""
                       (concat lead
                               (format "[%s](%s)"
                                       (etaf-web--escape-link-label title)
                                       (etaf-web--format-link-dest href))
                               trail))))
                  (t (concat lead
                             (format "[%s](%s)"
                                     body
                                     (etaf-web--format-link-dest href))
                             trail)))))))))
      ((or 'img 'picture)
       (if-let* ((info (etaf-web--extract-img-info node ctx)))
           (let ((alt (plist-get info :alt))
                 (w (plist-get info :width))
                 (h (plist-get info :height)))
             ;; Drop tiny empty-alt inline decorative icons (<= 32px).
             (if (and (string-empty-p alt) w h (<= w 32) (<= h 32))
                 ""
               (format "![%s](%s)"
                       (etaf-web--escape-link-label alt)
                       (etaf-web--format-link-dest (plist-get info :url)))))
         ""))
      ('input
       ;; Task checkboxes are consumed by `li'; ignore standalone inputs.
       "")
      (_ (etaf-web--emit-inlines (dom-children node) ctx))))))

;;; ---------------------------------------------------------------------------
;;; Block emission: code, tables, lists, dl, details, callouts, figures
;;; ---------------------------------------------------------------------------

(defun etaf-web--code-language (pre-node code-node)
  "Return language tag for PRE-NODE / CODE-NODE, defaulting to \"text\"."
  (let ((found nil))
    (dolist (node (delq nil (list code-node pre-node)))
      (unless found
        (let ((data-lang (or (etaf-web--attr node 'data-lang)
                             (etaf-web--attr node 'data-language))))
          (when (and data-lang (not (string-blank-p data-lang)))
            (setq found (string-trim data-lang))))
        (unless found
          (dolist (cls (etaf-web--class-list node))
            (when (and (not found)
                       (string-match
                        "\\`\\(?:language-\\|lang-\\|highlight-source-\\|brush:\\)\\([a-z0-9_+#.-]+\\)\\'"
                        cls))
              (setq found (match-string 1 cls)))))))
    (if (and found (not (string-empty-p found))) found "text")))

(defun etaf-web--raw-code-text (node)
  "Extract literal text from code/pre DOM NODE preserving indentation."
  (cond
   ((stringp node) node)
   ((not (etaf-web--node-p node)) "")
   ((eq (dom-tag node) 'br) "\n")
   (t (mapconcat #'etaf-web--raw-code-text (dom-children node) ""))))

(defun etaf-web--emit-code-block (pre-node)
  "Emit a fenced code block for `<pre>' DOM PRE-NODE."
  (let* ((code-node (etaf-web--find-first
                     pre-node (lambda (n) (eq (dom-tag n) 'code))))
         (lang (etaf-web--code-language pre-node code-node))
         (raw (replace-regexp-in-string
               "\r\n?" "\n"
               (etaf-web--raw-code-text (or code-node pre-node))))
         ;; Trim a single leading/trailing newline from pretty-printed HTML.
         (body (replace-regexp-in-string "\\`\n\\|\n\\'" "" raw))
         (max-run 2)
         (pos 0))
    (while (string-match "`+" body pos)
      (setq max-run (max max-run (- (match-end 0) (match-beginning 0)))
            pos (match-end 0)))
    (let ((fence (make-string (max 3 (1+ max-run)) ?`)))
      (if (string-blank-p body)
          ""
        (format "%s%s\n%s\n%s" fence lang body fence)))))

(defun etaf-web--collect-cell-parts (cell-node ctx)
  "Collect flattened inline text fragments from table CELL-NODE under CTX."
  (let ((parts nil)
        (inline-buf nil))
    (cl-labels
        ((flush-inlines ()
           (when inline-buf
             (let* ((text (etaf-web--emit-inlines (nreverse inline-buf) ctx))
                    (segs (split-string text "\\\\\n\\|\n" t)))
               (dolist (s segs)
                 (let ((clean (string-trim (etaf-web--collapse-ws s))))
                   (unless (string-empty-p clean)
                     (push clean parts)))))
             (setq inline-buf nil)))
         (collect (children)
           (dolist (child children)
             (cond
              ((and (etaf-web--node-p child)
                    (memq (dom-tag child) '(ul ol)))
               (flush-inlines)
               (dolist (li (dom-children child))
                 (when (and (etaf-web--node-p li) (eq (dom-tag li) 'li))
                   (dolist (p (etaf-web--collect-cell-parts li ctx))
                     (push p parts)))))
              ((and (etaf-web--node-p child)
                    (memq (dom-tag child) etaf-web--block-tags))
               (flush-inlines)
               (dolist (p (etaf-web--collect-cell-parts child ctx))
                 (push p parts)))
              (t (push child inline-buf))))))
      (collect (dom-children cell-node))
      (flush-inlines))
    (nreverse parts)))

(defun etaf-web--compile-table-cell (cell-node ctx)
  "Compile table CELL-NODE to a single pipe-escaped GFM table cell string.
Multiple block children or hard breaks are joined with \"；\"."
  (let ((joined (mapconcat #'identity
                           (etaf-web--collect-cell-parts cell-node ctx)
                           "；")))
    (string-replace "|" "\\|"
                    (string-trim (etaf-web--collapse-ws joined)))))

(defun etaf-web--table-rows (table-node)
  "Return ordered list of `<tr>' DOM nodes inside TABLE-NODE."
  (let ((thead-rows nil)
        (body-rows nil)
        (tfoot-rows nil))
    (dolist (child (dom-children table-node))
      (when (etaf-web--node-p child)
        (pcase (dom-tag child)
          ('thead
           (dolist (tr (dom-children child))
             (when (and (etaf-web--node-p tr) (eq (dom-tag tr) 'tr))
               (push tr thead-rows))))
          ('tbody
           (dolist (tr (dom-children child))
             (when (and (etaf-web--node-p tr) (eq (dom-tag tr) 'tr))
               (push tr body-rows))))
          ('tfoot
           (dolist (tr (dom-children child))
             (when (and (etaf-web--node-p tr) (eq (dom-tag tr) 'tr))
               (push tr tfoot-rows))))
          ('tr (push child body-rows)))))
    (append (nreverse thead-rows) (nreverse body-rows) (nreverse tfoot-rows))))

(defun etaf-web--layout-table-p (table-node trs)
  "Return non-nil when HTML `<table>' TABLE-NODE is a layout container.
Treats `role=presentation|none', tables nesting another `<table>', 1-column
tables without `<th>', single-row headerless tables, and headerless tables
containing long essays or block structures (`<pre>', `<blockquote>', `h1'-`h3')
as layout wrappers rather than GFM data tables."
  (let* ((role (downcase (string-trim (or (etaf-web--attr table-node 'role) ""))))
         (has-thead (cl-some (lambda (c)
                               (and (etaf-web--node-p c) (eq (dom-tag c) 'thead)))
                             (dom-children table-node)))
         (has-th nil)
         (has-nested-table nil)
         (has-prose-block nil)
         (max-cols 0)
         (max-cell-len 0))
    (dolist (tr trs)
      (let ((cols 0))
        (dolist (cell (dom-children tr))
          (when (and (etaf-web--node-p cell) (memq (dom-tag cell) '(th td)))
            (when (eq (dom-tag cell) 'th) (setq has-th t))
            (setq cols (+ cols (max 1 (string-to-number
                                       (or (etaf-web--attr cell 'colspan) "1")))))
            (setq max-cell-len (max max-cell-len
                                    (length (etaf-web--clean-text cell))))
            (when (etaf-web--find-first
                   cell (lambda (n) (and (not (eq n cell))
                                         (eq (dom-tag n) 'table))))
              (setq has-nested-table t))
            (when (etaf-web--find-first
                   cell (lambda (n) (memq (dom-tag n) '(pre blockquote h1 h2 h3))))
              (setq has-prose-block t))))
        (setq max-cols (max max-cols cols))))
    (or (member role '("presentation" "none"))
        has-nested-table
        (and (<= max-cols 1) (not has-th))
        (and (not has-th) (not has-thead)
             (or (<= (length trs) 1)
                 (> max-cell-len 400)
                 has-prose-block)))))

(defun etaf-web--emit-layout-table (trs ctx)
  "Emit rows TRS of a layout `<table>' as regular Markdown blocks under CTX."
  (let ((blocks nil))
    (dolist (tr trs)
      (let ((row-parts nil)
            (has-block nil))
        (dolist (cell (dom-children tr))
          (when (and (etaf-web--node-p cell) (memq (dom-tag cell) '(th td)))
            (let ((rendered (etaf-web--emit-children-blocks
                             (dom-children cell) ctx)))
              (unless (string-empty-p rendered)
                (when (or (string-match-p "\n" rendered)
                          (> (length rendered) 120))
                  (setq has-block t))
                (push rendered row-parts)))))
        (setq row-parts (nreverse row-parts))
        (when row-parts
          (push (mapconcat #'identity row-parts (if has-block "\n\n" " "))
                blocks))))
    (mapconcat #'identity (nreverse blocks) "\n\n")))

(defun etaf-web--emit-table (table-node ctx)
  "Compile HTML `<table>' TABLE-NODE into a GFM pipe table under CTX.
Layout tables are unwrapped into normal Markdown blocks; data tables expand
`colspan' and `rowspan' by repeating the cell value."
  (let* ((trs (etaf-web--table-rows table-node))
         (row-count (length trs)))
    (cond
     ((<= row-count 0) nil)
     ((etaf-web--layout-table-p table-node trs)
      (etaf-web--emit-layout-table trs ctx))
     (t
      (let ((grid (make-hash-table :test #'equal))
            (aligns (make-hash-table :test #'eql))
            (max-cols 0))
        (cl-loop
         for tr in trs
         for r from 0
         do
         (let ((c 0))
           (dolist (cell (dom-children tr))
             (when (and (etaf-web--node-p cell) (memq (dom-tag cell) '(th td)))
               (while (gethash (cons r c) grid)
                 (setq c (1+ c)))
               (let* ((colspan (max 1 (min 32 (string-to-number
                                               (or (etaf-web--attr cell 'colspan) "1")))))
                      (rowspan (max 1 (min 64 (string-to-number
                                               (or (etaf-web--attr cell 'rowspan) "1")))))
                      (text (etaf-web--compile-table-cell cell ctx))
                      (align (downcase (string-trim (or (etaf-web--attr cell 'align) "")))))
                 (dotimes (dr rowspan)
                   (dotimes (dc colspan)
                     (puthash (cons (+ r dr) (+ c dc)) text grid)))
                 (when (member align '("left" "center" "right"))
                   (dotimes (dc colspan)
                     (unless (gethash (+ c dc) aligns)
                       (puthash (+ c dc) align aligns))))
                 (setq c (+ c colspan)
                       max-cols (max max-cols c)))))))
        (when (> max-cols 0)
          (let* ((total-rows
                  (1+ (cl-loop for key being the hash-keys of grid
                               maximize (car key))))
                 (format-row
                  (lambda (r)
                    (concat "| "
                            (mapconcat
                             (lambda (c) (or (gethash (cons r c) grid) ""))
                             (number-sequence 0 (1- max-cols))
                             " | ")
                            " |")))
                 (sep-row
                  (concat "| "
                          (mapconcat
                           (lambda (c)
                             (pcase (gethash c aligns)
                               ("left" ":---")
                               ("center" ":---:")
                               ("right" "---:")
                               (_ "---")))
                           (number-sequence 0 (1- max-cols))
                           " | ")
                          " |"))
                 (lines (list (funcall format-row 0) sep-row)))
            (cl-loop for r from 1 below total-rows
                     do (setq lines (append lines (list (funcall format-row r)))))
            (mapconcat #'identity lines "\n"))))))))

(defun etaf-web--extract-checkbox (children)
  "Check if list item CHILDREN begin with a checkbox `<input>'.
Return `(STATE . REST-CHILDREN)' where STATE is `checked', `unchecked' or nil."
  (let ((trimmed (cl-member-if-not
                  (lambda (c) (and (stringp c) (string-blank-p c)))
                  children)))
    (cond
     ((and trimmed
           (etaf-web--node-p (car trimmed))
           (eq (dom-tag (car trimmed)) 'input)
           (equal (downcase (or (etaf-web--attr (car trimmed) 'type) ""))
                  "checkbox"))
      (cons (if (assq 'checked (dom-attributes (car trimmed)))
                'checked
              'unchecked)
            (cdr trimmed)))
     ((and trimmed
           (etaf-web--node-p (car trimmed))
           (eq (dom-tag (car trimmed)) 'p))
      (let ((inner (etaf-web--extract-checkbox (dom-children (car trimmed)))))
        (if (car inner)
            (cons (car inner)
                  (cons (cons 'p (cons (dom-attributes (car trimmed))
                                       (cdr inner)))
                        (cdr trimmed)))
          (cons nil children))))
     (t (cons nil children)))))

(defun etaf-web--emit-list-item (li-node marker depth ctx)
  "Emit one `<li>' node at nesting DEPTH with MARKER string under CTX."
  (let* ((indent (make-string (* 2 depth) ?\s))
         (check (etaf-web--extract-checkbox (dom-children li-node)))
         (checkbox (pcase (car check)
                     ('checked "[x] ")
                     ('unchecked "[ ] ")
                     (_ "")))
         (children (cdr check))
         (inline-buf nil)
         (blocks nil))
    (cl-labels
        ((flush-inlines ()
           (when inline-buf
             (let ((s (string-trim (etaf-web--emit-inlines (nreverse inline-buf) ctx))))
               (unless (string-empty-p s)
                 (push (cons 'text s) blocks)))
             (setq inline-buf nil))))
      (dolist (child children)
        (cond
         ((and (etaf-web--node-p child) (memq (dom-tag child) '(ul ol)))
          (flush-inlines)
          (let ((sub (etaf-web--emit-list child (1+ depth) ctx)))
            (unless (string-empty-p sub)
              (push (cons 'list sub) blocks))))
         ((and (etaf-web--node-p child) (memq (dom-tag child) etaf-web--block-tags))
          (flush-inlines)
          (let ((blk (etaf-web--emit-block child ctx)))
            (unless (string-empty-p blk)
              (push (cons 'block blk) blocks))))
         (t (push child inline-buf))))
      (flush-inlines))
    (setq blocks (nreverse blocks))
    (when blocks
      (let* ((prefix (concat indent marker checkbox))
             (cont-indent (make-string (+ (* 2 depth) (length marker)) ?\s))
             (first (car blocks))
             (rest (cdr blocks))
             (lines nil))
        (if (eq (car first) 'list)
            (progn
              (push (string-trim-right prefix) lines)
              (push (cdr first) lines))
          (let ((first-lines (split-string (cdr first) "\n")))
            (push (concat prefix (car first-lines)) lines)
            (dolist (l (cdr first-lines))
              (push (if (string-empty-p l) "" (concat cont-indent l)) lines))))
        (dolist (blk rest)
          (if (eq (car blk) 'list)
              (push (cdr blk) lines)
            (push "" lines)
            (dolist (l (split-string (cdr blk) "\n"))
              (push (if (string-empty-p l) "" (concat cont-indent l)) lines))))
        (mapconcat #'identity (nreverse lines) "\n")))))

(defun etaf-web--emit-list (list-node depth ctx)
  "Emit `<ul>' or `<ol>' LIST-NODE at nesting DEPTH under CTX."
  (let* ((ordered (eq (dom-tag list-node) 'ol))
         (start (if ordered
                    (max 1 (string-to-number
                            (or (etaf-web--attr list-node 'start) "1")))
                  1))
         (index start)
         (items nil))
    (dolist (child (dom-children list-node))
      (when (and (etaf-web--node-p child) (eq (dom-tag child) 'li))
        (let* ((marker (if ordered (format "%d. " index) "- "))
               (rendered (etaf-web--emit-list-item child marker depth ctx)))
          (when (and rendered (not (string-empty-p rendered)))
            (push rendered items)
            (when ordered (setq index (1+ index)))))))
    (mapconcat #'identity (nreverse items) "\n")))

(defun etaf-web--emit-dl (dl-node ctx)
  "Emit `<dl>' DL-NODE as an etaf-dialect definition list under CTX."
  (let ((entries nil)
        (current-term nil)
        (current-defs nil))
    (cl-flet ((flush-entry ()
                (when (and current-term current-defs)
                  (push (concat current-term "\n"
                                (mapconcat #'identity (nreverse current-defs) "\n"))
                        entries))
                (setq current-term nil current-defs nil)))
      (dolist (child (dom-children dl-node))
        (when (etaf-web--node-p child)
          (pcase (dom-tag child)
            ('dt
             (when current-defs (flush-entry))
             (let ((term (string-trim
                          (etaf-web--collapse-ws
                           (etaf-web--emit-inlines (dom-children child) ctx)))))
               (unless (string-empty-p term)
                 (setq current-term term))))
            ('dd
             (let ((body (etaf-web--emit-children-blocks (dom-children child) ctx)))
               (unless (string-empty-p body)
                 (let ((lines (split-string body "\n")))
                   (push (mapconcat
                          #'identity
                          (cons (concat ": " (car lines))
                                (mapcar (lambda (l)
                                          (if (string-empty-p l) "" (concat "  " l)))
                                        (cdr lines)))
                          "\n")
                         current-defs)))))
            ('div
             ;; HTML5 allows `<div>` wrappers around `<dt>`/`<dd>` groups.
             (let ((sub (etaf-web--emit-dl child ctx)))
               (unless (string-empty-p sub)
                 (flush-entry)
                 (push sub entries)))))))
      (flush-entry))
    (mapconcat #'identity (nreverse entries) "\n\n")))

(defun etaf-web--sanitize-attr-value (text)
  "Prepare TEXT for a double-quoted `:::' container attribute value."
  (string-trim
   (replace-regexp-in-string
    "\"" "'"
    (etaf-web--collapse-ws (or text "")))))

(defun etaf-web--emit-details (node ctx)
  "Emit `<details>' DOM NODE as a `:::details' container under CTX."
  (let* ((open-p (and (assq 'open (dom-attributes node))
                      (not (equal (downcase (or (etaf-web--attr node 'open) ""))
                                  "false"))))
         (summary-node nil)
         (rest-children nil))
    (dolist (child (dom-children node))
      (if (and (null summary-node)
               (etaf-web--node-p child)
               (eq (dom-tag child) 'summary))
          (setq summary-node child)
        (push child rest-children)))
    (let* ((title (and summary-node
                       (etaf-web--sanitize-attr-value
                        (etaf-web--clean-text summary-node))))
           (body (etaf-web--emit-children-blocks (nreverse rest-children) ctx))
           (attrs (concat (when (and title (not (string-empty-p title)))
                            (format "title=\"%s\" " title))
                          (format "open=%s" (if open-p "true" "false")))))
      (if (string-empty-p body)
          (format ":::details {%s}\n:::" attrs)
        (format ":::details {%s}\n%s\n:::" attrs body)))))

(defun etaf-web--callout-title-node-p (node)
  "Return non-nil when DOM NODE is an explicit title inside a callout."
  (when (etaf-web--node-p node)
    (let ((classes (etaf-web--class-list node)))
      (or (cl-some (lambda (c)
                     (string-match-p "title\\|heading\\|header\\|label" c))
                   classes)
          (memq (dom-tag node) '(h3 h4 h5 h6))))))

(defun etaf-web--emit-callout (node kind ctx)
  "Emit DOM NODE as a `:::KIND' callout container under CTX."
  (let* ((children (cl-remove-if
                    (lambda (c) (and (stringp c) (string-blank-p c)))
                    (dom-children node)))
         (first (car children))
         (title nil)
         (body-nodes children))
    (when (and first (etaf-web--callout-title-node-p first) (> (length children) 1))
      (setq title (etaf-web--sanitize-attr-value (etaf-web--clean-text first))
            body-nodes (cdr children)))
    (let ((body (etaf-web--emit-children-blocks body-nodes ctx)))
      (unless (string-empty-p body)
        (if (and title (not (string-empty-p title)))
            (format ":::%s {title=\"%s\"}\n%s\n:::" kind title body)
          (format ":::%s\n%s\n:::" kind body))))))

(defun etaf-web--emit-figure (node ctx)
  "Emit `<figure>' DOM NODE.
For an image figure with `<figcaption>', uses the caption's plain text as the
image alt text without emitting an extra caption paragraph."
  (let ((caption-node nil)
        (content-nodes nil))
    (dolist (child (dom-children node))
      (if (and (etaf-web--node-p child) (eq (dom-tag child) 'figcaption))
          (setq caption-node child)
        (push child content-nodes)))
    (setq content-nodes (nreverse content-nodes))
    (let* ((caption-text (and caption-node (etaf-web--clean-text caption-node)))
           (has-caption (and caption-text (not (string-empty-p caption-text))))
           (media-node (cl-find-if
                        (lambda (n)
                          (and (etaf-web--node-p n)
                               (memq (dom-tag n) '(img picture))))
                        content-nodes))
           (nested-img (or media-node
                           (etaf-web--find-first
                            node (lambda (n) (memq (dom-tag n) '(picture img))))))
           (is-img-figure (and nested-img
                               (not (etaf-web--find-first
                                     node (lambda (n) (memq (dom-tag n) '(pre table))))))))
      (if is-img-figure
          (when-let* ((info (etaf-web--extract-img-info nested-img ctx)))
            (etaf-web--format-block-img info (when has-caption caption-text)))
        (let ((parts nil)
              (rendered (etaf-web--emit-children-blocks content-nodes ctx)))
          (unless (string-empty-p rendered)
            (push rendered parts))
          (when has-caption
            (let ((inline-cap (string-trim
                               (etaf-web--emit-inlines (dom-children caption-node) ctx))))
              (unless (string-empty-p inline-cap)
                (push (etaf-web--wrap-inline "*" inline-cap) parts))))
          (mapconcat #'identity (nreverse parts) "\n\n"))))))

(defun etaf-web--emit-blockquote (node ctx)
  "Emit `<blockquote>' DOM NODE under CTX."
  (let ((body (etaf-web--emit-children-blocks (dom-children node) ctx)))
    (unless (string-empty-p body)
      (mapconcat (lambda (line)
                   (if (string-empty-p line) ">" (concat "> " line)))
                 (split-string body "\n")
                 "\n"))))

;;; ---------------------------------------------------------------------------
;;; Layout-aware containers: card grids, tabs, steps and timelines
;;; ---------------------------------------------------------------------------

(defun etaf-web--heading-link-href (node ctx)
  "Return resolved href when heading/title NODE is or wraps a primary link."
  (when (etaf-web--node-p node)
    (let ((link (if (eq (dom-tag node) 'a)
                    node
                  (etaf-web--find-first node (lambda (n) (eq (dom-tag n) 'a))))))
      (when link
        (let ((href (etaf-web--resolve-url
                     (etaf-web--attr link 'href)
                     (etaf-web--ctx-base-url ctx))))
          (when (and href (not (string-empty-p href)))
            href))))))

(defun etaf-web--strip-leading-separator (nodes)
  "Strip a leading punctuation separator (`:', `：', `-', `—') from NODES."
  (if (and nodes (stringp (car nodes)))
      (let ((rest (replace-regexp-in-string
                   "\\`[ \t\n\r]*[:：—–-][ \t\n\r]*" "" (car nodes))))
        (if (string-empty-p rest)
            (cdr nodes)
          (cons rest (cdr nodes))))
    nodes))

(defun etaf-web--strip-trailing-colon (text)
  "Trim whitespace and trailing colon from title TEXT."
  (string-trim
   (replace-regexp-in-string "[ \t]*[:：]+\\'" "" (or text ""))))

(defun etaf-web--extract-strong-title-from-p (p-node ctx)
  "If P-NODE starts with `<strong>' or `<b>', return `(TITLE HREF REST-P)'.
REST-P is nil when P-NODE held only the bold title, or a `<p>' node holding
the remaining inline children."
  (let* ((sig (etaf-web--significant-children p-node))
         (first (car sig)))
    (when (and first (etaf-web--node-p first))
      (let* ((is-bold (memq (dom-tag first) '(strong b)))
             (link-bold (and (eq (dom-tag first) 'a)
                             (let ((inner (etaf-web--significant-children first)))
                               (and (= (length inner) 1)
                                    (etaf-web--node-p (car inner))
                                    (memq (dom-tag (car inner)) '(strong b)))))))
        (when (or is-bold link-bold)
          (let ((title (etaf-web--strip-trailing-colon
                        (etaf-web--clean-text first)))
                (href (etaf-web--heading-link-href first ctx))
                (rem (etaf-web--strip-leading-separator (cdr sig))))
            (when (and (not (string-empty-p title)) (<= (length title) 80))
              (list title href
                    (when rem
                      (cons 'p (cons (dom-attributes p-node) rem)))))))))))

(defun etaf-web--extract-title-and-body (children ctx &optional allow-first-link)
  "Extract `(TITLE HREF BODY-NODES)' from CHILDREN under CTX, or nil.
Checks `h2'–`h4' headings, leading `strong'/`b' elements or bold-led `<p>',
and (when ALLOW-FIRST-LINK is non-nil) a leading `<a>' title link."
  (let ((sig (cl-remove-if (lambda (c) (and (stringp c) (string-blank-p c)))
                           children))
        (title nil)
        (href nil)
        (body nil))
    ;; 1. Direct h2..h4 heading (or wrapped in a single `<a>' or `<header>').
    (let ((head-idx
           (cl-position-if
            (lambda (c)
              (and (etaf-web--node-p c)
                   (or (memq (dom-tag c) '(h2 h3 h4))
                       (and (eq (dom-tag c) 'a)
                            (let ((in (etaf-web--significant-children c)))
                              (and (= (length in) 1)
                                   (etaf-web--node-p (car in))
                                   (memq (dom-tag (car in)) '(h2 h3 h4))))))))
            sig)))
      (when head-idx
        (let ((hnode (nth head-idx sig)))
          (setq title (etaf-web--clean-text hnode)
                href (etaf-web--heading-link-href hnode ctx)
                body (append (cl-subseq sig 0 head-idx)
                             (cl-subseq sig (1+ head-idx)))))))
    ;; 2. Heading nested inside a direct `<header>' child.
    (when (and (null title) sig)
      (let ((hdr-idx (cl-position-if
                      (lambda (c)
                        (and (etaf-web--node-p c)
                             (eq (dom-tag c) 'header)
                             (etaf-web--find-first
                              c (lambda (n) (memq (dom-tag n) '(h2 h3 h4))))))
                      sig)))
        (when hdr-idx
          (let* ((hdr (nth hdr-idx sig))
                 (inner (etaf-web--extract-title-and-body
                         (dom-children hdr) ctx nil)))
            (when inner
              (setq title (nth 0 inner)
                    href (nth 1 inner)
                    body (append (cl-subseq sig 0 hdr-idx)
                                 (nth 2 inner)
                                 (cl-subseq sig (1+ hdr-idx)))))))))
    ;; 3. Leading `<strong>' / `<b>' or `<p><strong>...</strong>...</p>'.
    (when (and (null title) sig (etaf-web--node-p (car sig)))
      (let ((first (car sig)))
        (cond
         ((or (memq (dom-tag first) '(strong b))
              (and (eq (dom-tag first) 'a)
                   (let ((in (etaf-web--significant-children first)))
                     (and (= (length in) 1)
                          (etaf-web--node-p (car in))
                          (memq (dom-tag (car in)) '(strong b))))))
          (let ((cand (etaf-web--strip-trailing-colon (etaf-web--clean-text first))))
            (when (and (not (string-empty-p cand)) (<= (length cand) 80))
              (setq title cand
                    href (etaf-web--heading-link-href first ctx)
                    body (etaf-web--strip-leading-separator (cdr sig))))))
         ((eq (dom-tag first) 'p)
          (when-let* ((res (etaf-web--extract-strong-title-from-p first ctx)))
            (setq title (nth 0 res)
                  href (nth 1 res)
                  body (if (nth 2 res)
                           (cons (nth 2 res) (cdr sig))
                         (cdr sig))))))))
    ;; 4. Leading `<a>' title link (e.g. `<figcaption><a href="...">name</a><span>desc</span></figcaption>').
    (when (and (null title) allow-first-link sig (etaf-web--node-p (car sig))
               (eq (dom-tag (car sig)) 'a)
               (not (etaf-web--sole-media-child (car sig))))
      (let ((cand (etaf-web--clean-text (car sig))))
        (when (and (not (string-empty-p cand)) (<= (length cand) 80))
          (setq title cand
                href (etaf-web--heading-link-href (car sig) ctx)
                body (cdr sig)))))
    (when (and title (not (string-empty-p (etaf-web--sanitize-attr-value title))))
      (list (etaf-web--sanitize-attr-value title) href body))))

(defun etaf-web--card-disqualified-p (item)
  "Return non-nil when ITEM contains block structures unsuitable for a card."
  (or (not (etaf-web--node-p item))
      (etaf-web--find-first
       item (lambda (n)
              (or (memq (dom-tag n) '(pre table h1))
                  (etaf-web--tablist-node-p n)
                  (etaf-web--steps-class-p n)
                  (etaf-web--timeline-class-p n))))))

(defun etaf-web--strip-card-leading-ordinal (body)
  "Drop a leading 1-3 digit decorative ordinal paragraph from card BODY."
  (if (not (stringp body))
      ""
    (let ((parts (split-string body "\n\n")))
      (if (and parts
               (string-match-p "\\`[0-9]\\{1,3\\}\\'"
                               (string-trim (car parts))))
          (mapconcat #'identity (cdr parts) "\n\n")
        body))))

(defun etaf-web--extract-figure-card (fig-node ctx)
  "Extract card plist `(:title T :href H :body B :plain-len N)' from FIG-NODE."
  (let* ((caption (cl-find-if (lambda (c)
                                (and (etaf-web--node-p c)
                                     (eq (dom-tag c) 'figcaption)))
                              (dom-children fig-node)))
         (media (etaf-web--find-first
                 fig-node (lambda (n) (memq (dom-tag n) '(picture img)))))
         (cap-res (and caption
                       (etaf-web--extract-title-and-body
                        (dom-children caption) ctx t))))
    (when cap-res
      (let* ((title (nth 0 cap-res))
             (href (nth 1 cap-res))
             (cap-rest (nth 2 cap-res))
             (plain-len (length (string-trim
                                 (etaf-web--collapse-ws
                                  (mapconcat #'etaf-web--plain-text cap-rest " ")))))
             (parts nil))
        (when media
          (when-let* ((info (etaf-web--extract-img-info media ctx)))
            (push (etaf-web--format-block-img info) parts)))
        (let ((cap-body (etaf-web--emit-children-blocks cap-rest ctx)))
          (unless (string-empty-p cap-body)
            (push cap-body parts)))
        (list :title title
              :href href
              :body (etaf-web--strip-card-leading-ordinal
                     (mapconcat #'identity (nreverse parts) "\n\n"))
              :plain-len plain-len)))))

(defun etaf-web--extract-card (item ctx strict-p)
  "Extract card plist `(:title :href :body :plain-len)' from ITEM, or nil.
When STRICT-P is non-nil (class-less structural grid), applies tighter tag and
body-length bounds to avoid false positives on prose."
  (let ((allowed-tags (if strict-p
                          '(div article section figure a)
                        '(div article section figure a li))))
    (when (and (etaf-web--node-p item)
               (memq (dom-tag item) allowed-tags)
               (not (etaf-web--card-disqualified-p item)))
      (let ((card
             (cond
              ((eq (dom-tag item) 'figure)
               (etaf-web--extract-figure-card item ctx))
              (t
               (let* ((outer-link (cond
                                   ((eq (dom-tag item) 'a) item)
                                   ((let ((sig (etaf-web--significant-children item)))
                                      (and (= (length sig) 1)
                                           (etaf-web--node-p (car sig))
                                           (eq (dom-tag (car sig)) 'a)))
                                    (car (etaf-web--significant-children item)))))
                      (target (or outer-link item))
                      (outer-href (and outer-link
                                       (etaf-web--resolve-url
                                        (etaf-web--attr outer-link 'href)
                                        (etaf-web--ctx-base-url ctx))))
                      (res (etaf-web--extract-title-and-body
                            (dom-children target) ctx (not strict-p))))
                 (when res
                   (let* ((title (nth 0 res))
                          (href (or (nth 1 res) outer-href))
                          (body-nodes (nth 2 res))
                          (plain-len
                           (length (string-trim
                                    (etaf-web--collapse-ws
                                     (mapconcat #'etaf-web--plain-text body-nodes " ")))))
                          (saved (etaf-web--ctx-in-card ctx))
                          (body nil))
                     (setf (etaf-web--ctx-in-card ctx) t)
                     (unwind-protect
                         (setq body (etaf-web--strip-card-leading-ordinal
                                     (etaf-web--emit-children-blocks body-nodes ctx)))
                       (setf (etaf-web--ctx-in-card ctx) saved))
                     (list :title title :href href :body body :plain-len plain-len))))))))
        (when card
          (let ((title (plist-get card :title))
                (body (plist-get card :body))
                (plain-len (plist-get card :plain-len))
                (max-len (if strict-p 240 400)))
            (when (and (not (string-empty-p title))
                       (<= (length title) (if strict-p 80 100))
                       (<= plain-len max-len)
                       (if strict-p
                           (and (> plain-len 0) (not (string-empty-p body)))
                         (or (not (string-empty-p body))
                             (plist-get card :href))))
              card)))))))

(defun etaf-web--row-wrapper-p (node)
  "Return non-nil when NODE is a `<div>' row wrapper inside a multi-row grid."
  (and (etaf-web--node-p node)
       (eq (dom-tag node) 'div)
       (or (etaf-web--grid-style-p node)
           (cl-some (lambda (tok)
                      (string-match-p
                       "\\(?:\\`\\|[-_]\\)\\(?:row\\|grid-row\\|card-row\\)\\'"
                       tok))
                    (etaf-web--class-tokens node)))))

(defun etaf-web--card-grid-items (node)
  "Return candidate card children of NODE, flattening uniform grid rows."
  (let ((elems (cl-remove-if
                (lambda (n)
                  (and (string-empty-p (etaf-web--clean-text n))
                       (not (etaf-web--find-first
                             n (lambda (c) (memq (dom-tag c) '(img picture)))))))
                (etaf-web--element-children node))))
    (if (and (>= (length elems) 2)
             (cl-every #'etaf-web--row-wrapper-p elems))
        (cl-loop for row in elems
                 append (etaf-web--element-children row))
      elems)))

(defun etaf-web--partition-cards (cards)
  "Split CARDS into `(COL-COUNT . CHUNK)' groups for `:::columns'.
2–3 cards stay in one group matching the count; 4 cards form one 2-column
2x2 grid; 5 or more cards split into 3-column batches (e.g. 5 -> 3+2)."
  (let ((n (length cards)))
    (cond
     ((<= n 3) (list (cons n cards)))
     ((= n 4) (list (cons 2 cards)))
     (t
      (let ((groups nil)
            (rest cards))
        (while rest
          (let ((chunk (seq-take rest 3)))
            (push (cons (length chunk) chunk) groups)
            (setq rest (nthcdr 3 rest))))
        (nreverse groups))))))

(defun etaf-web--format-card (card)
  "Format CARD plist as a `:::col' containing a `:::card' block."
  (let* ((title (plist-get card :title))
         (href (plist-get card :href))
         (body (or (plist-get card :body) ""))
         (attrs (concat (format "title=\"%s\"" title)
                        (when (and href (not (string-empty-p href)))
                          (format " href=\"%s\""
                                  (etaf-web--sanitize-attr-value href))))))
    (if (string-empty-p body)
        (format ":::col\n:::card {%s}\n:::\n:::" attrs)
      (format ":::col\n:::card {%s}\n%s\n:::\n:::" attrs body))))

(defun etaf-web--try-emit-card-grid (node ctx)
  "Compile card-grid DOM NODE into `:::columns' + `:::card' blocks, or nil."
  (when (and (not (etaf-web--ctx-in-card ctx))
             (etaf-web--node-p node)
             (memq (dom-tag node) '(div section ul ol))
             (not (etaf-web--steps-class-p node))
             (not (etaf-web--timeline-class-p node))
             (not (etaf-web--tabs-class-p node)))
    (let* ((has-loose-text
            (cl-some (lambda (c) (and (stringp c) (not (string-blank-p c))))
                     (dom-children node)))
           (class-grid (etaf-web--card-grid-class-p node))
           (elems (unless has-loose-text (etaf-web--card-grid-items node)))
           (row-flattened (and elems
                               (let ((direct (etaf-web--element-children node)))
                                 (and (>= (length direct) 2)
                                      (cl-every #'etaf-web--row-wrapper-p direct)))))
           (explicit (or class-grid row-flattened))
           (count (length elems)))
      (cond
       ;; Explicit class/CSS-grid container: >= 2 valid cards, no upper cap.
       ((and explicit (>= count 2))
        (let ((cards (mapcar (lambda (el) (etaf-web--extract-card el ctx nil))
                             elems)))
          (when (cl-every #'identity cards)
            (mapconcat
             (lambda (group)
               (format ":::columns {columns=\"%d\" min-width=\"22ch\" divider=false}\n%s\n:::"
                       (car group)
                       (mapconcat #'etaf-web--format-card (cdr group) "\n")))
             (etaf-web--partition-cards cards)
             "\n\n"))))
       ;; Structural homogeneity without grid class: div/section, 2..6 same-tag siblings.
       ((and (not explicit)
             (memq (dom-tag node) '(div section))
             (<= 2 count) (<= count 6)
             (not (cl-some (lambda (tok)
                             (string-match-p etaf-web--content-hint-regexp tok))
                           (etaf-web--class-tokens node)))
             (let ((first-tag (dom-tag (car elems))))
               (cl-every (lambda (el) (eq (dom-tag el) first-tag)) elems)))
        (let ((cards (mapcar (lambda (el) (etaf-web--extract-card el ctx t))
                             elems)))
          (when (cl-every #'identity cards)
            (mapconcat
             (lambda (group)
               (format ":::columns {columns=\"%d\" min-width=\"22ch\" divider=false}\n%s\n:::"
                       (car group)
                       (mapconcat #'etaf-web--format-card (cdr group) "\n")))
             (etaf-web--partition-cards cards)
             "\n\n"))))))))

(defun etaf-web--tab-triggers (tablist-node)
  "Return ordered list of tab trigger DOM nodes inside TABLIST-NODE."
  (or (etaf-web--find-all
       tablist-node
       (lambda (n) (equal (downcase (string-trim (or (etaf-web--attr n 'role) "")))
                          "tab")))
      (etaf-web--find-all tablist-node (lambda (n) (eq (dom-tag n) 'button)))
      (etaf-web--find-all tablist-node (lambda (n) (eq (dom-tag n) 'a)))
      (etaf-web--find-all tablist-node (lambda (n) (eq (dom-tag n) 'li)))))

(defun etaf-web--tab-trigger-controls (trigger)
  "Return target panel id referenced by tab TRIGGER, or nil."
  (let ((ctrl (etaf-web--attr trigger 'aria-controls))
        (href (etaf-web--attr trigger 'href)))
    (cond
     ((and ctrl (not (string-blank-p ctrl))) (string-trim ctrl))
     ((and href (string-prefix-p "#" (string-trim href)))
      (substring (string-trim href) 1))
     (t nil))))

(defun etaf-web--tab-trigger-selected-p (trigger)
  "Return non-nil when tab TRIGGER is marked active/selected."
  (let ((aria (downcase (string-trim (or (etaf-web--attr trigger 'aria-selected) ""))))
        (classes (etaf-web--class-list trigger)))
    (or (equal aria "true")
        (cl-some (lambda (c) (member c '("active" "selected" "is-active")))
                 classes))))

(defun etaf-web--emit-tabs-from-parts (triggers panels ctx)
  "Compile paired tab TRIGGERS and PANELS under CTX into a `:::tabs' block."
  (when (and triggers panels)
    (let ((used (make-hash-table :test #'eq))
          (entries nil)
          (had-selected nil))
      (cl-loop
       for trigger in triggers
       for idx from 0
       for title = (etaf-web--sanitize-attr-value (etaf-web--clean-text trigger))
       when (not (string-empty-p title))
       do
       (let* ((ctrl (etaf-web--tab-trigger-controls trigger))
              (tid (etaf-web--attr trigger 'id))
              (panel
               (or (and ctrl
                        (cl-find-if
                         (lambda (p)
                           (and (not (gethash p used))
                                (equal (etaf-web--attr p 'id) ctrl)))
                         panels))
                   (and tid (not (string-empty-p tid))
                        (cl-find-if
                         (lambda (p)
                           (and (not (gethash p used))
                                (equal (etaf-web--attr p 'aria-labelledby) tid)))
                         panels))
                   (let ((pos-panel (nth idx panels)))
                     (and pos-panel (not (gethash pos-panel used)) pos-panel))
                   (cl-find-if (lambda (p) (not (gethash p used))) panels))))
         (when panel
           (puthash panel t used)
           (let* ((sel (and (not had-selected)
                            (etaf-web--tab-trigger-selected-p trigger)))
                  (body (etaf-web--emit-children-blocks (dom-children panel) ctx)))
             (when sel (setq had-selected t))
             (push (list :title title :selected sel :body body) entries)))))
      (setq entries (nreverse entries))
      (when entries
        (concat ":::tabs\n"
                (mapconcat
                 (lambda (entry)
                   (let ((hdr (if (plist-get entry :selected)
                                  (format "@tab {title=\"%s\" selected=true}"
                                          (plist-get entry :title))
                                (format "@tab {title=\"%s\"}"
                                        (plist-get entry :title))))
                         (body (plist-get entry :body)))
                     (if (string-empty-p body)
                         hdr
                       (concat hdr "\n" body))))
                 entries
                 "\n\n")
                "\n:::")))))

(defun etaf-web--panel-wrapper-children (node)
  "If NODE is a container holding only tabpanel elements, return them."
  (when (and (etaf-web--node-p node) (memq (dom-tag node) '(div section)))
    (let ((elems (etaf-web--element-children node)))
      (when (and elems (cl-every #'etaf-web--tabpanel-node-p elems))
        elems))))

(defun etaf-web--try-emit-tabs-container (node ctx)
  "Compile a `.tabs' / `.code-tabs' wrapper NODE into `:::tabs', or nil."
  (when (etaf-web--tabs-class-p node)
    (let* ((elems (etaf-web--element-children node))
           (tablist (cl-find-if #'etaf-web--tablist-node-p elems))
           (triggers (if tablist
                         (etaf-web--tab-triggers tablist)
                       (cl-remove-if-not
                        (lambda (e)
                          (or (eq (dom-tag e) 'button)
                              (equal (downcase (or (etaf-web--attr e 'role) ""))
                                     "tab")))
                        elems)))
           (panels (let ((direct (cl-remove-if-not #'etaf-web--tabpanel-node-p elems)))
                     (or direct
                         (cl-loop for e in elems
                                  unless (eq e tablist)
                                  for wrapped = (etaf-web--panel-wrapper-children e)
                                  when wrapped return wrapped)))))
      (when (and (>= (length triggers) 2) panels)
        (etaf-web--emit-tabs-from-parts triggers panels ctx)))))

(defun etaf-web--step-number-node-p (node)
  "Return non-nil when DOM NODE is a standalone step-number badge."
  (when (and (etaf-web--node-p node)
             (not (memq (dom-tag node) '(h1 h2 h3 h4 h5 h6 pre table))))
    (let ((text (etaf-web--clean-text node))
          (tokens (etaf-web--class-tokens node)))
      (and (not (string-empty-p text))
           (<= (length text) 16)
           (or (string-match-p
                "\\`\\(?:step[ \t]*\\)?[0-9]+[.)]?\\'\\|\\`第[ \t]*[0-9]+[ \t]*步\\'"
                (downcase text))
               (and (cl-some (lambda (tok)
                               (string-match-p
                                "num\\|number\\|index\\|badge\\|counter\\|order"
                                tok))
                             tokens)
                    (string-match-p "[0-9]" text)))))))

(defun etaf-web--strip-step-prefix (title)
  "Remove redundant leading step numbering from TITLE when text remains."
  (let ((cleaned
         (cond
          ((string-match
            "\\`\\(?:[Ss]tep[ \t]+[0-9]+[ \t]*[:.)—–-]*[ \t]*\\|[0-9]+[.)][ \t]+\\|[0-9]+[ \t]*[—–:-][ \t]+\\|第[ \t]*[0-9]+[ \t]*步[：:. \t]*\\)\\(.+\\)\\'"
            title)
           (string-trim (match-string 1 title)))
          (t title))))
    (if (string-empty-p cleaned) title cleaned)))

(defun etaf-web--step-item-numbered-p (item)
  "Return non-nil when step ITEM carries an explicit step number."
  (or (etaf-web--attr item 'data-step)
      (etaf-web--attr item 'value)
      (cl-some #'etaf-web--step-number-node-p (etaf-web--element-children item))
      (let ((text (downcase (etaf-web--clean-text item))))
        (string-match-p
         "\\`\\(?:step[ \t]+[0-9]+\\|[0-9]+[.)][ \t]\\|0[1-9][ \t]\\|第[ \t]*[0-9]+[ \t]*步\\|[①②③④⑤⑥⑦⑧⑨⑩]\\)"
         text))))

(defun etaf-web--extract-sequence-items (node)
  "Return `(LEADING-HEADING ITEMS ORDERED-P)' for sequence container NODE."
  (if (memq (dom-tag node) '(ol ul))
      (list nil
            (cl-remove-if-not (lambda (c) (and (etaf-web--node-p c)
                                               (eq (dom-tag c) 'li)))
                              (dom-children node))
            (eq (dom-tag node) 'ol))
    (let* ((elems (etaf-web--element-children node))
           (first (car elems))
           (heading (when (and first (memq (dom-tag first) '(h2 h3 h4 header)))
                      first))
           (rest (if heading (cdr elems) elems)))
      (cond
       ((and (= (length rest) 1) (memq (dom-tag (car rest)) '(ol ul)))
        (list heading
              (cl-remove-if-not (lambda (c) (and (etaf-web--node-p c)
                                                 (eq (dom-tag c) 'li)))
                                (dom-children (car rest)))
              (eq (dom-tag (car rest)) 'ol)))
       ((and (= (length rest) 1)
             (memq (dom-tag (car rest)) '(div section))
             (>= (length (etaf-web--element-children (car rest))) 2))
        (list heading (etaf-web--element-children (car rest)) nil))
       (t (list heading rest nil))))))

(defun etaf-web--extract-step-entry (item ctx)
  "Extract `(TITLE . BODY)' for one step ITEM under CTX, or nil."
  (let* ((children (cl-remove-if #'etaf-web--step-number-node-p
                                 (etaf-web--significant-children item)))
         (res (etaf-web--extract-title-and-body children ctx nil))
         (title nil)
         (body-nodes nil))
    (cond
     (res
      (setq title (nth 0 res)
            body-nodes (nth 2 res)))
     ;; Element with title/heading/label class.
     ((let ((tidx (cl-position-if
                   (lambda (c)
                     (and (etaf-web--node-p c)
                          (cl-some (lambda (cls)
                                     (string-match-p "title\\|heading\\|label\\|name" cls))
                                   (etaf-web--class-list c))))
                   children)))
        (when tidx
          (setq title (etaf-web--sanitize-attr-value
                       (etaf-web--clean-text (nth tidx children)))
                body-nodes (append (cl-subseq children 0 tidx)
                                   (cl-subseq children (1+ tidx))))
          t)))
     ;; Plain `<li>' or simple step: first block/paragraph is title, rest is body.
     ((and children (etaf-web--node-p (car children))
           (memq (dom-tag (car children)) '(p div span))
           (> (length children) 1))
      (setq title (etaf-web--sanitize-attr-value
                   (etaf-web--clean-text (car children)))
            body-nodes (cdr children)))
     (t
      (setq title (etaf-web--sanitize-attr-value (etaf-web--clean-text item))
            body-nodes nil)))
    (setq title (etaf-web--sanitize-attr-value (etaf-web--strip-step-prefix title)))
    (when (and title (not (string-empty-p title)))
      (cons title (etaf-web--emit-children-blocks body-nodes ctx)))))

(defun etaf-web--try-emit-steps (node ctx)
  "Compile a steps/stepper/how-it-works container into `:::steps', or nil."
  (when (etaf-web--steps-class-p node)
    (let* ((seq-info (etaf-web--extract-sequence-items node))
           (heading (nth 0 seq-info))
           (items (nth 1 seq-info))
           (ordered-p (nth 2 seq-info))
           (numbered-count (cl-count-if #'etaf-web--step-item-numbered-p items)))
      (when (and (>= (length items) 2)
                 (or ordered-p (>= numbered-count 2)))
        (let ((steps (delq nil
                           (mapcar (lambda (it) (etaf-web--extract-step-entry it ctx))
                                   items))))
          (when (>= (length steps) 2)
            (let* ((hdr-md (and heading (etaf-web--emit-block heading ctx)))
                   (steps-md
                    (concat ":::steps {list-style=\"decimal\"}\n"
                            (mapconcat
                             (lambda (st)
                               (if (string-empty-p (cdr st))
                                   (format ":::step {title=\"%s\"}\n:::" (car st))
                                 (format ":::step {title=\"%s\"}\n%s\n:::"
                                         (car st) (cdr st))))
                             steps "\n")
                            "\n:::")))
              (if (and hdr-md (not (string-empty-p hdr-md)))
                  (concat hdr-md "\n\n" steps-md)
                steps-md))))))))

(defun etaf-web--timeline-time-node-p (node)
  "Return non-nil when DOM NODE represents a timeline event timestamp."
  (when (etaf-web--node-p node)
    (let ((text (etaf-web--clean-text node)))
      (and (not (string-empty-p text))
           (<= (length text) 40)
           (or (eq (dom-tag node) 'time)
               (cl-some (lambda (cls)
                          (string-match-p
                           "\\(?:\\`\\|[-_]\\)\\(?:time\\|date\\|year\\|timestamp\\|period\\)\\(?:\\'\\|[-_]\\)"
                           cls))
                        (etaf-web--class-list node)))))))

(defun etaf-web--extract-timeline-entry (item ctx)
  "Extract `(:title :time :body)' for one timeline ITEM under CTX, or nil."
  (let* ((sig (etaf-web--significant-children item))
         (time-node (cl-find-if #'etaf-web--timeline-time-node-p sig))
         (time-str (and time-node
                        (etaf-web--sanitize-attr-value
                         (etaf-web--clean-text time-node))))
         (rest (if time-node (cl-remove time-node sig :count 1 :test #'eq) sig))
         (res (etaf-web--extract-title-and-body rest ctx nil))
         (title nil)
         (body-nodes nil))
    (cond
     (res
      (setq title (nth 0 res)
            body-nodes (nth 2 res)))
     ((let ((tidx (cl-position-if
                   (lambda (c)
                     (and (etaf-web--node-p c)
                          (cl-some (lambda (cls)
                                     (string-match-p "title\\|heading\\|label" cls))
                                   (etaf-web--class-list c))))
                   rest)))
        (when tidx
          (setq title (etaf-web--sanitize-attr-value
                       (etaf-web--clean-text (nth tidx rest)))
                body-nodes (append (cl-subseq rest 0 tidx)
                                   (cl-subseq rest (1+ tidx))))
          t)))
     ((and rest (etaf-web--node-p (car rest))
           (memq (dom-tag (car rest)) '(p div span))
           (> (length rest) 1))
      (setq title (etaf-web--sanitize-attr-value (etaf-web--clean-text (car rest)))
            body-nodes (cdr rest)))
     (t
      (let ((fallback (etaf-web--sanitize-attr-value
                       (mapconcat #'etaf-web--plain-text rest " "))))
        (setq title (if (not (string-empty-p fallback)) fallback time-str)
              body-nodes nil))))
    (when (and title (not (string-empty-p title)))
      (list :title title
            :time (and time-str (not (string-empty-p time-str))
                       (not (equal time-str title))
                       time-str)
            :body (etaf-web--emit-children-blocks body-nodes ctx)))))

(defun etaf-web--try-emit-timeline (node ctx)
  "Compile a `timeline' container NODE into `:::timeline', or nil."
  (when (etaf-web--timeline-class-p node)
    (let* ((seq-info (etaf-web--extract-sequence-items node))
           (heading (nth 0 seq-info))
           (items (nth 1 seq-info)))
      (when (>= (length items) 2)
        (let ((events (delq nil
                            (mapcar (lambda (it)
                                      (etaf-web--extract-timeline-entry it ctx))
                                    items))))
          (when (>= (length events) 2)
            (let* ((hdr-md (and heading (etaf-web--emit-block heading ctx)))
                   (tl-md
                    (concat ":::timeline\n"
                            (mapconcat
                             (lambda (ev)
                               (let ((attrs (concat
                                             (format "title=\"%s\"" (plist-get ev :title))
                                             (when (plist-get ev :time)
                                               (format " time=\"%s\""
                                                       (plist-get ev :time)))))
                                     (body (plist-get ev :body)))
                                 (if (string-empty-p body)
                                     (format ":::event {%s}\n:::" attrs)
                                   (format ":::event {%s}\n%s\n:::" attrs body))))
                             events "\n")
                            "\n:::")))
              (if (and hdr-md (not (string-empty-p hdr-md)))
                  (concat hdr-md "\n\n" tl-md)
                tl-md))))))))

(defun etaf-web--consume-adjacent-tabpanels (nodes)
  "Consume leading tabpanels (or one tabpanel wrapper) from NODES.
Return `(PANELS . REMAINING-NODES)'."
  (let ((panels nil)
        (rest nodes))
    (while (and rest (stringp (car rest)) (string-blank-p (car rest)))
      (setq rest (cdr rest)))
    (cond
     ((and rest (etaf-web--tabpanel-node-p (car rest)))
      (let ((done nil))
        (while (and rest (not done))
          (cond
           ((and (stringp (car rest)) (string-blank-p (car rest)))
            (setq rest (cdr rest)))
           ((etaf-web--tabpanel-node-p (car rest))
            (push (pop rest) panels))
           (t (setq done t)))))
      (cons (nreverse panels) rest))
     ((and rest (etaf-web--panel-wrapper-children (car rest)))
      (cons (etaf-web--panel-wrapper-children (car rest)) (cdr rest)))
     (t (cons nil nodes)))))

(defun etaf-web--standalone-block-media (nodes ctx)
  "If NODES holds a single standalone image/lightbox wrapper, return it formatted."
  (let ((sig (cl-remove-if (lambda (c) (and (stringp c) (string-blank-p c)))
                           nodes)))
    (when (and (= (length sig) 1) (etaf-web--node-p (car sig)))
      (let* ((only (car sig))
             (media (cond
                     ((memq (dom-tag only) '(img picture)) only)
                     ((and (eq (dom-tag only) 'a)
                           (let ((child (etaf-web--sole-media-child only)))
                             (and child
                                  (or (assq 'data-lightbox (dom-attributes only))
                                      (let* ((raw-img (etaf-web--img-raw-url
                                                       (if (eq (dom-tag child) 'picture)
                                                           (etaf-web--find-first
                                                            child
                                                            (lambda (n) (eq (dom-tag n) 'img)))
                                                         child)))
                                             (href (etaf-web--resolve-url
                                                    (etaf-web--attr only 'href)
                                                    (etaf-web--ctx-base-url ctx))))
                                        (and raw-img href
                                             (equal href
                                                    (etaf-web--resolve-url
                                                     raw-img
                                                     (etaf-web--ctx-base-url ctx)))))))))
                      (etaf-web--sole-media-child only)))))
        (when media
          (if-let* ((info (etaf-web--extract-img-info media ctx)))
              (etaf-web--format-block-img info)
            ""))))))

(defun etaf-web--trim-block-inlines (text)
  "Trim outer whitespace and stray leading/trailing `<br>' breaks from TEXT."
  (let ((s (string-trim (or text ""))))
    (setq s (replace-regexp-in-string "\\`\\(?:\\\\[ \t\n]*\\)+" "" s))
    (setq s (replace-regexp-in-string "\\(?:[ \t\n]*\\\\\\)+\\'" "" s))
    (string-trim s)))

(defun etaf-web--emit-children-blocks (children ctx)
  "Compile mixed block/inline DOM CHILDREN under CTX into Markdown blocks."
  (let ((blocks nil)
        (inline-buf nil)
        (rest children))
    (cl-flet ((flush-inlines ()
                (when inline-buf
                  (let* ((items (nreverse inline-buf))
                         (solo (etaf-web--standalone-block-media items ctx))
                         (text (or solo
                                   (etaf-web--trim-block-inlines
                                    (etaf-web--emit-inlines items ctx)))))
                    (unless (string-empty-p text)
                      (push text blocks)))
                  (setq inline-buf nil))))
      (while rest
        (let ((child (pop rest)))
          (cond
           ((and (etaf-web--node-p child)
                 (etaf-web--tablist-node-p child))
            (let* ((consumed (etaf-web--consume-adjacent-tabpanels rest))
                   (panels (car consumed))
                   (tabs-md (and panels
                                 (etaf-web--emit-tabs-from-parts
                                  (etaf-web--tab-triggers child) panels ctx))))
              (if tabs-md
                  (progn
                    (flush-inlines)
                    (push tabs-md blocks)
                    (setq rest (cdr consumed)))
                ;; Standalone tablist without panels: fall through normally.
                (flush-inlines)
                (let ((blk (etaf-web--emit-block child ctx)))
                  (when (and blk (not (string-empty-p blk)))
                    (push blk blocks))))))
           ((and (etaf-web--node-p child)
                 (or (memq (dom-tag child) etaf-web--block-tags)
                     (etaf-web--callout-kind child)
                     (etaf-web--footnote-container-p child)))
            (flush-inlines)
            (let ((blk (etaf-web--emit-block child ctx)))
              (when (and blk (not (string-empty-p blk)))
                (push blk blocks))))
           (t (push child inline-buf)))))
      (flush-inlines))
    (mapconcat #'identity (nreverse blocks) "\n\n")))

(defun etaf-web--emit-block (node ctx)
  "Compile a single block DOM NODE under CTX into Markdown text."
  (cond
   ((not (etaf-web--node-p node)) "")
   ((etaf-web--footnote-container-p node) "")
   ((etaf-web--callout-kind node)
    (etaf-web--emit-callout node (etaf-web--callout-kind node) ctx))
   (t
    (pcase (dom-tag node)
      ((and tag (guard (memq tag '(h1 h2 h3 h4 h5 h6))))
       (unless (eq node (etaf-web--ctx-skip-heading ctx))
         (let* ((level (string-to-number (substring (symbol-name tag) 1)))
                (text (string-trim
                       (etaf-web--collapse-ws
                        (etaf-web--emit-inlines (dom-children node) ctx)))))
           (unless (string-empty-p text)
             (concat (make-string level ?#) " " text)))))
      ('p
       (let* ((solo (etaf-web--standalone-block-media (dom-children node) ctx))
              (text (or solo
                        (etaf-web--trim-block-inlines
                         (etaf-web--emit-inlines (dom-children node) ctx)))))
         (unless (string-empty-p text) text)))
      ('pre (etaf-web--emit-code-block node))
      ('table (etaf-web--emit-table node ctx))
      ((or 'ul 'ol)
       (or (etaf-web--try-emit-steps node ctx)
           (etaf-web--try-emit-timeline node ctx)
           (etaf-web--try-emit-card-grid node ctx)
           (etaf-web--emit-list node 0 ctx)))
      ('dl (etaf-web--emit-dl node ctx))
      ('blockquote (etaf-web--emit-blockquote node ctx))
      ('hr "---")
      ('details (etaf-web--emit-details node ctx))
      ('figure (etaf-web--emit-figure node ctx))
      ((or 'div 'section)
       (or (etaf-web--try-emit-tabs-container node ctx)
           (etaf-web--try-emit-steps node ctx)
           (etaf-web--try-emit-timeline node ctx)
           (etaf-web--try-emit-card-grid node ctx)
           (etaf-web--emit-children-blocks (dom-children node) ctx)))
      ((or 'article 'main 'header 'body 'html 'hgroup 'address 'fieldset)
       (etaf-web--emit-children-blocks (dom-children node) ctx))
      (_ (etaf-web--emit-children-blocks (dom-children node) ctx))))))

(defun etaf-web--emit-footnotes (ctx)
  "Emit referenced GFM footnote definitions accumulated in CTX, or nil."
  (let ((ordered (nreverse (copy-sequence (etaf-web--ctx-fn-order ctx))))
        (entries nil))
    (dolist (id ordered)
      (when-let* ((def-node (gethash id (etaf-web--ctx-fn-defs ctx)))
                  (num (gethash id (etaf-web--ctx-fn-numbers ctx))))
        (let ((body (etaf-web--emit-children-blocks (dom-children def-node) ctx)))
          (unless (string-empty-p body)
            (let ((lines (split-string body "\n")))
              (push (mapconcat
                     #'identity
                     (cons (format "[^%d]: %s" num (car lines))
                           (mapcar (lambda (l)
                                     (if (string-empty-p l) "" (concat "    " l)))
                                   (cdr lines)))
                     "\n")
                    entries))))))
    (when entries
      (mapconcat #'identity (nreverse entries) "\n\n"))))

;;; ---------------------------------------------------------------------------
;;; Output normalization & entry points
;;; ---------------------------------------------------------------------------

(defun etaf-web--normalize-markdown (text)
  "Trim trailing spaces, collapse blank lines and ensure one trailing newline."
  (let* ((unix (replace-regexp-in-string "\r\n?" "\n" (or text "")))
         (no-trail (replace-regexp-in-string "[ \t]+$" "" unix))
         (collapsed (replace-regexp-in-string "\n\\{3,\\}" "\n\n" no-trail))
         (trimmed (string-trim collapsed "\n+" "\n+")))
    (if (string-empty-p trimmed)
        "\n"
      (concat trimmed "\n"))))

(cl-defun etaf-web--compile (html &key base-url image-rewriter)
  "Compile HTML into a plist `(:markdown STRING :meta ALIST :title STRING)'.
BASE-URL resolves relative links and images.  IMAGE-REWRITER, when non-nil, is
called with each resolved image URL and returns a replacement URL or path."
  (let* ((parsed (etaf-web--parse-html html))
         (clean (etaf-web--sanitize-dom parsed))
         (extracted (etaf-web--extract-main clean))
         (main (car extracted))
         (fn-roots (cdr extracted))
         (meta (etaf-web--extract-meta clean main base-url))
         (title (cdr (assoc "title" meta)))
         (skip-heading (etaf-web--leading-duplicate-h1 main title))
         (fn-defs (etaf-web--collect-footnote-defs main fn-roots))
         (heading-ids (etaf-web--collect-heading-ids main skip-heading))
         (ctx (etaf-web--ctx-create
               :base-url base-url
               :image-rewriter image-rewriter
               :doc-title title
               :skip-heading skip-heading
               :heading-ids heading-ids
               :fn-defs fn-defs
               :fn-order nil
               :fn-numbers (make-hash-table :test #'equal)))
         (front (etaf-web--format-front-matter meta))
         (body (etaf-web--emit-block main ctx))
         (footnotes (etaf-web--emit-footnotes ctx))
         (sections (delq nil
                         (mapcar (lambda (s)
                                   (and (stringp s) (not (string-empty-p s)) s))
                                 (list front body footnotes))))
         (markdown (etaf-web--normalize-markdown
                    (mapconcat #'identity sections "\n\n"))))
    (list :markdown markdown
          :meta meta
          :title (cdr (assoc "title" meta)))))

(cl-defun etaf-web-to-markdown (html &key base-url)
  "Compile HTML string into `etaf-md' intermediate language text.
Pure function with no network or disk I/O.  BASE-URL, when given, resolves
relative links and image sources into absolute URLs while preserving `#anchor'
fragments.  Signals `etaf-web-error' on invalid input or missing libxml."
  (plist-get (etaf-web--compile html :base-url base-url) :markdown))

(provide 'etaf-web-compile)
;;; etaf-web-compile.el ends here
