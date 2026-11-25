;;; etaf-translate-integrations.el --- Built-in ecosystem rules and providers -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Native integrations connecting `etaf-translate' cleanly with ETAF ecosystem
;; applications using public APIs only:
;; - `etaf-web' domain/URL resolver via `etaf-web-state'
;; - Built-in low-priority rules for `etaf-web', `etaf-md', `etaf-org',
;;   `etaf-manual', `etaf-rss', `etaf-telega', `maillist' and `etaf-reader'
;; - Dedicated virtualized-page provider for `etaf-reader' (EPUB/ebook reader),
;;   reconstructing logical paragraphs from fixed 1-line visual slots and
;;   attaching bilingual companions without clipping.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'etaf)
(require 'etaf-ext)
(require 'etaf-translate-core)
(require 'etaf-translate-rules)
(require 'etaf-translate-extract)
(require 'etaf-translate-render)
(require 'etaf-translate-session)

(declare-function etaf-web-state "etaf-web" (&optional buffer))

(defun etaf-translate--provider-tree (runtime)
  "Read Host tree for RUNTIME through `etaf-ext-tree' when attached."
  (if-let* ((ctx (etaf-ext-context 'etaf-translate runtime)))
      (etaf-ext-tree ctx)
    (etaf-runtime-host-tree runtime)))

(defun etaf-translate--provider-present (runtime updates)
  "Apply provider presentation UPDATES on RUNTIME via `etaf-ext-present'."
  (if-let* ((ctx (etaf-ext-context 'etaf-translate runtime)))
      (etaf-ext-present ctx updates)
    (etaf-runtime-set-host-presentations runtime 'etaf-translate updates)))

(defun etaf-translate--provider-clear (runtime)
  "Clear `etaf-translate' presentations on RUNTIME via `etaf-ext'."
  (if-let* ((ctx (etaf-ext-context 'etaf-translate runtime)))
      (etaf-ext-clear-presentations ctx)
    (etaf-runtime-clear-presentations runtime 'etaf-translate)))

;;;; 1. Site/domain resolver for etaf-web

(defun etaf-translate--resolve-etaf-web-site (_runtime buffer)
  "Resolve hostname from an `etaf-web' BUFFER via public `etaf-web-state'."
  (when (and (buffer-live-p buffer)
             (fboundp 'etaf-web-state))
    (when-let* ((st (ignore-errors (etaf-web-state buffer)))
                (url (and (listp st) (plist-get st :url))))
      (etaf-translate--extract-host-from-url url))))

(etaf-translate-register-site-resolver #'etaf-translate--resolve-etaf-web-site)

;;;; 2. Built-in ecosystem rules (low priority 90 so user/site rules always win)

(defun etaf-translate--register-builtin-rules ()
  "Register default non-intrusive rules for standard ETAF applications."
  (dolist (entry
           '((etaf-translate-builtin:etaf-web
              :priority 90
              :buffer-regexp "\\`\\*Web:"
              :exclude-roles (navigation toolbar statusbar))
             (etaf-translate-builtin:etaf-md
              :priority 90
              :buffer-regexp "\\`\\*ETAF Markdown")
             (etaf-translate-builtin:etaf-org
              :priority 90
              :buffer-regexp "\\`\\*ETAF Org"
              :exclude-roles (navigation toolbar statusbar))
             (etaf-translate-builtin:etaf-manual
              :priority 90
              :buffer-regexp "\\`\\*ETAF Manual"
              :exclude-roles (navigation toolbar))
             (etaf-translate-builtin:etaf-rss
              :priority 90
              :buffer-regexp "\\`\\*ETAF RSS"
              :exclude-roles (navigation toolbar statusbar))
             (etaf-translate-builtin:etaf-telega
              :priority 90
              :buffer-regexp "\\`\\*ETAF Telega"
              :exclude-roles (navigation toolbar statusbar))
             (etaf-translate-builtin:maillist
              :priority 90
              :buffer-regexp "\\`\\*[Mm]aillist"
              :exclude-roles (navigation toolbar statusbar))
             (etaf-translate-builtin:etaf-reader
              :priority 90
              :buffer-regexp "\\`\\*ETAF Reader")))
    (unless (assq (car entry) etaf-translate--rules)
      (apply #'etaf-translate-register-rule (car entry) (cdr entry)))))

(etaf-translate--register-builtin-rules)

;;;; 3. Virtualized-page Provider for etaf-reader (EPUB/ebook reader)

(defun etaf-translate--reader-collect-lines (host-tree)
  "Collect `(SLOT HOST-ID TEXT GEO)' entries from `etaf-reader' HOST-TREE."
  (let ((lines nil))
    (cl-labels
        ((node-text (node)
           (if (eq (plist-get node :tag) 'text)
               (or (plist-get node :text) "")
             (mapconcat #'node-text (plist-get node :children) "")))
         (walk (nodes)
           (dolist (node nodes)
             (let* ((props (plist-get node :props))
                    (id-str (plist-get props :id)))
               (if (and (stringp id-str)
                        (string-match "\\`reader-line-\\([0-9]+\\)\\'" id-str))
                   (push (list (string-to-number (match-string 1 id-str))
                               (plist-get node :id)
                               (node-text node)
                               (plist-get node :geometry))
                         lines)
                 (walk (plist-get node :children)))))))
      (walk host-tree))
    (sort lines (lambda (a b) (< (car a) (car b))))))

(defun etaf-translate--reader-match-p (runtime _buffer)
  "Return non-nil when RUNTIME appears to be a mounted `etaf-reader' page."
  (and runtime
       (etaf-runtime-mounted-p runtime)
       (not (null (etaf-translate--reader-collect-lines
                   (etaf-translate--provider-tree runtime))))))

(defun etaf-translate--reader-join-lines (texts)
  "Join pre-wrapped visual lines TEXTS cleanly into one logical paragraph."
  (let ((out ""))
    (dolist (raw texts)
      (let ((s (string-trim raw)))
        (unless (string-empty-p s)
          (cond
           ((string-empty-p out) (setq out s))
           ((and (string-suffix-p "-" out)
                 (> (length out) 1)
                 (string-match-p "\\`[a-z]" s))
            ;; De-hyphenate wrapped English word break.
            (setq out (concat (substring out 0 -1) s)))
           (t
            (let* ((last-ch (aref out (1- (length out))))
                   (first-ch (aref s 0))
                   (cjk-join (and (> last-ch 127) (> first-ch 127))))
              (setq out (concat out (if cjk-join "" " ") s))))))))
    out))

(defun etaf-translate--reader-extract (runtime policy)
  "Group `etaf-reader' fixed visual line slots into logical paragraph units."
  (let* ((lines (etaf-translate--reader-collect-lines
                 (etaf-translate--provider-tree runtime)))
         (target-lang (plist-get policy :target-lang))
         (max-len (cl-loop for l in lines maximize (length (string-trim (nth 2 l)))
                           into m finally return (max 24 (or m 24))))
         (cur-texts nil)
         (cur-last-id nil)
         (cur-last-geo nil)
         (units nil))
    (cl-labels
        ((flush-para ()
           (when (and cur-texts cur-last-id)
             (let ((joined (etaf-translate--reader-join-lines (nreverse cur-texts))))
               (when (and (etaf-translate-text-meaningful-p joined)
                          (not (etaf-translate-text-matches-target-p joined target-lang)))
                 (push (etaf-translate-make-unit
                        :id cur-last-id
                        :text joined
                        :kind 'paragraph
                        :geometry cur-last-geo)
                       units))))
           (setq cur-texts nil cur-last-id nil cur-last-geo nil)))
      (dolist (line lines)
        (let* ((hid (nth 1 line))
               (raw (or (nth 2 line) ""))
               (trimmed (string-trim raw))
               (indented (string-match-p "\\`\\(?:  \\|\t\\|\u3000\\)" raw)))
          (cond
           ((string-blank-p trimmed)
            (flush-para))
           (t
            (when (and cur-texts indented)
              (flush-para))
            (push raw cur-texts)
            (setq cur-last-id hid
                  cur-last-geo (nth 3 line))
            ;; End paragraph early when a noticeably short line ends a sentence.
            (when (and (< (length trimmed) (* 0.72 max-len))
                       (string-match-p "[.!?。！？\"”'’]\\'" trimmed))
              (flush-para))))))
      (flush-para))
    (nreverse units)))

(defun etaf-translate--reader-apply (runtime unit translated mode style)
  "Attach TRANSLATED bilingual companion cleanly below UNIT's anchor line."
  (let ((hid (etaf-translate-unit-host-id unit)))
    (if (etaf-translate--same-as-source-p unit translated)
        (etaf-translate--provider-present runtime (list (cons hid nil)))
      (let* ((palette (etaf-translate--palette runtime))
             (eff-style (if (eq mode 'replace) 'muted style))
             (view (etaf-translate--styled-companion-view
                    runtime unit translated eff-style palette)))
        ;; Always attach `companion-after` outside the 1lh clipped line box.
        (etaf-translate--provider-present
         runtime
         (list (cons hid (list :mode 'companion-after :view view))))))))

(defun etaf-translate--reader-clear (runtime)
  "Restore `etaf-reader' lines by clearing `etaf-translate' presentations."
  (etaf-translate--provider-clear runtime))

(etaf-translate-register-provider
 'etaf-reader
 :match #'etaf-translate--reader-match-p
 :extract #'etaf-translate--reader-extract
 :apply #'etaf-translate--reader-apply
 :clear #'etaf-translate--reader-clear)

;;;; 4. Logical-Paragraph Provider for maillist (plain-text mailing list emails)

(defvar etaf-translate--maillist-groups (make-hash-table :test #'eq :weakness 'key)
  "Map from mounted `maillist' Runtime to hash table of ANCHOR-ID -> HOST-IDs.")

(defun etaf-translate--maillist-node-text (node)
  "Return concatenated plain text beneath Host NODE."
  (if (eq (plist-get node :tag) 'text)
      (or (plist-get node :text) "")
    (mapconcat #'etaf-translate--maillist-node-text
               (plist-get node :children) "")))

(defun etaf-translate--maillist-region-reader-p (node)
  "Return non-nil when Host NODE is the `maillist' reader root region."
  (let* ((props (plist-get node :props))
         (region (plist-get props :region)))
    (and (listp region)
         (eq (plist-get region :id) 'reader))))

(defun etaf-translate--maillist-body-scroll-p (node)
  "Return non-nil when Host NODE is the `maillist' scrolling email body column."
  (let ((props (plist-get node :props)))
    (and (eq (plist-get props :overflow) 'scroll)
         (equal (plist-get props :aria-label) "邮件正文"))))

(defun etaf-translate--maillist-find-node (nodes pred)
  "Depth-first search NODES for first Host matching PRED."
  (cl-loop for node in nodes
           for hit = (if (funcall pred node)
                         node
                       (etaf-translate--maillist-find-node
                        (plist-get node :children) pred))
           when hit return hit))

(defun etaf-translate--maillist-match-p (runtime buffer)
  "Return non-nil when RUNTIME in BUFFER is a mounted `maillist' reader."
  (and runtime
       (etaf-runtime-mounted-p runtime)
       (buffer-live-p buffer)
       (string-match-p "\\`\\*[Mm]aillist" (buffer-name buffer))
       (not (null (etaf-translate--maillist-find-node
                   (etaf-translate--provider-tree runtime)
                   #'etaf-translate--maillist-body-scroll-p)))))

(defun etaf-translate--maillist-quote-info (text)
  "Return `(DEPTH . BODY)' for quoted email line TEXT, or nil if not quoted."
  (when (string-match "\\`\\(\\(?:[ \t]*>\\)+\\)[ \t]?\\(.*\\)\\'" text)
    (let* ((prefix (match-string 1 text))
           (body (string-trim (match-string 2 text)))
           (depth (cl-count ?> prefix)))
      (cons depth body))))

(defun etaf-translate--maillist-skip-line-p (raw)
  "Return non-nil when plain-text email line RAW is non-prose technical noise."
  (let ((trimmed (string-trim raw)))
    (or (string-empty-p trimmed)
        ;; Indented code / patch blocks (4+ leading spaces or tab).
        (string-match-p "\\`\\(?:    \\|\t\\)" raw)
        ;; Unified diff & git patch markers.
        (string-match-p
         "\\`\\(?:diff --git \\|--- \\|\\+\\+\\+ \\|@@ \\|index [0-9a-f]\\{6,\\}\\.\\|From [0-9a-f]\\{20,\\} \\)"
         trimmed)
        ;; Mail headers quoted inline.
        (string-match-p
         "\\`\\(?:From\\|To\\|Cc\\|Bcc\\|Date\\|Subject\\|Message-ID\\|In-Reply-To\\|References\\):[ \t]"
         trimmed)
        ;; Bare URL or angle-bracketed URL line.
        (string-match-p "\\`<?https?://[^ \t]+>?\\'" trimmed)
        ;; Horizontal ASCII divider rules.
        (string-match-p "\\`[-=_*~#]\\{4,\\}\\'" trimmed)
        ;; Pure email quote attribution lines ("On Sun, ..., Alice wrote:").
        (and (< (length trimmed) 140)
             (string-match-p "\\b\\(?:wrote\\|writes\\|said\\):\\s-*\\'" trimmed)))))

(defun etaf-translate--maillist-signature-start-p (raw)
  "Return non-nil when email line RAW begins a standard signature block."
  (or (string= raw "-- ")
      (string= (string-trim raw) "--")))

(defun etaf-translate--maillist-list-item-p (trimmed)
  "Return non-nil when TRIMMED starts a bullet or numbered list item."
  (string-match-p "\\`\\(?:[-*+•] \\|[0-9]+[.)] \\|([0-9]+) \\)" trimmed))

(defun etaf-translate--maillist-body-lines-column-p (node)
  "Return non-nil when NODE is a `maillist-message' body lines container."
  (and (eq (plist-get node :tag) 'column)
       (let ((children (plist-get node :children)))
         (and children
              (cl-some (lambda (ch) (eq (plist-get ch :tag) 'column))
                       children)))
       (equal (plist-get (plist-get node :props) :padding-left) '(ch 3))))

(defun etaf-translate--maillist-classify-line (line-col)
  "Classify one `maillist-body-line' column Host LINE-COL.
Returns a plist `(:id ID :geo GEO :type TYPE :depth D :text STR :raw RAW)'
where TYPE is `blank', `skip', `quote' or `prose'."
  (let* ((hid (plist-get line-col :id))
         (geo (plist-get line-col :geometry))
         (child (car (plist-get line-col :children)))
         (cprops (and child (plist-get child :props)))
         (ctag (and child (plist-get child :tag)))
         (role (and cprops (plist-get cprops :role)))
         (raw (or (etaf-translate--maillist-node-text line-col) ""))
         (trimmed (string-trim raw)))
    (cond
     ((or (null child) (string-empty-p trimmed))
      (list :id hid :geo geo :type 'blank :raw raw :text ""))
     ;; Interactive rows (quote-fold buttons, links) are UI controls.
     ((eq role 'button)
      (list :id hid :geo geo :type 'skip :raw raw :text trimmed))
     ;; Quote line: box with border-left and quote background.
     ((and (eq ctag 'box) (plist-get cprops :border-left))
      (let ((qinfo (etaf-translate--maillist-quote-info raw)))
        (if (or (null qinfo) (string-empty-p (cdr qinfo)))
            (list :id hid :geo geo :type 'quote-blank :depth (or (car qinfo) 1)
                  :raw raw :text "")
          (list :id hid :geo geo :type 'quote :depth (car qinfo)
                :raw raw :text (cdr qinfo)))))
     ;; Patch add/del lines carry a diff background color.
     ((and (eq ctag 'flex) (plist-get cprops :background-color))
      (list :id hid :geo geo :type 'skip :raw raw :text trimmed))
     ;; Standard prose/text line.
     (t
      (list :id hid :geo geo :type 'prose :raw raw :text trimmed)))))

(defun etaf-translate--maillist-attribution-p (text)
  "Return non-nil when joined paragraph TEXT is a pure quote attribution line."
  (let ((s (string-trim text)))
    (and (< (length s) 220)
         (or (string-match-p
              "\\`On [^\n]+\\b\\(?:wrote\\|writes\\|said\\):\\s-*\\'" s)
             (string-match-p
              "<[^ \t>]+@[^ \t>]+>\\s-*\\(?:wrote\\|writes\\|said\\)?:?\\s-*\\'" s)))))

(defun etaf-translate--maillist-extract-message-body (body-col target-lang groups)
  "Extract logical prose and quote paragraph units from BODY-COL.
Populates GROUPS map (`ANCHOR-ID -> MEMBER-HOST-IDS') and returns unit list."
  (let ((cur-type nil)
        (cur-depth nil)
        (cur-texts nil)
        (cur-ids nil)
        (cur-geo nil)
        (in-sig nil)
        (units nil))
    (cl-labels
        ((flush ()
           (when (and cur-texts cur-ids)
             (let* ((ordered-ids (nreverse cur-ids))
                    (anchor-id (car (last ordered-ids)))
                    (joined (etaf-translate--reader-join-lines (nreverse cur-texts)))
                    (kind (if (eq cur-type 'quote) 'quote-paragraph 'paragraph)))
               (when (and (etaf-translate-text-meaningful-p joined)
                          (not (etaf-translate--maillist-attribution-p joined))
                          (not (etaf-translate-text-matches-target-p joined target-lang)))
                 (puthash anchor-id ordered-ids groups)
                 (push (etaf-translate-make-unit
                        :id anchor-id
                        :text joined
                        :kind kind
                        :geometry cur-geo)
                       units))))
           (setq cur-type nil cur-depth nil cur-texts nil cur-ids nil cur-geo nil)))
      (dolist (child (plist-get body-col :children))
        (when (and (not in-sig) (eq (plist-get child :tag) 'column))
          (let* ((info (etaf-translate--maillist-classify-line child))
                 (ltype (plist-get info :type))
                 (raw (plist-get info :raw))
                 (text (plist-get info :text))
                 (hid (plist-get info :id))
                 (geo (plist-get info :geo))
                 (depth (plist-get info :depth)))
            (cond
             ((eq ltype 'blank)
              (flush))
             ((eq ltype 'quote-blank)
              (flush))
             ((eq ltype 'skip)
              (flush))
             ((eq ltype 'quote)
              (unless (and (eq cur-type 'quote) (eql cur-depth depth))
                (flush))
              (if (etaf-translate--maillist-skip-line-p text)
                  (flush)
                (when (and cur-texts (etaf-translate--maillist-list-item-p text))
                  (flush))
                (setq cur-type 'quote cur-depth depth cur-geo geo)
                (push text cur-texts)
                (push hid cur-ids)))
             ((eq ltype 'prose)
              (cond
               ((etaf-translate--maillist-signature-start-p raw)
                (flush)
                (setq in-sig t))
               ((etaf-translate--maillist-skip-line-p raw)
                (flush))
               (t
                (unless (eq cur-type 'prose)
                  (flush))
                (when (and cur-texts (etaf-translate--maillist-list-item-p text))
                  (flush))
                (setq cur-type 'prose cur-depth nil cur-geo geo)
                (push text cur-texts)
                (push hid cur-ids))))))))
      (flush))
    (nreverse units)))

(defun etaf-translate--maillist-extract (runtime policy)
  "Extract thread heading and logical email paragraphs from `maillist' RUNTIME."
  (let* ((tree (etaf-translate--provider-tree runtime))
         (target-lang (plist-get policy :target-lang))
         (reader (or (etaf-translate--maillist-find-node
                      tree #'etaf-translate--maillist-region-reader-p)
                     (etaf-translate--maillist-find-node
                      tree #'etaf-translate--maillist-body-scroll-p)))
         (scroll-body (and reader
                           (etaf-translate--maillist-find-node
                            (list reader) #'etaf-translate--maillist-body-scroll-p)))
         (groups (make-hash-table :test #'eql))
         (units nil))
    (puthash runtime groups etaf-translate--maillist-groups)
    ;; 1. Thread subject heading (clean subtitle without noisy bar).
    (when reader
      (when-let* ((hdr-node
                   (etaf-translate--maillist-find-node
                    (list reader)
                    (lambda (n)
                      (let ((cls (plist-get (plist-get n :props) :class)))
                        (and (eq (plist-get n :tag) 'box)
                             (stringp cls)
                             (string-search "heading" cls)))))))
        (let ((subj (string-trim (etaf-translate--maillist-node-text hdr-node))))
          (when (and (etaf-translate-text-meaningful-p subj)
                     (not (etaf-translate-text-matches-target-p subj target-lang)))
            (push (etaf-translate-make-unit
                   :id (plist-get hdr-node :id)
                   :text subj
                   :kind 'heading
                   :geometry (plist-get hdr-node :geometry))
                  units)))))
    ;; 2. Walk every message body container inside the scrolling reader column.
    (when scroll-body
      (cl-labels
          ((collect-bodies (nodes)
             (dolist (n nodes)
               (if (etaf-translate--maillist-body-lines-column-p n)
                   (setq units (nconc units
                                      (etaf-translate--maillist-extract-message-body
                                       n target-lang groups)))
                 (collect-bodies (plist-get n :children))))))
        (collect-bodies (plist-get scroll-body :children))))
    units))

(defun etaf-translate--maillist-apply (runtime unit translated mode style)
  "Apply TRANSLATED paragraph cleanly to `maillist' UNIT in RUNTIME."
  (let* ((hid (etaf-translate-unit-host-id unit))
         (kind (etaf-translate-unit-kind unit))
         (groups (gethash runtime etaf-translate--maillist-groups))
         (members (and groups (gethash hid groups)))
         (earlier (and members (butlast members)))
         (palette (etaf-translate--palette runtime))
         (updates nil))
    (if (etaf-translate--same-as-source-p unit translated)
        (progn
          (dolist (mid earlier) (push (cons mid nil) updates))
          (push (cons hid nil) updates))
      (pcase mode
        ('replace
         ;; Replace mode hides wrapped prefix lines and renders the complete
         ;; translated paragraph once on the anchor with hover-original tooltip.
         (dolist (mid earlier)
           (push (cons mid (list :mode 'override
                                 :view (etaf-node 'fragment nil nil)))
                 updates))
         (let* ((orig-tip (etaf-translate-unit-source-text unit))
                (fg (if (eq kind 'quote-paragraph)
                        (plist-get palette :muted)
                      (plist-get palette :fg)))
                (props (append
                        (list :width 'stretch :wrap-mode 'word :color fg)
                        (when (eq kind 'quote-paragraph)
                          (list :background-color (plist-get palette :quote-bg)
                                :border-left (list '(px 2) 'solid
                                                   (plist-get palette :quote-bar))
                                :padding-left '(ch 1)))
                        (when (and (stringp orig-tip) (not (string-empty-p orig-tip)))
                          (list :help-echo orig-tip))))
                (view (etaf-node 'box props
                                 (list (etaf-node 'text nil (list translated))))))
           (push (cons hid (list :mode 'override :view view)) updates)))
        (_
         ;; Bilingual mode keeps all wrapped original lines intact and attaches
         ;; ONE complete translated paragraph cleanly below the anchor line.
         (dolist (mid earlier) (push (cons mid nil) updates))
         (let ((view (etaf-translate--styled-companion-view
                      runtime unit translated style palette)))
           (push (cons hid (list :mode (if (eq kind 'heading)
                                           'companion-inside
                                         'companion-after)
                                 :view view))
                 updates)))))
    (etaf-translate--provider-present runtime (nreverse updates))))

(defun etaf-translate--maillist-clear (runtime)
  "Restore `maillist' lines by clearing `etaf-translate' presentations."
  (remhash runtime etaf-translate--maillist-groups)
  (etaf-translate--provider-clear runtime))

(etaf-translate-register-provider
 'maillist
 :match #'etaf-translate--maillist-match-p
 :extract #'etaf-translate--maillist-extract
 :apply #'etaf-translate--maillist-apply
 :clear #'etaf-translate--maillist-clear)

(provide 'etaf-translate-integrations)
;;; etaf-translate-integrations.el ends here
