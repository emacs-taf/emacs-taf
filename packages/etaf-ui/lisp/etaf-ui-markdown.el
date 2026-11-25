;;; etaf-ui-markdown.el --- Markdown document rendering for etaf-ui -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; Markdown document rendering shared by ETAF applications.  The functions
;; turn the block tree of `etaf-ui-markdown-parse' into ordinary ETAF Views:
;; headings, paragraphs, lists, blockquote callouts, pipe tables, fenced code
;; blocks, footnotes and inline emphasis, code, links and media placeholders.
;; Presentation is data-driven: every color comes from the caller's `:palette'
;; alist, and media and code blocks go through caller callbacks, so one
;; renderer serves a previewer, a manual reader or any other document view.
;;
;; The renderer owns no state and no buffer; it is a pure function of a block
;; tree plus an environment plist, which makes it usable for headless tests and
;; inside a mounted Component alike.  See `etaf-ui-markdown-view-block' and
;; `etaf-ui-markdown-view-blocks' for the environment contract.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'etaf)
(require 'etaf-ui-basic)
(require 'etaf-ui-feedback)
(require 'etaf-ui-icon)
(require 'etaf-ui-markdown-parse)
(require 'etaf-ui-markdown-highlight)



;;; ---------------------------------------------------------------------------

(defun etaf-ui-markdown--env-color (env key)
  "Return ENV's color for semantic KEY.
ENV carries a `:palette' alist of semantic color keys; a missing palette or an
unknown key signals `etaf-ui-markdown-error'."
  (let ((palette (plist-get env :palette)))
    (unless palette
      (signal 'etaf-ui-markdown-error
              (list "Markdown rendering requires a :palette")))
    (or (cdr (assq key palette))
        (signal 'etaf-ui-markdown-error
                (list (format "Unknown markdown color: %S" key))))))

(defun etaf-ui-markdown--env-color-or (env key fallback-key)
  "Return ENV's color for KEY, or its FALLBACK-KEY when KEY is absent.
A palette may leave an optional key out; the fallback keeps the renderer from
requiring every palette to name a color it never wanted to choose."
  (let ((palette (plist-get env :palette)))
    (or (and palette (cdr (assq key palette)))
        (etaf-ui-markdown--env-color env fallback-key))))

(defun etaf-ui-markdown--mono-family ()
  "Return the family code spans paint with, or nil for the body family.
A theme provides `:font-mono' when it wants code set apart.  Without that
token the body family is the honest default: Emacs's `fixed-pitch' face
names the generic family \"Monospace\", which no font backs on Windows, so
code silently switched to Courier at a different size."
  (let ((family (etaf-theme-token :font-mono nil)))
    (and (stringp family) (not (string-empty-p family)) family)))

(defun etaf-ui-markdown--heading-ratio (level)
  "Return the heading size for LEVEL as a multiple of the body size.
The steps are the ones a markdown page uses on the web, so a document reads at
the rank it was written in: level 1 is twice the body, level 2 one and a half,
level 3 one and a quarter, and level 4 a little above the body.  Levels 5 and 6
keep the body size, because a heading is never painted smaller than the text it
introduces, and their muted colour tells them apart instead.  A ratio follows
the reader's default font on any platform instead of assuming a body size in
CSS pixels."
  (pcase level
    (1 2.0)
    (2 1.5)
    (3 1.25)
    (4 1.1)
    (_ 1.0)))

(defun etaf-ui-markdown--divider (&optional label)
  "Return a horizontal divider View, optionally labeled."
  (etaf-node 'etaf-divider (list :orientation 'horizontal :label label) nil))

(defun etaf-ui-markdown--spacer (&optional lines)
  "Return an empty spacer Box LINES lines tall."
  (etaf-node 'box (list :height (list 'lh (or lines 1))) nil))


(defun etaf-ui-markdown--dark-page-p (env)
  "Return non-nil when ENV paints a dark page.
A page with a background of its own is judged by that surface; `auto' paints
none and follows the frame the reader is looking at."
  (let ((background (plist-get env :background)))
    (if (and background (stringp background))
        (<= (etaf-ui-color-contrast background "#000000") 1.5)
      (eq (etaf-appearance) 'dark))))

(defun etaf-ui-markdown--code-color (env)
  "Return ENV's background for code surfaces.
The palette may provide `:code-bg'; without it code uses `:panel'."
  (etaf-ui-markdown--env-color
   env (if (assq :code-bg (plist-get env :palette)) :code-bg :panel)))

(defun etaf-ui-markdown--heading-underline-p (env)
  "Return non-nil when headings in ENV draw rules and link underlines."
  (if (plist-member env :heading-underline)
      (plist-get env :heading-underline)
    t))

(defun etaf-ui-markdown--run-props (run env)
  "Return the ETAF style props of inline RUN in ENV."
  (let ((props nil))
    (when (plist-get run :bold)
      (setq props (plist-put props :font-weight 'bold)))
    (when (plist-get run :italic)
      (setq props (plist-put props :font-style 'italic)))
    (when (plist-get run :strike)
      (setq props (plist-put props :text-decoration-line '(line-through))))
    (when (plist-get run :code)
      (setq props (plist-put props :background-color
                             (etaf-ui-markdown--code-color env)))
      (let ((mono (etaf-ui-markdown--mono-family)))
        (when mono (setq props (plist-put props :font-family mono)))))
    (when (plist-get run :link)
      (setq props (plist-put props :color (etaf-ui-markdown--env-color env :accent)))
      (unless (plist-get run :no-underline)
        (setq props (plist-put props :text-decoration-line '(underline)))))
    (when (plist-get run :muted)
      (setq props (plist-put props :color (etaf-ui-markdown--env-color env :muted))))
    (when (plist-get run :math)
      ;; A formula is not code: italic sets it apart and keeps the reader's
      ;; line height, which a raised or lowered glyph would not.
      (setq props (plist-put props :font-style 'italic)))
    (when-let* ((title (plist-get run :abbreviation)))
      (unless (plist-get run :no-underline)
        (setq props (plist-put props :text-decoration-line '(underline))))
      (setq props (plist-put props :help-echo title)))
    (when (plist-member run :mark)
      ;; A marker is a fill behind the text.  The run also takes the page ink:
      ;; a fill alone merges back into the surrounding text, and a marker has
      ;; to stand apart from it in every palette.  A marker without a class is
      ;; still a marker, so the key's presence is what counts.
      (let* ((class (plist-get run :mark))
             (variant (pcase (and class (downcase class))
                       ((or "warning" "warn" "caution") 'warning)
                       ((or "danger" "error" "important") 'danger)
                       ((or "success" "tip") 'success)
                       ((or "info" "note") 'info)
                       (_ 'warning))))
        (setq props (plist-put props :color (etaf-ui-markdown--run-ink env)))
        (setq props (plist-put props :background-color
                               (etaf-ui-markdown--run-soft-fill env variant)))))
    (when (plist-get run :kbd)
      ;; A run is a text node, so its colours are the page's own strings.
      (let* ((palette (plist-get env :palette))
             (fill (or (etaf-ui-markdown--palette-value palette :panel2)
                       (etaf-ui-markdown--palette-value palette :panel))))
        (when fill (setq props (plist-put props :background-color fill)))
        (when-let* ((ink (etaf-ui-markdown--run-ink env)))
          (setq props (plist-put props :color ink))))
      (setq props (plist-put props :font-weight 'bold)))
    (when-let* ((variant (plist-get run :badge)))
      (let ((variant (etaf-ui-markdown--badge-variant variant)))
        (setq props (plist-put props :color (etaf-ui-markdown--run-ink env)))
        (setq props (plist-put props :background-color
                               (etaf-ui-markdown--run-soft-fill env variant)))
        (setq props (plist-put props :font-weight 'bold))))
    props))

(defun etaf-ui-markdown--palette-value (palette key)
  "Return KEY's colour from PALETTE, in alist or plist form."
  (or (alist-get key palette) (plist-get palette key)))

(defun etaf-ui-markdown--run-soft-fill (env variant)
  "Return the page palette's soft fill for VARIANT in ENV.
A highlight, a key cap and a badge are fills behind text, so they read the
page's own soft colours.  A palette without them falls back to its panel, so
the run keeps a surface instead of nothing."
  (let ((palette (plist-get env :palette)))
    (pcase variant
      ('warning (or (etaf-ui-markdown--palette-value palette :warn-soft)
                    (etaf-ui-markdown--palette-value palette :panel)))
      ('danger (or (etaf-ui-markdown--palette-value palette :danger-soft)
                   (etaf-ui-markdown--palette-value palette :panel)))
      ('success (or (etaf-ui-markdown--palette-value palette :ok-soft)
                    (etaf-ui-markdown--palette-value palette :panel)))
      ('info (or (etaf-ui-markdown--palette-value palette :accent-soft)
                 (etaf-ui-markdown--palette-value palette :panel)))
      (_ (or (etaf-ui-markdown--palette-value palette :panel)
             (etaf-ui-markdown--palette-value palette :panel2))))))

(defun etaf-ui-markdown--run-ink (env)
  "Return the page ink a filled run writes with.
The soft fills are built for the page ink in both palettes, so a run never
needs a second semantic colour of its own."
  (let ((palette (plist-get env :palette)))
    (or (etaf-ui-markdown--palette-value palette :ink)
        (etaf-ui-markdown--palette-value palette :fg))))

(defun etaf-ui-markdown--badge-variant (class)
  "Return the badge variant named by CLASS."
  (pcase (and class (downcase class))
    ((or "warning" "warn" "caution") 'warning)
    ((or "danger" "error" "important") 'danger)
    ((or "success" "tip") 'success)
    ((or "info" "note") 'info)
    (_ 'neutral)))

(defun etaf-ui-markdown--block-state (env key &optional default)
  "Read KEY from ENV's per-block interactive state, or return DEFAULT."
  (if-let* ((getter (plist-get env :block-state)))
      (funcall getter key default)
    default))

(defun etaf-ui-markdown--set-block-state (env key value)
  "Store VALUE under KEY in ENV's per-block interactive state."
  (when-let* ((setter (plist-get env :set-block-state)))
    (funcall setter key value))
  value)

(defun etaf-ui-markdown--hover-p (env)
  "Return non-nil when ENV enables pointer hover highlights on controls."
  (if (plist-member env :link-hover)
      (plist-get env :link-hover)
    t))

(defun etaf-ui-markdown--hover-fill (env &optional variant)
  "Return a theme-derived hover background fill for ENV, or nil when disabled."
  (when (etaf-ui-markdown--hover-p env)
    (pcase variant
      ('soft (etaf-ui-markdown--env-color-or env :panel2 :panel))
      (_ (etaf-ui-markdown--env-color-or env :accent-soft :panel2)))))

(defun etaf-ui-markdown--plot-view (node env)
  "Return interactive spoiler/cloze View for plot NODE in ENV."
  (let* ((plain (etaf-ui-markdown--plain-text (plist-get node :children)))
         (key (cons 'plot (plist-get node :text)))
         (revealed (or (plist-get env :reveal-spoilers)
                       (etaf-ui-markdown--block-state env key nil)))
         (mask-width (max 2 (string-width plain)))
         (panel (etaf-ui-markdown--env-color-or env :panel2 :panel))
         (muted (etaf-ui-markdown--env-color env :muted))
         (ink (etaf-ui-markdown--env-color env :ink))
         (hover (etaf-ui-markdown--hover-fill env))
         (toggle (lambda ()
                   (etaf-ui-markdown--set-block-state env key (not revealed)))))
    (if revealed
        (etaf-node 'text
                   (append
                    (list :color ink
                          :background-color (etaf-ui-markdown--env-color-or env :panel :panel2)
                          :role 'button :tab-index 0 :pointer 'hand
                          :help-echo "点击重新隐藏"
                          :on-press toggle)
                    (when hover (list :hover-style (list :background-color hover))))
                   (list (format " %s " plain)))
      (etaf-node 'text
                 (append
                  (list :color muted
                        :background-color panel
                        :role 'button :tab-index 0 :pointer 'hand
                        :help-echo "点击显示隐秘内容"
                        :on-press toggle)
                  (when hover (list :hover-style (list :background-color hover))))
                 (list (concat " " (make-string mask-width ?░) " "))))))

(defun etaf-ui-markdown--annotation-ref-view (node env)
  "Return clickable inline annotation trigger View for NODE in ENV."
  (let* ((label (plist-get node :label))
         (key (cons 'annotation label))
         (open (etaf-ui-markdown--block-state env key nil))
         (accent (etaf-ui-markdown--env-color env :accent))
         (soft (etaf-ui-markdown--env-color-or env :accent-soft :panel))
         (hover (unless open (etaf-ui-markdown--hover-fill env))))
    (etaf-node 'text
               (append
                (list :color accent
                      :background-color (when open soft)
                      :font-weight 'bold
                      :role 'button :tab-index 0 :pointer 'hand
                      :aria-expanded (if open t 'false)
                      :help-echo (format "注释 %s（按 RET 展开/收起）" label)
                      :on-press (lambda ()
                                  (etaf-ui-markdown--set-block-state env key (not open))))
                (when hover (list :hover-style (list :background-color hover))))
               (list (format "[+%s]" label)))))

(defun etaf-ui-markdown--abbreviation-view (node env)
  "Return interactive abbreviation View for NODE in ENV."
  (let* ((word (or (plist-get node :text) ""))
         (title (or (plist-get node :title) ""))
         (interactive-p (functionp (plist-get env :set-block-state)))
         (key (cons 'abbr word))
         (open (and interactive-p (etaf-ui-markdown--block-state env key nil)))
         (soft (etaf-ui-markdown--env-color-or env :accent-soft :panel))
         (hover (and interactive-p (not open) (etaf-ui-markdown--hover-fill env))))
    (etaf-node 'text
               (append
                (list :text-decoration-line '(underline)
                      :help-echo (if interactive-p
                                     (format "%s（按 RET 展开说明）" title)
                                   title))
                (when open (list :background-color soft))
                (when interactive-p
                  (list :role 'button :tab-index 0 :pointer 'hand
                        :on-press (lambda ()
                                    (etaf-ui-markdown--set-block-state
                                     env key (not open)))))
                (when hover (list :hover-style (list :background-color hover))))
               (list word))))

(defun etaf-ui-markdown--wiki-link-view (node env)
  "Return clickable wiki-link View for NODE in ENV."
  (let* ((target (plist-get node :target))
         (anchor (plist-get node :anchor))
         (label (or (plist-get node :label) target ""))
         (open-wiki (plist-get env :open-wiki-link))
         (open-link (plist-get env :open-link))
         (dest (if (and anchor (not (string-empty-p anchor)))
                   (format "%s#%s" (or target "") anchor)
                 (or target "")))
         (hover (etaf-ui-markdown--hover-fill env)))
    (etaf-node 'text
               (append
                (list :color (etaf-ui-markdown--env-color env :accent)
                      :text-decoration-line '(underline)
                      :role 'link :tab-index 0 :pointer 'hand
                      :help-echo (format "[[%s]]" dest)
                      :on-press (lambda ()
                                  (cond
                                   ((functionp open-wiki)
                                    (funcall open-wiki target anchor label))
                                   ((functionp open-link)
                                    (funcall open-link dest)))))
                (when hover (list :hover-style (list :background-color hover))))
               (list label))))

(defun etaf-ui-markdown--symbol-view (node env)
  "Return clickable Emacs symbol chip View for NODE in ENV."
  (let* ((name (or (plist-get node :name) ""))
         (mono (etaf-ui-markdown--mono-family))
         (accent (etaf-ui-markdown--env-color env :accent))
         (panel (etaf-ui-markdown--env-color-or env :panel2 :panel))
         (hover (etaf-ui-markdown--hover-fill env))
         (on-symbol (plist-get env :open-symbol)))
    (etaf-node 'text
               (append
                (list :color accent
                      :background-color panel
                      :role 'link :tab-index 0 :pointer 'hand
                      :help-echo (format "Emacs 符号：%s（按 RET 查看/跳转）" name)
                      :on-press (lambda ()
                                  (when (functionp on-symbol)
                                    (funcall on-symbol name))))
                (when mono (list :font-family mono))
                (when hover (list :hover-style (list :background-color hover))))
               (list (format " ƒ %s " name)))))

(defun etaf-ui-markdown--collect-inline-popups (nodes env)
  "Return open inline annotation/abbreviation detail Views for NODES in ENV."
  (let ((popups nil)
        (seen (make-hash-table :test #'equal))
        (annotations (plist-get env :annotations)))
    (cl-labels
        ((walk (items)
           (dolist (node items)
             (pcase (plist-get node :type)
               ('annotation-ref
                (let* ((label (plist-get node :label))
                       (key (cons 'annotation label)))
                  (when (and (not (gethash key seen))
                             (etaf-ui-markdown--block-state env key nil))
                    (puthash key t seen)
                    (when-let* ((blocks (cdr (assoc label annotations))))
                      (push (etaf-ui-markdown--inline-popup-card
                             label blocks key env)
                            popups)))))
               ('abbreviation
                (let* ((word (plist-get node :text))
                       (title (plist-get node :title))
                       (key (cons 'abbr word)))
                  (when (and (not (gethash key seen))
                             (etaf-ui-markdown--block-state env key nil))
                    (puthash key t seen)
                    (push (etaf-ui-markdown--inline-popup-card
                           word
                           (list (list :type 'paragraph
                                       :children (list (list :type 'text
                                                             :text title))))
                           key env)
                          popups))))
               (_ (when-let* ((kids (plist-get node :children)))
                    (walk kids)))))))
      (walk nodes))
    (nreverse popups)))

(defun etaf-ui-markdown--inline-popup-card (title blocks state-key env)
  "Return a compact inline explanation card for TITLE and BLOCKS in ENV.
STATE-KEY is toggled off when the user activates the close leaf button."
  (let* ((accent (etaf-ui-markdown--env-color env :accent))
         (panel (etaf-ui-markdown--env-color-or env :panel :panel2))
         (border (etaf-ui-markdown--env-color env :border))
         (muted (etaf-ui-markdown--env-color env :muted))
         (hover (etaf-ui-markdown--hover-fill env)))
    (etaf-node
     'column
     (list :width 'stretch :item-gap '(lh 0)
           :background-color panel
           :border-top (list '(px 1) 'solid border)
           :border-right (list '(px 1) 'solid border)
           :border-bottom (list '(px 1) 'solid border)
           :border-left (list '(px 3) 'solid accent)
           :padding '((lh 0) (ch 2)))
     (append
      (list
       (etaf-node
        'flex
        (list :width 'stretch :align-items 'center)
        (list
         (etaf-node 'text (list :color accent :font-weight 'bold)
                    (list title))
         (etaf-node 'box (list :flex-basis '(ch 0) :flex-grow 1) nil)
         (etaf-node 'text
                    (append
                     (list :color muted :role 'button :tab-index 0
                           :pointer 'hand :help-echo "收起说明"
                           :on-press (lambda ()
                                       (etaf-ui-markdown--set-block-state
                                        env state-key nil)))
                     (when hover
                       (list :hover-style (list :background-color hover))))
                    (list " × ")))))
      (etaf-ui-markdown-view-blocks blocks env t)))))

(defun etaf-ui-markdown--flatten-inlines (nodes inherited env)
  "Return styled run entries for inline NODES in ENV.
INHERITED is the style attribute plist of the enclosing inline element.
Entries are (:text STRING :props PLIST) or (:view VIEW)."
  (let (result)
    (dolist (node nodes)
      (pcase (plist-get node :type)
        ('text
         (push (list :text (or (plist-get node :text) "") :props inherited) result))
        ('break
         ;; A soft break is a space: CommonMark reads the source line end
         ;; inside a paragraph as a space, so the paragraph flows and wraps at
         ;; the column width the way a browser shows it.  A hard break, written
         ;; with two trailing spaces or a backslash, is the author asking for a
         ;; line end and paints one.
         (push (list :text (if (plist-get node :hard) "\n" " ") :props inherited)
               result))
        ('code
         (push (list :text (or (plist-get node :text) "")
                     :props (plist-put (copy-sequence inherited) :code t))
               result))
        ((or 'subscript 'superscript)
         ;; The parser wrote the script form, so the page shows `H₂O' without
         ;; shrinking anything: the line keeps the reader's own type size.
         (push (list :text (or (plist-get node :rendered)
                               (plist-get node :text)
                               "")
                     :props inherited)
               result))
        ('abbreviation
         (if (functionp (plist-get env :set-block-state))
             (push (list :view (etaf-ui-markdown--abbreviation-view node env)) result)
           (push (list :text (or (plist-get node :text) "")
                       :props (plist-put (copy-sequence inherited)
                                         :abbreviation (plist-get node :title)))
                 result)))
        ('plot
         (push (list :view (etaf-ui-markdown--plot-view node env)) result))
        ('annotation-ref
         (push (list :view (etaf-ui-markdown--annotation-ref-view node env)) result))
        ('wiki-link
         (push (list :view (etaf-ui-markdown--wiki-link-view node env)) result))
        ('comment nil)
        ('color-chip
         (let ((hex (plist-get node :color))
               (mono (etaf-ui-markdown--mono-family))
               (panel (etaf-ui-markdown--code-color env)))
           (push (list :view
                       (etaf-node 'text (list :color hex) (list "■")))
                 result)
           (push (list :text (concat " " hex)
                       :props (let ((p (copy-sequence inherited)))
                                (setq p (plist-put p :code t))
                                (when mono (setq p (plist-put p :font-family mono)))
                                (when panel (setq p (plist-put p :background-color panel)))
                                p))
                 result)))
        ('symbol
         (push (list :view (etaf-ui-markdown--symbol-view node env)) result))
        ('emoji
         ;; A shortcode paints as its character; the source keeps the name, so
         ;; the page shows a picture and the file stays readable text.
         (push (list :text (or (plist-get node :char) (plist-get node :text) "")
                     :props inherited)
               result))
        ('math
         (push (list :text (etaf-ui-markdown-math-text
                            (or (plist-get node :text) ""))
                     :props (plist-put (copy-sequence inherited) :math t))
               result))
        ('mark
         (setq result
               (append (nreverse
                        (etaf-ui-markdown--flatten-inlines
                         (plist-get node :children)
                         (plist-put (copy-sequence inherited)
                                    :mark (plist-get node :class))
                         env))
                       result)))
        ('icon
         ;; An icon paints as its glyph run: a nested View would become a
         ;; block of its own inside the paragraph and break the line.
         (push (list :text (or (car (etaf-ui-icon-lines (plist-get node :name))) "")
                     :props inherited)
               result))
        ('kbd
         (push (list :text (concat " "
                                   (mapconcat #'identity (plist-get node :keys) "+")
                                   " ")
                     :props (plist-put (copy-sequence inherited) :kbd t))
               result))
        ('badge
         (push (list :text (concat " " (or (plist-get node :content) "") " ")
                     :props (plist-put (copy-sequence inherited)
                                       :badge (plist-get node :variant)))
               result))
        ((or 'emph 'strong 'strike)
         (let ((child (copy-sequence inherited)))
           (when (eq (plist-get node :type) 'emph)
             (setq child (plist-put child :italic t)))
           (when (eq (plist-get node :type) 'strong)
             (setq child (plist-put child :bold t)))
           (when (eq (plist-get node :type) 'strike)
             (setq child (plist-put child :strike t)))
           (setq result
                 (append (nreverse
                          (etaf-ui-markdown--flatten-inlines
                           (plist-get node :children) child env))
                         result))))
        ((or 'link 'autolink)
         (let ((child (plist-put (copy-sequence inherited) :link (plist-get node :url))))
           (setq result
                 (append (nreverse
                          (etaf-ui-markdown--flatten-inlines
                           (plist-get node :children) child env))
                         result))))
        ('footnote-ref
         (push (list :view (etaf-ui-markdown--footnote-view node env)) result))
        ('image
         (push (list :view (etaf-ui-markdown--render-media 'inline-image node env))
               result))
        ('html
         (push (list :text (or (plist-get node :text) "")
                     :props (plist-put (copy-sequence inherited) :muted t))
               result))
        (_ nil)))
    (nreverse result)))

(defun etaf-ui-markdown--inline-runs (inlines env base)
  "Flatten INLINES into styled runs for ENV.
BASE is the plist of style attributes inherited from the enclosing block.
Adjacent text runs with equal styles are merged into one entry."
  (let ((runs nil))
    (dolist (run (etaf-ui-markdown--flatten-inlines inlines base env))
      (let* ((previous (car runs))
             (text (plist-get run :text))
             (props (plist-get run :props))
             (merge (and previous
                         (not (plist-get previous :view))
                         (not (plist-get run :view))
                         (plist-get previous :text)
                         (equal (plist-get previous :props) props)
                         (not (string-suffix-p "\n" (plist-get previous :text)))
                         (not (string-prefix-p "\n" text)))))
        (if merge
            (setcar runs (plist-put previous :text
                                    (concat (plist-get previous :text) text)))
          (push run runs))))
    (nreverse runs)))

(defun etaf-ui-markdown--render-media (kind node env)
  "Render media NODE of KIND through ENV's `:render-media', or a placeholder.
KIND is `image' for a block image, `video' for a block video, `inline-image'
for an inline image and `html-media' for a source-bearing HTML media element.
NODE is the parsed inline or a media descriptor.  Without `:render-media' the
renderer keeps the document text: the media's alt text or URL."
  (if-let* ((renderer (plist-get env :render-media)))
      (funcall renderer kind node env)
    (etaf-node 'text
               (list :color (etaf-ui-markdown--env-color env :muted))
               (list (format "[%s]" (or (plist-get node :alt)
                                         (plist-get node :url)
                                         "media"))))))

(defun etaf-ui-markdown--code-link (run env)
  "Return (URL . HELP) when code RUN links through ENV, or nil.
ENV's `:code-link' is called with the code text; it may return a URL string
or a (URL . HELP) cons.  Only code spans are asked."
  (when-let* ((callback (plist-get env :code-link))
              (text (plist-get run :text))
              ((plist-get (plist-get run :props) :code)))
    (let ((link (funcall callback text)))
      (cond ((stringp link) (cons link link))
            ((and (consp link) (stringp (car link))) link)
            (t nil)))))

(defun etaf-ui-markdown--runs-view (inlines env base &optional extra)
  "Return ETAF children for INLINES in ENV.
BASE is a run-attribute plist (`:bold', `:italic', `:strike', `:code',
`:link', `:muted'); EXTRA is an Ebox style plist applied to every text run."
  (let ((nodes nil))
    (dolist (run (etaf-ui-markdown--inline-runs inlines env base))
      (if-let* ((view (plist-get run :view)))
          (push view nodes)
        (let* ((attributes (plist-get run :props))
               (text (plist-get run :text))
               (code-link (etaf-ui-markdown--code-link run env))
               (props (let ((merged (copy-sequence extra))
                            (inline (etaf-ui-markdown--run-props attributes env)))
                        ;; Heading typography supplies defaults; an inline
                        ;; link or code span overrides only its own properties.
                        (while inline
                          (setq merged (plist-put merged (pop inline) (pop inline))))
                        merged))
               (url (or (plist-get attributes :link) (car code-link)))
               (help (or (cdr code-link) url))
               (open (plist-get env :open-link))
               (props (if url
                          (let* ((hover-p (if (plist-member env :link-hover)
                                              (plist-get env :link-hover)
                                            t))
                                 (result (append props
                                                 (list :role 'link :tab-index 0
                                                       :pointer 'hand :help-echo help)
                                                 (when hover-p
                                                   (list :hover-style
                                                         (list :background-color
                                                               (etaf-ui-markdown--env-color
                                                                env :accent-soft)))))))
                            ;; A code link may share a span with its own text
                            ;; decoration; a second entry would be a duplicate
                            ;; View property.
                            (when (and code-link
                                       (not (plist-get attributes :no-underline)))
                              (setq result (plist-put
                                            result :text-decoration-line '(underline))))
                            (append result
                                    (list :on-press (when open
                                                      (lambda () (funcall open url))))))
                        props)))
          (push (etaf-node 'text props (list text)) nodes))))
    (nreverse nodes)))

(defun etaf-ui-markdown--footnote-view (node env)
  "Return the superscript reference View of footnote NODE in ENV."
  (let ((number (or (plist-get node :number)
                    (plist-get node :label)))
        (label (plist-get node :label))
        (hover (etaf-ui-markdown--hover-fill env)))
    (etaf-node 'text
               (append
                (list :color (etaf-ui-markdown--env-color env :accent))
                (unless (plist-get env :line-grid)
                  (list :font-size 0.8))
                (list :role 'link :tab-index 0 :pointer 'hand
                      :help-echo (format "Footnote %s" label)
                      :on-press (lambda ()
                                  (when-let* ((jump (plist-get env :footnote-jump)))
                                    (funcall jump label))))
                (when hover (list :hover-style (list :background-color hover))))
               (list (format "[%s]" number)))))

(defun etaf-ui-markdown--paragraph-node (block env)
  "Return the paragraph View of BLOCK in ENV.
A paragraph that contains only one image delegates to ENV's `:render-media'.
When inline annotations or abbreviations inside BLOCK are expanded, renders
their detail cards immediately below the paragraph."
  (let ((children (plist-get block :children)))
    (cond
     ((and (= 1 (length children))
           (eq (plist-get (car children) :type) 'image))
      (etaf-ui-markdown--render-media 'image (car children) env))
     ((cl-every (lambda (child) (eq (plist-get child :type) 'comment)) children)
      nil)
     (t
      (let ((para (etaf-node 'box
                             (list :width 'stretch :wrap-mode 'word)
                             (etaf-ui-markdown--runs-view children env nil)))
            (popups (etaf-ui-markdown--collect-inline-popups children env)))
        (if popups
            (etaf-node 'column (list :width 'stretch :item-gap '(lh 0))
                       (cons para popups))
          para))))))

(defun etaf-ui-markdown--heading-node (block env)
  "Return the heading View of BLOCK in ENV.
With ENV's `:line-grid' the heading keeps the body font size, so its line
has the standard height; the level then shows through color and, for level
2, an accent bar drawn as a left border that occupies no line.  Without
`:line-grid' the top two levels draw a rule from `:heading-rule' under the
text, which sets the level apart even in a theme whose heading color is its
body color."
  (let* ((level (plist-get block :level))
         (grid (plist-get env :line-grid))
         (heading-underline (etaf-ui-markdown--heading-underline-p env))
         (color (cond ((>= level 5) (etaf-ui-markdown--env-color env :muted))
                      ((and grid (= level 1))
                       (etaf-ui-markdown--env-color env :accent))
                      (t (etaf-ui-markdown--env-color env :heading))))
         (base (append (list :bold t)
                       (unless heading-underline
                         (list :no-underline t))))
         (children
          (etaf-ui-markdown--runs-view
           (plist-get block :children) env base
           (append (unless grid
                     (list :font-size (etaf-ui-markdown--heading-ratio level)))
                   (list :color color)))))
    (etaf-node 'box
               (append
                (list :id (plist-get block :id)
                      :width 'stretch
                      ;; The block flow separates every sibling with exactly
                      ;; one blank line, including heading-to-heading, so a
                      ;; heading carries no margin of its own.
                      :margin '((lh 0) (ch 0)))
                (when (and grid (= level 2))
                  (list :border-left
                        (list '(px 3) 'solid
                              (etaf-ui-markdown--env-color env :accent))
                        :padding-left '(ch 1)))
                (when (and (not grid) heading-underline (<= level 2))
                  (list :border-bottom
                        (list '(px 1) 'solid
                              (etaf-ui-markdown--env-color-or
                               env :heading-rule :border))
                        :padding-bottom '(lh 0.35))))
               children)))

(defcustom etaf-ui-markdown-code-renderers nil
  "Renderers for one fenced language, as an alist of (LANGUAGE . FUNCTION).
FUNCTION receives the block and ENV and returns a View, or nil to keep the
default.  A language that needs a program -- a diagram language, a typesetter
-- belongs here, so the parser stays pure and a missing program only means that
block shows its source.  ENV's `:render-code-block' is consulted first, which
lets one caller override the table without changing it."
  :type '(alist :key-type string :value-type function)
  :group 'text)

(defun etaf-ui-markdown--code-block-renderer (block env)
  "Return the View ENV's renderer for BLOCK's language draws, or nil."
  (let* ((lang (plist-get block :lang))
         (entry (and lang (assoc (downcase lang) etaf-ui-markdown-code-renderers))))
    (or (when-let* ((renderer (plist-get env :render-code-block)))
          (funcall renderer block env))
        (when-let* ((renderer (cdr entry)))
          (funcall renderer block env)))))

(defun etaf-ui-markdown--code-block-node (block env)
  "Return the code block View of BLOCK in ENV.
ENV's `:render-code-block', when present, may return a View for the block;
nil falls back to `etaf-ui-markdown-code-renderers', and then to the default
fenced block.  A BLOCK whose `:header' is nil draws without its language
strip, for a caller that already names the language.  A BLOCK whose
`:frame' is nil keeps the syntax colours without its own surface and
border, for a caller that supplies the card around it."
  (or (etaf-ui-markdown--code-block-renderer block env)
      (etaf-ui-markdown--default-code-block-node block env)))

(defconst etaf-ui-markdown--code-mark-regexp
  "[ \t]*\\(?://\\|#\\|;\\|<!--\\)?[ \t]*\\[!code \\([^]]+\\)\\][ \t]*\\(?:-->[ \t]*\\)?$"
  "Trailing marker a code line uses to state how it is painted.")

(defun etaf-ui-markdown--code-numbers (spec)
  "Return the line numbers SPEC names, as `(LOW . HIGH)' pairs.
SPEC is what a fence writes between braces: `4', `6-8', `1,4,6-8'."
  (let ((numbers nil))
    (dolist (part (split-string (or spec "") "[, ]+" t))
      (cond
       ((string-match "\\`\\([0-9]+\\)-\\([0-9]+\\)\\'" part)
        (push (cons (string-to-number (match-string 1 part))
                    (string-to-number (match-string 2 part)))
              numbers))
       ((string-match "\\`[0-9]+\\'" part)
        (let ((number (string-to-number part)))
          (push (cons number number) numbers)))))
    numbers))

(defun etaf-ui-markdown--code-line-marked-p (line-number ranges)
  "Return non-nil when 1-based LINE-NUMBER falls inside any (LOW . HIGH) in RANGES."
  (cl-some (lambda (range)
             (and (<= (car range) line-number)
                  (<= line-number (cdr range))))
           ranges))

(defun etaf-ui-markdown--code-info (block)
  "Return BLOCK's fence options.
Returns a plist of `:lang', `:title', `:lines', `:numbers', `:collapsed-lines',
`:words', `:whitespace' and `:indent-guides'."
  (let* ((info (or (plist-get block :info) ""))
         (title (when (string-match "title=\"\\([^\"]*\\)\"" info)
                  (match-string 1 info)))
         (spec (when (string-match "{\\([^}]*\\)}" info)
                 (match-string 1 info)))
         (numbers (cond
                   ((string-match ":no-line-numbers" info) nil)
                   ((string-match ":line-numbers=\\([0-9]+\\)" info)
                    (string-to-number (match-string 1 info)))
                   ((string-match ":line-numbers" info) 1)
                   (t nil)))
         (collapsed (cond
                     ((string-match ":no-collapsed-lines" info) nil)
                     ((string-match ":collapsed-lines=\\([0-9]+\\)" info)
                      (max 1 (string-to-number (match-string 1 info))))
                     ((string-match ":collapsed-lines\\b" info) 15)
                     (t nil)))
         (whitespace (and (string-match-p ":whitespace\\b" info) t))
         (indent-guides (and (string-match-p ":indent-guides\\b" info) t))
         (stripped (replace-regexp-in-string
                    "title=\"[^\"]*\"\\|{[^}]*}\\|:no-line-numbers\\|:line-numbers\\(=[0-9]+\\)?\\|:no-collapsed-lines\\|:collapsed-lines\\(=[0-9]+\\)?\\|:whitespace\\b\\|:indent-guides\\b"
                    "" info))
         (words nil)
         (pos 0))
    (while (string-match "/\\([^/ \t\n][^/\n]*?\\)/" stripped pos)
      (push (match-string 1 stripped) words)
      (setq pos (match-end 0)))
    (setq stripped (string-trim
                    (replace-regexp-in-string "/[^/ \t\n][^/\n]*?/" "" stripped)))
    (list :lang (and (not (equal stripped ""))
                     (car (split-string stripped "[ \t]+" t)))
          :title title
          :lines (etaf-ui-markdown--code-numbers spec)
          :numbers numbers
          :collapsed-lines collapsed
          :words (nreverse words)
          :whitespace whitespace
          :indent-guides indent-guides)))

(defun etaf-ui-markdown--code-line-states (lines)
  "Return one paint state per entry of LINES and the text without markers.
A line states its paint with a trailing `[!code ...]' comment; the comment
leaves the painted text, and its word becomes the line's state."
  (let ((texts nil)
        (states nil)
        (line-words nil)
        (focus nil))
    (dolist (line lines)
      (let ((state nil)
            (count 0)
            (words nil))
        (while (string-match etaf-ui-markdown--code-mark-regexp line)
          (let ((word (match-string 1 line)))
            (setq line (substring line 0 (match-beginning 0)))
            (cond
             ((equal word "highlight") (setq state 'highlight))
             ((equal word "++") (setq state 'add))
             ((equal word "--") (setq state 'remove))
             ((equal word "warning") (setq state 'warning))
             ((equal word "error") (setq state 'error))
             ((string-match "\\`word:\\(.+\\)\\'" word)
              (push (string-trim (match-string 1 word)) words))
             ((string-match "\\`focus\\(?::\\([0-9]+\\)\\)?\\'" word)
              (setq state 'focus)
              (setq count (if (match-string 1 word)
                              (string-to-number (match-string 1 word)) 0))))))
        (setq focus (or focus (eq state 'focus)))
        (push line texts)
        (push (cons state count) states)
        (push (nreverse words) line-words)))
    (list :texts (nreverse texts)
          :states (nreverse states)
          :words (nreverse line-words)
          :focus focus)))

(defun etaf-ui-markdown--code-highlight-words (runs words word-fill)
  "Split RUNS so every occurrence of WORDS carries `:background-color' WORD-FILL."
  (if (null words)
      runs
    (let ((regexp (mapconcat #'regexp-quote words "\\|")))
      (cl-loop
       for run in runs
       append
       (let ((text (or (plist-get run :text) ""))
             (props (plist-get run :props))
             (pos 0)
             (out nil))
         (while (and (< pos (length text))
                     (string-match regexp text pos))
           (let ((mb (match-beginning 0))
                 (me (match-end 0)))
             (when (> mb pos)
               (push (list :text (substring text pos mb) :props props) out))
             (push (list :text (substring text mb me)
                         :props (plist-put (copy-sequence props)
                                           :word-highlight word-fill))
                   out)
             (setq pos (max (1+ pos) me))))
         (when (< pos (length text))
           (push (list :text (substring text pos) :props props) out))
         (nreverse out))))))

(defun etaf-ui-markdown--code-decorate-leading (runs whitespace indent-guides faint)
  "Decorate leading indentation in RUNS when WHITESPACE or INDENT-GUIDES is set."
  (if (not (or whitespace indent-guides))
      runs
    (let ((in-indent t)
          (col 0)
          (out nil))
      (dolist (run runs (nreverse out))
        (let* ((text (or (plist-get run :text) ""))
               (props (plist-get run :props)))
          (if (not (or in-indent whitespace))
              (push run out)
            (let ((buf "")
                  (flush (lambda (txt p)
                           (unless (string-empty-p txt)
                             (push (list :text txt :props p) out)))))
              (dotimes (i (length text))
                (let ((ch (aref text i)))
                  (cond
                   ((and in-indent (eq ch ?\s))
                    (funcall flush buf props)
                    (setq buf "")
                    (let ((glyph (cond
                                  ((and indent-guides (> col 0) (zerop (% col 2))) "│")
                                  (whitespace "·")
                                  (t " "))))
                      (push (list :text glyph
                                  :props (if (equal glyph " ") props
                                           (list :color faint :raw-color t)))
                            out))
                    (setq col (1+ col)))
                   ((eq ch ?\t)
                    (funcall flush buf props)
                    (setq buf "")
                    (push (list :text (if whitespace "→ " "  ")
                                :props (if whitespace (list :color faint :raw-color t) props))
                          out)
                    (setq col (+ col 2)))
                   ((and whitespace (eq ch ?\s))
                    (funcall flush buf props)
                    (setq buf "")
                    (push (list :text "·" :props (list :color faint :raw-color t)) out)
                    (setq col (1+ col)))
                   (t
                    (setq in-indent nil)
                    (setq buf (concat buf (char-to-string ch)))
                    (setq col (1+ col))))))
              (funcall flush buf props))))))))

(defun etaf-ui-markdown--code-split-runs (runs)
  "Split RUNS at newlines, returning one run list per line."
  (let ((lines (list nil)))
    (dolist (run runs)
      (let ((text (plist-get run :text))
            (start 0))
        (while (<= start (length text))
          (let ((newline (string-search "\n" text start)))
            (if newline
                (progn
                  (when (> newline start)
                    (setcar lines
                            (cons (plist-put (copy-sequence run) :text
                                             (substring text start newline))
                                  (car lines))))
                  (setq lines (cons nil lines))
                  (setq start (1+ newline)))
              (when (> (length text) start)
                (setcar lines
                        (cons (plist-put (copy-sequence run) :text
                                         (substring text start))
                              (car lines))))
              (setq start (1+ (length text))))))))
    (mapcar #'nreverse (nreverse lines))))

(defun etaf-ui-markdown--code-line-colour (props env surface dim)
  "Return the ink of a code run with PROPS on SURFACE, dimmed when DIM.
A token with a role takes the page's own syntax colour; one without keeps the
face's colour.  Every colour is made readable against SURFACE, which is the
row's own fill when it has one; a dimmed row recedes but stays legible."
  (let* ((dark (etaf-ui-markdown--dark-page-p env))
         (ink (etaf-ui-markdown--env-color env :ink))
         (colour (or (etaf-ui-markdown-highlight-color props dark)
                     (or (plist-get props :color) ink))))
    (etaf-ui-color-legible
     (if dim (etaf-ui-color-mix colour surface 0.55) colour)
     surface)))

(defun etaf-ui-markdown--code-row (line-runs kind number number-width fill dim
                                             env code-bg mono ink muted
                                             &optional colour-fn)
  "Return one painted code ROW.
LINE-RUNS are the highlighted runs of the row; KIND is its paint state,
NUMBER its label or nil, FILL its background; DIM recedes an unfocused row.
Optional COLOUR-FN resolves `(PROPS SURFACE DIM)' using a per-block cache."
  (let* ((surface (or fill code-bg))
         (resolve (or colour-fn
                      (lambda (props s d)
                        (etaf-ui-markdown--code-line-colour props env s d))))
         (children
          (if line-runs
              (mapcar
               (lambda (run)
                 (let* ((props (plist-get run :props))
                        (wfill (plist-get props :word-highlight))
                        (raw-color (plist-get props :raw-color))
                        (run-surface (or wfill surface))
                        (clean-props (let ((copy (copy-sequence props)))
                                       (setq copy (plist-put copy :word-highlight nil))
                                       (setq copy (plist-put copy :raw-color nil))
                                       copy))
                        (final-props
                         (append
                          (plist-put clean-props
                                     :color (if raw-color
                                                (plist-get props :color)
                                              (funcall resolve props run-surface dim)))
                          (when wfill (list :background-color wfill)))))
                   (etaf-node 'text final-props (list (plist-get run :text)))))
               line-runs)
            (list (etaf-node 'text
                             (list :color (if dim muted ink))
                             (list " "))))))
    ;; Plain code rows carry neither a line-number gutter nor a diff sign, so a
    ;; single stretched `box' paints them directly without a per-line `flex'.
    (if (and (null number) (not (memq kind '(add remove))))
        (etaf-node
         'box
         (append (list :width 'stretch
                       :padding-inline '(ch 2)
                       :wrap-mode 'word)
                 (when fill (list :background-color fill)))
         children)
      (etaf-node
       'flex
       (append (list :width 'stretch
                     :align-items 'start
                     :padding-inline '(ch 2))
               (when fill (list :background-color fill)))
       (append
        (when number
          (list (etaf-node
                 'box
                 (list :padding-right '(ch 1))
                 (list (etaf-node 'text
                                  (list :font-family mono
                                        :color (etaf-ui-color-legible muted surface))
                                  ;; The label carries its own padding: a fixed
                                  ;; width with right alignment clipped it.
                                  (list (format (format "%%%dd " number-width)
                                                number)))))))
        (when (memq kind '(add remove))
          (list (etaf-node
                 'text
                 (list :font-family mono
                       :color (etaf-ui-color-legible
                               (etaf-ui-markdown--env-color-or
                                env (if (eq kind 'add) :ok :danger) :accent)
                               surface))
                 (list (if (eq kind 'add) "+ " "- ")))))
        (list
         (etaf-node
          'box
          (list :flex-basis '(ch 0) :flex-grow 1 :wrap-mode 'word)
          children)))))))

(defun etaf-ui-markdown--default-code-block-node (block env)
  "Return the default fenced code block View of BLOCK in ENV.
The fence's options live in its info string the way plume writes them: a
`title=' names the block, `:line-numbers[=N]' numbers its rows, and a `{...}'
or a trailing `[!code ...]' marker paints a row as highlighted, focused, added,
removed, warned or failed.  A block with a language opens with a header strip,
and the header carries the copy action; the code starts under that rule, so
the label frames the block instead of floating over its first line."
  (let* ((mono (etaf-ui-markdown--mono-family))
         (frame (or (not (plist-member block :frame))
                    (plist-get block :frame)))
         (border (etaf-ui-markdown--env-color env :border))
         (info (etaf-ui-markdown--code-info block))
         (lang (plist-get info :lang))
         (title (plist-get info :title))
         (label (or title lang))
         (numbers (plist-get info :numbers))
         (collapsed-limit (plist-get info :collapsed-lines))
         (block-words (plist-get info :words))
         (whitespace (plist-get info :whitespace))
         (indent-guides (plist-get info :indent-guides))
         (text (string-trim-right (or (plist-get block :text) "") "\n"))
         (parsed (etaf-ui-markdown--code-line-states (split-string text "\n")))
         (texts (plist-get parsed :texts))
         (states (plist-get parsed :states))
         (per-line-words (plist-get parsed :words))
         (focus-any (plist-get parsed :focus))
         (clean (mapconcat #'identity texts "\n"))
         (code-bg (etaf-ui-markdown--code-color env))
         (ink (etaf-ui-markdown--env-color env :ink))
         (muted (etaf-ui-markdown--env-color env :muted))
         (faint (etaf-ui-markdown--env-color-or env :faint :muted))
         (accent (etaf-ui-markdown--env-color-or env :accent :link))
         (word-fill (etaf-ui-markdown--env-color-or env :warn-soft :accent-soft))
         (runs (unless (and (plist-member env :highlight-code)
                            (null (plist-get env :highlight-code)))
                 (etaf-ui-markdown-highlight-code lang clean)))
         (run-lines (if runs
                        (etaf-ui-markdown--code-split-runs runs)
                      (mapcar (lambda (line) (list (list :text line))) texts)))
         (line-ranges (plist-get info :lines))
         (number-width (length (number-to-string
                                (+ (or numbers 1) (max 0 (1- (length texts)))))))
         (focus-lines nil))
    (when focus-any
      (cl-loop for state in states
               for index from 0
               when (eq (car state) 'focus)
               do (dotimes (offset (1+ (or (cdr state) 0)))
                    (push (+ index offset) focus-lines))))
    (let* ((colour-cache (make-hash-table :test #'equal))
           (dark (etaf-ui-markdown--dark-page-p env))
           (line-count (length texts))
           (collapsible (and collapsed-limit (> line-count collapsed-limit)))
           (expanded (or (not collapsible)
                         (etaf-ui-markdown--block-state env 'code-expanded nil)))
           (visible-count (if expanded line-count collapsed-limit))
           (hover (etaf-ui-markdown--hover-fill env))
           (resolve-colour
            (lambda (props surface dim)
              (let* ((role (plist-get props :role))
                     (raw (or (etaf-ui-markdown-highlight-color props dark)
                              (plist-get props :color)
                              ink))
                     (ckey (list role raw surface dim)))
                (or (gethash ckey colour-cache)
                    (puthash ckey
                             (etaf-ui-color-legible
                              (if dim (etaf-ui-color-mix raw surface 0.55) raw)
                              surface)
                             colour-cache)))))
           (rows
            (cl-loop for line-runs in run-lines
                     for state in states
                     for lwords in per-line-words
                     for index from 0 below visible-count
                     for kind = (car state)
                     for active-words = (append block-words lwords)
                     for decorated = (etaf-ui-markdown--code-decorate-leading
                                      (etaf-ui-markdown--code-highlight-words
                                       line-runs active-words word-fill)
                                      whitespace indent-guides faint)
                     for fill =
                     (cond
                      ((eq kind 'highlight)
                       (etaf-ui-color-mix accent code-bg 0.82))
                      ((eq kind 'add)
                       (etaf-ui-color-mix
                        (etaf-ui-markdown--env-color-or env :ok :accent)
                        code-bg 0.80))
                      ((memq kind '(remove error))
                       (etaf-ui-color-mix
                        (etaf-ui-markdown--env-color-or env :danger :accent)
                        code-bg 0.80))
                      ((eq kind 'warning)
                       (etaf-ui-color-mix
                        (etaf-ui-markdown--env-color-or env :warn :accent)
                        code-bg 0.80))
                      ((etaf-ui-markdown--code-line-marked-p (1+ index) line-ranges)
                       (etaf-ui-color-mix accent code-bg 0.82)))
                     for dim = (and focus-any (not (memq index focus-lines)))
                     collect (etaf-ui-markdown--code-row
                              decorated kind
                              (and numbers (+ numbers index))
                              number-width fill dim env code-bg mono ink muted
                              resolve-colour)))
           (body (etaf-node 'column
                            (list :width 'stretch :item-gap '(lh 0)
                                  :padding '((lh 1) (ch 0)))
                            rows))
           (on-copy (plist-get env :on-copy))
           (header (when (and label
                              (or (not (plist-member block :header))
                                  (plist-get block :header)))
                     (etaf-node
                      'flex
                      (list :width 'stretch :align-items 'center
                            :border-bottom (list '(px 1) 'solid border)
                            :padding '((lh 0) (ch 2)))
                      (list
                       (etaf-node 'text
                                  (list :font-family mono
                                        :font-weight (if title 'bold nil)
                                        :color (if title ink muted))
                                  (list label))
                       (etaf-node 'box
                                  (list :flex-basis '(ch 0) :flex-grow 1)
                                  nil)
                       (etaf-node 'text
                                  (append
                                   (list :color accent :role 'button :tab-index 0
                                         :pointer 'hand
                                         :help-echo "把这段代码复制下来"
                                         :on-press (lambda ()
                                                     (kill-new clean)
                                                     (when (functionp on-copy)
                                                       (funcall on-copy 'code clean line-count))))
                                   (when hover
                                     (list :hover-style (list :background-color hover))))
                                  (list " 复制 "))))))
           (fold-footer
            (when collapsible
              (let ((hidden (- line-count collapsed-limit)))
                (etaf-node
                 'box
                 (list :width 'stretch
                       :border-top (list '(px 1) 'solid border)
                       :padding '((lh 0) (ch 2))
                       :text-align 'center)
                 (list
                  (etaf-node
                   'text
                   (append
                    (list :color accent :font-weight 'bold
                          :role 'button :tab-index 0 :pointer 'hand
                          :help-echo (if expanded "收起代码块" "展开完整代码")
                          :on-press (lambda ()
                                      (etaf-ui-markdown--set-block-state
                                       env 'code-expanded (not expanded))))
                    (when hover
                      (list :hover-style (list :background-color hover))))
                   (list (if expanded
                             (format " ▴ 收起代码（共 %d 行） " line-count)
                           (format " ▾ 展开剩余 %d 行（共 %d 行） "
                                   hidden line-count))))))))))
      (etaf-node 'box
                 (append (list :width 'stretch
                               :translate 'no
                               :background-color code-bg)
                         (when frame
                           (list :border (list '(px 1) 'solid border))))
                 (append (when header (list header))
                         (list body)
                         (when fold-footer (list fold-footer)))))))

(defun etaf-ui-markdown--blockquote-node (block env)
  "Return the blockquote View of BLOCK in ENV.
A GitHub or Obsidian alert (`> [!NOTE]', `> [!TIP]- Title', `> [!WARNING]+')
becomes a tinted callout (optionally collapsible via `-' / `+'); any other
quote keeps the muted surface and the accent bar."
  (let* ((children (plist-get block :children))
         (alert-info (and (plist-get (plist-get env :features) :alerts)
                          (etaf-ui-markdown--alert-kind children env))))
    (if alert-info
        (let* ((kind (nth 0 alert-info))
               (collapsible (nth 1 alert-info))
               (default-open (nth 2 alert-info))
               (custom-title (nth 3 alert-info))
               (spec (etaf-ui-markdown--alert-spec kind env))
               (color (etaf-ui-markdown--env-color env (nth 1 spec)))
               (soft (etaf-ui-markdown--env-color env (nth 2 spec)))
               (open (if collapsible
                         (etaf-ui-markdown--block-state
                          env (cons 'alert-open (plist-get block :begin))
                          default-open)
                       t))
               (label (or custom-title (nth 0 spec)))
               (hover (and collapsible (etaf-ui-markdown--hover-fill env 'soft)))
               (header
                (if collapsible
                    (etaf-node
                     'text
                     (append
                      (list :color color :font-weight 'bold
                            :role 'button :tab-index 0 :pointer 'hand
                            :aria-expanded (if open t 'false)
                            :help-echo (if open "收起提示块" "展开提示块")
                            :on-press
                            (lambda ()
                              (etaf-ui-markdown--set-block-state
                               env (cons 'alert-open (plist-get block :begin))
                               (not open))))
                      (when hover
                        (list :hover-style (list :background-color hover))))
                     (list (format "%s %s %s" (if open "▾" "▸") (nth 3 spec) label)))
                  (etaf-node 'text
                             (list :color color :font-weight 'bold)
                             (list (format "%s %s" (nth 3 spec) label))))))
          (etaf-node 'box
                     (list :width 'stretch
                           :background-color soft
                           :border-left (list '(px 3) 'solid color)
                           :padding-top '(lh 0)
                           :padding-bottom '(lh 0)
                           :padding-left '(ch 2)
                           :padding-right '(ch 2))
                     (append
                      (list header)
                      (when open
                        (etaf-ui-markdown-view-blocks
                         (etaf-ui-markdown--alert-blocks children) env t)))))
      (etaf-node 'box
                 (list :width 'stretch
                       :background-color (etaf-ui-markdown--env-color env :quote-bg)
                       :border-left (list '(px 3) 'solid
                                          (etaf-ui-markdown--env-color env :quote-bar))
                       ;; A quote recedes behind its own surface: its plain
                       ;; text takes the muted color, while a link and a code
                       ;; span keep the colors they set for themselves.
                       :color (etaf-ui-markdown--env-color env :muted)
                       :padding-top '(lh 0)
                       :padding-bottom '(lh 0)
                       :padding-left '(ch 2)
                       :padding-right '(ch 2))
                 ;; A quote holds paragraphs, lists and nested quotes: one
                 ;; blank row between them separates what the source wrote as
                 ;; separate blocks, exactly as the top level separates its
                 ;; own, without adding one before the first or after the last.
                 (etaf-ui-markdown-view-blocks children env)))))

(defun etaf-ui-markdown--alert-kind (blocks env)
  "Return (KIND COLLAPSIBLE DEFAULT-OPEN CUSTOM-TITLE) for alert BLOCKS, or nil."
  (let* ((first (car blocks))
         (children (and first (eq (plist-get first :type) 'paragraph)
                        (plist-get first :children)))
         (text (and children (eq (plist-get (car children) :type) 'text)
                    (plist-get (car children) :text))))
    (when (and text
               (string-match
                "\\`\\[!\\([A-Za-z]+\\)\\]\\([+-]\\)?\\(?:[ \t]+\\([^\n]+\\)\\)?\\(?:\n\\|\\'\\)"
                text))
      (let* ((kind (downcase (match-string 1 text)))
             (fold (match-string 2 text))
             (custom (match-string 3 text))
             (custom (and custom (not (string-blank-p custom)) (string-trim custom))))
        (when (etaf-ui-markdown--alert-spec kind env)
          (list kind (and fold t) (not (equal fold "-")) custom))))))
(defconst etaf-ui-markdown--alert-defaults
  '((note "Note" :accent :accent-soft "i")
    (info "Info" :accent :accent-soft "i")
    (tip "Tip" :ok :ok-soft "✔")
    (important "Important" :important :important-soft "★")
    (warning "Warning" :warn :warn-soft "⚠")
    (caution "Caution" :danger :danger-soft "⊘")
    (danger "Danger" :danger :danger-soft "⊘"))
  "GitHub and Obsidian alert kinds with their default label, color keys and icon.
The note's mark is the plain `i': the information sign is missing from common
monospace fonts and renders as a box or a stray bar.")

(defun etaf-ui-markdown--alert-spec (kind env)
  "Return (LABEL COLOR-KEY SOFT-KEY ICON) for alert KIND in ENV, or nil.
ENV's `:alert-labels' alist may override the labels of
`etaf-ui-markdown--alert-defaults'."
  (let* ((name (intern (downcase kind)))
         (spec (cdr (assq name etaf-ui-markdown--alert-defaults))))
    (when spec
      (if-let* ((label (cdr (assq name (plist-get env :alert-labels)))))
          (cons label (cdr spec))
        spec))))

(defun etaf-ui-markdown--alert-blocks (blocks)
  "Return BLOCKS with the leading alert marker line removed.
The document tree is shared across renders, so the first paragraph is rebuilt
instead of mutated."
  (let* ((first (car blocks))
         (children (plist-get first :children))
         (text (plist-get (car children) :text))
         (rest (string-trim-left
                (replace-regexp-in-string
                 "\\`\\[![A-Za-z]+\\][+-]?[^\n]*\n?" "" text)))
         (rest-children (if (string-empty-p rest)
                            (cdr children)
                          (cons (plist-put (copy-sequence (car children)) :text rest)
                                (cdr children)))))
    ;; The marker sat on its own line, so the break that ended that line still
    ;; leads the paragraph: dropping it puts the alert's text on the row under
    ;; its label, which is where a callout puts it.
    (while (eq (plist-get (car rest-children) :type) 'break)
      (setq rest-children (cdr rest-children)))
    (if rest-children
        (cons (let ((paragraph (copy-sequence first)))
                (plist-put paragraph :children rest-children))
              (cdr blocks))
      (cdr blocks))))

(defun etaf-ui-markdown--inline-plain-text (node)
  "Return the rendered plain text contributed directly by inline NODE.
Container inlines such as `mark', `emph', `strong', `strike' and `link' carry
their display text in `:children', so they contribute an empty string here to
avoid double-counting raw source text."
  (pcase (plist-get node :type)
    ('badge (concat " " (or (plist-get node :content) "") " "))
    ('kbd (concat " " (mapconcat #'identity (plist-get node :keys) "+") " "))
    ('emoji (or (plist-get node :char) (plist-get node :text) ""))
    ((or 'subscript 'superscript)
     (or (plist-get node :rendered) (plist-get node :text) ""))
    ('icon (or (car (etaf-ui-icon-lines (plist-get node :name))) ""))
    ('math (etaf-ui-markdown-math-text (or (plist-get node :text) "")))
    ('footnote-ref (format "[%s]" (or (plist-get node :number)
                                      (plist-get node :label)
                                      "")))
    ((or 'mark 'emph 'strong 'strike 'link 'autolink) "")
    ('image (or (plist-get node :alt) (plist-get node :url) ""))
    (_ (or (plist-get node :text) ""))))

(defun etaf-ui-markdown--inline-width (inlines)
  "Return the display width of the rendered text of INLINES and their children."
  (let ((width 0))
    (dolist (node inlines)
      (setq width (+ width
                     (string-width (etaf-ui-markdown--inline-plain-text node))
                     (etaf-ui-markdown--inline-width
                      (plist-get node :children)))))
    width))

(defconst etaf-ui-markdown--cell-min-width 12
  "Cap, in character cells, of a wide-character token's table floor.
A line may break between wide characters, so a long CJK sentence does not
force a wide column.  A narrow token has no such break opportunity, so it
keeps its full width instead.")

(defconst etaf-ui-markdown--cell-max-floor 32
  "Cap, in character cells, of one table column's unbreakable floor.")

(defun etaf-ui-markdown--token-width (token)
  "Return the floor TOKEN asks of its table column."
  (let ((width (string-width token))
        (wide (cl-some (lambda (char) (>= (char-width char) 2))
                       (string-to-list token))))
    (if wide (min etaf-ui-markdown--cell-min-width width) width)))

(defun etaf-ui-markdown--inline-segments (inlines)
  "Return unbreakable widths of rendered text for INLINES and their children."
  (let ((widths nil))
    (dolist (node inlines)
      (dolist (token (split-string (etaf-ui-markdown--inline-plain-text node)
                                   "[ \t\n]+" t))
        (push (etaf-ui-markdown--token-width token) widths))
      (setq widths (append (etaf-ui-markdown--inline-segments
                            (plist-get node :children))
                           widths)))
    widths))

(defconst etaf-ui-markdown--table-cell-padding 2
  "Cells of a column, in character widths on each side.
The floor of a column covers this padding on both sides plus its one-pixel
border, so a change here has to reach both places or the widest token in a
column gets clipped to its last character.")

(defun etaf-ui-markdown--table-floors (rows columns)
  "Return the min-width floors of COLUMNS for table ROWS.
A column's floor covers its widest unbreakable token plus the cell's padding
and hairline borders, so a word or a short CJK run stays whole.  Every row
gets the same floor for a column: the table is one grid, so a floor taken
from a single row would resolve that row's tracks against other widths and
push it out of line."
  (let ((widths (make-list columns 0)))
    (dolist (row rows)
      (cl-loop for inlines in row
               for column from 0
               do (setf (nth column widths)
                        (max (nth column widths)
                             (apply #'max 0
                                    (etaf-ui-markdown--inline-segments inlines))))))
    (mapcar (lambda (width)
              (+ (* 2 etaf-ui-markdown--table-cell-padding)
                 1
                 (min etaf-ui-markdown--cell-max-floor (or width 0))))
            widths)))

(defun etaf-ui-markdown--table-tracks (floors weights)
  "Return the grid tracks of a table from FLOORS and content WEIGHTS.
Each column keeps its floor, so its words stay whole, and shares the space
above the floors in proportion to its widest cell, bounded so one long
column cannot starve the others."
  (cl-loop for floor in floors
           for weight in weights
           collect (list 'minmax (list 'ch floor)
                         (list 'fr (max 4 (min 32 weight))))))

(defun etaf-ui-markdown--table-stripe (env)
  "Return the body-row stripe surface of a table in ENV, or nil.
A palette whose stripe and header row are the same surface gets no stripes:
painting a row the color it already has costs a paint and shows nothing."
  (let ((stripe (etaf-ui-markdown--env-color env :table-stripe))
        (header (etaf-ui-markdown--env-color env :table-header)))
    (unless (equal stripe header) stripe)))

(defun etaf-ui-markdown--header-fill (env)
  "Return the header tint for a table in ENV, deepened to stay visible.
A theme's own `:table-header' colour is used when it stands apart from the
page.  A tint that sits within a tenth of the page's own lightness disappears
behind the text on it, which is what a dark palette's tint tends to do, so the
band is then rebuilt as one step from the page toward its ink."
  (let* ((page (or (plist-get env :background)
                   (etaf-ui-markdown--env-color env :panel)))
         (ink (etaf-ui-markdown--env-color env :ink))
         (tint (etaf-ui-markdown--env-color env :table-header)))
    (if (< (etaf-ui-color-contrast tint page) 1.12)
        (etaf-ui-color-mix page ink 0.08)
      tint)))

(defun etaf-ui-markdown--table-compact-widths (weights avail)
  "Return per-column widths summing to `(- AVAIL 2)' for compact grid layout.
Returns nil when AVAIL cannot fit every column with at least a minimal readable
width (4 cells of content plus compact 1ch side padding and hairline border),
signaling that the table should fall back to stacked record cards."
  (let* ((columns (length weights))
         (inner-budget (- avail 2))
         (chrome 3) ; 1ch left pad + 1ch right pad + 1ch border
         (min-cols (mapcar (lambda (w)
                             (+ chrome (min (max 2 (or w 2)) 4)))
                           weights))
         (min-sum (apply #'+ min-cols)))
    (when (and (> columns 0) (<= min-sum inner-budget))
      (let* ((want-cols (mapcar (lambda (w)
                                  (+ chrome (min etaf-ui-markdown--cell-max-floor
                                                 (max 4 (or w 4)))))
                                weights))
             (extra (- inner-budget min-sum))
             (demands (cl-mapcar (lambda (want lo) (max 0 (- want lo)))
                                 want-cols min-cols))
             (demand-sum (apply #'+ demands))
             (alloc (if (<= demand-sum 0)
                        (make-list columns 0)
                      (let* ((raw (mapcar (lambda (d)
                                            (* (float extra)
                                               (/ (float d) demand-sum)))
                                          demands))
                             (floors (mapcar #'floor raw))
                             (rem (- extra (apply #'+ floors)))
                             (order (sort (number-sequence 0 (1- columns))
                                          (lambda (a b)
                                            (> (- (nth a raw) (nth a floors))
                                               (- (nth b raw) (nth b floors)))))))
                        (dotimes (k (max 0 rem))
                          (let ((idx (nth (mod k columns) order)))
                            (setf (nth idx floors) (1+ (nth idx floors)))))
                        floors)))
             (result (cl-mapcar #'+ min-cols alloc))
             (leftover (- inner-budget (apply #'+ result))))
        (when (> leftover 0)
          ;; Every column reached its desired cap; distribute remaining width
          ;; proportionally to raw content weights.
          (let* ((wsum (max 1 (apply #'+ (mapcar (lambda (w) (max 1 (or w 1))) weights))))
                 (raw (mapcar (lambda (w)
                                (* (float leftover) (/ (float (max 1 (or w 1))) wsum)))
                              weights))
                 (floors (mapcar #'floor raw))
                 (rem (- leftover (apply #'+ floors)))
                 (order (sort (number-sequence 0 (1- columns))
                              (lambda (a b)
                                (> (- (nth a raw) (nth a floors))
                                   (- (nth b raw) (nth b floors)))))))
            (dotimes (k (max 0 rem))
              (let ((idx (nth (mod k columns) order)))
                (setf (nth idx floors) (1+ (nth idx floors)))))
            (setq result (cl-mapcar #'+ result floors))))
        result))))

(defun etaf-ui-markdown--table-cards-node (rows env line header-fill avail)
  "Render table ROWS as responsive stacked record cards inside AVAIL cells.
Used when a multi-column table cannot fit side-by-side in a narrow viewport
without clipping or collapsing columns below readable width."
  (let* ((header (car rows))
         (body (cdr rows))
         (muted (etaf-ui-markdown--env-color env :muted))
         (card-w (max 20 avail))
         (two-col (>= card-w 34))
         (label-w (max 8 (min 18 (/ card-w 3))))
         (val-w (max 8 (- card-w label-w 4)))
         (soft-line (list '(px 1) 'solid
                          (etaf-ui-color-mix
                           (or (plist-get env :background)
                               (etaf-ui-markdown--env-color env :panel))
                           (etaf-ui-markdown--env-color env :ink) 0.12))))
    (if (null body)
        (etaf-node 'column
                   (list :width 'stretch
                         :max-width (list 'ch card-w)
                         :border line
                         :background-color header-fill
                         :item-gap '(lh 0))
                   (cl-loop for cell in header
                            for idx from 0
                            collect (etaf-node 'box
                                               (list :width 'stretch
                                                     :padding '((lh 0) (ch 1))
                                                     :wrap-mode 'word
                                                     :border-bottom (and (< idx (1- (length header)))
                                                                         soft-line))
                                               (etaf-ui-markdown--runs-view
                                                cell env (list :bold t)))))
      (etaf-node
       'column
       (list :width 'stretch
             :max-width (list 'ch card-w)
             :item-gap '(lh 1))
       (mapcar
        (lambda (row)
          (let* ((lead-hdr (car header))
                 (lead-val (car row))
                 (rest-hdr (cdr header))
                 (rest-val (cdr row))
                 (pair-count (length rest-val)))
            (etaf-node
             'column
             (list :width 'stretch :border line :item-gap '(lh 0))
             (cons
              ;; Card header band: first column label + value so every column
              ;; heading and cell value remains searchable and legible.
              (etaf-node
               'box
               (list :width 'stretch
                     :padding '((lh 0) (ch 1))
                     :wrap-mode 'word
                     :background-color header-fill
                     :border-bottom (and (> pair-count 0) line))
               (append
                (when (and lead-hdr (> (etaf-ui-markdown--inline-width lead-hdr) 0))
                  (append (etaf-ui-markdown--runs-view lead-hdr env (list :color muted))
                          (list (etaf-node 'text (list :color muted) (list " · ")))))
                (etaf-ui-markdown--runs-view lead-val env (list :bold t))))
              (cl-loop for h in rest-hdr
                       for v in rest-val
                       for idx from 0
                       collect
                       (if two-col
                           (etaf-node
                            'grid
                            (list :width 'stretch
                                  :grid-template-columns
                                  (list (list 'ch label-w)
                                        (list 'minmax (list 'ch val-w) '(fr 1)))
                                  :border-bottom (and (< idx (1- pair-count)) soft-line))
                            (list
                             (etaf-node 'box
                                        (list :width 'stretch
                                              :padding '((lh 0) (ch 1))
                                              :wrap-mode 'word
                                              :border-right soft-line)
                                        (etaf-ui-markdown--runs-view
                                         h env (list :bold t :color muted)))
                             (etaf-node 'box
                                        (list :width 'stretch
                                              :padding '((lh 0) (ch 1))
                                              :wrap-mode 'word)
                                        (etaf-ui-markdown--runs-view v env nil))))
                         (etaf-node
                          'column
                          (list :width 'stretch
                                :padding '((lh 0) (ch 1))
                                :item-gap '(lh 0)
                                :border-bottom (and (< idx (1- pair-count)) soft-line))
                          (list
                           (etaf-node 'box (list :width 'stretch :wrap-mode 'word)
                                      (etaf-ui-markdown--runs-view
                                       h env (list :bold t :color muted)))
                           (etaf-node 'box (list :width 'stretch :wrap-mode 'word)
                                      (etaf-ui-markdown--runs-view v env nil))))))))))
        body)))))

(defun etaf-ui-markdown--table-node (block env)
  "Return the table View of BLOCK in ENV.
Every cell carries the same hairline, one step of ink away from the page's own
surface, and the header is set apart by its tint and its weight instead of by a
heavier rule: a page wants to see where a cell ends, not to read a spreadsheet's
grid of black lines.  A palette that names a `:table-stripe' different from its
header tints every other body row.  Columns share the width in proportion to
their content and never go narrower than their widest unbreakable token plus the
cell padding, and cells wrap at word boundaries.

The whole table is one grid, and its floors are the column maximums over
every row.  When ENV supplies `:width' (and optionally `:table-max-width' for
wide viewport breakout), a table whose natural floors exceed the available
budget adapts cleanly without right-edge clipping: first expanding up to
`:table-max-width' when the viewport allows, then compressing cell padding and
scaling column floors proportionally to fit inside the budget, and finally
folding into stacked record cards when too many columns face a narrow split."
  (let* ((aligns (plist-get block :aligns))
         (columns (length aligns))
         (rows (append (list (plist-get block :header))
                       (plist-get block :rows)))
         (floors (etaf-ui-markdown--table-floors rows columns))
         (natural-w (+ 2 (apply #'+ floors)))
         (weights (cl-loop for column below columns
                           collect (cl-loop for row in rows
                                            maximize (etaf-ui-markdown--inline-width
                                                      (nth column row)))))
         (ideal-w (+ 2 (cl-loop for w in weights
                                sum (+ (* 2 etaf-ui-markdown--table-cell-padding)
                                       1
                                       (max 2 (min etaf-ui-markdown--cell-max-floor w))))))
         (measure (let ((w (plist-get env :width)))
                    (and (integerp w) (> w 0) w)))
         (max-w (let ((tw (plist-get env :table-max-width)))
                  (if (and (integerp tw) (> tw 0)) tw measure)))
         ;; One hairline for the whole table, a fifth of the way from the
         ;; surface to the page's ink: the weight a documentation site gives its
         ;; grid, visible on every edge and still quiet next to the text.  The
         ;; header is told apart by its tint and its weight, not by a heavier
         ;; rule; a dark rule there fought the band it sits under.
         (line (list '(px 1) 'solid
                     (etaf-ui-color-mix
                      (or (plist-get env :background)
                          (etaf-ui-markdown--env-color env :panel))
                      (etaf-ui-markdown--env-color env :ink) 0.2)))
         (header-fill (etaf-ui-markdown--header-fill env))
         (compact-cols (and max-w (> natural-w max-w)
                            (etaf-ui-markdown--table-compact-widths weights max-w)))
         (use-cards (and max-w (> natural-w max-w) (null compact-cols))))
    (if use-cards
        (etaf-ui-markdown--table-cards-node rows env line header-fill max-w)
      (let* ((cell-pad (if compact-cols 1 etaf-ui-markdown--table-cell-padding))
             (active-floors (or compact-cols floors))
             (tracks (if compact-cols
                         (cl-loop for w in compact-cols
                                  collect (list 'minmax (list 'ch w)
                                                (list 'fr (max 1 w))))
                       (etaf-ui-markdown--table-tracks floors weights)))
             (min-w (+ 2 (apply #'+ active-floors)))
             (box-max-w
              (cond
               ((null max-w) nil)
               (compact-cols max-w)
               ((and measure (> max-w measure) (> natural-w measure))
                (min max-w (max natural-w ideal-w)))
               ((and measure (> max-w measure))
                measure)
               (t max-w)))
             (last-row (1- (length rows)))
             (cells nil))
        (cl-loop for row in rows
                 for row-index from 0
                 do (cl-loop for inlines in row
                             for align in aligns
                             for column-index from 0
                             do (push
                                 (etaf-node 'box
                                            (list :padding
                                                  `((lh 0) (ch ,cell-pad))
                                                  :min-width (list 'ch (nth column-index active-floors))
                                                  :width 'stretch
                                                  :overflow 'hidden
                                                  :wrap-mode 'word
                                                  :text-align (or align 'left)
                                                  :border-bottom
                                                  (and (< row-index last-row) line)
                                                  :border-right
                                                  (and (/= column-index (1- columns))
                                                       line)
                                                  :background-color
                                                  (and (zerop row-index) header-fill))
                                            (etaf-ui-markdown--runs-view
                                             inlines env
                                             (when (zerop row-index) (list :bold t))))
                                 cells)))
        (etaf-node 'box
                   (append (list :width 'stretch
                                 :min-width (list 'ch min-w)
                                 ;; One pixel closes the grid, so the table reads as one
                                 ;; object on the page: the frame is the table's own edge,
                                 ;; painted in the page's border colour and no heavier than
                                 ;; the rules inside it.
                                 :border line)
                           (when box-max-w
                             (list :max-width (list 'ch box-max-w))))
                   (list (etaf-node 'grid
                                    (list :width 'stretch
                                          :grid-template-columns tracks)
                                    (nreverse cells))))))))

(defun etaf-ui-markdown--thematic-break-node ()
  "Return the thematic break View."
  (etaf-ui-markdown--divider))

(defconst etaf-ui-markdown--html-media-regexp
  "<\\(video\\|img\\)\\b[^>]*>"
  "Opening tags whose source is rendered as a media card.")

(defun etaf-ui-markdown--html-attribute (tag name)
  "Return NAME's attribute value from TAG, or nil."
  (let ((case-fold-search t))
    (cond
     ((string-match (format "\\b%s[ \t]*=[ \t]*[\"']\\([^\"']*\\)[\"']" name) tag)
      (match-string 1 tag))
     ((string-match (format "\\b%s[ \t]*=[ \t]*\\([^ \t\n\r\"'=<>`/]+\\)" name) tag)
      (match-string 1 tag)))))

(defun etaf-ui-markdown--html-px (value)
  "Return positive pixel number parsed from HTML size VALUE, or nil."
  (when (and (stringp value)
             (string-match "\\`[ \t]*\\([0-9]+\\(?:\\.[0-9]+\\)?\\)\\(?:px\\)?[ \t]*\\'"
                           (downcase value)))
    (let ((num (string-to-number (match-string 1 value))))
      (when (> num 0) num))))

(defun etaf-ui-markdown--html-comment-p (text)
  "Return non-nil when TEXT is an HTML comment block.
Comments carry no rendered content, so the renderer drops them instead of
printing markup the document never intended to show."
  (string-prefix-p "<!--" (string-trim text)))

(defun etaf-ui-markdown--html-media (text)
  "Return a media descriptor for raw HTML TEXT, or nil.
A `<video>' or `<img>' opening tag with a source becomes a descriptor with
`:url', `:kind' (`video' or `image'), `:alt', and optional `:width'/`:height'
pixel bounds when declared on the tag."
  (when (string-match etaf-ui-markdown--html-media-regexp text)
    (let* ((tag (match-string 0 text))
           (src (etaf-ui-markdown--html-attribute tag "src"))
           (width (etaf-ui-markdown--html-px
                   (etaf-ui-markdown--html-attribute tag "width")))
           (height (etaf-ui-markdown--html-px
                    (etaf-ui-markdown--html-attribute tag "height"))))
      (when src
        (append (list :type 'html-media
                      :url src
                      :kind (if (string-match-p "\\`<video" tag) 'video 'image)
                      :alt (or (etaf-ui-markdown--html-attribute tag "alt")
                               (etaf-ui-markdown--html-attribute tag "title")))
                (when width (list :width width))
                (when height (list :height height)))))))

(defun etaf-ui-markdown--html-block-node (block env)
  "Return the View of raw HTML BLOCK in ENV, or nil.
HTML comments render as nothing; a media element goes through ENV's
`:render-media'; other tags stay visible as code, so the renderer never
silently drops content it cannot render."
  (let* ((text (plist-get block :text))
         (media (and (not (etaf-ui-markdown--html-comment-p text))
                     (etaf-ui-markdown--html-media text))))
    (cond
     ((etaf-ui-markdown--html-comment-p text) nil)
     (media (etaf-ui-markdown--render-media (plist-get media :kind) media env))
     (t (etaf-ui-markdown--html-code-node text env)))))

(defun etaf-ui-markdown--html-code-node (text env)
  "Return a muted monospace block View for raw HTML TEXT in ENV."
  (etaf-node 'box
             (list :width 'stretch :wrap-mode 'char :translate 'no
                   :background-color (etaf-ui-markdown--env-color env :panel)
                   :padding-top '(lh 1)
                   :padding-bottom '(lh 1)
                   :padding-left '(ch 2)
                   :padding-right '(ch 2))
             (list (etaf-node 'text
                              (list :color (etaf-ui-markdown--env-color env :muted))
                              (list text)))))

(defun etaf-ui-markdown--list-node (block env)
  "Return the list View of BLOCK in ENV."
  (let* ((tight (plist-get block :tight))
         (ordered (plist-get block :ordered))
         (start (or (plist-get block :start) 1))
         ;; The marker column fits the widest mark in this list plus one cell
         ;; of air: a two-digit item still lines up with a one-digit one, and a
         ;; list of single marks does not reserve a gap as wide as a CJK
         ;; character between the mark and its text.
         (marks (cl-loop for item in (plist-get block :items)
                         for number from start
                         maximize (cond ((plist-get item :task) 1)
                                        (ordered (length (format "%d." number)))
                                        (t 1))))
         (index 0)
         (items nil))
    (dolist (item (plist-get block :items))
      (cl-incf index)
      (let* ((checked (plist-get item :checked))
             (task (plist-get item :task))
             (marker
              (cond
               ;; Both squares come from the text's own font, so the two
               ;; states have one box geometry and the column stays even; a
               ;; ballot box or a boxed inner square is drawn by another font
               ;; on macOS and shifts or resizes the mark.  Fill shows the
               ;; state without relying on the words' colour alone.
               (task
                (let* ((on-toggle (plist-get env :on-toggle-task))
                       (item-index index)
                       (hover (and (functionp on-toggle)
                                   (etaf-ui-markdown--hover-fill env))))
                  (etaf-node
                   'text
                   (append
                    (list :color (if checked
                                     (etaf-ui-markdown--env-color env :accent)
                                   (etaf-ui-markdown--env-color env :muted)))
                    (when (functionp on-toggle)
                      (list :role 'checkbox :tab-index 0 :pointer 'hand
                            :aria-checked (if checked t 'false)
                            :help-echo (if checked "标记为未完成" "标记为已完成")
                            :on-press (lambda ()
                                        (funcall on-toggle block item item-index))))
                    (when hover
                      (list :hover-style (list :background-color hover))))
                   (list (if checked "■" "□")))))
               ;; A number is padded to the widest mark of its own list, so a
               ;; list that reaches ten keeps one text column.
               (ordered (etaf-node 'text
                                   (list :color (etaf-ui-markdown--env-color env :muted))
                                   (list (format (format "%%%ds" marks)
                                                 (format "%d." (+ start (1- index)))))))
               (t (etaf-node 'text
                             (list :color (etaf-ui-markdown--env-color env :muted))
                             (list "•")))))
             (content (etaf-ui-markdown-view-blocks (plist-get item :children) env tight)))
        (push (etaf-node 'flex
                         (list :width 'stretch)
                         (list
                          (etaf-node 'box
                                     (list :width (list 'ch (1+ marks)) :flex-shrink 0)
                                     (list marker))
                          (etaf-node 'column
                                     (list :width 'stretch :min-width '(ch 0))
                                     content)))
              items)))
    (etaf-node 'column
               (list :width 'stretch
                     :item-gap (list 'lh (if tight 0 1)))
               (nreverse items))))

(defun etaf-ui-markdown--footnote-def-node (block env)
  "Return the footnote definition View of BLOCK in ENV."
  (let* ((label (plist-get block :label))
         (ref-fn (plist-get env :footnote-ref))
         (ref (and (functionp ref-fn) (funcall ref-fn label)))
         (back-fn (plist-get env :footnote-back))
         (accent (etaf-ui-markdown--env-color env :accent)))
    (etaf-node 'box
               (append (list :width 'stretch :wrap-mode 'word
                             :id (format "footnote-%s" label))
                       (when ref (list :ref ref)))
               (append
                (list (etaf-node 'text
                                 (list :color accent
                                       :font-weight 'bold)
                                 (list (format "[%s] " (plist-get block :number)))))
                (etaf-ui-markdown--runs-view
                 (cl-loop for child in (plist-get block :children)
                          append (if (eq (plist-get child :type) 'paragraph)
                                     (plist-get child :children)
                                   nil))
                 env nil)
                (when (functionp back-fn)
                  (let ((hover (etaf-ui-markdown--hover-fill env)))
                    (list (etaf-node 'text nil (list " "))
                          (etaf-node 'text
                                     (append
                                      (list :color accent :role 'link :tab-index 0
                                            :pointer 'hand
                                            :help-echo (format "返回脚注 %s 引用处" label)
                                            :on-press (lambda () (funcall back-fn label)))
                                      (when hover
                                        (list :hover-style (list :background-color hover))))
                                     (list "↩")))))))))

(defun etaf-ui-markdown--definition-list-node (block env)
  "Return the definition list View of BLOCK in ENV.
A term is bold on its own line and each definition sits behind a quiet rule,
indented by two columns, the way a printed glossary reads.  The marker the
source writes before a definition is not repeated: the rule and the indent
already say what the line is, and a `:' there would compete with the text."
  (let ((rule (etaf-ui-markdown--env-color env :border))
        (items nil))
    (dolist (item (plist-get block :items))
      (let ((rows nil))
        (push (etaf-node 'box
                         (list :width 'stretch :wrap-mode 'word)
                         ;; Bold is a run attribute, not a box one: the text
                         ;; nodes carry the weight, so a term reads heavier
                         ;; than its definitions without changing size.
                         (etaf-ui-markdown--runs-view (plist-get item :children)
                                                      env (list :bold t)))
              rows)
        (dolist (definition (plist-get item :definitions))
          (let* ((children (plist-get definition :children))
                 (first (car children))
                 (rest (cdr children)))
            (push (etaf-node 'box
                             (list :width 'stretch :wrap-mode 'word
                                   :border-left (list '(px 2) 'solid rule)
                                   :padding-left '(ch 2))
                             (append
                              (when (and first
                                         (eq (plist-get first :type) 'paragraph))
                                (etaf-ui-markdown--runs-view
                                 (plist-get first :children) env nil))
                              (mapcan (lambda (child)
                                        (etaf-ui-markdown--view-block child env))
                                      rest)))
                  rows)))
        (push (etaf-node 'column
                         (list :width 'stretch :item-gap '(lh 0))
                         (nreverse rows))
              items)))
    (etaf-node 'column
               ;; One blank row between a definition and the next term: the
               ;; list is several entries, not one block of lines.
               (list :width 'stretch :item-gap '(lh 1))
               (nreverse items))))

(defun etaf-ui-markdown--math-node (block env)
  "Return the display formula View of BLOCK in ENV.
ENV's `:render-math', when present, may return a View for the formula and nil
to keep the text; without it this is `etaf-ui-markdown-math-text' drawn as one
centered line, so a formula shows even where nothing else is installed."
  (or (when-let* ((renderer (plist-get env :render-math)))
        (funcall renderer block env))
      (etaf-node 'box
                 (list :width 'stretch :text-align 'center
                       :padding '((lh 1) (ch 0)))
                 (list (etaf-node 'text
                                  (list :font-style 'italic
                                        :color (etaf-ui-markdown--env-color env :ink))
                                  (list (etaf-ui-markdown-math-text
                                         (or (plist-get block :text) ""))))))))

(defun etaf-ui-markdown--view-block (block env)
  "Return the list of Views for one BLOCK in ENV."
  (pcase (plist-get block :type)
    ('heading (list (etaf-ui-markdown--heading-node block env)))
    ('paragraph
     (when-let* ((node (etaf-ui-markdown--paragraph-node block env)))
       (list node)))
    ('code-block (list (etaf-ui-markdown--code-block-node block env)))
    ('blockquote (list (etaf-ui-markdown--blockquote-node block env)))
    ('list (list (etaf-ui-markdown--list-node block env)))
    ('table (list (etaf-ui-markdown--table-node block env)))
    ('thematic-break (list (etaf-ui-markdown--thematic-break-node)))
    ('html-block
     (when-let* ((node (etaf-ui-markdown--html-block-node block env)))
       (list node)))
    ('footnote-def (list (etaf-ui-markdown--footnote-def-node block env)))
    ('definition-list (list (etaf-ui-markdown--definition-list-node block env)))
    ('math (list (etaf-ui-markdown--math-node block env)))
    ('comment nil)
    (_ nil)))

(defun etaf-ui-markdown-view-block (block env)
  "Return BLOCK rendered as one ETAF View, or nil when nothing renders.
A block that expands to several Views is wrapped in one column, so callers
own one node per block for references, spacing or scrolling."
  (let ((views (etaf-ui-markdown--view-block block env)))
    (cond
     ((null views) nil)
     ((null (cdr views)) (car views))
     (t (etaf-node 'column (list :width 'stretch :item-gap '(lh 0)) views)))))

(defun etaf-ui-markdown-view-blocks (blocks env &optional tight)
  "Return the list of Views for BLOCKS in ENV, in document order.
Every block is rendered by `etaf-ui-markdown--view-block'; consecutive blocks
are separated by one blank line, unless TIGHT drops it for nested content.
The list preserves the document order, so callers may wrap each View in their
own container for scrolling, selection or per-block references."
  (let ((nodes nil)
        (first t))
    (dolist (block blocks)
      (when-let* ((views (etaf-ui-markdown--view-block block env)))
        (unless (or first tight)
          (push (etaf-ui-markdown--spacer) nodes))
        (setq first nil)
        (dolist (view views)
          (when view (push view nodes)))))
    (nreverse nodes)))

(provide 'etaf-ui-markdown)
;;; etaf-ui-markdown.el ends here
