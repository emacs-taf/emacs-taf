;;; etaf-org-views.el --- Org document and node rendering -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; Document tree in, ETAF Views out.  Every function here is a pure function
;; of the parsed tree plus an environment plist; nothing reads a file, opens a
;; buffer, starts a subprocess, or touches the network during `:render'.
;;
;; Typography stays at the user's Emacs body metrics (`1.0x') for all prose,
;; chips, tables, drawers, footnotes, code blocks, and widgets; only the
;; document title and H1-H4 headlines use the reading type ladder.
;;
;; Interactive pointer hover follows strict leaf-only discipline via
;; `etaf-org--leaf-button': selected or disabled controls suppress
;; `:hover-style', and multi-styled containers never carry hover fills.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'etaf)
(require 'etaf-ui)
(require 'etaf-org-theme)
(require 'etaf-org-node)
(require 'etaf-org-env)
(require 'etaf-org-parse)
(require 'etaf-org-typeset)
(require 'etaf-org-assets)
(require 'etaf-org-nodes)
(require 'etaf-org-widgets)

(declare-function etaf-org--env "etaf-org-model" (session))
(declare-function etaf-org--read "etaf-org-model" (session key))
(declare-function etaf-org--write "etaf-org-model" (session key value))
(declare-function etaf-org--activate-media "etaf-org-model" (session kind path &optional caption))
(declare-function etaf-org--peek-citation "etaf-org-model" (session key))
(declare-function etaf-org--peek-symbol "etaf-org-model" (session name))
(declare-function etaf-org--return-from-footnote "etaf-org-model" (session label))
(declare-function etaf-org--clear-filter "etaf-org-model" (session))
(declare-function etaf-org--section-matches-filter-p "etaf-org-model" (section filter))
(declare-function etaf-ui-markdown-highlight-code "etaf-ui-markdown-highlight" (language text))
(declare-function etaf-ui-color-legible "etaf-ui" (color background &optional ratio))
(declare-function etaf-ui-color-contrast "etaf-ui" (first second))
(defvar etaf-org-toc-side)
(defvar etaf-org--toc-width-min)
(defvar etaf-org--toc-width-max)
(defvar etaf-org--toc-min-article)
(declare-function etaf-org-outline "etaf-org-model" (session))
(declare-function etaf-org-locate "etaf-org-model" (session index))
(declare-function etaf-org--section-ref "etaf-org-model" (id))
(declare-function etaf-org--toc-side-by-side-p "etaf-org-model" (raw-cols))
(declare-function etaf-org--clamp-toc-width "etaf-org-model" (width &optional available))
(declare-function etaf-org--set-toc-width "etaf-org-model" (session width))
(declare-function etaf-org-toggle-toc "etaf-org-app" (&optional arg))

(defconst etaf-org--measure-gutter 2
  "Character cells kept blank on each side of the reading measure.")

(defconst etaf-org--day-names
  '(("Mon" . "周一") ("Tue" . "周二") ("Wed" . "周三") ("Thu" . "周四")
    ("Fri" . "周五") ("Sat" . "周六") ("Sun" . "周日"))
  "English day abbreviations mapped to the Chinese label the preview shows.")

(defconst etaf-org--icon-glyphs
  '(("check" . "✓") ("cross" . "✕") ("warn" . "⚠") ("info" . "ℹ")
    ("star" . "★") ("spark" . "✦") ("bolt" . "⚡") ("clock" . "◷")
    ("book" . "▤") ("file" . "▪") ("folder" . "▸") ("link" . "↗")
    ("lock" . "⛨") ("tag" . "#") ("play" . "▶") ("code" . "<>"))
  "Built-in inline icon tokens for `[[icon:...]]' micro-widgets.")

;;; ---------------------------------------------------------------------------
;;; Shared helpers
;;; ---------------------------------------------------------------------------

(defun etaf-org--color (env key)
  "Return ENV's palette color for semantic KEY."
  (etaf-org--env-color env key))

(defun etaf-org--scaled (factor)
  "Return heading scale FACTOR clamped to a sensible range."
  (max 1.0 (min 4.0 factor)))

(defun etaf-org--mono ()
  "Return the theme's optional `:font-mono' family, or nil for unified body font."
  (etaf-org--mono-family))

(defun etaf-org--spacer (&optional lines)
  "Return an empty spacer Box LINES lines tall."
  (etaf-node 'box (list :height (list 'lh (or lines 1))) nil))

(defun etaf-org--rule (_env &optional spacing)
  "Return a hairline divider, separated from its neighbours by SPACING lines."
  (etaf-node 'etaf-divider
             (list :orientation 'horizontal
                   :margin-top (list 'lh (or spacing 1))
                   :margin-bottom (list 'lh (or spacing 1)))
             nil))

(defun etaf-org--chip (env text ink background &optional bold)
  "Return a standard-height semantic chip for TEXT in ENV."
  (etaf-node 'box
             (list :background-color (etaf-org--color env background)
                   :color (etaf-org--color env ink)
                   :width 'max-content
                   :flex-shrink 0
                   :padding-left '(ch 1)
                   :padding-right '(ch 1))
             (list (etaf-node 'text (list :font-weight (if bold 'bold 'normal))
                              (list text)))))

(defun etaf-org--heading-size (level)
  "Return the heading scale ratio for LEVEL (1..4 scaled, 5+ body size)."
  (etaf-org--scaled (pcase level
                      (1 2.00)
                      (2 1.50)
                      (3 1.25)
                      (4 1.10)
                      (_ 1.00))))

(defun etaf-org--heading-ink (level)
  "Return the palette key a LEVEL heading is written in."
  (if (<= level 4) :heading :muted))

(defun etaf-org--heading-gap (_env _level)
  "Return one body line above a heading."
  (list 'lh 1.0))

(defun etaf-org--act (env key &rest args)
  "Call ENV's action KEY with ARGS, when present."
  (when-let* ((actions (plist-get env :actions))
              (fn (plist-get actions key)))
    (apply fn args)))

(defun etaf-org--make-node-env (node block env &optional state-ref section)
  "Build an `etaf-org-env' struct for NODE/BLOCK inside legacy ENV."
  (etaf-org-env-create
   :session (plist-get env :session)
   :node node
   :width (or (plist-get env :width) 88)
   :state (or state-ref (plist-get env :block-state))
   :palette (plist-get env :palette)
   :theme (plist-get env :theme)
   :block block
   :slot (plist-get env :slot)
   :section (or section
                (plist-get env :section)
                (plist-get (plist-get env :slot) :section))
   :legacy-env env))

(defun etaf-org--copy-to-kill-ring (text &optional label)
  "Save TEXT to `kill-ring' and report LABEL."
  (kill-new (or text ""))
  (message "已复制%s" (if label (concat "：" label) "")))

;;; ---------------------------------------------------------------------------
;;; Inline rendering
;;; ---------------------------------------------------------------------------

(defun etaf-org--format-stamp-part (part)
  "Format one timestamp PART plist."
  (when part
    (let* ((day-raw (plist-get part :day))
           (day (or (and day-raw (cdr (assoc day-raw etaf-org--day-names)))
                    (and day-raw (not (string-empty-p day-raw)) day-raw)))
           (hh (plist-get part :hh))
           (mm (plist-get part :mm))
           (end-hh (plist-get part :end-hh))
           (end-mm (plist-get part :end-mm))
           (time (if hh
                     (format " %02d:%02d%s" hh (or mm 0)
                             (if end-hh (format "-%02d:%02d" end-hh (or end-mm 0)) ""))
                   "")))
      (format "%04d-%02d-%02d%s%s"
              (plist-get part :y) (plist-get part :m) (plist-get part :d)
              (if day (concat " " day) "") time))))

(defun etaf-org--timestamp-text (stamp)
  "Return STAMP formatted for reading (including date ranges and delays)."
  (let* ((start (etaf-org--format-stamp-part (plist-get stamp :start)))
         (end-stamp (plist-get stamp :end))
         (end (and end-stamp (etaf-org--format-stamp-part (plist-get end-stamp :start))))
         (repeater (or (plist-get stamp :repeater) ""))
         (warning (or (plist-get stamp :warning) "")))
    (concat (or start "")
            (if end (concat " → " end) "")
            (if (string-empty-p repeater) "" (concat " " repeater))
            (if (string-empty-p warning) "" (concat " " warning)))))

(defun etaf-org--emphasis-props (marker)
  "Return the style props of an emphasis MARKER."
  (pcase marker
    ("*" (list :font-weight 'bold))
    ("/" (list :font-style 'italic))
    ("_" (list :text-decoration-line '(underline)))
    ("+" (list :text-decoration-line '(line-through)))
    (_ nil)))

(defun etaf-org--format-citation-label (keys env)
  "Format citation KEYS using ENV's loaded `:bibliography' table when present."
  (let ((bib (plist-get env :bibliography)))
    (if (and (hash-table-p bib) (> (hash-table-count bib) 0))
        (format "(%s)"
                (mapconcat
                 (lambda (k)
                   (if-let* ((entry (gethash k bib)))
                       (let* ((au (or (plist-get entry :author) k))
                              (short (car (split-string au " and \\|,\\|;" t)))
                              (yr (plist-get entry :year)))
                         (if (and yr (not (string-empty-p yr)))
                             (format "%s, %s" (string-trim short) yr)
                           (string-trim short)))
                     (concat "@" k)))
                 keys "; "))
      (mapconcat (lambda (key) (concat "@" key)) keys " "))))

(defun etaf-org--inline-widget-entry (node env inherited)
  "Render an `inline-widget' AST NODE into an inline entry for ENV."
  (let* ((scheme (plist-get node :scheme))
         (payload (or (plist-get node :payload) ""))
         (label (plist-get node :label))
         (shown (or label payload))
         (session (plist-get env :session))
         (hover (etaf-org--hover-fill env)))
    (pcase scheme
      ('kbd
       (list :text (format " %s " shown)
             :props (append (list :background-color (etaf-org--color env :panel2)
                                  :color (etaf-org--color env :ink)
                                  :font-family (etaf-org--mono)
                                  :font-weight 'bold)
                            inherited)))
      ('badge
       (let* ((parts (split-string payload ":" t))
              (tone (intern (downcase (or (car parts) "primary"))))
              (txt (or label (string-join (cdr parts) ":") payload))
              (fg (pcase tone
                    ('success (etaf-org--color env :ok))
                    ('warning (etaf-org--color env :warn))
                    ('danger (etaf-org--color env :danger))
                    ('important (etaf-org--color env :important))
                    ('neutral (etaf-org--color env :muted))
                    (_ (etaf-org--color env :accent))))
              (bg (pcase tone
                    ('success (etaf-org--color env :ok-soft))
                    ('warning (etaf-org--color env :warn-soft))
                    ('danger (etaf-org--color env :danger-soft))
                    ('important (etaf-org--color env :important-soft))
                    ('neutral (etaf-org--color env :panel2))
                    (_ (etaf-org--color env :accent-soft)))))
         (list :text (format " %s " txt)
               :props (append (list :color fg :background-color bg :font-weight 'bold)
                              inherited))))
      ('sym
       (list :text shown
             :props (append (list :color (etaf-org--color env :accent)
                                  :background-color (etaf-org--color env :panel2)
                                  :font-family (etaf-org--mono))
                            inherited)
             :press (lambda ()
                      (when (and session (fboundp 'etaf-org--peek-symbol))
                        (etaf-org--peek-symbol session payload)))
             :hover hover
             :data-target (concat "sym:" payload)
             :help (format "查看符号：%s（点击或 K 速览）" payload)))
      ('color
       (let ((hex (if (string-prefix-p "#" payload) payload (concat "#" payload))))
         (list :text (format "■ %s" shown)
               :props (append (list :color (if (string-match-p "\\`#[0-9a-fA-F]\\{3,8\\}\\'" hex)
                                               hex
                                             (etaf-org--color env :accent))
                                    :font-family (etaf-org--mono))
                              inherited))))
      ('spoiler
       (let* ((revealed (plist-get env :spoilers-revealed))
              (txt (if revealed shown (make-string (max 4 (min 16 (string-width shown))) ?▓))))
         (list :text txt
               :props (append (list :background-color (etaf-org--color env :panel2)
                                    :color (if revealed
                                               (etaf-org--color env :ink)
                                             (etaf-org--color env :muted)))
                              inherited)
               :press (lambda () (etaf-org--act env :toggle-spoilers))
               :hover hover
               :help (if revealed "隐藏剧透内容" "点击显示剧透内容"))))
      ('icon
       (list :text (or (cdr (assoc (downcase payload) etaf-org--icon-glyphs))
                       (format "[%s]" payload))
             :props (append (list :color (etaf-org--color env :accent)) inherited)))
      ('abbr
       (let ((exp (or (cdr (assoc payload (plist-get env :abbreviations)))
                      label payload)))
         (list :text (or label payload)
               :props (append (list :text-decoration-line '(underline)
                                    :color (etaf-org--color env :ink))
                              inherited)
               :help (format "%s：%s" payload exp))))
      ((or 'roam 'denote)
       (list :text (format "◇ %s" shown)
             :props (append (list :color (etaf-org--color env :link)
                                  :text-decoration-line '(underline))
                            inherited)
             :press (lambda ()
                      (etaf-org--act env :open (format "%s:%s" scheme payload)))
             :hover hover
             :help (format "%s 笔记：%s" scheme payload)))
      (_
       (list :text shown :props inherited)))))

(defun etaf-org--inline-entries (inlines env &optional inherited)
  "Flatten INLINES into styled entries for ENV."
  (let ((result nil)
        (hover (etaf-org--hover-fill env))
        (spoilers-revealed (plist-get env :spoilers-revealed)))
    (dolist (node inlines)
      (let ((type (plist-get node :type)))
        (pcase type
          ('text
           (push (list :text (or (plist-get node :text) "") :props inherited)
                 result))
          ('emphasis
           (setq result
                 (append
                  (nreverse
                   (etaf-org--inline-entries
                    (plist-get node :children) env
                    (append (etaf-org--emphasis-props (plist-get node :marker))
                            inherited)))
                  result)))
          ('mark
           (setq result
                 (append
                  (nreverse
                   (etaf-org--inline-entries
                    (plist-get node :children) env
                    (append (list :background-color (etaf-org--color env :warn-soft)
                                  :color (etaf-org--color env :ink))
                            inherited)))
                  result)))
          ('spoiler
           (let* ((plain (etaf-org-inline-plain-text (plist-get node :children)))
                  (shown (if spoilers-revealed
                             plain
                           (make-string (max 4 (min 18 (string-width plain))) ?▓))))
             (push (list :text shown
                         :props (append (list :background-color (etaf-org--color env :panel2)
                                              :color (if spoilers-revealed
                                                         (etaf-org--color env :ink)
                                                       (etaf-org--color env :muted)))
                                        inherited)
                         :press (lambda () (etaf-org--act env :toggle-spoilers))
                         :hover hover
                         :help (if spoilers-revealed "点击隐藏剧透" "点击展开剧透（S 键全局切换）"))
                   result)))
          ('code
           (push (list :text (or (plist-get node :text) "")
                       :props (append
                               (list :background-color (etaf-org--color env :panel)
                                     :font-family (etaf-org--mono))
                               inherited))
                 result))
          ('inline-widget
           (push (etaf-org--inline-widget-entry node env inherited) result))
          ('link
           (let* ((target (plist-get node :target))
                  (desc (plist-get node :desc))
                  (text (if desc (etaf-org-inline-plain-text desc) target)))
             (push (list :text text
                         :props (append
                                 (list :color (etaf-org--color env :link)
                                       :text-decoration-line '(underline))
                                 inherited)
                         :press (lambda () (etaf-org--act env :open target))
                         :hover hover
                         :data-target target
                         :help (format "%s（RET 打开 / K 速览）" target))
                   result)))
          ('timestamp
           (push (list :text (etaf-org--timestamp-text node)
                       :props (append
                               (list :color (etaf-org--color
                                             env (if (plist-get node :active)
                                                     :date :muted))
                                     :font-family (etaf-org--mono))
                               inherited))
                 result))
          ('footnote-ref
           (let ((label (plist-get node :label)))
             (push (list :text (format "[%d]" (plist-get node :number))
                         :props (append
                                 (list :color (etaf-org--color env :link)
                                       :font-weight 'bold)
                                 inherited)
                         :press (lambda () (etaf-org--act env :footnote label))
                         :hover hover
                         :data-target (concat "fn:" label)
                         :help (format "跳到脚注 %s（K 速览）" label))
                   result)))
          ('entity
           (push (list :text (or (plist-get node :text) "") :props inherited)
                 result))
          ('subsup
           (push (list :text (or (plist-get node :text) "") :props inherited)
                 result))
          ('statistics-cookie
           (push (list :text (plist-get node :text)
                       :props (append
                               (list :color (etaf-org--color env :muted)
                                     :font-family (etaf-org--mono))
                               inherited))
                 result))
          ('citation
           (let* ((keys (plist-get node :keys))
                  (first-key (car keys))
                  (label (etaf-org--format-citation-label keys env))
                  (session (plist-get env :session)))
             (push (list :text label
                         :props (append
                                 (list :color (etaf-org--color env :accent)
                                       :background-color (etaf-org--color env :panel))
                                 inherited)
                         :press (when first-key
                                  (lambda ()
                                    (when (and session (fboundp 'etaf-org--peek-citation))
                                      (etaf-org--peek-citation session first-key))))
                         :hover hover
                         :data-target (when first-key (concat "cite:" first-key))
                         :help (format "查看参考文献 %s" (string-join keys ", ")))
                   result)))
          ('latex-fragment
           (push (list :text (plist-get node :text)
                       :props (append
                               (list :color (etaf-org--color env :link)
                                     :font-family (etaf-org--mono)
                                     :font-style 'italic)
                               inherited))
                 result))
          ('inline-src
           (push (list :text (plist-get node :text)
                       :props (append
                               (list :background-color (etaf-org--color env :panel2)
                                     :font-family (etaf-org--mono))
                               inherited))
                 result))
          ('export-snippet
           (push (list :text (or (plist-get node :text) "")
                       :props (append
                               (list :background-color (etaf-org--color env :panel2)
                                     :font-family (etaf-org--mono))
                               inherited))
                 result))
          ('break
           (push (list :text "\n" :props inherited) result))
          ('target
           (let ((name (or (plist-get node :name) "")))
             (if (plist-get node :radio)
                 (push (list :text (concat "◆ " name)
                             :props (append
                                     (list :color (etaf-org--color env :faint)
                                           :font-family (etaf-org--mono))
                                     inherited))
                       result)
               (push (list :text name
                           :press (lambda () (etaf-org--act env :target name))
                           :hover hover
                           :data-target (concat "target:" name)
                           :help (format "跳到目标：%s" name)
                           :props (append
                                   (list :color (etaf-org--color env :link)
                                         :text-decoration-line '(underline))
                                   inherited))
                     result))))
          (_
           (when-let* ((text (plist-get node :text)))
             (push (list :text text :props inherited) result))))))
    (nreverse result)))

(defun etaf-org--merge-entries (entries)
  "Merge adjacent non-interactive text ENTRIES sharing identical style."
  (let ((result nil))
    (dolist (entry entries)
      (let ((previous (car result)))
        (if (and previous
                 (not (plist-get previous :view))
                 (not (plist-get entry :view))
                 (null (plist-get previous :press))
                 (null (plist-get entry :press))
                 (null (plist-get previous :help))
                 (null (plist-get entry :help))
                 (equal (plist-get previous :props) (plist-get entry :props)))
            (setcar result (plist-put previous :text
                                      (concat (plist-get previous :text)
                                              (plist-get entry :text))))
          (push entry result))))
    (nreverse result)))

(defun etaf-org--entries-nodes (entries)
  "Turn merged ENTRIES into ETAF text nodes."
  (mapcar
   (lambda (entry)
     (if (plist-get entry :view)
         (plist-get entry :view)
       (etaf-node 'text
                  (append (plist-get entry :props)
                          (when (plist-get entry :help)
                            (list :help-echo (plist-get entry :help)))
                          (when (plist-get entry :data-target)
                            (list :attributes (list (cons 'target (plist-get entry :data-target)))))
                          (when (plist-get entry :press)
                            (append
                             (list :on-press (plist-get entry :press)
                                   :role 'button :tab-index 0 :pointer 'hand)
                             (when (plist-get entry :hover)
                               (list :hover-style
                                     (list :background-color (plist-get entry :hover)))))))
                  (list (plist-get entry :text)))))
   entries))

(defun etaf-org--inline-nodes (inlines env &optional inherited)
  "Return INLINES as ETAF text nodes for ENV."
  (etaf-org--entries-nodes
   (etaf-org--merge-entries
    (etaf-org--inline-entries inlines env inherited))))

(defun etaf-org--runs-box (inlines env &optional props)
  "Return a wrapping paragraph Box of INLINES in ENV with PROPS."
  (let ((align (plist-get env :text-align)))
    (etaf-node 'box
               (append (list :width 'stretch :wrap-mode 'word)
                       (when align (list :text-align align))
                       props)
               (etaf-org--inline-nodes inlines env))))

;;; ---------------------------------------------------------------------------
;;; Images & Videos (metric-safe via `etaf-org--cell-metrics')
;;; ---------------------------------------------------------------------------

(defun etaf-org--attr-columns (value env)
  "Return VALUE as a column count in ENV, or nil."
  (when-let* ((text (cond ((numberp value) (number-to-string value))
                          ((stringp value) value)))
              ((string-match-p "\\`[0-9]+\\(?:\\.[0-9]+\\)?%?\\'" text)))
    (let* ((number (string-to-number text))
           (percent (string-suffix-p "%" text))
           (cw (car (etaf-org--cell-metrics))))
      (max 4 (round (if percent
                        (* (or (plist-get env :width) 92) (/ number 100.0))
                      (/ number (float (max 1 cw)))))))))

(defun etaf-org--attr-rows (value)
  "Return VALUE as a row count, or nil."
  (when-let* ((text (cond ((numberp value) (number-to-string value))
                          ((stringp value) value)))
              ((string-match-p "\\`[0-9]+\\(?:\\.[0-9]+\\)?\\'" text)))
    (let ((ch (cdr (etaf-org--cell-metrics))))
      (max 1 (round (/ (string-to-number text) (float (max 1 ch))))))))

(defun etaf-org--grid-for-pixels (env pixels)
  "Return `(COLUMNS . ROWS)' for PIXELS in ENV's reading measure."
  (let* ((max-columns (max 8 (- (or (plist-get env :width) 92) 4)))
         (max-rows (or (plist-get env :image-max-rows) 24))
         (cell (etaf-org--cell-metrics))
         (cw (float (max 1 (car cell))))
         (ch (float (max 1 (cdr cell)))))
    (if pixels
        (let* ((width (max 1 (car pixels)))
               (height (max 1 (cdr pixels)))
               (columns (max 4 (round (/ (* 1.0 width) cw))))
               (rows (max 1 (round (/ (* 1.0 height) ch))))
               (scale (min 1.0 (/ (float max-columns) columns)
                           (/ (float max-rows) rows))))
          (cons (max 4 (round (* columns scale)))
                (max 1 (round (* rows scale)))))
      (cons (min 48 max-columns) 12))))

(defun etaf-org--media-grid (media env)
  "Return `(COLUMNS . ROWS)' of MEDIA in ENV preserving aspect ratio."
  (let* ((pixels (and (plist-get media :width)
                      (cons (plist-get media :width) (plist-get media :height))))
         (grid (etaf-org--grid-for-pixels env pixels))
         (attrs (plist-get media :attrs))
         (column-cap (etaf-org--attr-columns (plist-get attrs :width) env))
         (row-cap (etaf-org--attr-rows (plist-get attrs :height)))
         (scale (min 1.0
                     (if (and column-cap (< column-cap (car grid)))
                         (/ (float column-cap) (car grid))
                       1.0)
                     (if (and row-cap (< row-cap (cdr grid)))
                         (/ (float row-cap) (cdr grid))
                       1.0))))
    (if (< scale 1.0)
        (cons (max 4 (round (* (car grid) scale)))
              (max 1 (round (* (cdr grid) scale))))
      grid)))

(defun etaf-org--image-card (media env)
  "Return the image card for MEDIA in ENV, or a placeholder card."
  (let* ((path (plist-get media :path))
         (grid (etaf-org--media-grid media env))
         (caption (plist-get media :caption))
         (alt (plist-get media :alt))
         (session (plist-get env :session)))
    (etaf-node 'column
               (list :width 'stretch :cross-align 'center :item-gap '(lh 0))
               (append
                (list
                 (if (and path (plist-get media :exists))
                     (etaf-node 'image
                                (list :src path
                                      :columns (car grid) :rows (cdr grid)
                                      :adapter 'auto
                                      :role 'button :tab-index 0 :pointer 'hand
                                      :on-press (lambda ()
                                                  (if (and session (fboundp 'etaf-org--activate-media))
                                                      (etaf-org--activate-media
                                                       session 'image path
                                                       (or caption alt))
                                                    (etaf-org--act env :open-file path)))
                                      :help-echo (format "%s（RET 灯箱预览/打开）"
                                                         (or alt (file-name-nondirectory path))))
                                nil)
                   (etaf-node 'box
                              (list :border (etaf-org--hairline env)
                                    :background-color (etaf-org--color env :panel)
                                    :padding '((lh 1) (ch 2)))
                              (list (etaf-org--leaf-button
                                     env
                                     (format "图片不可用：%s" (or path "未知路径"))
                                     (lambda () (etaf-org--act env :open (or path "")))
                                     :color (etaf-org--color env :muted))))))
                (when (and caption (not (string-empty-p caption)))
                  (list (etaf-node 'text
                                   (list :color (etaf-org--color env :muted))
                                   (list caption))))))))

(defun etaf-org--video-card (media env)
  "Return inline video playback card or fallback file card for MEDIA in ENV."
  (let* ((path (plist-get media :path))
         (caption (or (plist-get media :caption)
                      (and path (file-name-nondirectory path))
                      "视频"))
         (node-env (etaf-org--make-node-env nil nil env))
         (playing (etaf-org-block-state node-env :video-playing nil))
         (cols (min 64 (max 24 (- (or (plist-get env :width) 88) 4))))
         (rows (max 8 (round (* cols 0.35))))
         (session (plist-get env :session)))
    (if (and playing path (file-exists-p path) (executable-find "ffmpeg"))
        (etaf-node 'column
                   (list :width 'stretch :cross-align 'center :item-gap '(lh 0))
                   (list
                    (etaf-node 'box
                               (list :border (etaf-org--hairline env))
                               (list (etaf-node 'etaf-video
                                                (list :src path
                                                      :columns cols :rows rows
                                                      :mode 'image :autoplay t)
                                                nil)))
                    (etaf-node 'flex
                               (list :gap '((lh 0) (ch 2)) :align-items 'center)
                               (list
                                (etaf-node 'text (list :color (etaf-org--color env :muted))
                                           (list (format "▶ %s" caption)))
                                (etaf-org--leaf-button
                                 env "[停止]"
                                 (lambda () (etaf-org-set-block-state node-env :video-playing nil)))))))
      (etaf-node 'box
                 (list :width 'stretch :border (etaf-org--hairline env)
                       :background-color (etaf-org--color env :panel)
                       :padding '((lh 0) (ch 2)))
                 (list
                  (etaf-node 'flex
                             (list :width 'stretch :justify-content 'space-between
                                   :align-items 'center :gap '((lh 0) (ch 2)))
                             (list
                              (etaf-node 'text (list :color (etaf-org--color env :ink))
                                         (list (format "▶ 视频：%s" caption)))
                              (etaf-org--leaf-button
                               env
                               (if (and path (file-exists-p path) (executable-find "ffmpeg"))
                                   "[内嵌播放]"
                                 "[外部打开]")
                               (lambda ()
                                 (if (and path (file-exists-p path) (executable-find "ffmpeg"))
                                     (etaf-org-set-block-state node-env :video-playing t)
                                   (if (and session (fboundp 'etaf-org--activate-media))
                                       (etaf-org--activate-media session 'video path caption)
                                     (etaf-org--act env :open-file path))))))))))))

(defun etaf-org--file-card (block env)
  "Return a card for a file BLOCK in ENV."
  (let ((path (or (plist-get block :path) (plist-get block :target) ""))
        (label (or (plist-get block :label) "文件")))
    (etaf-node 'box
               (list :width 'stretch
                     :border (etaf-org--hairline env)
                     :background-color (etaf-org--color env :panel)
                     :padding '((lh 0) (ch 2)))
               (list (etaf-org--leaf-button
                      env
                      (format "%s：%s" label path)
                      (lambda () (etaf-org--act env :open path))
                      :color (etaf-org--color env :link)
                      :help (format "打开 %s" path))))))

;;; ---------------------------------------------------------------------------
;;; Tables (sorting, highlighting, zebra, TSV copy, TBLFM)
;;; ---------------------------------------------------------------------------

(defun etaf-org--parse-int-list (spec)
  "Parse whitespace/comma-separated positive integers from SPEC."
  (when (stringp spec)
    (cl-loop for tok in (split-string spec "[, \t]+" t)
             when (string-match-p "\\`[0-9]+\\'" tok)
             collect (string-to-number tok))))

(defun etaf-org--parse-cell-coords (spec)
  "Parse `ROW:COL' pairs from SPEC into alist of `(ROW . COL)'."
  (when (stringp spec)
    (cl-loop for tok in (split-string spec "[, \t]+" t)
             when (string-match "\\`\\([0-9]+\\):\\([0-9]+\\)\\'" tok)
             collect (cons (string-to-number (match-string 1 tok))
                           (string-to-number (match-string 2 tok))))))

(defun etaf-org--table-column-widths (floors available)
  "Return column widths fitting FLOORS inside AVAILABLE cells."
  (let* ((count (length floors))
         (total (apply #'+ floors)))
    (if (<= total available)
        floors
      (let* ((budget (max (* 3 count) available))
             (result (cl-loop for floor in floors
                              collect (max 3 (floor (* floor (/ (float budget)
                                                                total))))))
             (leftover (- budget (apply #'+ result))))
        (while (> (apply #'+ result) budget)
          (let ((widest (cl-position (apply #'max result) result)))
            (setf (nth widest result) (1- (nth widest result)))))
        (cl-loop for index from 0 below count
                 while (> leftover 0)
                 when (< (nth index result) (nth index floors))
                 do (setf (nth index result) (1+ (nth index result)))
                 and do (cl-decf leftover))
        result))))

(defun etaf-org--table-tsv (rows)
  "Serialize parsed table ROWS as tab-separated values."
  (mapconcat
   (lambda (row)
     (mapconcat (lambda (cell)
                  (etaf-org-inline-plain-text (plist-get cell :inlines)))
                (plist-get row :cells) "\t"))
   rows "\n"))

(defun etaf-org--sort-table-rows (body-rows col dir)
  "Return BODY-ROWS sorted by 0-based COL in DIR (`asc' or `desc')."
  (let* ((cell-key (lambda (row)
                     (let* ((c (nth col (plist-get row :cells)))
                            (txt (string-trim
                                  (etaf-org-inline-plain-text (plist-get c :inlines)))))
                       (if (string-match-p "\\`-?[0-9]+\\(?:\\.[0-9]+\\)?%?\\'" txt)
                           (cons 'num (string-to-number txt))
                         (cons 'str (downcase txt))))))
         (sorted
          (sort (copy-sequence body-rows)
                (lambda (a b)
                  (let ((ka (funcall cell-key a))
                        (kb (funcall cell-key b)))
                    (if (and (eq (car ka) 'num) (eq (car kb) 'num))
                        (< (cdr ka) (cdr kb))
                      (string< (format "%s" (cdr ka))
                               (format "%s" (cdr kb)))))))))
    (if (eq dir 'desc) (nreverse sorted) sorted)))

(defun etaf-org--table-header-fill (env)
  "Return the header tint for a table in ENV, deepened to stay visible.
Mirrors `etaf-ui-markdown--header-fill': when `:table-header' sits too close
to the page surface, rebuild it as one clean step toward `:ink'."
  (let* ((page (or (plist-get env :background)
                   (etaf-org--color env :bg)))
         (ink (etaf-org--color env :ink))
         (tint (etaf-org--color env :table-header)))
    (if (and page ink tint
             (< (or (etaf-ui-color-contrast tint page) 2.0) 1.12))
        (etaf-ui-color-mix page ink 0.08)
      tint)))

(defun etaf-org--table-view (block env &optional opts)
  "Return the 3-line booktabs table View of BLOCK in ENV with style OPTS.
Aligns with `etaf-md--table-view': full-width 3-line booktabs with zero
vertical borders, unified title + `复制表格' bar, clickable `▲'/`▼'/`⇅' sort
headers when `:sortable t', and whole-table centering/right alignment when
`:align' is `center' or `right'."
  (let* ((all-rows (plist-get block :rows))
         (columns (max 1 (or (plist-get block :columns) 1)))
         (header-count (or (plist-get block :header-count) 0))
         (align-override (plist-get opts :align))
         (table-align (pcase align-override
                        ('center 'center)
                        ((or 'right 'end) 'right)
                        ((or 'left 'start) 'left)
                        (_ nil)))
         (aligns (or (plist-get block :aligns) nil))
         (widths-cookie (or (plist-get block :widths) nil))
         (node-env (or (plist-get opts :env) (etaf-org--make-node-env nil block env)))
         (sortable (plist-get opts :sortable))
         (copy-btn (plist-get opts :copy))
         (zebra (plist-get opts :zebra))
         (hi-rows (etaf-org--parse-int-list (plist-get opts :highlight-rows)))
         (hi-cols (etaf-org--parse-int-list (plist-get opts :highlight-columns)))
         (hi-cells (etaf-org--parse-cell-coords (plist-get opts :highlight-cells)))
         (hi-accent (or (plist-get opts :highlight) 'warning))
         (hi-fg (etaf-org-accent node-env hi-accent))
         (hi-bg (etaf-org-accent node-env hi-accent t))
         (hdr-bg (or (and (plist-get opts :header-background)
                          (etaf-org-surface node-env (plist-get opts :header-background)))
                     (etaf-org--table-header-fill env)))
         (stripe-bg (or (and (plist-get opts :stripe-background)
                             (etaf-org-surface node-env (plist-get opts :stripe-background)))
                        (etaf-org--color env :table-stripe)))
         (sort-col (and sortable (etaf-org-block-state node-env :sort-col nil)))
         (sort-dir (and sortable (etaf-org-block-state node-env :sort-dir nil)))
         (head-rows (cl-subseq all-rows 0 (min header-count (length all-rows))))
         (body-rows (nthcdr (min header-count (length all-rows)) all-rows))
         (sorted-body (if (and sortable (integerp sort-col) sort-dir)
                          (etaf-org--sort-table-rows body-rows sort-col sort-dir)
                        body-rows))
         (rows (append head-rows sorted-body))
         (avail (max 16 (or (plist-get env :width) 88)))
         (extra-hdr (if sortable 2 0))
         (raw-widths
          (cl-loop for column from 0 below columns
                   collect
                   (let ((cookie (nth column widths-cookie)))
                     (if (and (integerp cookie) (> cookie 0))
                         (+ 3 cookie)
                       (+ 4 extra-hdr
                          (cl-loop for row in rows
                                   maximize
                                   (string-width
                                    (etaf-org-inline-plain-text
                                     (plist-get
                                      (nth column (plist-get row :cells))
                                      :inlines)))
                                   into w
                                   finally return (max 3 w)))))))
         (sum-w (apply #'+ raw-widths))
         (cell-pad-ch (if (> sum-w avail) 1 2))
         (clamped-widths
          (cond
           ((<= sum-w avail)
            (if (and (null table-align) (> columns 1) (< sum-w avail))
                ;; Full-width booktabs measure when no explicit table alignment:
                ;; distribute leftover columns proportionally so narrow tables
                ;; span the reading column cleanly without cramping any column.
                (let* ((extra (- avail sum-w))
                       (expanded
                        (mapcar (lambda (w)
                                  (+ w (floor (* extra (/ (float w) (max 1 sum-w))))))
                                raw-widths))
                       (rem (- avail (apply #'+ expanded))))
                  (when (> rem 0)
                    (setf (car (last expanded)) (+ (car (last expanded)) rem)))
                  expanded)
              raw-widths))
           ((<= columns 1) (list (max 4 avail)))
           (t
            (let* ((scaled (mapcar (lambda (w)
                                     (max 4 (floor (* avail (/ (float w) sum-w)))))
                                   raw-widths))
                   (rem (- avail (apply #'+ scaled))))
              (when (> rem 0)
                (setf (car (last scaled)) (+ (car (last scaled)) rem)))
              scaled))))
         (tracks (mapcar (lambda (w) (list 'ch w)) clamped-widths))
         (table-width (list 'ch (apply #'+ clamped-widths)))
         (cross-align (pcase table-align
                        ('center 'center)
                        ('right 'end)
                        (_ 'start)))
         (border-col (or (etaf-org--color env :border) (etaf-org--muted env)))
         (line (etaf-org--hairline env))
         (hdr-rule (list '(px 1) 'solid (or (etaf-org--color env :table-border) border-col)))
         (title (or (plist-get opts :title) (plist-get block :caption)))
         (numbering (plist-get opts :numbering))
         (num-prefix (when (and (eq numbering 'decimal) (plist-get block :derived-number))
                       (format "表 %s：" (plist-get block :derived-number))))
         (header-bar
          (when (or title num-prefix copy-btn)
            (etaf-node 'flex
                       (list :width 'stretch
                             :align-items 'center :column-gap '(ch 2)
                             :padding-bottom '(lh 1))
                       (delq nil
                             (list
                              (if (or title num-prefix)
                                  (etaf-node 'box
                                             (list :flex-basis '(ch 0) :flex-grow 1
                                                   :min-width '(ch 12) :wrap-mode 'word)
                                             (list (etaf-node
                                                    'text (list :font-weight 'bold)
                                                    (list (concat (or num-prefix "")
                                                                  (or title ""))))))
                                (etaf-node 'box (list :flex-basis '(ch 0) :flex-grow 1) nil))
                              (when copy-btn
                                (etaf-node
                                 'box (list :flex-shrink 0)
                                 (list (etaf-org--leaf-button
                                        node-env "复制表格"
                                        (lambda ()
                                          (etaf-org--copy-to-kill-ring
                                           (etaf-org--table-tsv rows)
                                           (format "表格（%d 行）" (length rows))))
                                        :bold nil
                                        :help "把整张表复制成制表符分隔的文本")))))))))
         (row-views nil)
         (row-idx 0))
    (dolist (row rows)
      (let* ((is-header (< row-idx header-count))
             (is-header-bottom (and (> header-count 0) (= row-idx (1- header-count))))
             (body-num (if is-header 0 (1+ (- row-idx header-count))))
             (row-hi (and (not is-header) (memq body-num hi-rows)))
             (row-bg (cond (is-header hdr-bg)
                           (row-hi hi-bg)
                           ((and zebra (cl-evenp body-num)) stripe-bg)
                           (t nil)))
             (cells-list (plist-get row :cells))
             (cell-views nil)
             (col-idx 0))
        (dotimes (_ columns)
          (let* ((cell (nth col-idx cells-list))
                 (col-num (1+ col-idx))
                 (cell-hi (and (not is-header)
                               (or (memq col-num hi-cols)
                                   (member (cons body-num col-num) hi-cells))))
                 (cbg (or (when cell-hi hi-bg) row-bg))
                 (align (or (nth col-idx aligns) table-align 'left))
                 (col-capture col-idx)
                 (content
                  (cond
                   ((and is-header sortable)
                    (let* ((active-col (eql sort-col col-capture))
                           (indicator (cond ((and active-col (eq sort-dir 'asc)) " ▲")
                                            ((and active-col (eq sort-dir 'desc)) " ▼")
                                            (t " ⇅")))
                           (txt (concat (if cell
                                            (etaf-org-inline-plain-text (plist-get cell :inlines))
                                          "")
                                        indicator)))
                      (list (etaf-org--leaf-button
                             node-env txt
                             (lambda ()
                               (let* ((cur-col (etaf-org-block-state node-env :sort-col nil))
                                      (cur-dir (etaf-org-block-state node-env :sort-dir nil))
                                      (next-dir (if (eql cur-col col-capture)
                                                    (pcase cur-dir ('asc 'desc) ('desc nil) (_ 'asc))
                                                  'asc)))
                                 (etaf-org-set-block-state node-env :sort-col (and next-dir col-capture))
                                 (etaf-org-set-block-state node-env :sort-dir next-dir)))
                             :selected active-col
                             :keep-pointer t
                             :color (if active-col
                                        (etaf-org--color env :accent)
                                      (etaf-org--color env :ink))
                             :bold t
                             :help "点击按此列排序"))))
                   (cell
                    (etaf-org--inline-nodes
                     (plist-get cell :inlines) env
                     (append (when (or is-header cell-hi row-hi) '(:font-weight bold))
                             (when (or cell-hi row-hi) (list :color hi-fg)))))
                   (t (list (etaf-node 'text nil (list "")))))))
            (push (etaf-node 'box
                             (append
                              (list :width (nth col-idx tracks)
                                    :padding (list '(lh 0) (list 'ch cell-pad-ch))
                                    :overflow 'hidden
                                    :wrap-mode 'word
                                    :text-align align
                                    :border-top (when (= row-idx 0) line)
                                    :border-bottom (if is-header-bottom hdr-rule line))
                              (when cbg (list :background-color cbg)))
                             content)
                  cell-views))
          (cl-incf col-idx))
        (push (etaf-node 'flex (list :width table-width) (nreverse cell-views))
              row-views))
      (cl-incf row-idx))
    (etaf-node 'column
               (list :width 'stretch :cross-align cross-align :item-gap '(lh 0))
               (delq nil
                     (list
                      header-bar
                      (etaf-node 'column
                                 (list :width table-width :item-gap '(lh 0))
                                 (nreverse row-views))
                      (when-let* ((tblfm (plist-get block :tblfm)))
                        (etaf-node 'text
                                   (list :color (etaf-org--color env :faint)
                                         :font-family (etaf-org--mono))
                                   (list (format "公式未求值：%s" tblfm)))))))))

;;; ---------------------------------------------------------------------------
;;; Lists (with surgical checkbox toggling)
;;; ---------------------------------------------------------------------------

(defun etaf-org--list-marker-text (item)
  "Return the text that marks ITEM in an ordered list, or nil."
  (when (plist-get item :ordered)
    (let* ((marker (plist-get item :marker))
           (suffix (if (and marker (eq (aref marker (1- (length marker))) ?\)))
                       ")" "."))
           (counter (plist-get item :counter)))
      (cond (counter (concat counter suffix))
            (marker marker)
            (t (format "%d." (or (plist-get item :number) 1)))))))

(defun etaf-org--list-marks (items)
  "Return the marker column width shared by ITEMS."
  (let ((width 1))
    (dolist (item items)
      (cond
       ((plist-get item :checkbox) (setq width (max width 1)))
       ((plist-get item :term) nil)
       (t (when-let* ((text (etaf-org--list-marker-text item)))
            (setq width (max width (string-width text)))))))
    width))

(defun etaf-org--list-marker (item env marks)
  "Return the marker View of list ITEM in ENV in a MARKS wide column.
Checkboxes use font-native geometric squares (`■', `◧', `□') matching
`etaf-ui-markdown', so line height never shifts across CJK/Latin fonts."
  (let ((cb (plist-get item :checkbox))
        (lno (plist-get item :line-start))
        (session (plist-get env :session)))
    (cond
     (cb
      (let* ((glyph (pcase cb ('on "■") ('partial "◧") (_ "□")))
             (col (pcase cb
                    ('on (etaf-org--color env :accent))
                    ('partial (etaf-org--color env :warn))
                    (_ (etaf-org--color env :muted))))
             (interactive-p (and etaf-org-interactive-checkbox session lno))
             (hover (and interactive-p (etaf-org--hover-fill env 'soft))))
        (etaf-node
         'text
         (append
          (list :color col)
          (when interactive-p
            (list :role 'checkbox :tab-index 0 :pointer 'hand
                  :aria-checked (if (eq cb 'on) t 'false)
                  :help-echo (if (eq cb 'on) "标记为未完成" "标记为已完成")
                  :on-press (lambda () (etaf-org-assets-toggle-checkbox session lno))))
          (when hover (list :hover-style (list :background-color hover))))
         (list glyph))))
     ((plist-get item :ordered)
      (etaf-node 'text
                 (list :color (etaf-org--color env :muted)
                       :font-family (etaf-org--mono))
                 (list (format (format "%%%ds" marks)
                               (etaf-org--list-marker-text item)))))
     (t (etaf-node 'text
                   (list :color (etaf-org--color env :muted))
                   (list "•"))))))

(defun etaf-org--list-view (block env)
  "Return the list View of BLOCK in ENV."
  (let* ((items (plist-get block :items))
         (marks (etaf-org--list-marks items))
         (description (cl-some (lambda (item) (plist-get item :term)) items))
         (views nil))
    (dolist (item items)
      (let* ((term (plist-get item :term))
             (content (etaf-org--block-views (plist-get item :blocks) env)))
        (push
         (if term
             (etaf-node 'column
                        (list :width 'stretch :item-gap '(lh 0))
                        (list
                         (etaf-node 'box
                                    (list :width 'stretch :wrap-mode 'word)
                                    (etaf-org--inline-nodes
                                     term env '(:font-weight bold)))
                         (etaf-node 'box
                                    (list :width 'stretch
                                          :border-left (list '(px 2) 'solid
                                                             (etaf-org--color env :border))
                                          :padding-left '(ch 2))
                                    content)))
           (etaf-node 'flex
                      (list :width 'stretch :align-items 'start)
                      (list
                       (etaf-node 'box
                                  (list :width (list 'ch (1+ marks))
                                        :flex-shrink 0)
                                  (list (etaf-org--list-marker item env marks)))
                       (etaf-node 'column
                                  (list :width 'stretch :min-width '(ch 0)
                                        :item-gap '(lh 0))
                                  content))))
         views)))
    (etaf-node 'column
               (list :width 'stretch
                     :item-gap (list 'lh (if description 1 0)))
               (nreverse views))))

;;; ---------------------------------------------------------------------------
;;; Code blocks (syntax highlight, markers, folding, copy, Babel, RESULTS)
;;; ---------------------------------------------------------------------------

(defconst etaf-org--code-token-colors
  '((light . ((keyword . "#cf222e") (builtin . "#0550ae") (string . "#0a3069")
              (comment . "#6e7781") (function . "#8250df") (variable . "#953800")
              (type . "#953800") (constant . "#0550ae")
              (preprocessor . "#953800") (warning . "#9a6700")))
    (dark . ((keyword . "#ff7b72") (builtin . "#79c0ff") (string . "#a5d6ff")
             (comment . "#8b949e") (function . "#d2a8ff") (variable . "#ffa657")
             (type . "#ffa657") (constant . "#79c0ff")
             (preprocessor . "#ffa657") (warning . "#e3b341"))))
  "Syntax colours for source blocks on light and dark pages.")

(defun etaf-org--dark-page-p (env)
  "Return non-nil when ENV paints a dark page."
  (let ((background (or (plist-get env :background) (etaf-org--color env :bg))))
    (if (and (stringp background)
             (string-match-p "\\`#[0-9a-fA-F]\\{3,8\\}\\'" background))
        (> (or (etaf-org--contrast-ratio background "#ffffff") 0)
           (or (etaf-org--contrast-ratio background "#000000") 0))
      (eq (etaf-appearance) 'dark))))

(defun etaf-org--code-token-color (props env)
  "Return syntax color for PROPS in ENV."
  (let* ((dark (etaf-org--dark-page-p env))
         (role (plist-get props :role))
         (palette (alist-get (if dark 'dark 'light) etaf-org--code-token-colors))
         (surface (etaf-org--color env :panel)))
    (or (alist-get role palette)
        (etaf-ui-color-legible
         (or (plist-get props :color) (etaf-org--color env :ink))
         surface))))

(defun etaf-org--code-runs (language text env)
  "Return syntax-highlighted runs for TEXT in LANGUAGE."
  (when (and (stringp language) (not (string-empty-p language)))
    (when-let* ((runs (etaf-ui-markdown-highlight-code language text)))
      (mapcar
       (lambda (run)
         (let* ((props (copy-sequence (plist-get run :props)))
                (color (etaf-org--code-token-color props env)))
           (list :text (plist-get run :text)
                 :props (plist-put props :color color))))
       runs))))

(defun etaf-org--code-lines (text runs)
  "Split TEXT / highlighted RUNS into per-line run lists."
  (if (not runs)
      (mapcar (lambda (line) (list (list :text line :props nil)))
              (split-string text "\n"))
    (let ((lines nil) (current nil))
      (dolist (run runs)
        (let ((remaining (plist-get run :text))
              (props (plist-get run :props)))
          (while (not (string-empty-p remaining))
            (let ((newline (string-match "\n" remaining)))
              (if newline
                  (progn
                    (when (> newline 0)
                      (push (list :text (substring remaining 0 newline) :props props)
                            current))
                    (push (nreverse current) lines)
                    (setq current nil
                          remaining (substring remaining (1+ newline))))
                (push (list :text remaining :props props) current)
                (setq remaining ""))))))
      (push (nreverse current) lines)
      (nreverse lines))))

(defun etaf-org--code-first-line (switches)
  "Return starting line number requested by Org SWITCHES (`-n [N]'), or nil."
  (let ((tokens (and switches (split-string switches "[ \t]+" t))))
    (when (member "-n" tokens)
      (let ((rest (cdr (member "-n" tokens))))
        (if (and rest (string-match-p "\\`[0-9]+\\'" (car rest)))
            (string-to-number (car rest))
          1)))))

(defun etaf-org--parse-highlight-set (spec)
  "Parse `1,3-5' highlight SPEC into a hash table of 1-based line numbers."
  (let ((set (make-hash-table :test #'eql)))
    (when (stringp spec)
      (dolist (part (split-string (string-trim spec "[{} \t]+" "[{} \t]+") "[, \t]+" t))
        (cond
         ((string-match "\\`\\([0-9]+\\)-\\([0-9]+\\)\\'" part)
          (cl-loop for i from (string-to-number (match-string 1 part))
                   to (string-to-number (match-string 2 part))
                   do (puthash i t set)))
         ((string-match-p "\\`[0-9]+\\'" part)
          (puthash (string-to-number part) t set)))))
    set))

(defun etaf-org--extract-code-markers (raw-lines)
  "Inspect RAW-LINES for `[!code KIND]' markers.
Return `(CLEAN-LINES . MARKER-ALIST)' where MARKER-ALIST maps 1-based line
index to one of `highlight', `focus', `add', `remove', `warning', `error'."
  (let ((clean nil) (markers nil) (idx 0))
    (dolist (ln raw-lines)
      (cl-incf idx)
      (if (string-match "[ \t]*\\(?://\\|#\\|;+\\|--\\|/\\*\\)[ \t]*\\[!code[ \t]+\\(highlight\\|focus\\|\\+\\+\\|--\\|warning\\|error\\)\\][ \t]*\\(?:\\*/\\)?[ \t]*\\'" ln)
          (let ((kind (pcase (match-string 1 ln)
                        ("highlight" 'highlight)
                        ("focus" 'focus)
                        ("++" 'add)
                        ("--" 'remove)
                        ("warning" 'warning)
                        ("error" 'error))))
            (push (cons idx kind) markers)
            (push (substring ln 0 (match-beginning 0)) clean))
        (push ln clean)))
    (cons (nreverse clean) (nreverse markers))))

(defun etaf-org--highlight-word-in-segments (segments word env)
  "Split SEGMENTS to highlight literal WORD with accent-soft background."
  (if (or (null word) (string-empty-p word))
      segments
    (let ((out nil)
          (bg (etaf-org--color env :warn-soft)))
      (dolist (seg segments)
        (let ((txt (or (plist-get seg :text) ""))
              (props (plist-get seg :props))
              (pos 0)
              (q (regexp-quote word)))
          (while (string-match q txt pos)
            (let ((mb (match-beginning 0))
                  (me (match-end 0)))
              (when (> mb pos)
                (push (list :text (substring txt pos mb) :props props) out))
              (let ((hi-props (plist-put (plist-put (copy-sequence props)
                                                    :background-color bg)
                                         :font-weight 'bold)))
                (push (list :text (substring txt mb me) :props hi-props) out))
              (setq pos me)))
          (when (< pos (length txt))
            (push (list :text (substring txt pos) :props props) out))))
      (nreverse out))))

(defun etaf-org--render-results-view (results env &optional embedded)
  "Render paired `#+RESULTS:' block RESULTS in ENV.
When EMBEDDED is non-nil, draws as a flush sunken strip inside the enclosing
source card without repeating outer borders."
  (when results
    (let ((body-block (plist-get results :body-block))
          (text (plist-get results :text))
          (name (plist-get results :name)))
      (etaf-node 'column
                 (append
                  (list :width 'stretch
                        :background-color (or (etaf-org--color env :sunken)
                                              (etaf-org--color env :panel2))
                        :padding '((lh 1) (ch 2))
                        :item-gap '(lh 0))
                  (if embedded
                      (list :border-top (etaf-org--hairline env))
                    (list :border-left (list '(px 3) 'solid (etaf-org--color env :ok)))))
                 (delq nil
                       (list
                        (etaf-node 'text (list :color (etaf-org--color env :ok)
                                               :font-weight 'bold)
                                   (list (if (and name (not (string-empty-p name)))
                                             (format "▸ 结果 · %s" name)
                                           "▸ 结果")))
                        (cond
                         (body-block (etaf-org--block-view body-block env))
                         ((and (stringp text) (not (string-empty-p text)))
                          (etaf-node 'box (list :width 'stretch :wrap-mode 'word
                                                :font-family (etaf-org--mono))
                                     (list (etaf-node 'text
                                                      (list :color (etaf-org--color env :ink))
                                                      (list text))))))))))))

(defun etaf-org--code-block-view (block env &optional label opts)
  "Return the code card for BLOCK in ENV with optional LABEL and OPTS.
OPTS accepts `:frame' (default t) and `:header' (default t) so container
widgets (`code-tabs', `code-tree', `demo', `include', `code-ref', `run')
can embed frameless syntax-highlighted code without double borders."
  (let* ((raw-text (or (plist-get block :text) ""))
         (language (or label (plist-get block :lang)))
         (node-env (or (plist-get opts :env) (etaf-org--make-node-env nil block env)))
         (session (plist-get env :session))
         (frame (if (plist-member opts :frame) (plist-get opts :frame) t))
         (show-header (if (plist-member opts :header) (plist-get opts :header) t))
         (extracted (etaf-org--extract-code-markers (split-string raw-text "\n")))
         (clean-lines (car extracted))
         (markers (cdr extracted))
         (has-focus (cl-some (lambda (m) (eq (cdr m) 'focus)) markers))
         (clean-text (string-join clean-lines "\n"))
         (runs (etaf-org--code-runs language clean-text env))
         (all-line-runs (etaf-org--code-lines clean-text runs))
         (total-lines (length all-line-runs))
         (title (or (plist-get opts :title) (plist-get block :caption)))
         (first-line (or (etaf-org--code-first-line (plist-get block :switches))
                         (plist-get block :start-line)
                         (when (plist-get opts :line-numbers) 1)))
         (hi-set (etaf-org--parse-highlight-set (plist-get opts :highlight)))
         (word (plist-get opts :word))
         (collapse-n (plist-get opts :collapsed-lines))
         (expanded (etaf-org-block-state node-env :code-expanded nil))
         (foldable (and (integerp collapse-n) (> total-lines collapse-n)))
         (visible-count (if (and foldable (not expanded)) collapse-n total-lines))
         (indent-guides (plist-get opts :indent-guides))
         (show-ws (plist-get opts :whitespace))
         (show-copy (if (plist-member opts :copy) (plist-get opts :copy) t))
         (bg (or (and (plist-get opts :background)
                      (etaf-org-surface node-env (plist-get opts :background)))
                 (when frame (etaf-org--color env :panel))))
         (label-color (or (plist-get opts :label-color) (etaf-org--color env :muted)))
         (header-args (plist-get block :header-args))
         (tangle (cdr (assoc ":tangle" header-args)))
         (can-babel (and etaf-org-allow-babel
                         (eq (plist-get block :type) 'src-block)
                         (plist-get block :line-start)
                         session))
         (header-left
          (delq nil
                (list
                 (cond
                  ((and title (not (string-empty-p title)))
                   (etaf-node 'text (list :color (etaf-org--color env :ink)
                                          :font-family (etaf-org--mono)
                                          :font-weight 'bold)
                              (list title)))
                  ((and language (not (string-empty-p language)))
                   (etaf-node 'text (list :color label-color
                                          :font-family (etaf-org--mono))
                              (list language))))
                 (when (and tangle (not (equal tangle "no")))
                   (etaf-org--chip env (format "tangle: %s" tangle) :muted :panel2)))))
         (header-right
          (delq nil
                (list
                 (when can-babel
                   (let ((lno (plist-get block :line-start)))
                     (etaf-org--leaf-button
                      node-env " ▶ 运行 "
                      (lambda () (etaf-org-assets-execute-babel session lno))
                      :color (etaf-org--color env :ok)
                      :bold t
                      :help "通过 Org Babel 执行此代码块")))
                 (when show-copy
                   (let ((copied (etaf-org-block-state node-env :copied nil)))
                     (etaf-org--leaf-button
                      node-env (if copied " 已复制 " " 复制 ")
                      (lambda ()
                        (etaf-org--copy-to-kill-ring clean-text (or language "代码"))
                        (etaf-org-set-block-state node-env :copied t))
                      :color (if copied (etaf-org--color env :ok) (etaf-org--color env :accent))
                      :help "把这段代码复制下来"))))))
         (header (when (and show-header (or header-left header-right))
                   (etaf-node 'flex
                              (list :width 'stretch
                                    :justify-content 'space-between
                                    :align-items 'center
                                    :border-bottom (etaf-org--hairline env)
                                    :padding '((lh 0) (ch 2)))
                              (list
                               (etaf-node 'flex (list :gap '((lh 0) (ch 1)) :align-items 'center)
                                          header-left)
                               (etaf-node 'flex (list :gap '((lh 0) (ch 1)) :align-items 'center)
                                          header-right)))))
         (num-width (when first-line
                      (length (number-to-string (+ first-line (max 0 (1- total-lines)))))))
         (any-marker (cl-some (lambda (m)
                                (and (<= (car m) visible-count)
                                     (memq (cdr m) '(add remove warning error))))
                              markers))
         (code-surface (or bg (etaf-org--color env :panel)))
         (ink (etaf-org--color env :ink))
         (row-views nil))
    (cl-loop for i from 1 to visible-count
             for segs in all-line-runs
             do
             (let* ((mark (cdr (assq i markers)))
                    (is-hi (or (eq mark 'highlight) (gethash i hi-set)))
                    (is-dim (and has-focus (not (eq mark 'focus))))
                    (row-bg (pcase mark
                              ('add (etaf-ui-color-mix (etaf-org--color env :ok) code-surface 0.80))
                              ('remove (etaf-ui-color-mix (etaf-org--color env :danger) code-surface 0.80))
                              ('warning (etaf-ui-color-mix (etaf-org--color env :warn) code-surface 0.80))
                              ('error (etaf-ui-color-mix (etaf-org--color env :danger) code-surface 0.80))
                              (_ (when is-hi
                                   (etaf-ui-color-mix (etaf-org--color env :accent) code-surface 0.82)))))
                    (row-surface (or row-bg code-surface))
                    (gutter-mark (pcase mark
                                   ('add "+ ") ('remove "- ")
                                   ('warning "! ") ('error "× ") (_ nil)))
                    (processed-segs
                     (let ((s (if word (etaf-org--highlight-word-in-segments segs word env) segs)))
                       (when show-ws
                         (setq s (mapcar
                                  (lambda (seg)
                                    (let ((t0 (or (plist-get seg :text) "")))
                                      (setq t0 (replace-regexp-in-string " " "·" t0))
                                      (setq t0 (replace-regexp-in-string "\t" "→   " t0))
                                      (list :text t0 :props (plist-get seg :props))))
                                  s)))
                       (when (and indent-guides s)
                         (let* ((first-seg (car s))
                                (t0 (or (plist-get first-seg :text) "")))
                           (when (string-match "\\`\\(  +\\)" t0)
                             (let* ((n (/ (length (match-string 1 t0)) 2))
                                    (guides (mapconcat (lambda (_) "│ ") (make-list n t) ""))
                                    (rest-txt (substring t0 (* 2 n)))
                                    (guide-seg (list :text guides
                                                     :props (list :color (etaf-org--color env :faint)
                                                                  :font-family (etaf-org--mono)))))
                               (setq s (cons guide-seg
                                             (if (string-empty-p rest-txt)
                                                 (cdr s)
                                               (cons (list :text rest-txt
                                                           :props (plist-get first-seg :props))
                                                     (cdr s)))))))))
                       s))
                    (nodes (if processed-segs
                               (mapcar (lambda (seg)
                                         (let* ((p (copy-sequence (plist-get seg :props)))
                                                (base-col (or (plist-get p :color) ink))
                                                (seg-surf (or (plist-get p :background-color) row-surface))
                                                (col (etaf-ui-color-legible
                                                      (if is-dim
                                                          (etaf-ui-color-mix base-col seg-surf 0.55)
                                                        base-col)
                                                      seg-surf)))
                                           (setq p (plist-put p :color col))
                                           (etaf-node 'text p (list (or (plist-get seg :text) "")))))
                                       processed-segs)
                             (list (etaf-node 'text nil (list " "))))))
               (push
                (if (and (null first-line) (not any-marker))
                    (etaf-node 'box
                               (append (list :width 'stretch
                                             :padding-inline '(ch 2)
                                             :wrap-mode 'word)
                                       (when row-bg (list :background-color row-bg)))
                               nodes)
                  (etaf-node 'flex
                             (append (list :width 'stretch :align-items 'start
                                           :padding-inline '(ch 2))
                                     (when row-bg (list :background-color row-bg)))
                             (delq nil
                                   (list
                                    (when first-line
                                      (etaf-node 'box
                                                 (list :padding-right '(ch 1) :flex-shrink 0)
                                                 (list (etaf-node
                                                        'text
                                                        (list :font-family (etaf-org--mono)
                                                              :color (etaf-ui-color-legible
                                                                      (etaf-org--color env :muted)
                                                                      row-surface))
                                                        (list (format (format "%%%dd" num-width)
                                                                      (+ first-line (1- i))))))))
                                    (when any-marker
                                      (etaf-node 'text
                                                 (list :font-family (etaf-org--mono)
                                                       :color (if gutter-mark
                                                                  (etaf-ui-color-legible
                                                                   (pcase mark
                                                                     ('add (etaf-org--color env :ok))
                                                                     ('remove (etaf-org--color env :danger))
                                                                     ('warning (etaf-org--color env :warn))
                                                                     (_ (etaf-org--color env :danger)))
                                                                   row-surface)
                                                                (etaf-org--color env :faint)))
                                                 (list (or gutter-mark "  "))))
                                    (etaf-node 'box
                                               (list :flex-basis '(ch 0) :flex-grow 1
                                                     :wrap-mode 'word)
                                               nodes)))))
                row-views)))
    (etaf-node 'column
               (append
                (list :width 'stretch :item-gap '(lh 0))
                (when bg (list :background-color bg))
                (when frame (list :border (etaf-org--hairline env))))
               (delq nil
                     (list
                      header
                      (etaf-node 'column
                                 (list :width 'stretch :item-gap '(lh 0)
                                       :font-family (etaf-org--mono)
                                       :padding '((lh 1) (ch 0))
                                       :color ink)
                                 (nreverse row-views))
                      (when foldable
                        (etaf-node 'box
                                   (list :width 'stretch :padding '((lh 0) (ch 2))
                                         :border-top (etaf-org--hairline env)
                                         :text-align 'center)
                                   (list
                                    (etaf-org--leaf-button
                                     node-env
                                     (if expanded
                                         (format " ▴ 收起代码（共 %d 行） " total-lines)
                                       (format " ▾ 展开全部 %d 行 " total-lines))
                                     (lambda ()
                                       (etaf-org-set-block-state node-env :code-expanded (not expanded)))
                                     :color (etaf-org--color env :accent)
                                     :bold t))))
                      (when-let* ((res (plist-get block :results)))
                        (etaf-org--render-results-view res env frame)))))))

;;; ---------------------------------------------------------------------------
;;; Drawers, Quotes, Verse, Special/Dynamic blocks, Directives
;;; ---------------------------------------------------------------------------

(defun etaf-org--drawer-view (drawer env hidden)
  "Return the View of DRAWER in ENV with local click toggle or global HIDDEN."
  (let* ((name (or (plist-get drawer :name) "DRAWER"))
         (text (or (plist-get drawer :text) ""))
         (node-env (etaf-org--make-node-env nil drawer env))
         (local-open (etaf-org-block-state node-env :drawer-open nil))
         (open (or hidden local-open)))
    (if open
        (etaf-node 'column
                   (list :width 'stretch :item-gap '(lh 0)
                         :border-left (list '(px 2) 'solid (etaf-org--color env :border))
                         :padding '((lh 0) (ch 2)))
                   (delq nil
                         (list
                          (etaf-org--leaf-button
                           node-env (format "▾ 抽屉 %s" name)
                           (lambda ()
                             (if hidden
                                 (etaf-org--act env :hidden)
                               (etaf-org-set-block-state node-env :drawer-open nil)))
                           :color (etaf-org--color env :muted)
                           :help "折叠抽屉")
                          (unless (string-empty-p text)
                            (etaf-node 'box (list :width 'stretch :wrap-mode 'word)
                                       (list (etaf-node 'text
                                                        (list :color (etaf-org--color env :ink))
                                                        (list text))))))))
      (etaf-node 'box (list :padding-left '(ch 0))
                 (list (etaf-org--leaf-button
                        node-env (format "▸ 抽屉 %s" name)
                        (lambda () (etaf-org-set-block-state node-env :drawer-open t))
                        :color (etaf-org--color env :muted)
                        :hover-variant 'soft
                        :help "展开抽屉内容"))))))

(defun etaf-org--quote-view (block env &optional opts)
  "Return the quote View of BLOCK in ENV with optional style OPTS.
Matches `etaf-ui-markdown--blockquote-node': sleek 3px left bar, muted
ink, soft quote tint, and zero bloated top/bottom empty rows."
  (let* ((node-env (etaf-org--make-node-env nil block env))
         (bg (or (and (plist-get opts :background)
                      (etaf-org-surface node-env (plist-get opts :background)))
                 (etaf-org--color env :quote-bg)))
         (fstyle (plist-get opts :font-style))
         (attr-inlines (plist-get block :attribution-inlines))
         (attr-raw (plist-get block :attribution)))
    (etaf-node 'box
               (append
                (list :width 'stretch
                      :border-left (list '(px 3) 'solid (etaf-org--color env :quote-bar))
                      :color (etaf-org--color env :muted)
                      :padding '((lh 0) (ch 2)))
                (when bg (list :background-color bg))
                (when (eq fstyle 'italic) (list :font-style 'italic)))
               (delq nil
                     (list
                      (etaf-node 'column
                                 (list :width 'stretch :item-gap '(lh 1))
                                 (etaf-org--block-views (plist-get block :blocks) env))
                      (when (or attr-inlines attr-raw)
                        (etaf-node 'box
                                   (list :width 'stretch :text-align 'right)
                                   (cons (etaf-node 'text
                                                    (list :color (etaf-org--color env :muted))
                                                    (list "— "))
                                         (if attr-inlines
                                             (etaf-org--inline-nodes
                                              attr-inlines env
                                              (list :color (etaf-org--color env :muted)))
                                           (list (etaf-node 'text
                                                            (list :color (etaf-org--color env :muted))
                                                            (list attr-raw))))))))))))

(defun etaf-org--verse-view (block env)
  "Return the verse View of BLOCK preserving indentation and inline markup."
  (let ((lines (plist-get block :lines)))
    (if lines
        (etaf-node 'column
                   (list :width 'stretch :item-gap '(lh 0)
                         :border-left (list '(px 2) 'solid (etaf-org--color env :border))
                         :padding-left '(ch 2))
                   (mapcar
                    (lambda (ln)
                      (let ((indent (or (plist-get ln :indent) 0))
                            (inlines (plist-get ln :inlines)))
                        (etaf-node 'box
                                   (list :width 'stretch :wrap-mode 'word
                                         :padding-left (list 'ch indent))
                                   (if inlines
                                       (etaf-org--inline-nodes inlines env)
                                     (list (etaf-node 'text nil (list " ")))))))
                    lines))
      (etaf-node 'box (list :width 'stretch :wrap-mode 'word)
                 (list (etaf-node 'text (list :color (etaf-org--color env :ink))
                                  (list (or (plist-get block :text) ""))))))))

(defun etaf-org--block-to-node (block type &optional derived)
  "Wrap parsed BLOCK into an `etaf-org-node' of TYPE with optional DERIVED."
  (let* ((raw-children (or (plist-get block :children) (plist-get block :blocks)))
         (children
          (mapcar (lambda (ch)
                    (cond
                     ((etaf-org-node-p ch) ch)
                     ((and (listp ch) (eq (plist-get ch :type) 'marker-child))
                      (etaf-org-node-create
                       :type (plist-get ch :node-type)
                       :attrs (plist-get ch :attrs)
                       :children (plist-get ch :blocks)
                       :source (plist-get ch :source)
                       :line (plist-get ch :line-start)
                       :block ch))
                     (t ch)))
                  raw-children)))
    (etaf-org-node-create
     :type type
     :attrs (plist-get block :attrs)
     :derived derived
     :children children
     :source (or (plist-get block :source) (plist-get block :raw-content))
     :block block
     :line (plist-get block :line-start)
     :errors (plist-get block :errors))))

(defun etaf-org--special-or-dynamic-view (block env)
  "Render a `special-block' or `dynamic-block' via the unified node registry."
  (let* ((btype (plist-get block :type))
         (raw-lname (downcase (or (plist-get block :name) "")))
         (lname (pcase raw-lname
                  ("hint" "tip")
                  ("success" "tip")
                  ("attention" "warning")
                  ("error" "danger")
                  (_ raw-lname)))
         (node-type (or (plist-get block :node-type)
                        (car (etaf-org--definition-by-name lname))))
         (features (plist-get env :features))
         (containers-ok (if (eq btype 'dynamic-block)
                            (plist-get features :dynamic-widgets)
                          (plist-get features :containers))))
    (cond
     ;; Registered container / widget (e.g. note, card, tabs, org-query, kanban...).
     ((and node-type
           (or containers-ok
               (member lname '("note" "info" "tip" "hint" "important" "success"
                               "warning" "attention" "caution" "danger" "error"))))
      (let* ((node (etaf-org--block-to-node block node-type))
             (node-env (etaf-org--make-node-env node block env)))
        (etaf-org--paint node node-env)))
     ;; Native Org dynamic blocks (`clocktable' / `columnview'): render inner Org blocks!
     ((and (eq btype 'dynamic-block) (member lname '("clocktable" "columnview")))
      (etaf-node 'column
                 (list :width 'stretch :item-gap '(lh 0))
                 (cons (etaf-node 'text (list :color (etaf-org--color env :muted)
                                              :font-family (etaf-org--mono))
                                  (list (format "动态块 · %s" lname)))
                       (etaf-org--block-views (plist-get block :blocks) env))))
     ;; Unregistered special-block: neutral frame rendering inner Org blocks.
     ((eq btype 'special-block)
      (etaf-node 'column
                 (list :width 'stretch :item-gap '(lh 1)
                       :background-color (etaf-org--color env :panel)
                       :border (etaf-org--hairline env)
                       :padding '((lh 1) (ch 2)))
                 (cons (etaf-node 'text
                                  (list :color (etaf-org--color env :muted)
                                        :font-family (etaf-org--mono))
                                  (list (upcase lname)))
                       (etaf-org--block-views (plist-get block :blocks) env))))
     ;; Unregistered dynamic-block fallback.
     (t
      (etaf-node 'column
                 (list :width 'stretch :item-gap '(lh 0)
                       :background-color (etaf-org--color env :panel)
                       :border (etaf-org--hairline env)
                       :padding '((lh 1) (ch 2)))
                 (delq nil
                       (list
                        (etaf-node 'text (list :color (etaf-org--color env :muted))
                                   (list (format "未求值的动态块：%s" lname)))
                        (if (plist-get block :blocks)
                            (etaf-node 'column (list :width 'stretch :item-gap '(lh 1))
                                       (etaf-org--block-views (plist-get block :blocks) env))
                          (when-let* ((text (plist-get block :text)))
                            (etaf-node 'text (list :color (etaf-org--color env :faint)
                                                   :font-family (etaf-org--mono))
                                       (list text)))))))))))

(defun etaf-org--include-card-view (block env)
  "Render native `#+INCLUDE:' BLOCK using L1 `:asset-data' when available."
  (let ((data (plist-get block :asset-data)))
    (cond
     ((plist-get data :error)
      (etaf-org--failure-view env (format "#+INCLUDE: %s" (plist-get block :target))
                              (plist-get data :error)))
     ((and (plist-get data :ok) (memq (plist-get data :kind) '(src example)))
      (etaf-org--code-block-view
       (list :type 'src-block
             :lang (plist-get data :lang)
             :text (plist-get data :content)
             :start-line (plist-get data :start-line))
       env nil
       (list :title (format "INCLUDE · %s" (plist-get data :rel))
             :line-numbers t :copy t)))
     ((and (plist-get data :ok) (eq (plist-get data :kind) 'quote))
      (etaf-node 'box
                 (list :width 'stretch :background-color (etaf-org--color env :quote-bg)
                       :border-left (list '(px 2) 'solid (etaf-org--color env :quote-bar))
                       :padding '((lh 1) (ch 2)) :wrap-mode 'word)
                 (list (etaf-node 'text (list :color (etaf-org--color env :ink))
                                  (list (or (plist-get data :content) ""))))))
     ((and (plist-get data :ok) (plist-get data :blocks))
      (etaf-node 'column
                 (list :width 'stretch :item-gap '(lh 1)
                       :border-left (list '(px 2) 'solid (etaf-org--color env :accent))
                       :padding-left '(ch 2))
                 (cons (etaf-node 'text (list :color (etaf-org--color env :muted))
                                  (list (format "↪ INCLUDE：%s" (plist-get block :target))))
                       (etaf-org--block-views (plist-get data :blocks) env))))
     (t
      (etaf-org--file-card (list :path (plist-get block :target) :label "包含文件") env)))))

(defun etaf-org--toc-directive-view (block env)
  "Render inline `#+TOC: headlines N | tables | listings' BLOCK."
  (let* ((kind (or (plist-get block :kind) "headlines"))
         (depth (or (plist-get block :depth) 3))
         (doc (plist-get env :document))
         (muted (etaf-org--color env :muted)))
    (pcase kind
      ("tables"
       (let ((tables (plist-get doc :tables-index)))
         (etaf-node 'column
                    (list :width 'stretch :item-gap '(lh 0)
                          :border-left (list '(px 2) 'solid (etaf-org--color env :rule))
                          :padding-left '(ch 2))
                    (cons (etaf-node 'text (list :color muted :font-weight 'bold) (list "表格目录"))
                          (if tables
                              (mapcar (lambda (tbl)
                                        (let ((sid (plist-get tbl :section-id))
                                              (lbl (format "表 %d · %s"
                                                           (plist-get tbl :number)
                                                           (plist-get tbl :caption))))
                                          (if sid
                                              (etaf-org--leaf-button
                                               env lbl
                                               (lambda () (etaf-org--act env :locate sid))
                                               :color (etaf-org--color env :link))
                                            (etaf-node 'text (list :color muted) (list lbl)))))
                                      tables)
                            (list (etaf-node 'text (list :color muted) (list "（无表格）"))))))))
      ("listings"
       (let ((listings (plist-get doc :listings-index)))
         (etaf-node 'column
                    (list :width 'stretch :item-gap '(lh 0)
                          :border-left (list '(px 2) 'solid (etaf-org--color env :rule))
                          :padding-left '(ch 2))
                    (cons (etaf-node 'text (list :color muted :font-weight 'bold) (list "代码清单"))
                          (if listings
                              (mapcar (lambda (it)
                                        (let ((sid (plist-get it :section-id))
                                              (lbl (format "%s%s"
                                                           (plist-get it :caption)
                                                           (if (plist-get it :lang)
                                                               (format " (%s)" (plist-get it :lang))
                                                             ""))))
                                          (if sid
                                              (etaf-org--leaf-button
                                               env lbl
                                               (lambda () (etaf-org--act env :locate sid))
                                               :color (etaf-org--color env :link))
                                            (etaf-node 'text (list :color muted) (list lbl)))))
                                      listings)
                            (list (etaf-node 'text (list :color muted) (list "（无命名代码块）"))))))))
      (_
       (etaf-org--toc-view doc (plist-put (copy-sequence env) :toc-depth depth))))))

(defun etaf-org--print-bibliography-view (env)
  "Render `#+PRINT_BIBLIOGRAPHY:' block from ENV's loaded bibliography table."
  (let* ((bib (plist-get env :bibliography))
         (doc (plist-get env :document))
         (cited (plist-get doc :citations))
         (keys (or cited
                   (when (hash-table-p bib)
                     (let (ks) (maphash (lambda (k _v) (push k ks)) bib) (sort ks #'string<)))))
         (idx 0))
    (etaf-node 'column
               (list :width 'stretch :item-gap '(lh 0)
                     :background-color (etaf-org--color env :panel)
                     :border (etaf-org--hairline env)
                     :padding '((lh 1) (ch 2)))
               (cons (etaf-node 'text (list :color (etaf-org--color env :heading)
                                            :font-weight 'bold)
                                (list "参考文献"))
                     (if (and keys (hash-table-p bib) (> (hash-table-count bib) 0))
                         (mapcar
                          (lambda (k)
                            (cl-incf idx)
                            (let* ((entry (gethash k bib))
                                   (au (or (plist-get entry :author) "未知作者"))
                                   (yr (plist-get entry :year))
                                   (ti (or (plist-get entry :title) k))
                                   (line (if entry
                                             (format "[%d] %s%s. %s."
                                                     idx au (if yr (format " (%s)" yr) "") ti)
                                           (format "[%d] @%s（未在参考文献库中找到）" idx k))))
                              (etaf-node 'box (list :width 'stretch :wrap-mode 'word)
                                         (list (etaf-node 'text
                                                          (list :color (etaf-org--color env :ink))
                                                          (list line))))))
                          keys)
                       (list (etaf-node 'text (list :color (etaf-org--color env :muted))
                                        (list "（未加载本地参考文献库或无引用条目）"))))))))

(defun etaf-org--block-view (block env)
  "Return the View of BLOCK in ENV, or nil when nothing renders."
  (let ((type (plist-get block :type))
        (hidden (plist-get env :hidden)))
    (pcase type
      ('paragraph
       (if-let* ((media (plist-get block :media)))
           (if (eq (plist-get media :kind) 'video)
               (etaf-org--video-card
                (plist-put (copy-sequence media) :caption (plist-get block :caption)) env)
             (etaf-org--image-card
              (plist-put (copy-sequence media) :caption (plist-get block :caption)) env))
         (etaf-org--runs-box (plist-get block :inlines) env)))
      ('list (etaf-org--list-view block env))
      ('table
       (let* ((node (etaf-org--block-to-node
                     block 'table
                     (list :number (plist-get block :derived-number)
                           :columns (plist-get block :columns)
                           :rows (length (plist-get block :rows))
                           :has-formula (and (plist-get block :tblfm) t))))
              (node-env (etaf-org--make-node-env node block env)))
         (etaf-org--paint node node-env)))
      ('src-block
       (let* ((lang (downcase (or (plist-get block :lang) "")))
              (custom (cdr (assoc lang etaf-org-src-renderers)))
              (custom-view (when (functionp custom) (funcall custom block env))))
         (cond
          (custom-view custom-view)
          ((plist-get block :picture)
           (etaf-org--typeset-figure
            (pcase lang ("mermaid" 'mermaid) ("svg" 'svg) (_ 'diagram))
            (plist-get block :picture) env nil (plist-get block :caption)))
          (t
           (let* ((tangle (cdr (assoc ":tangle" (plist-get block :header-args))))
                  (node (etaf-org--block-to-node
                         block 'src
                         (list :language lang
                               :tangled (and tangle (not (equal tangle "no")) t)
                               :has-results (and (plist-get block :results) t))))
                  (node-env (etaf-org--make-node-env node block env)))
             (etaf-org--paint node node-env))))))
      ('example-block (etaf-org--code-block-view block env "example"))
      ('results (etaf-org--render-results-view block env))
      ('fixed-width
       (etaf-node 'box
                  (list :width 'stretch :wrap-mode 'char
                        :font-family (etaf-org--mono)
                        :color (etaf-org--color env :muted))
                  (list (etaf-node 'text nil (list (or (plist-get block :text) ""))))))
      ('quote-block
       (let* ((node (etaf-org--block-to-node
                     block 'quote
                     (list :has-attribution (and (plist-get block :attribution) t))))
              (node-env (etaf-org--make-node-env node block env)))
         (etaf-org--paint node node-env)))
      ((or 'special-block 'dynamic-block)
       (etaf-org--special-or-dynamic-view block env))
      ('center-block
       (let ((cenv (plist-put (copy-sequence env) :text-align 'center)))
         (etaf-node 'column
                    (list :width 'stretch :cross-align 'center :item-gap '(lh 1))
                    (etaf-org--block-views (plist-get block :blocks) cenv))))
      ('verse-block (etaf-org--verse-view block env))
      ('comment-block
       (when hidden
         (etaf-node 'box
                    (list :width 'stretch
                          :background-color (etaf-org--color env :panel)
                          :padding '((lh 1) (ch 2)))
                    (list (etaf-node 'text
                                     (list :color (etaf-org--color env :faint)
                                           :font-family (etaf-org--mono))
                                     (list (or (plist-get block :text) "")))))))
      ('export-block
       (etaf-org--code-block-view
        block env (format "export %s" (or (plist-get block :backend) ""))))
      ('comment
       (when hidden
         (etaf-node 'text
                    (list :color (etaf-org--color env :faint)
                          :font-family (etaf-org--mono))
                    (list (or (plist-get block :text) "")))))
      ('keyword
       (when (and hidden (not (plist-get block :attached)))
         (etaf-node 'text
                    (list :color (etaf-org--color env :faint)
                          :font-family (etaf-org--mono))
                    (list (format "#+%s: %s" (plist-get block :key)
                                  (plist-get block :value))))))
      ('horizontal-rule (etaf-org--rule env 1))
      ((or 'latex-environment 'display-math)
       (let ((eq-num (plist-get block :derived-number)))
         (or (when-let* ((picture (plist-get block :picture)))
               (etaf-org--typeset-figure 'math picture env eq-num))
             (let ((body (etaf-node 'text
                                    (list :color (etaf-org--color env :ink)
                                          :font-family (etaf-org--mono)
                                          :font-style 'italic)
                                    (list (or (plist-get block :text) "")))))
               (etaf-node 'flex
                          (list :width 'stretch
                                :background-color (etaf-org--color env :panel)
                                :border-left (when (eq type 'latex-environment)
                                               (list '(px 2) 'solid (etaf-org--color env :border)))
                                :padding '((lh 1) (ch 2))
                                :justify-content (if eq-num 'space-between 'center)
                                :align-items 'center)
                          (if eq-num
                              (list (etaf-node 'box (list :width '(ch 4)) nil)
                                    body
                                    (etaf-node 'text (list :color (etaf-org--color env :muted))
                                               (list eq-num)))
                            (list body)))))))
      ('babel-call
       (etaf-node 'box
                  (list :width 'stretch
                        :background-color (etaf-org--color env :panel)
                        :border (etaf-org--hairline env)
                        :padding '((lh 1) (ch 2)))
                  (list (etaf-node 'text (list :color (etaf-org--color env :muted))
                                   (list (format "未执行的调用：%s%s"
                                                 (or (plist-get block :name) "")
                                                 (or (plist-get block :args) "")))))))
      ('toc-directive (etaf-org--toc-directive-view block env))
      ('print-bibliography (etaf-org--print-bibliography-view env))
      ('include-card (etaf-org--include-card-view block env))
      ('drawer (etaf-org--drawer-view block env hidden))
      ('footnote-def nil)
      (_ nil))))

(defun etaf-org--block-views (blocks env)
  "Return the list of Views for BLOCKS in ENV."
  (let (views)
    (dolist (block blocks)
      (when-let* ((view (etaf-org--block-view block env)))
        (push view views)))
    (nreverse views)))

;;; ---------------------------------------------------------------------------
;;; Headline & Section Components
;;; ---------------------------------------------------------------------------

(defun etaf-org--keyword-kind (todo todo-keywords)
  "Return the semantic kind of TODO from TODO-KEYWORDS."
  (when todo
    (let* ((entry (assoc todo todo-keywords))
           (state (cdr entry)))
      (cond
       ((eq state 'done)
        (if (string-match-p "CANCEL\\|ARCHIVE\\|REJECT" (upcase todo)) 'hold 'done))
       ((string-match-p "NEXT\\|STARTED\\|PROGRESS\\|DOING" (upcase todo)) 'progress)
       ((string-match-p "WAIT\\|HOLD\\|BLOCK" (upcase todo)) 'hold)
       (t 'todo)))))

(defun etaf-org--keyword-chip (todo kind env &optional section)
  "Return the single-line inline keyword badge for TODO of KIND in ENV.
Uses a plain `text' node rather than a `box' so it never stretches to a
tall 2.0x rectangle inside H1/H2 headline flex rows."
  (let* ((session (plist-get env :session))
         (lno (and section (etaf-org-section-line-start section)))
         (fg (pcase kind
               ('done (etaf-org--color env :ok))
               ('progress (etaf-org--color env :info))
               ('hold (etaf-org--color env :muted))
               (_ (etaf-org--color env :warn))))
         (bg (pcase kind
               ('done (etaf-org--color env :ok-soft))
               ('progress (etaf-org--color env :info-soft))
               ('hold (etaf-org--color env :panel2))
               (_ (etaf-org--color env :warn-soft)))))
    (if (and etaf-org-interactive-todo session lno)
        (etaf-org--leaf-button
         env (format " %s " todo)
         (lambda () (etaf-org-assets-cycle-todo session lno todo))
         :color fg :background bg :bold t
         :help "点击切换 TODO 状态")
      (etaf-node 'text (list :color fg :background-color bg :font-weight 'bold)
                 (list (format " %s " todo))))))

(defun etaf-org--planning-items (planning env)
  "Return inline planning Views for PLANNING in ENV."
  (let ((entries nil)
        (overdue (plist-get planning :overdue))
        (due-soon (plist-get planning :due-soon)))
    (dolist (pair '((:scheduled "计划" :date)
                    (:deadline "截止" :date)
                    (:closed "完成" :muted)))
      (when-let* ((stamp (plist-get planning (nth 0 pair))))
        (let* ((is-dl (eq (nth 0 pair) :deadline))
               (color-key (cond ((and is-dl overdue) :danger)
                                ((and is-dl due-soon) :warn)
                                (t (nth 2 pair))))
               (suffix (cond ((and is-dl overdue) "（已逾期）")
                             ((and is-dl due-soon) "（临近）")
                             (t ""))))
          (push (etaf-node 'flex
                           (list :gap '((lh 0) (ch 1)) :align-items 'baseline)
                           (list (etaf-node 'text
                                            (list :color (etaf-org--color env color-key)
                                                  :font-weight 'bold)
                                            (list (nth 1 pair)))
                                 (etaf-node 'text
                                            (list :color (etaf-org--color env color-key)
                                                  :font-family (etaf-org--mono))
                                            (list (concat (etaf-org--timestamp-text stamp)
                                                          suffix)))))
                entries))))
    (nreverse entries)))

(defun etaf-org--planning-view (planning env)
  "Return the planning line View of PLANNING in ENV."
  (when-let* ((entries (etaf-org--planning-items planning env)))
    (etaf-node 'flex
               (list :width 'stretch :gap '((lh 0) (ch 2))
                     :flex-wrap 'wrap)
               entries)))

(defun etaf-org--section-meta-view (section env hidden)
  "Return one quiet editorial metadata strip for SECTION in ENV.
Combines planning timestamps, property count and logbook summary onto a
single scannable line separated by muted dots when HIDDEN is nil, and
expands properties and logbook details cleanly when HIDDEN is non-nil."
  (let* ((planning (etaf-org-section-planning section))
         (plan-items (when planning (etaf-org--planning-items planning env)))
         (properties (etaf-org-section-properties section))
         (entries (etaf-org-section-logbook section))
         (notes (etaf-org-section-logbook-notes section))
         (has-log (or entries notes))
         (log-label
          (when has-log
            (let* ((minutes (cl-loop for entry in entries
                                     sum (or (plist-get entry :minutes) 0)))
                   (total (+ (length entries) (length notes))))
              (if (> minutes 0)
                  (format "记录 %d · %d:%02d" total (/ minutes 60) (% minutes 60))
                (format "记录 %d" total)))))
         (faint (etaf-org--color env :faint))
         (muted (etaf-org--color env :muted))
         (sep (lambda () (etaf-node 'text (list :color faint) '("·"))))
         (strip-items nil))
    (dolist (it plan-items)
      (when strip-items (push (funcall sep) strip-items))
      (push it strip-items))
    (when (and properties (not hidden))
      (when strip-items (push (funcall sep) strip-items))
      (push (etaf-org--leaf-button
             env (format "属性 %d" (length properties))
             (lambda () (etaf-org--act env :hidden))
             :color muted :hover-variant 'soft
             :help "切换显示属性抽屉（H）")
            strip-items))
    (when (and has-log (not hidden))
      (when strip-items (push (funcall sep) strip-items))
      (push (etaf-org--leaf-button
             env log-label
             (lambda () (etaf-org--act env :hidden))
             :color muted :hover-variant 'soft
             :help "切换显示工时与状态记录（H）")
            strip-items))
    (let ((expanded
           (when hidden
             (delq nil
                   (list
                    (when properties
                      (etaf-node 'column
                                 (list :width 'stretch :item-gap '(lh 0)
                                       :border-left (list '(px 2) 'solid (etaf-org--color env :border))
                                       :padding-left '(ch 2))
                                 (mapcar (lambda (pair)
                                           (etaf-node 'flex
                                                      (list :width 'stretch :gap '((lh 0) (ch 1)))
                                                      (list
                                                       (etaf-node 'text
                                                                  (list :color muted
                                                                        :font-family (etaf-org--mono))
                                                                  (list (car pair)))
                                                       (etaf-node 'text
                                                                  (list :color (etaf-org--color env :ink)
                                                                        :font-family (etaf-org--mono))
                                                                  (list (cdr pair))))))
                                         properties)))
                    (when has-log
                      (etaf-node 'column
                                 (list :width 'stretch :item-gap '(lh 0)
                                       :border-left (list '(px 2) 'solid (etaf-org--color env :border))
                                       :padding-left '(ch 2))
                                 (delq nil
                                       (list
                                        (etaf-node 'text (list :color muted :font-weight 'bold)
                                                   (list log-label))
                                        (when-let* ((text (etaf-org-section-logbook-text section))
                                                    ((not (string-empty-p text))))
                                          (etaf-node 'box
                                                     (list :width 'stretch :wrap-mode 'word
                                                           :color muted
                                                           :font-family (etaf-org--mono))
                                                     (list (etaf-node 'text nil (list text))))))))))))))
      (when (or strip-items expanded)
        (etaf-node 'column
                   (list :width 'stretch :item-gap '(lh 0)
                         :padding-top '(lh 1))
                   (append
                    (when strip-items
                      (list (etaf-node 'flex
                                       (list :width 'stretch :gap '((lh 0) (ch 1))
                                             :align-items 'center :flex-wrap 'wrap)
                                       (nreverse strip-items))))
                    expanded))))))

(defun etaf-org--tags-view (tags env)
  "Return TAGS as quiet inline muted text in ENV (never stretched grey boxes)."
  (when tags
    (etaf-node 'text
               (list :color (etaf-org--color env :faint)
                     :font-family (etaf-org--mono))
               (list (concat ":" (string-join tags ":") ":")))))

(defun etaf-org--priority-box (priority env)
  "Return the single-line inline priority badge of PRIORITY in ENV."
  (let ((fg (etaf-org--color env (pcase priority
                                   ("A" :danger) ("B" :warn) (_ :muted))))
        (bg (etaf-org--color env (pcase priority
                                   ("A" :danger-soft) ("B" :warn-soft) (_ :panel2)))))
    (etaf-node 'text
               (list :color fg :background-color bg
                     :font-weight 'bold
                     :font-family (etaf-org--mono))
               (list (format " #%s " priority)))))

(defun etaf-org--headline-node (section)
  "Build `etaf-org-node' of type `headline' for SECTION."
  (etaf-org-node-create
   :type 'headline
   :derived (list :level (max 1 (etaf-org-section-level section))
                  :number (etaf-org-section-number section)
                  :todo (etaf-org-section-todo section)
                  :todo-state (etaf-org-section-todo-state section)
                  :priority (etaf-org-section-priority section)
                  :tags (etaf-org-section-effective-tags section)
                  :archived (and (etaf-org-section-archived section) t)
                  :commented (and (etaf-org-section-commented section) t)
                  :has-children (and (etaf-org-section-children section) t))
   :line (etaf-org-section-line-start section)))

(defun etaf-org--heading-view (section state env)
  "Return the headline row of SECTION at STATE in ENV."
  (let* ((hnode (etaf-org--headline-node section))
         (henv (etaf-org--make-node-env hnode nil env nil section))
         (level (max 1 (etaf-org-section-level section)))
         (number (etaf-org-section-number section))
         (prefix (or (etaf-org-attr henv :prefix) ""))
         (style-color (etaf-org-attr henv :color))
         (style-weight (or (etaf-org-attr henv :font-weight) 'bold))
         (style-rule-set (plist-member (etaf-org-node-attrs hnode) :rule))
         (style-rule (etaf-org-attr henv :rule))
         (show-rule (cond ((not (null style-rule)) t)
                          ((and (null style-rule)
                                (cl-some (lambda (e)
                                           (and (etaf-org--selector-matches-p (car e) hnode)
                                                (assq :rule (cdr e))))
                                         etaf-org-styles))
                           nil)
                          (style-rule-set style-rule)
                          (t (and (plist-get env :heading-underline) (<= level 2)))))
         (accent-word (etaf-org-attr henv :accent))
         (accent-bar (when (and accent-word (not (eq accent-word 'neutral)))
                       (etaf-org-accent henv accent-word)))
         (todo (etaf-org-section-todo section))
         (kind (etaf-org--keyword-kind todo (plist-get env :todo-keywords)))
         (priority (etaf-org-section-priority section))
         (cookie (etaf-org-section-cookie section))
         (tags (and (plist-get env :show-tags)
                    (etaf-org-section-tags section)))
         (ink (or (and (stringp style-color)
                       (not (string-empty-p style-color))
                       (not (equal style-color "heading"))
                       style-color)
                  (etaf-org--color env (etaf-org--heading-ink level))))
         (label (format "第 %d 级标题：%s%s"
                        level
                        (if todo (concat todo " ") "")
                        (etaf-org-section-title-plain section)))
         (title-inlines (etaf-org-section-title-inlines section))
         (prefix-str (concat prefix
                             (if (and number (not (string-empty-p number)))
                                 (concat number " ")
                               "")))
         (title-nodes (append
                       (unless (string-empty-p prefix-str)
                         (list (etaf-node 'text
                                          (list :font-size (etaf-org--heading-size level)
                                                :font-weight style-weight
                                                :color (etaf-org--color env :muted))
                                          (list prefix-str))))
                       (etaf-org--inline-nodes
                        title-inlines env
                        (list :font-size (etaf-org--heading-size level)
                              :font-weight style-weight
                              :color ink))))
         (title-box (etaf-node 'box
                               (list :width 'stretch :min-width '(ch 10)
                                     :wrap-mode 'word)
                               title-nodes))
         (fold-pill
          (when (memq state '(folded children))
            (let ((n (length (etaf-org-section-children section)))
                  (sid (etaf-org-section-id section)))
              (etaf-org--leaf-button
               env
               (if (> n 0) (format "⋯ %d 子节" n) "⋯ 已折叠")
               (lambda () (etaf-org--act env :toggle sid))
               :color (etaf-org--color env :muted)
               :background (etaf-org--color env :panel2)
               :help "展开此章节（z）"))))
         (left (delq nil
                     (list
                      (when todo (etaf-org--keyword-chip todo kind env section))
                      (when priority (etaf-org--priority-box priority env))
                      (when (etaf-org-section-commented section)
                        (etaf-node 'text (list :color (etaf-org--color env :muted)
                                               :background-color (etaf-org--color env :panel))
                                   '(" 注释 ")))
                      (when (etaf-org-section-archived section)
                        (etaf-node 'text (list :color (etaf-org--color env :muted)
                                               :background-color (etaf-org--color env :hold-soft))
                                   '(" 归档 ")))
                      title-box
                      fold-pill)))
         (right (delq nil
                      (list
                       (when cookie
                         (etaf-node 'text (list :color (etaf-org--color env :muted)
                                                :font-family (etaf-org--mono))
                                    (list cookie)))
                       (when tags (etaf-org--tags-view tags env)))))
         (row (etaf-node 'flex
                         (append
                          (list :width 'stretch
                                :justify-content 'space-between
                                :align-items 'center
                                :flex-wrap 'wrap
                                :gap '((lh 0) (ch 1)))
                          (when show-rule
                            (list :border-bottom (list '(px 1) 'solid
                                                       (etaf-org--color env :heading-rule))
                                  :padding-bottom '(lh 0.35)))
                          (when accent-bar
                            (list :border-left (list '(px 2) 'solid accent-bar)
                                  :padding-left '(ch 1))))
                         (delq nil
                               (list
                                (etaf-node 'flex
                                           (list :flex-grow 1 :flex-shrink 1
                                                 :min-width '(ch 0)
                                                 :align-items 'center
                                                 :gap '((lh 0) (ch 1)))
                                           left)
                                (when right
                                  (etaf-node 'flex
                                             (list :flex-shrink 0
                                                   :align-items 'center
                                                   :justify-content 'end
                                                   :gap '((lh 0) (ch 1)))
                                             right)))))))
    (etaf-node 'column
               (list :width 'stretch
                     :ref (etaf-org--section-ref (etaf-org-section-id section))
                     :id (concat "org-section-" (etaf-org-section-id section))
                     :padding-top (etaf-org--heading-gap env level)
                     :aria-label label)
               (list row))))

(etaf-define-component etaf-org-block (&key session block slot)
  "Render one published body BLOCK (or reactive SLOT) of SESSION.
When SLOT is provided, reads its `:cell' and `:state' refs so editing or
interacting with one block repaints only that block."
  :render
  (let* ((cur-block (if slot (etaf-value (plist-get slot :cell)) block))
         (override (when-let* ((ov-ref (and slot (plist-get slot :override))))
                     (etaf-value ov-ref)))
         (base-env (etaf-org--env session))
         (env (if slot
                  (plist-put (plist-put (copy-sequence base-env)
                                        :block-state (plist-get slot :state))
                             :slot slot)
                base-env)))
    (cond
     (override override)
     (cur-block
      (let ((view (etaf-org--block-view cur-block env))
            (lstart (plist-get cur-block :line-start))
            (skey (and slot (plist-get slot :key))))
        (if (and view lstart)
            (etaf-node 'box
                       (list :width 'stretch
                             :id (format "org-line-%d-%s" lstart (or skey "b")))
                       (list view))
          view)))
     (t nil))))

(etaf-define-component etaf-org-section
    (&key section fold session body children)
  "Render one headline SECTION with its own fold cell and filter check."
  :render
  (let* ((env (etaf-org--env session))
         (filter (plist-get env :filter)))
    (when (or (null filter)
              (not (fboundp 'etaf-org--section-matches-filter-p))
              (etaf-org--section-matches-filter-p section filter))
      (let* ((state (etaf-value fold))
             (open (eq state 'open))
             (hidden (plist-get env :hidden))
             (hdef (etaf-org-node-definition 'headline))
             (heading-view
              (if (and hdef (plist-get hdef :overridden) (plist-get hdef :view))
                  (let* ((hnode (etaf-org--headline-node section))
                         (henv (etaf-org--make-node-env hnode nil env nil section)))
                    (etaf-org--paint hnode henv))
                (etaf-org--heading-view section state env)))
             (views (list heading-view)))
        (when (not (eq state 'folded))
          (when-let* ((meta-strip (etaf-org--section-meta-view section env hidden)))
            (push meta-strip views)))
        (when open
          (when body
            (push (etaf-node 'column
                             (list :width 'stretch :item-gap '(lh 1)
                                   :padding-top '(lh 1))
                             body)
                  views)))
        (when (and children (not (eq state 'folded)))
          (dolist (child children)
            (push child views)))
        (etaf-node 'column
                   (list :width 'stretch :item-gap '(lh 0))
                   (nreverse views))))))

;;; ---------------------------------------------------------------------------
;;; Document chrome: Hero, TOC (inline & docked rail), Filter, Peek, Lightbox
;;; ---------------------------------------------------------------------------

(defun etaf-org--hero-view (document env)
  "Return the title hero block of DOCUMENT in ENV."
  (let* ((title (or (plist-get document :title)
                    (plist-get env :fallback-title)
                    "Org 文档"))
         (subtitle (plist-get document :subtitle))
         (author (plist-get document :author))
         (date (plist-get document :date))
         (modified (plist-get env :modified))
         (keywords (plist-get document :keywords))
         (filetags (plist-get document :filetags))
         (meta-parts (delq nil
                           (list (when (and author (not (string-empty-p author)))
                                   (format "作者 %s" author))
                                 (when (and date (not (string-empty-p date)))
                                   (format "日期 %s" date))
                                 (when (and modified (not (string-empty-p modified)))
                                   modified))))
         (byline (string-join meta-parts "  ·  "))
         (degraded (plist-get document :degraded)))
    (etaf-node 'column
               (list :width 'stretch :item-gap '(lh 1))
               (delq nil
                     (list
                      (etaf-node 'text
                                 (list :color (etaf-org--color env :heading)
                                       :font-size (etaf-org--scaled 2.2)
                                       :font-weight 'bold)
                                 (list title))
                      (when (and subtitle (not (string-empty-p subtitle)))
                        (etaf-node 'text
                                   (list :color (etaf-org--color env :muted))
                                   (list subtitle)))
                      (when (or keywords filetags)
                        (etaf-node 'flex
                                   (list :width 'stretch
                                         :gap '((lh 0) (ch 1))
                                         :align-items 'center
                                         :flex-wrap 'wrap)
                                   (append
                                    (mapcar (lambda (keyword)
                                              (etaf-node 'etaf-tag
                                                         (list :text keyword :variant 'neutral)
                                                         nil))
                                            keywords)
                                    (mapcar (lambda (tag)
                                              (etaf-node 'etaf-tag
                                                         (list :text (concat "#" tag) :variant 'neutral)
                                                         nil))
                                            filetags))))
                      (when (not (string-empty-p byline))
                        (etaf-node 'text
                                   (list :color (etaf-org--color env :muted))
                                   (list byline)))
                      (when (> (or degraded 0) 0)
                        (etaf-org--chip env (format "%d 处已降级" degraded) :warn :warn-soft)))))))

(defun etaf-org--toc-entries (document depth)
  "Return filtered outline entries of DOCUMENT up to DEPTH."
  (when depth
    (let ((commented (make-hash-table :test #'equal)))
      (cl-labels ((walk (sections)
                    (dolist (section sections)
                      (when (etaf-org-section-commented section)
                        (puthash (etaf-org-section-id section) t commented))
                      (walk (etaf-org-section-children section)))))
        (walk (plist-get document :sections)))
      (cl-remove-if
       (lambda (entry)
         (or (> (nth 0 entry) depth)
             (gethash (nth 2 entry) commented)))
       (plist-get document :outline)))))

(defun etaf-org--toc-row (entry base env &optional active-id)
  "Return one TOC row for ENTRY under BASE indentation."
  (let* ((id (nth 2 entry))
         (selected (and active-id (equal id active-id))))
    (etaf-node 'box
               (list :width 'stretch
                     :padding-left (list 'ch (* 2 (max 0 (- (nth 0 entry) base)))))
               (list (etaf-org--leaf-button
                      env (nth 1 entry)
                      (lambda () (etaf-org--act env :locate id))
                      :selected selected
                      :color (if selected
                                 (etaf-org--color env :accent)
                               (etaf-org--color env :muted))
                      :help "跳到这一节")))))

(defun etaf-org--toc-view (document env)
  "Return inline preamble TOC View of DOCUMENT in ENV."
  (when-let* ((depth (plist-get env :toc-depth))
              (entries (etaf-org--toc-entries document depth)))
    (let* ((base (apply #'min (mapcar (lambda (entry) (nth 0 entry)) entries)))
           (rows (mapcar (lambda (entry) (etaf-org--toc-row entry base env nil))
                         entries)))
      (etaf-node 'box
                 (list :role 'navigation
                       :width 'stretch
                       :border-left (list '(px 2) 'solid (etaf-org--color env :rule))
                       :padding-left '(ch 2)
                       :margin-top '(lh 1)
                       :margin-bottom '(lh 1))
                 (list
                  (etaf-node 'text
                             (list :color (etaf-org--color env :muted)
                                   :font-weight 'bold)
                             (list "目录"))
                  (etaf-node 'box (list :width 'stretch :height '(lh 1)) nil)
                  (etaf-node 'column (list :width 'stretch :item-gap '(lh 0)) rows))))))

(defun etaf-org--filter-bar-view (document env)
  "Return live filter toolbar View when `:filter' is active in ENV."
  (when-let* ((filter (plist-get env :filter))
              ((not (string-blank-p filter))))
    (let* ((total (length (plist-get document :outline)))
           (matched 0)
           (session (plist-get env :session)))
      (cl-labels ((count-hits (secs)
                    (dolist (s secs)
                      (when (and (fboundp 'etaf-org--section-matches-filter-p)
                                 (etaf-org--section-matches-filter-p s filter))
                        (cl-incf matched))
                      (count-hits (etaf-org-section-children s)))))
        (count-hits (plist-get document :sections)))
      (etaf-node 'flex
                 (list :width 'stretch :role 'toolbar
                       :justify-content 'space-between :align-items 'center
                       :background-color (etaf-org--color env :accent-soft)
                       :border (list '(px 1) 'solid (etaf-org--color env :accent))
                       :padding '((lh 0) (ch 2))
                       :margin-bottom '(lh 1))
                 (list
                  (etaf-node 'text (list :color (etaf-org--color env :ink))
                             (list (format "筛选：%s（匹配 %d / %d 节）" filter matched total)))
                  (etaf-org--leaf-button
                   env " 清除 "
                   (lambda ()
                     (when (and session (fboundp 'etaf-org--clear-filter))
                       (etaf-org--clear-filter session)))
                   :color (etaf-org--color env :accent)
                   :bold t
                   :help "清除筛选条件"))))))

(defun etaf-org--peek-card-view (env)
  "Return the floating `etaf-dialog' peek view (`K') when `:peek' is active."
  (when-let* ((peek (plist-get env :peek)))
    (let* ((title (or (plist-get peek :title) "速览"))
           (kind (plist-get peek :kind))
           (body (or (plist-get peek :body) ""))
           (target (plist-get peek :target))
           (session (plist-get env :session))
           (close-fn (lambda () (when session (etaf-org--write session :peek nil)))))
      (etaf-node
       'etaf-dialog
       (list :open t
             :title (if kind (format "%s · %s" kind title) title)
             :width '(ch 60)
             :compact t
             :close-label "关闭"
             :on-close close-fn
             :keys (list (list "K" close-fn "关闭速览")))
       (delq nil
             (list
              (etaf-node 'box (list :width 'stretch :max-height '(lh 8)
                                    :overflow 'scroll :wrap-mode 'word)
                         (list (etaf-node 'text (list :color (etaf-org--color env :ink))
                                          (list body))))
              (when target
                (etaf-node 'flex (list :width 'stretch :padding-top '(lh 1))
                           (list
                            (etaf-node 'etaf-button
                                       (list :label "打开目标 →"
                                             :variant 'primary
                                             :on-press
                                             (lambda ()
                                               (when session
                                                 (etaf-org--write session :peek nil))
                                               (etaf-org--act env :open target)))
                                       nil))))))))))

(defun etaf-org--toc-sidebar-view (session env toc-cols narrow-p)
  "Return the in-buffer TOC sidebar View for SESSION in ENV.
TOC-COLS is the sidebar width in columns when side-by-side.  When NARROW-P is
non-nil, stretches full width and auto-closes after jumping to a heading."
  (let* ((outline (etaf-org-outline session))
         (active-id (or (etaf-org--read session :active-section)
                        (nth 2 (car outline))))
         (panel (etaf-org--color env :panel))
         (ink (etaf-org--color env :ink))
         (muted (etaf-org--color env :muted))
         (faint (or (etaf-org--env-color env :faint) muted))
         (border (etaf-org--color env :border))
         (accent (etaf-org--color env :accent))
         (accent-soft (etaf-org--color env :accent-soft))
         (hover (etaf-org--hover-fill env 'soft))
         (min-lv (if outline (apply #'min (mapcar #'car outline)) 1))
         (count (length outline)))
    (etaf-node
     'column
     (append
      (list :height 'stretch
            :overflow 'hidden
            :box-sizing 'border-box
            :background-color panel
            :color ink
            :item-gap '(lh 0)
            :aria-label "文档目录")
      (if narrow-p
          (list :width 'stretch :flex-grow 1 :flex-basis '(px 0) :min-width '(px 0))
        (list :width (list 'ch toc-cols) :flex-shrink 0)))
     (list
      (etaf-node
       'flex
       (list :width 'stretch :align-items 'center
             :padding '((lh 0) (ch 2))
             :border-bottom (list '(px 1) 'solid border))
       (delq nil
             (list
              (etaf-node 'text (list :font-weight 'bold :color ink) (list "目录"))
              (when (> count 0)
                (etaf-node 'text (list :color faint) (list (format " · %d" count))))
              (etaf-node 'box (list :flex-basis '(ch 0) :flex-grow 1 :min-width '(ch 1)) nil)
              (etaf-node 'text
                         (append
                          (list :color muted :role 'button :tab-index 0 :pointer 'hand
                                :help-echo "关闭目录（T）"
                                :on-press (lambda () (etaf-org-toggle-toc -1)))
                          (when hover (list :hover-style (list :background-color hover))))
                         (list (if narrow-p "返回正文" "×"))))))
      (etaf-node
       'column
       (list :ref 'etaf-org-toc-pane
             :width 'stretch
             :flex-grow 1 :flex-basis '(px 0) :min-height '(lh 0)
             :overflow 'scroll
             :box-sizing 'border-box
             :padding '((lh 1) (ch 0))
             :item-gap '(lh 0)
             :on-direction
             (lambda (direction)
               (pcase direction
                 ('down
                  (when-let* ((rt (etaf-runtime-for-buffer (current-buffer))))
                    (ignore-errors (etaf-scroll-by rt 'etaf-org-toc-pane 1)))
                  'handled)
                 ('up
                  (when-let* ((rt (etaf-runtime-for-buffer (current-buffer))))
                    (ignore-errors (etaf-scroll-by rt 'etaf-org-toc-pane -1)))
                  'handled)
                 (_ 'release))))
       (if (null outline)
           (list (etaf-node 'box (list :width 'stretch :padding '((lh 0) (ch 2)))
                            (list (etaf-node 'text (list :color muted)
                                             (list "（文档暂无标题）")))))
         (cl-loop for entry in outline
                  for idx from 0
                  for lv = (nth 0 entry)
                  for text = (nth 1 entry)
                  for id = (nth 2 entry)
                  for is-active = (equal id active-id)
                  for indent = (* 2 (min 3 (max 0 (- lv min-lv))))
                  collect
                  (let ((target-idx idx))
                    (etaf-node
                     'box
                     (append
                      (when is-active (list :ref 'etaf-org-toc-active-row))
                      (list :width 'stretch
                            :box-sizing 'border-box
                            :padding (list '(lh 0) '(ch 1) '(lh 0) (list 'ch (+ 2 indent)))
                            :border-left (list '(px 2) 'solid (if is-active accent panel))
                            :wrap-mode 'word
                            :color (cond (is-active accent)
                                         ((= lv min-lv) ink)
                                         (t muted))
                            :font-weight (when (or is-active (= lv min-lv)) 'bold)
                            :role 'link :tab-index 0
                            :pointer (unless is-active 'hand)
                            :aria-selected (when is-active t)
                            :help-echo (format "跳转到 %s" text)
                            :on-press
                            (lambda ()
                              (when narrow-p
                                (etaf-org--write session :toc-open nil)
                                (when-let* ((buf (plist-get session :buffer))
                                            (rt (and (buffer-live-p buf)
                                                     (etaf-runtime-for-buffer buf))))
                                  (etaf-runtime-flush rt)))
                              (etaf-org-locate session target-idx)))
                      (when is-active (list :background-color accent-soft))
                      (when (and hover (not is-active))
                        (list :hover-style (list :background-color hover))))
                     (list (etaf-node 'text nil (list text))))))))))))

(defun etaf-org--toc-resizer-view (session env toc-cols raw-cols side cell-width)
  "Return the draggable `etaf-pane-resizer' for SESSION's in-buffer TOC."
  (let* ((cell (max 1 (or cell-width 8)))
         (min-cols etaf-org--toc-width-min)
         (max-cols (max min-cols
                        (min etaf-org--toc-width-max
                             (- raw-cols etaf-org--toc-min-article 1)))))
    (etaf-node 'etaf-pane-resizer
               (list :ref 'etaf-org-toc-resizer
                     :size (* cell toc-cols)
                     :side (if (eq side 'right) 'left 'right)
                     :min (* cell min-cols)
                     :max (* cell max-cols)
                     :line (etaf-org--color env :border)
                     :background (etaf-org--color env :bg)
                     :on-change (lambda (pixels)
                                  (etaf-org--set-toc-width
                                   session
                                   (round (/ (float pixels) cell)))))
               nil)))

(defun etaf-org--lightbox-view (env)
  "Return `etaf-media-viewer' overlay View when `:lightbox' is active in ENV."
  (when-let* ((lightbox (plist-get env :lightbox))
              (session (plist-get env :session)))
    (let* ((items (plist-get lightbox :items))
           (count (length items))
           (idx (min (max 0 (or (plist-get lightbox :index) 0)) (max 0 (1- count))))
           (current (nth idx items)))
      (when current
        (let ((src (plist-get current :src))
              (caption (plist-get current :caption)))
          (etaf-node
           'etaf-media-viewer
           (list :open t
                 :kind 'image
                 :src src
                 :source-size (etaf-org-typeset--image-pixels src)
                 :title (or caption (file-name-nondirectory src))
                 :subtitle (when (> count 1) (format "%d / %d" (1+ idx) count))
                 :caption caption
                 :on-close (lambda () (etaf-org--write session :lightbox nil))
                 :on-previous (when (> count 1)
                                (lambda ()
                                  (etaf-org--write
                                   session :lightbox
                                   (list :items items :index (mod (1- idx) count)))))
                 :on-next (when (> count 1)
                            (lambda ()
                              (etaf-org--write
                               session :lightbox
                               (list :items items :index (mod (1+ idx) count))))))
           nil))))))

(defun etaf-org--footnotes-view (document env)
  "Return the footnote section of DOCUMENT in ENV.
Supports multi-paragraph footnote bodies and clickable `↩' return links."
  (when-let* ((footnotes (plist-get document :footnotes)))
    (let ((session (plist-get env :session)))
      (etaf-node 'column
                 (list :width 'stretch :item-gap '(lh 1)
                       :padding-top '(lh 2))
                 (append
                  (list (etaf-node 'etaf-divider
                                   (list :orientation 'horizontal :label "脚注")
                                   nil))
                  (mapcar
                   (lambda (footnote)
                     (let ((label (plist-get footnote :label))
                           (blocks (plist-get footnote :blocks))
                           (inlines (plist-get footnote :inlines)))
                       (etaf-node 'flex
                                  (list :width 'stretch :gap '((lh 0) (ch 1))
                                        :align-items 'start)
                                  (list
                                   (etaf-node 'box
                                              (list :width '(ch 4) :flex-shrink 0)
                                              (list (etaf-node 'text
                                                               (list :color (etaf-org--color env :accent)
                                                                     :font-weight 'bold
                                                                     :font-family (etaf-org--mono))
                                                               (list (format "[%d]"
                                                                             (plist-get footnote :number))))))
                                   (etaf-node 'column
                                              (list :width 'stretch :item-gap '(lh 0))
                                              (append
                                               (if blocks
                                                   (etaf-org--block-views blocks env)
                                                 (list (etaf-node 'box
                                                                  (list :width 'stretch :wrap-mode 'word)
                                                                  (etaf-org--inline-nodes inlines env))))
                                               (list
                                                (etaf-org--leaf-button
                                                 env "↩ 返回正文"
                                                 (lambda ()
                                                   (when (and session
                                                              (fboundp 'etaf-org--return-from-footnote))
                                                     (etaf-org--return-from-footnote session label)))
                                                 :color (etaf-org--color env :accent)
                                                 :role 'link
                                                 :help "返回脚注引用处"))))))))
                   footnotes))))))

(defun etaf-org--view-document (document env)
  "Return the mounted reading View of DOCUMENT in ENV."
  (let* ((session (plist-get env :session))
         (toc-open (and session (etaf-org--read session :toc-open)))
         (width (max 24 (or (plist-get env :width) 92)))
         (gutter etaf-org--measure-gutter)
         (background (plist-get env :background))
         (sections (plist-get document :section-entries))
         (preamble (cl-remove-if
                    (lambda (entry)
                      (memq (plist-get (plist-get entry :block) :type)
                            '(keyword footnote-def)))
                    (plist-get document :preamble-entries)))
         (main-column
          (etaf-node 'column
                     (list :width 'stretch
                           :max-width (list 'ch (+ width (* 2 gutter)))
                           :overflow 'hidden
                           :padding (list (list 'lh 1) (list 'ch gutter))
                           :color (etaf-org--color env :ink))
                     (delq nil
                           (append
                            (list (etaf-org--filter-bar-view document env)
                                  (etaf-org--hero-view document env)
                                  (etaf-org--spacer 2)
                                  (etaf-org--toc-view document env)
                                  (when preamble
                                    (etaf-node 'column
                                               (list :width 'stretch :item-gap '(lh 1))
                                               (mapcar (lambda (entry) (plist-get entry :view))
                                                       preamble))))
                            (mapcar (lambda (entry) (plist-get entry :view)) sections)
                            (list (etaf-org--footnotes-view document env))))))
         (overlays (delq nil (list (etaf-org--peek-card-view env)
                                   (etaf-org--lightbox-view env))))
         (help-text "上下方向键按行滚动；TAB 切换控件，RET 激活；T 开关目录，/ 筛选，z/Z 折叠，H 隐含内容，K 速览，? 快捷键。"))
    (if (not toc-open)
        (etaf-node 'column
                   (append (list :width '(vw 100) :cross-align 'center
                                 :aria-label "Org 预览"
                                 :help help-text
                                 :on-direction
                                 (lambda (direction)
                                   (pcase direction
                                     ('down
                                      (when-let* ((rt (etaf-runtime-for-buffer (current-buffer))))
                                        (etaf-scroll-viewport rt 1))
                                      'handled)
                                     ('up
                                      (when-let* ((rt (etaf-runtime-for-buffer (current-buffer))))
                                        (etaf-scroll-viewport rt -1))
                                      'handled)
                                     (_ 'release))))
                           (when background (list :background-color background)))
                   (cons main-column overlays))
      (let* ((viewport (ignore-errors (etaf-viewport)))
             (buf (plist-get session :buffer))
             (win (and (buffer-live-p buf) (get-buffer-window buf t)))
             (canvas-cols (ignore-errors
                            (let* ((rt (or (etaf-current-runtime)
                                           (and (buffer-live-p buf)
                                                (etaf-runtime-for-buffer buf))))
                                   (c (and rt (etaf-runtime-mounted-p rt)
                                           (etaf-canvas-columns rt))))
                              (and (integerp c) (> c 0) c))))
             (raw-cols (or canvas-cols
                           (and (window-live-p win) (window-body-width win))
                           (and (consp viewport) (integerp (car viewport))
                                (> (car viewport) 0) (car viewport))
                           (plist-get env :viewport-width)
                           100))
             (vp-rows (or (and (consp viewport) (integerp (cdr viewport))
                               (> (cdr viewport) 0) (cdr viewport))
                          (and (window-live-p win) (window-body-height win))))
             (shell-h (list 'lh (if (and (integerp vp-rows) (> vp-rows 0))
                                    (max 12 (1- vp-rows))
                                  36)))
             (cell-width (or (plist-get (ignore-errors (etaf-display-metrics)) :char-width)
                             (frame-char-width)))
             (side-by-side (etaf-org--toc-side-by-side-p raw-cols))
             (side (if (eq etaf-org-toc-side 'right) 'right 'left))
             (body-shell
              (if (not side-by-side)
                  (etaf-node 'flex
                             (list :flex-direction 'row :align-items 'stretch
                                   :width 'stretch :height 'stretch
                                   :flex-grow 1 :flex-basis '(px 0)
                                   :min-height '(lh 0) :overflow 'hidden)
                             (list (etaf-org--toc-sidebar-view session env raw-cols t)))
                (let* ((toc-cols (etaf-org--clamp-toc-width
                                  (etaf-org--read session :toc-width) raw-cols))
                       (article-cols (max 24 (- raw-cols toc-cols 1)))
                       (toc-pane (etaf-org--toc-sidebar-view session env toc-cols nil))
                       (resizer (etaf-org--toc-resizer-view
                                 session env toc-cols raw-cols side cell-width))
                       (article-pane
                        (etaf-node 'column
                                   (append
                                    (list :ref 'etaf-org-article-pane
                                          :width (list 'ch article-cols)
                                          :height 'stretch
                                          :flex-grow 1 :flex-basis '(px 0)
                                          :min-width '(px 0)
                                          :overflow 'scroll
                                          :cross-align 'center
                                          :on-direction
                                          (lambda (direction)
                                            (pcase direction
                                              ('down
                                               (when-let* ((rt (etaf-runtime-for-buffer (current-buffer))))
                                                 (ignore-errors (etaf-scroll-by rt 'etaf-org-article-pane 1)))
                                               'handled)
                                              ('up
                                               (when-let* ((rt (etaf-runtime-for-buffer (current-buffer))))
                                                 (ignore-errors (etaf-scroll-by rt 'etaf-org-article-pane -1)))
                                               'handled)
                                              (_ 'release))))
                                    (when background (list :background-color background)))
                                   (list main-column))))
                  (etaf-node 'flex
                             (list :ref 'etaf-org-toc-shell
                                   :flex-direction 'row :align-items 'stretch
                                   :gap '((lh 0) (ch 0))
                                   :width 'stretch :height 'stretch
                                   :flex-grow 1 :flex-basis '(px 0)
                                   :min-height '(lh 0) :overflow 'hidden)
                             (if (eq side 'right)
                                 (list article-pane resizer toc-pane)
                               (list toc-pane resizer article-pane)))))))
        (etaf-node 'column
                   (append (list :width '(vw 100) :height shell-h
                                 :aria-label "Org 预览"
                                 :help help-text
                                 :on-direction
                                 (lambda (direction)
                                   (pcase direction
                                     ('down
                                      (when-let* ((rt (etaf-runtime-for-buffer (current-buffer))))
                                        (ignore-errors
                                          (if side-by-side
                                              (etaf-scroll-by rt 'etaf-org-article-pane 1)
                                            (etaf-scroll-by rt 'etaf-org-toc-pane 1))))
                                      'handled)
                                     ('up
                                      (when-let* ((rt (etaf-runtime-for-buffer (current-buffer))))
                                        (ignore-errors
                                          (if side-by-side
                                              (etaf-scroll-by rt 'etaf-org-article-pane -1)
                                            (etaf-scroll-by rt 'etaf-org-toc-pane -1))))
                                      'handled)
                                     (_ 'release))))
                           (when background (list :background-color background)))
                   (cons body-shell overlays))))))

(provide 'etaf-org-views)
;;; etaf-org-views.el ends here
