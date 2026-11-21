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

(defconst etaf-web--compiler-version "2"
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
   "nav\\|navbar\\|navigation\\|menu\\|menubar\\|breadcrumb\\|breadcrumbs\\|"
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
         (date (or (etaf-web--meta-content
                    dom 'property '("article:published_time" "og:updated_time"))
                   (etaf-web--meta-content
                    dom 'name '("date" "pubdate" "publish-date" "dc.date"))
                   (when time-node
                     (let ((dt (or (etaf-web--attr time-node 'datetime)
                                   (etaf-web--clean-text time-node))))
                       (and dt (not (string-empty-p (string-trim dt)))
                            (string-trim (etaf-web--collapse-ws dt)))))))
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

(defun etaf-web--boilerplate-node-p (node inside-primary)
  "Return non-nil when DOM NODE should be pruned as page chrome.
INSIDE-PRIMARY is non-nil once traversal is inside the chosen article/main."
  (when (etaf-web--node-p node)
    (let* ((tag (dom-tag node))
           (role (downcase (string-trim (or (etaf-web--attr node 'role) ""))))
           (tokens (etaf-web--class-tokens node))
           (hidden (or (assq 'hidden (dom-attributes node))
                       (equal (downcase (or (etaf-web--attr node 'aria-hidden) ""))
                              "true"))))
      (cond
       ((memq tag '(html body article main)) nil)
       ((etaf-web--callout-kind node) nil)
       ((etaf-web--footnote-container-p node) nil)
       ((etaf-web--contains-landmark-p node) nil)
       (hidden t)
       ((memq tag etaf-web--boilerplate-tags) t)
       ((and (eq tag 'header) (not inside-primary)) t)
       ((member role etaf-web--boilerplate-roles) t)
       ((cl-some (lambda (tok)
                   (string-match-p etaf-web--boilerplate-token-regexp tok))
                 tokens)
        t)
       (t nil)))))

(defun etaf-web--prune-boilerplate (node &optional inside-primary)
  "Return a copy of NODE with navigation, sidebars, footers and ads removed."
  (cond
   ((stringp node) node)
   ((not (etaf-web--node-p node)) nil)
   ((etaf-web--boilerplate-node-p node inside-primary) nil)
   (t
    (let* ((tag (dom-tag node))
           (primary (or inside-primary (memq tag '(article main))))
           (children (delq nil
                           (mapcar (lambda (c)
                                     (etaf-web--prune-boilerplate c primary))
                                   (dom-children node)))))
      (cons tag (cons (dom-attributes node) children))))))

(defun etaf-web--link-text-length (node)
  "Return total character count of text inside `<a>' elements under NODE."
  (cond
   ((stringp node) 0)
   ((not (etaf-web--node-p node)) 0)
   ((eq (dom-tag node) 'a) (length (etaf-web--clean-text node)))
   (t (cl-loop for child in (dom-children node)
               sum (etaf-web--link-text-length child)))))

(defun etaf-web--block-count (node)
  "Return count of substantive content blocks inside DOM NODE."
  (if (not (etaf-web--node-p node))
      0
    (+ (if (memq (dom-tag node) '(p pre table ul ol blockquote dl details)) 1 0)
       (cl-loop for child in (dom-children node)
                sum (etaf-web--block-count child)))))

(defun etaf-web--density-score (node)
  "Compute a heuristic main-content density score for DOM NODE."
  (let* ((text (etaf-web--clean-text node))
         (total (length text))
         (link-len (etaf-web--link-text-length node))
         (non-link (max 0 (- total link-len)))
         (link-ratio (if (> total 0) (/ (float link-len) total) 0.0))
         (blocks (etaf-web--block-count node))
         (tokens (etaf-web--class-tokens node))
         (bonus (if (cl-some (lambda (tok)
                               (string-match-p etaf-web--content-hint-regexp tok))
                             tokens)
                    1.25
                  1.0))
         (penalty (if (> link-ratio 0.5) 0.2 1.0)))
    (* (float non-link)
       (+ 1.0 (* 0.2 (min 10 blocks)))
       bonus
       penalty)))

(defun etaf-web--pick-densest-node (root)
  "Select the highest-density content container under pruned ROOT."
  (let ((best root)
        (best-score (etaf-web--density-score root)))
    (cl-labels
        ((walk (node)
           (when (etaf-web--node-p node)
             (when (memq (dom-tag node) '(div section main article td))
               (let ((score (etaf-web--density-score node)))
                 ;; Prefer a more specific descendant when it retains >= 80%
                 ;; of the best score so wrappers do not shadow the article div.
                 (when (or (> score best-score)
                           (and (> score 0.0)
                                (not (eq node root))
                                (>= score (* 0.8 best-score))))
                   (setq best node
                         best-score score))))
             (dolist (child (dom-children node))
               (walk child)))))
      (walk root))
    best))

(defun etaf-web--extract-main (dom)
  "Return (MAIN . FOOTNOTE-ROOTS) extracted from sanitized DOM."
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
         (chosen
          (cond
           (articles
            (let ((best (car articles))
                  (best-len -1))
              (dolist (art articles)
                (let* ((pruned (etaf-web--prune-boilerplate art t))
                       (len (length (etaf-web--clean-text pruned))))
                  (when (> len best-len)
                    (setq best pruned best-len len))))
              best))
           (mains
            (etaf-web--prune-boilerplate (car mains) t))
           (t
            (etaf-web--pick-densest-node pruned-body)))))
    (cons (or chosen pruned-body) fn-roots)))

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
  skip-heading     ; DOM node of leading h1 duplicating front matter title
  heading-ids      ; hash-table: html-id -> etaf-md heading slug
  fn-defs          ; hash-table: id -> DOM node
  fn-order         ; list of referenced ids (reversed while collecting)
  fn-numbers)      ; hash-table: id -> 1-based integer

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
    (let ((norm-title (string-trim (etaf-web--collapse-ws title)))
          (first (etaf-web--first-content-block main-node)))
      (when (and (etaf-web--node-p first)
                 (eq (dom-tag first) 'h1)
                 (equal (etaf-web--clean-text first) norm-title))
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

(defun etaf-web--parse-srcset-first (srcset)
  "Return the first URL candidate from an HTML SRCSET attribute, or nil."
  (when (and (stringp srcset) (not (string-blank-p srcset)))
    (let* ((first (string-trim (car (split-string srcset "," t))))
           (url (car (split-string first "[ \t\n\r]+" t))))
      (and url (not (string-empty-p url)) url))))

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

(defun etaf-web--extract-img-info (node ctx)
  "Return (URL . ALT) for an `<img>' or `<picture>' DOM NODE under CTX, or nil."
  (let* ((img (if (eq (dom-tag node) 'picture)
                  (etaf-web--find-first node (lambda (n) (eq (dom-tag n) 'img)))
                node))
         (raw-url
          (if (eq (dom-tag node) 'picture)
              (or (cl-loop for child in (dom-children node)
                           when (and (etaf-web--node-p child)
                                     (eq (dom-tag child) 'source))
                           for candidate = (etaf-web--parse-srcset-first
                                            (or (etaf-web--attr child 'srcset)
                                                (etaf-web--attr child 'src)))
                           when (and candidate
                                     (not (etaf-web--dangerous-url-p candidate))
                                     (etaf-web--decodable-source-p child candidate))
                           return candidate)
                  (and img (or (etaf-web--attr img 'src)
                               (etaf-web--attr img 'data-src)
                               (etaf-web--attr img 'data-original)
                               (etaf-web--parse-srcset-first
                                (etaf-web--attr img 'srcset)))))
            (or (let ((s (etaf-web--attr node 'src)))
                  (and s (not (string-prefix-p "data:" (downcase (string-trim s)))) s))
                (etaf-web--attr node 'data-src)
                (etaf-web--attr node 'data-original)
                (etaf-web--parse-srcset-first (etaf-web--attr node 'srcset))
                (etaf-web--attr node 'src))))
         (resolved (and raw-url
                        (not (string-prefix-p "data:" (downcase (string-trim raw-url))))
                        (etaf-web--resolve-url raw-url (etaf-web--ctx-base-url ctx))))
         (final-url (if (and resolved (etaf-web--ctx-image-rewriter ctx))
                        (or (funcall (etaf-web--ctx-image-rewriter ctx) resolved)
                            resolved)
                      resolved))
         (alt (string-trim
               (etaf-web--collapse-ws
                (or (and img (etaf-web--attr img 'alt))
                    (and img (etaf-web--attr img 'title))
                    "")))))
    (when final-url
      (cons final-url alt))))

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

(defun etaf-web--emit-inlines (nodes ctx)
  "Compile list of inline DOM NODES under CTX into a Markdown inline string."
  (let ((raw (mapconcat (lambda (n) (etaf-web--emit-inline n ctx)) nodes "")))
    ;; Collapse spaces around lines while keeping explicit `\\\n' breaks.
    (replace-regexp-in-string "[ \t]+\n" "\n" raw)))

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
                  (body (string-trim (etaf-web--emit-inlines (dom-children node) ctx))))
             (cond
              ((and raw-href (etaf-web--dangerous-url-p raw-href)) "")
              ((null href) body)
              ((string-empty-p body)
               (let ((title (string-trim (or (etaf-web--attr node 'title) ""))))
                 (if (string-empty-p title)
                     ""
                   (format "[%s](%s)"
                           (etaf-web--escape-link-label title)
                           (etaf-web--format-link-dest href)))))
              (t (format "[%s](%s)"
                         body
                         (etaf-web--format-link-dest href))))))))
      ((or 'img 'picture)
       (if-let* ((info (etaf-web--extract-img-info node ctx)))
           (format "![%s](%s)"
                   (etaf-web--escape-link-label (cdr info))
                   (etaf-web--format-link-dest (car info)))
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

(defun etaf-web--emit-table (table-node ctx)
  "Compile HTML `<table>' TABLE-NODE into a GFM pipe table under CTX.
Expands `colspan' and `rowspan' by repeating the cell value."
  (let* ((trs (etaf-web--table-rows table-node))
         (row-count (length trs))
         (grid (make-hash-table :test #'equal))
         (aligns (make-hash-table :test #'eql))
         (max-cols 0))
    (when (> row-count 0)
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
          (mapconcat #'identity lines "\n"))))))

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
            (let ((alt (if has-caption caption-text (cdr info))))
              (format "![%s](%s)"
                      (etaf-web--escape-link-label alt)
                      (etaf-web--format-link-dest (car info)))))
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

(defun etaf-web--emit-children-blocks (children ctx)
  "Compile mixed block/inline DOM CHILDREN under CTX into Markdown blocks."
  (let ((blocks nil)
        (inline-buf nil))
    (cl-flet ((flush-inlines ()
                (when inline-buf
                  (let ((text (string-trim
                               (etaf-web--emit-inlines (nreverse inline-buf) ctx))))
                    (unless (string-empty-p text)
                      (push text blocks)))
                  (setq inline-buf nil))))
      (dolist (child children)
        (cond
         ((and (etaf-web--node-p child)
               (or (memq (dom-tag child) etaf-web--block-tags)
                   (etaf-web--callout-kind child)
                   (etaf-web--footnote-container-p child)))
          (flush-inlines)
          (let ((blk (etaf-web--emit-block child ctx)))
            (when (and blk (not (string-empty-p blk)))
              (push blk blocks))))
         (t (push child inline-buf))))
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
       (let ((text (string-trim
                    (etaf-web--emit-inlines (dom-children node) ctx))))
         (unless (string-empty-p text) text)))
      ('pre (etaf-web--emit-code-block node))
      ('table (etaf-web--emit-table node ctx))
      ((or 'ul 'ol) (etaf-web--emit-list node 0 ctx))
      ('dl (etaf-web--emit-dl node ctx))
      ('blockquote (etaf-web--emit-blockquote node ctx))
      ('hr "---")
      ('details (etaf-web--emit-details node ctx))
      ('figure (etaf-web--emit-figure node ctx))
      ((or 'div 'section 'article 'main 'header 'body 'html 'hgroup 'address 'fieldset)
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
