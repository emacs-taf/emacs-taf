;;; etaf-md-app.el --- Application shell of etaf-md -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; The application layer binds one preview session to the Views.  The
;; `etaf-md-app' Component is the only place that reads the session's
;; reactive sources, so a palette, width or document change repaints the whole
;; preview in one place; it also provides the palette tokens to its subtree so
;; shared ETAF UI Components follow the same colors.
;;
;; `etaf-md-open' opens the session as an ETAF application: the
;; application buffer, its root keys, the initial reading measure, the page
;; background and the commands for outline navigation, reload and theming.  A
;; window resize reflows through the framework's own viewport update, so the
;; application never rebuilds the view for a geometry change.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'filenotify)
(require 'etaf)
(require 'etaf-ui)
(require 'etaf-md-theme)
(require 'etaf-md-model)
(require 'etaf-md-views)

(defun etaf-md--buffer-name (file)
  "Return the preview buffer name for FILE, disambiguating collisions.
When another live preview already holds `*ETAF Markdown: BASENAME*' for a
different file, includes the parent directory name so two files with the same
basename never overwrite or reuse each other's preview."
  (let* ((canonical (etaf-md--canonical-file file))
         (base (format "*ETAF Markdown: %s*" (file-name-nondirectory file)))
         (existing (get-buffer base))
         (existing-state (and existing (etaf-app-state existing)))
         (existing-file (and existing-state
                             (etaf-md--canonical-file
                              (plist-get existing-state :file)))))
    (if (or (null existing)
            (null existing-file)
            (equal existing-file canonical))
        base
      (let* ((dir (directory-file-name (file-name-directory canonical)))
             (parent (file-name-nondirectory dir))
             (qualified (if (and parent (not (string-empty-p parent)))
                            (format "*ETAF Markdown: %s/%s*"
                                    parent (file-name-nondirectory file))
                          base)))
        (if (let* ((qbuf (get-buffer qualified))
                   (qstate (and qbuf (etaf-app-state qbuf)))
                   (qfile (and qstate
                               (etaf-md--canonical-file
                                (plist-get qstate :file)))))
              (and qbuf qfile (not (equal qfile canonical))))
            (generate-new-buffer-name qualified)
          qualified)))))

(defvar etaf-md--follow-sessions)

(defun etaf-md--find-preview-buffer (file)
  "Return an existing live preview buffer displaying canonical FILE, or nil."
  (let ((canonical (etaf-md--canonical-file file)))
    (or (when-let* ((session (gethash canonical etaf-md--follow-sessions))
                    (buf (plist-get session :buffer))
                    ((buffer-live-p buf)))
          buf)
        (cl-find-if
         (lambda (buf)
           (when-let* ((state (and (buffer-live-p buf) (etaf-app-state buf)))
                       (sfile (plist-get state :file)))
             (equal (etaf-md--canonical-file sfile) canonical)))
         (buffer-list)))))

(defvar isearch-string)
(defvar isearch-case-fold-search)
(declare-function etaf-md--live-refresh "etaf-md-live" (session text &optional dirty-span live-p))
(declare-function etaf-md-assets--compute-symbol "etaf-md-assets" (attrs &optional session))
(declare-function etaf-md-assets--safe-path "etaf-md-assets" (session relpath))
(declare-function etaf-md-assets-open-symbol "etaf-md-assets" (session name))
(declare-function etaf-md--pulse-line "etaf-md-assets" (pos))

(defcustom etaf-md-keys
  '(("n" etaf-md-next-heading "下一个标题")
    ("p" etaf-md-previous-heading "上一个标题")
    ("j" etaf-md-goto-heading "选择标题")
    ("T" etaf-md-toggle-toc "开关目录侧窗")
    ("S" etaf-md-toggle-spoilers "显示/隐藏所有遮罩")
    ("K" etaf-md-preview-link "预览光标处链接或符号")
    ("e" etaf-md-goto-source "跳回源文档行")
    ("o" etaf-md-goto-source "跳回源文档行")
    ("v" etaf-md-toggle-split "开关双栏对照编辑")
    ("f" etaf-md-follow-scroll "开关滚动跟随")
    ("g" etaf-md-reload "重新加载文档")
    ("r" etaf-md-reload "重新加载文档")
    ("t" etaf-md-cycle-theme "切换主题")
    ("[" etaf-md-narrower "缩窄阅读栏")
    ("]" etaf-md-wider "加宽阅读栏")
    ("q" etaf-md-close "关闭预览"))
  "Key bindings active inside a preview opened by `etaf-md-open'.
Each entry is `(KEY COMMAND LABEL)' where KEY is a `kbd' string.  Defaults use
single keys only so user prefix maps (`C-c', `C-t', `C-x', etc.) are never
shadowed; `?` opens the built-in ETAF key help.  Customize or set to nil to
rely solely on `M-x' / `M-X' interactive commands or your own bindings."
  :type '(repeat (list (string :tag "Key")
                       (function :tag "Command")
                       (string :tag "Label")))
  :group 'etaf-md)

(defun etaf-md--republish-appearance (&rest _)
  "Republish every preview that follows the Emacs theme.
A picture is drawn for the ink it was published with, so a theme switch changes
what a page needs while its text stays the same: without this the page keeps a
formula drawn in the previous theme's ink, which reads as a blank block when the
two are both light."
  (dolist (buffer (buffer-list))
    (with-current-buffer buffer
      (when-let* ((session (ignore-errors (etaf-app-state))))
        (when (eq (etaf-md--read session :theme-mode) 'auto)
          (ignore-errors (etaf-md--republish session)))))))

(add-hook 'enable-theme-functions #'etaf-md--republish-appearance)
(when (boundp 'ns-system-appearance-change-functions)
  (add-hook 'ns-system-appearance-change-functions
            #'etaf-md--republish-appearance))

(defun etaf-md--preview-buffer-p (&optional buffer)
  "Return non-nil when BUFFER (defaulting to current) is an active preview."
  (let ((buf (or buffer (current-buffer))))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (let ((state (etaf-app-state)))
          (and (listp state)
               (etaf-ref-p (plist-get state :document))
               t))))))

(defun etaf-md--preview-command-p (_symbol buffer)
  "Completion predicate limiting preview commands to active preview buffers."
  (etaf-md--preview-buffer-p buffer))

(defun etaf-md--follow-command-p (_symbol buffer)
  "Enable `etaf-md-follow-scroll' in preview or linked source buffers."
  (and (buffer-live-p buffer)
       (with-current-buffer buffer
         (and (etaf-md--follow-scroll-session) t))))

(defun etaf-md--current-session ()
  "Return the preview session of the current buffer."
  (let ((state (etaf-app-state)))
    (if (and (listp state)
             (etaf-ref-p (plist-get state :document)))
        state
      (user-error "Not an ETAF markdown preview buffer"))))

;;; ---------------------------------------------------------------------------
;;; Preview navigation and display commands (buffer-scoped interactive)
;;; ---------------------------------------------------------------------------

(defun etaf-md-next-heading ()
  "Move to the next outline heading of the current preview."
  (declare (completion etaf-md--preview-command-p))
  (interactive)
  (let ((session (etaf-md--current-session)))
    (unless (etaf-md--adjacent-heading session 1)
      (message "No further heading"))))

(defun etaf-md-previous-heading ()
  "Move to the previous outline heading of the current preview."
  (declare (completion etaf-md--preview-command-p))
  (interactive)
  (let ((session (etaf-md--current-session)))
    (unless (etaf-md--adjacent-heading session -1)
      (message "No earlier heading"))))

(defun etaf-md-goto-heading ()
  "Choose an outline heading of the current preview and move to it."
  (declare (completion etaf-md--preview-command-p))
  (interactive)
  (let* ((session (etaf-md--current-session))
         (outline (etaf-md-outline session))
         (candidates
          (cl-loop for entry in outline
                   for index from 0
                   collect (cons (format "%s%s %s"
                                         (make-string (* 2 (1- (nth 0 entry))) ?\s)
                                         (make-string (1+ (nth 0 entry)) ?#)
                                         (nth 1 entry))
                                 index))))
    (unless candidates
      (user-error "This document has no headings"))
    (let ((choice (completing-read "Heading: " candidates nil t)))
      (etaf-md-locate session (cdr (assoc choice candidates))))))

(defun etaf-md-reload ()
  "Re-read and repaint the current preview."
  (declare (completion etaf-md--preview-command-p))
  (interactive)
  (let ((session (etaf-md--current-session)))
    (etaf-md-refresh session)
    (message "Reloaded %s" (etaf-md--read session :title))))

(defconst etaf-md--preview-border-re "[│┃▎▌┌┐└┘├┤┬┴┼─]"
  "Regexp matching decorative box/table border characters in preview lines.")

(defconst etaf-md--preview-vborder-re "[│┃]"
  "Regexp matching vertical column dividers in rendered table rows.")

(defconst etaf-md--preview-chrome-prefix-re
  "\\`[›⌄▸▾▶▼•◦▪☐☑✓✕✗●○◉★☆↩⧉]+[ \t]*"
  "Regexp matching rendered UI prefixes that do not appear verbatim in source.")

(defconst etaf-md--source-projection-max-chars 65536
  "Maximum source block length projected into visible text for cursor mapping.")

(defun etaf-md--block-table-like-p (block)
  "Return non-nil when parsed BLOCK is a table or contains one."
  (when (listp block)
    (let ((type (plist-get block :type)))
      (or (eq type 'table)
          (and (eq type 'container)
               (or (equal (plist-get block :name) "table")
                   (cl-some #'etaf-md--block-table-like-p
                            (plist-get block :children))))))))

(defun etaf-md--normalize-ws-with-map (str)
  "Collapse whitespace runs in STR to single spaces and trim ends.
Returns `(NORM . MAP)' where MAP is a vector mapping each 0-based index of NORM
to its 0-based index in STR."
  (let ((len (length str))
        (i 0)
        (chars nil)
        (indices nil)
        (pending-space nil))
    (while (< i len)
      (let ((ch (aref str i)))
        (if (memq ch '(?\s ?\t ?\r ?\n))
            (when (and chars (null pending-space))
              (setq pending-space i))
          (when pending-space
            (push ?\s chars)
            (push pending-space indices)
            (setq pending-space nil))
          (push ch chars)
          (push i indices)))
      (setq i (1+ i)))
    (cons (apply #'string (nreverse chars))
          (vconcat (nreverse indices)))))

(defun etaf-md--map-offset-to-norm (map-vec raw-off)
  "Map 0-based RAW-OFF in the unnormalized string onto normalized MAP-VEC."
  (let ((n (length map-vec))
        (i 0))
    (while (and (< i n) (< (aref map-vec i) raw-off))
      (setq i (1+ i)))
    i))

(defun etaf-md--preview-line-cells (line)
  "Return list of `(BEG . END)' cell spans when LINE has >= 2 table columns.
Ignores blank outer margins outside the first and last vertical divider while
preserving empty interior cells so column indices stay exact."
  (let ((len (length line))
        (pos 0)
        (borders nil))
    (while (and (< pos len)
                (string-match etaf-md--preview-vborder-re line pos))
      (push (match-beginning 0) borders)
      (setq pos (match-end 0)))
    (when borders
      (setq borders (nreverse borders))
      (let ((spans nil)
            (prev 0))
        (dolist (b borders)
          (push (cons prev b) spans)
          (setq prev (1+ b)))
        (push (cons prev len) spans)
        (setq spans (nreverse spans))
        ;; Drop blank outer margin before the leftmost divider.
        (when (and spans
                   (string-blank-p (substring line (caar spans) (cdar spans))))
          (setq spans (cdr spans)))
        ;; Drop blank outer margin after the rightmost divider.
        (when spans
          (let ((last-span (car (last spans))))
            (when (string-blank-p (substring line (car last-span) (cdr last-span)))
              (setq spans (butlast spans)))))
        (when (>= (length spans) 2)
          spans)))))

(defun etaf-md--cell-index-for-col (cells col)
  "Return the 0-based index in CELLS containing COL, or nil."
  (when cells
    (let ((idx 0)
          (found nil))
      (dolist (span cells)
        (when (and (null found) (<= (car span) col) (<= col (cdr span)))
          (setq found idx))
        (setq idx (1+ idx)))
      found)))

(defun etaf-md--clean-piece-with-span (line beg end rel)
  "Trim whitespace and UI chrome from LINE[BEG..END), tracking REL.
Returns plist `(:text :offset :beg :end)' or nil when empty."
  (let ((sb beg)
        (se end)
        (off rel))
    (while (and (< sb se) (memq (aref line sb) '(?\s ?\t)))
      (setq sb (1+ sb)
            off (max 0 (1- off))))
    (while (and (> se sb) (memq (aref line (1- se)) '(?\s ?\t)))
      (setq se (1- se)
            off (min (- se sb) off)))
    (when (< sb se)
      (let ((seg (substring line sb se)))
        (when (string-match etaf-md--preview-chrome-prefix-re seg)
          (let ((n (match-end 0)))
            (setq sb (+ sb n)
                  seg (substring seg n)
                  off (max 0 (- off n)))))
        (when (string-match "[ \t]*↩[ \t]*\\'" seg)
          (let ((keep (match-beginning 0)))
            (setq se (+ sb keep)
                  seg (substring seg 0 keep)
                  off (min keep off))))
        (unless (string-empty-p seg)
          (list :text seg
                :offset (max 0 (min (length seg) off))
                :beg sb
                :end se))))))

(defun etaf-md--preview-segment-at (line col &optional table-like-p)
  "Extract cleaned segment metadata around COL in LINE.
Returns a plist with `:text', `:offset', `:beg', `:end', `:hfrac',
`:cursor-cell-col', `:seg-cell-col' and `:cells'."
  (let* ((len (length line))
         (c (max 0 (min len col)))
         (cells (and table-like-p (etaf-md--preview-line-cells line)))
         (cursor-cell-col (etaf-md--cell-index-for-col cells c))
         (hfrac
          (cond
           (cells
            (let* ((lo (caar cells))
                   (hi (cdr (car (last cells))))
                   (span (max 1 (- hi lo))))
              (max 0.0 (min 1.0 (/ (float (- c lo)) (float span))))))
           ((> len 0)
            (let ((lo 0)
                  (hi len))
              (while (and (< lo hi)
                          (or (memq (aref line lo) '(?\s ?\t))
                              (string-match-p etaf-md--preview-border-re
                                              (substring line lo (1+ lo)))))
                (setq lo (1+ lo)))
              (while (and (> hi lo)
                          (or (memq (aref line (1- hi)) '(?\s ?\t))
                              (string-match-p etaf-md--preview-border-re
                                              (substring line (1- hi) hi))))
                (setq hi (1- hi)))
              (if (> hi lo)
                  (max 0.0 (min 1.0 (/ (float (- c lo)) (float (- hi lo)))))
                0.0)))
           (t 0.0)))
         (beg c)
         (end c))
    ;; Isolate the cell/pane around C bounded by box-drawing borders so table
    ;; cells and line-numbered code rows match their own column cleanly.
    (while (and (> beg 0)
                (not (string-match-p etaf-md--preview-border-re
                                     (substring line (1- beg) beg))))
      (setq beg (1- beg)))
    (while (and (< end len)
                (not (string-match-p etaf-md--preview-border-re
                                     (substring line end (1+ end)))))
      (setq end (1+ end)))
    (let* ((raw (substring line beg end))
           (rel (- c beg))
           (piece-beg beg)
           (piece-end end))
      ;; If cursor sits on a border or in outer centering margin spaces, scan
      ;; right (then left) for the first non-blank text segment on the line.
      (when (string-blank-p raw)
        (let ((scan end)
              (found nil))
          (while (and (< scan len) (null found))
            (if (string-match-p etaf-md--preview-border-re
                                (substring line scan (1+ scan)))
                (setq scan (1+ scan))
              (let ((s-beg scan))
                (while (and (< scan len)
                            (not (string-match-p etaf-md--preview-border-re
                                                 (substring line scan (1+ scan)))))
                  (setq scan (1+ scan)))
                (let ((piece (substring line s-beg scan)))
                  (unless (string-blank-p piece)
                    (setq raw piece piece-beg s-beg piece-end scan
                          rel 0 found t))))))
          (unless found
            (let ((lscan beg))
              (while (and (> lscan 0) (null found))
                (if (string-match-p etaf-md--preview-border-re
                                    (substring line (1- lscan) lscan))
                    (setq lscan (1- lscan))
                  (let ((s-end lscan))
                    (while (and (> lscan 0)
                                (not (string-match-p etaf-md--preview-border-re
                                                     (substring line (1- lscan) lscan))))
                      (setq lscan (1- lscan)))
                    (let ((piece (substring line lscan s-end)))
                      (unless (string-blank-p piece)
                        (setq raw piece piece-beg lscan piece-end s-end
                              rel (length piece) found t))))))))))
      (let* ((cleaned (unless (string-blank-p raw)
                        (etaf-md--clean-piece-with-span line piece-beg piece-end rel)))
             (seg-cell-col (and cleaned cells
                                (etaf-md--cell-index-for-col
                                 cells (plist-get cleaned :beg)))))
        (list :text (and cleaned (plist-get cleaned :text))
              :offset (and cleaned (plist-get cleaned :offset))
              :beg (and cleaned (plist-get cleaned :beg))
              :end (and cleaned (plist-get cleaned :end))
              :hfrac hfrac
              :cursor-cell-col cursor-cell-col
              :seg-cell-col seg-cell-col
              :cells cells)))))

(defun etaf-md--preview-clean-segment (line col)
  "Extract the cleaned preview text segment around COL in LINE.
Returns `(TEXT . OFFSET)' where OFFSET is the 0-based cursor position inside
TEXT, or nil when LINE carries only borders or whitespace."
  (let ((info (etaf-md--preview-segment-at line col nil)))
    (when (plist-get info :text)
      (cons (plist-get info :text) (plist-get info :offset)))))

(defun etaf-md--preview-line-pieces (line)
  "Return cleaned non-blank `(TEXT BEG END)' pieces of LINE split at borders."
  (let ((len (length line))
        (pos 0)
        (pieces nil))
    (while (< pos len)
      (if (string-match-p etaf-md--preview-border-re (substring line pos (1+ pos)))
          (setq pos (1+ pos))
        (let ((beg pos))
          (while (and (< pos len)
                      (not (string-match-p etaf-md--preview-border-re
                                           (substring line pos (1+ pos)))))
            (setq pos (1+ pos)))
          (when-let* ((cleaned (etaf-md--clean-piece-with-span line beg pos 0)))
            (push cleaned pieces)))))
    (nreverse pieces)))

(defun etaf-md--preview-block-context (preview-buf pbeg pend pos table-like-p)
  "Build preview block text context and cursor offsets around POS in [PBEG, PEND].
Returns a plist carrying `:seg-info', `:p-text', `:p-pos', `:p-frac',
`:seg-p-base', `:seg-norm', `:seg-norm-map', `:seg-norm-rel', `:table-col',
`:cursor-table-col', `:col-text', `:col-pos', `:col-frac', `:seg-col-base',
`:line', `:col' and `:hfrac'."
  (with-current-buffer preview-buf
    (save-excursion
      (let* ((lo (max (point-min) (min (point-max) pbeg)))
             (content-end (etaf-md--block-content-end preview-buf lo pend))
             (cur-pos (max (point-min) (min (point-max) pos)))
             (cur-lbeg (progn (goto-char cur-pos) (line-beginning-position)))
             (cur-lend (line-end-position))
             (cur-line (buffer-substring-no-properties cur-lbeg cur-lend))
             (cur-col (- cur-pos cur-lbeg))
             (seg-info (etaf-md--preview-segment-at cur-line cur-col table-like-p))
             (seg-beg (plist-get seg-info :beg))
             (seg-end (plist-get seg-info :end))
             (table-col (plist-get seg-info :seg-cell-col))
             (p-parts nil)
             (p-len 0)
             (p-pos nil)
             (seg-p-base nil)
             (seg-norm nil)
             (seg-norm-map nil)
             (seg-norm-rel nil)
             (col-parts nil)
             (col-len 0)
             (col-pos nil)
             (seg-col-base nil)
             (scan-beg (progn (goto-char lo) (line-beginning-position)))
             (scan-end (progn (goto-char (max lo content-end)) (line-end-position))))
        (goto-char scan-beg)
        (while (<= (point) scan-end)
          (let* ((lb (line-beginning-position))
                 (le (line-end-position))
                 (is-cur (= lb cur-lbeg))
                 (ltxt (if is-cur cur-line (buffer-substring-no-properties lb le))))
            (dolist (piece (etaf-md--preview-line-pieces ltxt))
              (let* ((norm-pair (etaf-md--normalize-ws-with-map (plist-get piece :text)))
                     (ntxt (car norm-pair))
                     (nmap (cdr norm-pair)))
                (unless (string-empty-p ntxt)
                  (when (> p-len 0)
                    (push " " p-parts)
                    (setq p-len (1+ p-len)))
                  (let ((base p-len))
                    (when (and is-cur seg-beg
                               (= (plist-get piece :beg) seg-beg)
                               (= (plist-get piece :end) seg-end))
                      (let ((nrel (etaf-md--map-offset-to-norm
                                   nmap (plist-get seg-info :offset))))
                        (setq seg-p-base base
                              seg-norm ntxt
                              seg-norm-map nmap
                              seg-norm-rel nrel
                              p-pos (+ base nrel))))
                    (push ntxt p-parts)
                    (setq p-len (+ p-len (length ntxt)))))))
            (when (and is-cur (null p-pos))
              (setq p-pos p-len))
            (when table-col
              (when-let* ((cells (etaf-md--preview-line-cells ltxt))
                          ((< table-col (length cells)))
                          (span (nth table-col cells))
                          (cleaned (etaf-md--clean-piece-with-span
                                    ltxt (car span) (cdr span) 0)))
                (let* ((norm-pair (etaf-md--normalize-ws-with-map
                                   (plist-get cleaned :text)))
                       (ntxt (car norm-pair))
                       (nmap (cdr norm-pair)))
                  (unless (string-empty-p ntxt)
                    (when (> col-len 0)
                      (push " " col-parts)
                      (setq col-len (1+ col-len)))
                    (let ((cbase col-len))
                      (when (and is-cur seg-beg
                                 (= (plist-get cleaned :beg) seg-beg)
                                 (= (plist-get cleaned :end) seg-end))
                        (let ((nrel (or seg-norm-rel
                                        (etaf-md--map-offset-to-norm
                                         nmap (plist-get seg-info :offset)))))
                          (setq seg-col-base cbase
                                col-pos (+ cbase nrel))))
                      (push ntxt col-parts)
                      (setq col-len (+ col-len (length ntxt)))))))
              (when (and is-cur (null col-pos))
                (setq col-pos col-len)))
            (if (or (>= le scan-end) (not (zerop (forward-line 1))))
                (goto-char (1+ scan-end)))))
        (let* ((p-text (apply #'concat (nreverse p-parts)))
               (col-text (and table-col (apply #'concat (nreverse col-parts))))
               (p-final-pos (or p-pos 0))
               (col-final-pos (or col-pos 0)))
          (list :seg-info seg-info
                :line cur-line
                :col cur-col
                :hfrac (plist-get seg-info :hfrac)
                :p-text p-text
                :p-pos p-final-pos
                :p-frac (if (> (length p-text) 0)
                            (max 0.0 (min 1.0 (/ (float p-final-pos)
                                                 (float (length p-text)))))
                          0.0)
                :seg-p-base seg-p-base
                :seg-norm seg-norm
                :seg-norm-map seg-norm-map
                :seg-norm-rel seg-norm-rel
                :table-col table-col
                :cursor-table-col (plist-get seg-info :cursor-cell-col)
                :col-text col-text
                :col-pos col-final-pos
                :col-frac (if (and col-text (> (length col-text) 0))
                              (max 0.0 (min 1.0 (/ (float col-final-pos)
                                                   (float (length col-text)))))
                            0.0)
                :seg-col-base seg-col-base))))))

(defun etaf-md--push-anchor-candidate (candidates seen kind value offset
                                                  &optional group p-start col-start)
  "Push candidate `(KIND VALUE OFFSET GROUP P-START COL-START)' if unseen."
  (when (and (stringp value)
             (not (string-blank-p value))
             (or (eq kind :regex)
                 (>= (length value) 2)
                 (and (= (length value) 1)
                      (>= (char-width (aref value 0)) 2))))
    (let ((key (list kind value offset p-start)))
      (unless (gethash key seen)
        (puthash key t seen)
        (push (list kind value offset (or group 0) p-start col-start)
              candidates))))
  candidates)

(defun etaf-md--add-segment-windows (candidates seen seg rel
                                                &optional p-base col-base)
  "Add prioritized literal window candidates from SEG around REL.
P-BASE and COL-BASE anchor each slice's exact 0-based start offset inside the
preview block and table column projections so duplicate occurrences stay
unambiguous.  Slices touching REL are always ordered before space-detached ones."
  (let* ((len (length seg))
         (detached nil)
         (make-slice
          (lambda (s e target)
            (when (< s e)
              (let ((ts s)
                    (te e))
                (while (and (< ts te) (memq (aref seg ts) '(?\s ?\t)))
                  (setq ts (1+ ts)))
                (while (and (> te ts) (memq (aref seg (1- te)) '(?\s ?\t)))
                  (setq te (1- te)))
                (when (< ts te)
                  (let* ((raw (substring seg ts te))
                         (off (max 0 (min (- te ts) (- target ts))))
                         (ps (and p-base (+ p-base ts)))
                         (cs (and col-base (+ col-base ts)))
                         (touches (and (<= ts target) (<= target te))))
                    (list raw off ps cs touches)))))))
         (add-slice
          (lambda (s e target)
            (when-let* ((info (funcall make-slice s e target)))
              (if (nth 4 info)
                  (setq candidates
                        (etaf-md--push-anchor-candidate
                         candidates seen :literal
                         (nth 0 info) (nth 1 info) 0 (nth 2 info) (nth 3 info)))
                (push info detached))))))
    (when (<= len 160)
      (setq candidates
            (etaf-md--push-anchor-candidate
             candidates seen :literal seg rel 0 p-base col-base)))
    (funcall add-slice (max 0 (- rel 14)) (min len (+ rel 14)) rel)
    (funcall add-slice rel (min len (+ rel 14)) rel)
    (funcall add-slice (max 0 (- rel 14)) rel rel)
    (dolist (info (nreverse detached))
      (setq candidates
            (etaf-md--push-anchor-candidate
             candidates seen :literal
             (nth 0 info) (nth 1 info) 0 (nth 2 info) (nth 3 info))))
    candidates))

(defun etaf-md--token-spans (seg)
  "Return list of `(START END TEXT)' for non-whitespace tokens in SEG."
  (let ((pos 0)
        (len (length seg))
        (spans nil))
    (while (and (< pos len)
                (string-match "[^ \t]+" seg pos))
      (push (list (match-beginning 0) (match-end 0) (match-string 0 seg)) spans)
      (setq pos (match-end 0)))
    (nreverse spans)))

(defun etaf-md--preview-isearch-hit (line col)
  "Return `(TEXT OFFSET LINE-START)' when `isearch-string' sits adjacent to COL."
  (when (and (boundp 'isearch-string)
             (stringp isearch-string)
             (> (length isearch-string) 0)
             (<= (length isearch-string) (length line)))
    (let* ((n (length isearch-string))
           (fold (if (boundp 'isearch-case-fold-search)
                     isearch-case-fold-search
                   case-fold-search))
           (eq-p (lambda (s)
                   (if fold
                       (string= (downcase s) (downcase isearch-string))
                     (string= s isearch-string)))))
      (cond
       ;; `C-s' leaves point immediately after the matched string.
       ((and (>= col n)
             (funcall eq-p (substring line (- col n) col)))
        (list (substring line (- col n) col) n (- col n)))
       ;; `C-r' leaves point immediately before the matched string.
       ((and (<= (+ col n) (length line))
             (funcall eq-p (substring line col (+ col n))))
        (list (substring line col (+ col n)) 0 col))))))

(defun etaf-md--preview-anchor-candidates (preview-buf pos &optional ctx)
  "Return ordered source-search anchor candidates around POS in PREVIEW-BUF.
When CTX (from `etaf-md--preview-block-context') is supplied, candidates carry
their exact 0-based start offsets inside the preview block and table column
projections for deterministic duplicate disambiguation."
  (with-current-buffer preview-buf
    (save-excursion
      (goto-char (max (point-min) (min (point-max) pos)))
      (let* ((line (or (and ctx (plist-get ctx :line))
                       (buffer-substring-no-properties
                        (line-beginning-position) (line-end-position))))
             (col (or (and ctx (plist-get ctx :col))
                      (- (point) (line-beginning-position))))
             (seg-info (or (and ctx (plist-get ctx :seg-info))
                           (etaf-md--preview-segment-at line col nil)))
             (raw-seg (plist-get seg-info :text))
             (raw-beg (plist-get seg-info :beg))
             (raw-end (plist-get seg-info :end))
             (norm-pair (when raw-seg
                          (if (and ctx (plist-get ctx :seg-norm))
                              (cons (plist-get ctx :seg-norm)
                                    (plist-get ctx :seg-norm-map))
                            (etaf-md--normalize-ws-with-map raw-seg))))
             (seg (and norm-pair (car norm-pair)))
             (seg-map (and norm-pair (cdr norm-pair)))
             (rel (when seg
                    (or (and ctx (plist-get ctx :seg-norm-rel))
                        (etaf-md--map-offset-to-norm
                         seg-map (plist-get seg-info :offset)))))
             (p-base (and ctx (plist-get ctx :seg-p-base)))
             (col-base (and ctx (plist-get ctx :seg-col-base)))
             (isearch-hit (etaf-md--preview-isearch-hit line col))
             (seen (make-hash-table :test #'equal))
             (candidates nil))
        (when (and seg (not (string-empty-p seg)))
          (let ((len (length seg)))
            ;; 1. Exact full segment & local windows around cursor.
            (setq candidates
                  (etaf-md--add-segment-windows
                   candidates seen seg rel p-base col-base))
            ;; 2. Active C-s / C-r match adjacent to point (handles inline
            ;;    markup such as **bold** or `code` breaking a longer window).
            (when isearch-hit
              (let* ((itxt (car (etaf-md--normalize-ws-with-map (nth 0 isearch-hit))))
                     (ioff (min (length itxt) (nth 1 isearch-hit)))
                     (iline-start (nth 2 isearch-hit))
                     (in-seg (and raw-beg raw-end
                                  (<= raw-beg iline-start)
                                  (< iline-start raw-end)))
                     (nstart (and in-seg seg-map
                                  (etaf-md--map-offset-to-norm
                                   seg-map (- iline-start raw-beg))))
                     (ips (and nstart p-base (+ p-base nstart)))
                     (ics (and nstart col-base (+ col-base nstart))))
                (setq candidates
                      (etaf-md--push-anchor-candidate
                       candidates seen :literal itxt ioff 0 ips ics))))
            ;; 3. Inline-markup-tolerant regex across up to 4 tokens near rel.
            (let* ((spans (etaf-md--token-spans seg))
                   (count (length spans)))
              (when (>= count 2)
                (let* ((focus-idx 0))
                  (cl-loop for sp in spans
                           for idx from 0
                           when (<= (nth 0 sp) rel)
                           do (setq focus-idx idx))
                  (let* ((start-idx (max 0 (min (- count 2) (1- focus-idx))))
                         (end-idx (min count (+ start-idx 4)))
                         (slice (cl-subseq spans start-idx end-idx))
                         (focus-local (- focus-idx start-idx))
                         (focus-span (nth focus-local slice))
                         (focus-off (max 0 (min (- (nth 1 focus-span) (nth 0 focus-span))
                                                (- rel (nth 0 focus-span)))))
                         (parts
                          (cl-loop for sp in slice
                                   for i from 0
                                   for q = (regexp-quote (nth 2 sp))
                                   collect (if (= i focus-local)
                                               (concat "\\(" q "\\)")
                                             q)))
                         (pattern (mapconcat #'identity parts "[ \t*_~`\\[\\]!$=]\\{0,12\\}")))
                    (setq candidates
                          (etaf-md--push-anchor-candidate
                           candidates seen :regex pattern focus-off 1))))))
            ;; 4. Stripped variants: stacked table card "Header · Value",
            ;;    footnote numbers "1. ..." / "[1] ...", and code line numbers.
            (when (string-match " · " seg)
              (let ((split-pos (match-beginning 0))
                    (after-pos (match-end 0)))
                (if (>= rel split-pos)
                    (setq candidates
                          (etaf-md--add-segment-windows
                           candidates seen
                           (substring seg after-pos)
                           (max 0 (- rel after-pos))
                           (and p-base (+ p-base after-pos))
                           (and col-base (+ col-base after-pos))))
                  (setq candidates
                        (etaf-md--add-segment-windows
                         candidates seen (substring seg 0 split-pos) rel
                         p-base col-base)))))
            (dolist (prefix-re '("\\`\\(?:\\[[0-9A-Za-z_-]+\\]\\|[0-9]+\\.\\)[ \t]+"
                                 "\\`[0-9]+[ \t]+"))
              (when (string-match prefix-re seg)
                (let* ((n (match-end 0))
                       (stripped (substring seg n))
                       (srel (max 0 (- rel n))))
                  (unless (string-empty-p stripped)
                    (setq candidates
                          (etaf-md--add-segment-windows
                           candidates seen stripped srel
                           (and p-base (+ p-base n))
                           (and col-base (+ col-base n))))))))
            ;; 5. Immediate token/word and short slices around cursor.
            (let ((word-re "[[:alnum:]_@/.:-]+\\|\\cC+"))
              (let ((pos-i 0)
                    (spanning nil)
                    (left-tok nil)
                    (right-tok nil))
                (while (and (< pos-i len) (string-match word-re seg pos-i))
                  (let ((tb (match-beginning 0))
                        (te (match-end 0))
                        (tw (match-string 0 seg)))
                    (cond
                     ((and (<= tb rel) (<= rel te))
                      (setq spanning (list tw (- rel tb) tb)))
                     ((< te rel)
                      (setq left-tok (list tw (length tw) tb)))
                     ((and (> tb rel) (null right-tok))
                      (setq right-tok (list tw 0 tb)))))
                  (setq pos-i (match-end 0)))
                (dolist (hit (list spanning right-tok left-tok))
                  (when hit
                    (let ((tb (nth 2 hit)))
                      (setq candidates
                            (etaf-md--push-anchor-candidate
                             candidates seen :literal (nth 0 hit) (nth 1 hit) 0
                             (and p-base (+ p-base tb))
                             (and col-base (+ col-base tb)))))))))
            (dolist (w '(6 4 2))
              (when (<= (+ rel w) len)
                (let ((ts rel) (te (+ rel w)))
                  (while (and (< ts te) (memq (aref seg ts) '(?\s ?\t))) (setq ts (1+ ts)))
                  (while (and (> te ts) (memq (aref seg (1- te)) '(?\s ?\t))) (setq te (1- te)))
                  (when (< ts te)
                    (setq candidates
                          (etaf-md--push-anchor-candidate
                           candidates seen :literal (substring seg ts te) 0 0
                           (and p-base (+ p-base ts))
                           (and col-base (+ col-base ts)))))))
              (when (>= rel w)
                (let ((ts (- rel w)) (te rel))
                  (while (and (< ts te) (memq (aref seg ts) '(?\s ?\t))) (setq ts (1+ ts)))
                  (while (and (> te ts) (memq (aref seg (1- te)) '(?\s ?\t))) (setq te (1- te)))
                  (when (< ts te)
                    (setq candidates
                          (etaf-md--push-anchor-candidate
                           candidates seen :literal (substring seg ts te) (- te ts) 0
                           (and p-base (+ p-base ts))
                           (and col-base (+ col-base ts))))))))
            ;; 6. Line-start and longest-token fallback (e.g. cursor at margin).
            (let ((te (min len 24)))
              (while (and (> te 0) (memq (aref seg (1- te)) '(?\s ?\t)))
                (setq te (1- te)))
              (when (> te 0)
                (setq candidates
                      (etaf-md--push-anchor-candidate
                       candidates seen :literal (substring seg 0 te) 0 0
                       p-base col-base))))
            (let ((longest nil))
              (dolist (sp (etaf-md--token-spans seg))
                (when (or (null longest) (> (length (nth 2 sp)) (length (nth 2 longest))))
                  (setq longest sp)))
              (when longest
                (setq candidates
                      (etaf-md--push-anchor-candidate
                       candidates seen :literal (nth 2 longest) 0 0
                       (and p-base (+ p-base (nth 0 longest)))
                       (and col-base (+ col-base (nth 0 longest)))))))))
        (when (and (or (null seg) (string-empty-p seg)) isearch-hit)
          (setq candidates
                (etaf-md--push-anchor-candidate
                 candidates seen :literal (nth 0 isearch-hit) (nth 1 isearch-hit))))
        (nreverse candidates)))))

(defun etaf-md--block-content-end (preview-buf pbeg pend)
  "Return end pos in [PBEG, PEND] of PREVIEW-BUF without blank margins."
  (with-current-buffer preview-buf
    (save-excursion
      (let* ((lo (max (point-min) (min (point-max) pbeg)))
             (hi (max lo (min (point-max) pend)))
             (content-end hi))
        ;; Exclude trailing blank margin rows contributed by `:margin-bottom'.
        (goto-char content-end)
        (while (and (> content-end lo)
                    (let ((lb (max lo (line-beginning-position))))
                      (string-blank-p
                       (buffer-substring-no-properties lb content-end))))
          (let ((prev (max lo (1- (line-beginning-position)))))
            (if (< prev content-end)
                (progn (setq content-end prev)
                       (goto-char content-end))
              (setq content-end lo))))
        content-end))))

(defun etaf-md--preview-line-frac (preview-buf pbeg pend pos)
  "Return 0-based vertical fraction [0.0, 1.0] of POS inside [PBEG, PEND].
Trims trailing blank margin lines from PEND and counts from line beginnings so
a mid-line cursor on line 0 always yields 0.0 instead of stepping onto line 1."
  (with-current-buffer preview-buf
    (save-excursion
      (let* ((lo (max (point-min) (min (point-max) pbeg)))
             (content-end (etaf-md--block-content-end preview-buf lo pend))
             (clamped (max lo (min content-end pos)))
             (start-bol (progn (goto-char lo) (line-beginning-position)))
             (cur-bol (progn (goto-char clamped) (line-beginning-position)))
             (end-bol (progn (goto-char content-end) (line-beginning-position)))
             (total (count-lines start-bol end-bol))
             (offset (count-lines start-bol cur-bol)))
        (if (<= total 0)
            0.0
          (min 1.0 (/ (float offset) (float total))))))))

(defun etaf-md--locate-entry-at (entries runtime pos)
  "Locate the entry in ENTRIES around buffer POS in O(log N) bounds queries.
Returns a plist with `:first-entry', `:first-bounds', `:last-entry',
`:last-bounds', `:match', `:match-bounds', `:prev', `:prev-bounds', `:next'."
  (let* ((vec (vconcat entries))
         (n (length vec)))
    (when (> n 0)
      (cl-labels
          ((bounds-at (i)
             (when (and (>= i 0) (< i n))
               (when-let* ((ref (plist-get (aref vec i) :ref)))
                 (etaf-host-ref-bounds runtime ref))))
           (first-valid ()
             (let ((i 0) res)
               (while (and (< i n) (null res))
                 (when-let* ((b (bounds-at i)))
                   (setq res (cons i b)))
                 (setq i (1+ i)))
               res))
           (last-valid ()
             (let ((i (1- n)) res)
               (while (and (>= i 0) (null res))
                 (when-let* ((b (bounds-at i)))
                   (setq res (cons i b)))
                 (setq i (1- i)))
               res)))
        (when-let* ((fv (first-valid))
                    (lv (last-valid)))
          (let* ((fi (car fv)) (fb (cdr fv))
                 (li (car lv)) (lb (cdr lv))
                 (match-i nil) (match-b nil)
                 (prev-i nil) (prev-b nil)
                 (next-i nil))
            (cond
             ((< pos (car fb))
              (setq next-i fi))
             ((> pos (cdr lb))
              (setq prev-i li prev-b lb))
             (t
              ;; Binary search for the entry whose [beg, end] contains POS, or
              ;; the tightest surrounding pair when POS lies in a gap.
              (let ((lo fi) (hi li))
                (while (and (<= lo hi) (null match-i))
                  (let* ((mid (/ (+ lo hi) 2))
                         (b (bounds-at mid))
                         (probe mid))
                    ;; If mid has nil bounds, step toward hi to find a mounted entry.
                    (while (and (null b) (< probe hi))
                      (setq probe (1+ probe) b (bounds-at probe)))
                    (if (null b)
                        (setq hi (1- mid))
                      (cond
                       ((and (<= (car b) pos) (<= pos (cdr b)))
                        (setq match-i probe match-b b))
                       ((< (cdr b) pos)
                        (setq prev-i probe prev-b b
                              lo (1+ probe)))
                       (t
                        (setq next-i probe
                              hi (1- mid))))))))))
            (list :first-entry (aref vec fi)
                  :first-bounds fb
                  :last-entry (aref vec li)
                  :last-bounds lb
                  :match (and match-i (aref vec match-i))
                  :match-bounds match-b
                  :prev (and prev-i (aref vec prev-i))
                  :prev-bounds prev-b
                  :next (and next-i (aref vec next-i)))))))))

(defun etaf-md--source-offset-at-point (session preview-buf pos)
  "Return a source location plist matching POS in PREVIEW-BUF, or nil.
Resolves front matter, body blocks and footnotes in O(log N) bounds lookups,
computes a 0-based line fraction without mid-line off-by-one drift, and extracts
cursor text anchors together with block/column projection offsets so duplicate
text on the same line or table row resolves deterministically."
  (when-let* ((runtime (and (buffer-live-p preview-buf)
                            (etaf-runtime-for-buffer preview-buf)))
              (entries (plist-get session :entries))
              (found (etaf-md--locate-entry-at entries runtime pos)))
    (let* ((first-entry (plist-get found :first-entry))
           (first-bounds (plist-get found :first-bounds))
           (last-entry (plist-get found :last-entry))
           (last-bounds (plist-get found :last-bounds))
           (best-entry (plist-get found :match))
           (best-bounds (plist-get found :match-bounds))
           (prev-entry (plist-get found :prev))
           (prev-bounds (plist-get found :prev-bounds))
           (first-block (and first-entry (plist-get first-entry :block)))
           (first-src-beg (and first-block (plist-get first-block :begin)))
           (doc (etaf-md--read session :document))
           (has-footnotes (and (listp doc) (plist-get doc :footnotes))))
      (cond
       ;; Cursor in front matter / hero header before the first body block.
       ((and first-bounds (< pos (car first-bounds))
             (integerp first-src-beg) (> first-src-beg 0))
        (let* ((pmin (with-current-buffer preview-buf (point-min)))
               (ctx (etaf-md--preview-block-context
                     preview-buf pmin (car first-bounds) pos nil))
               (candidates (etaf-md--preview-anchor-candidates preview-buf pos ctx)))
          (list :begin 0
                :end first-src-beg
                :frac (etaf-md--preview-line-frac
                       preview-buf pmin (car first-bounds) pos)
                :hfrac (plist-get ctx :hfrac)
                :p-text (plist-get ctx :p-text)
                :p-frac (plist-get ctx :p-frac)
                :zone 'front-matter
                :block-type 'front-matter
                :candidates candidates)))
       ;; Cursor inside the footnotes section rendered after the last block.
       ((and last-bounds (> pos (cdr last-bounds)) has-footnotes)
        (let* ((pmax (with-current-buffer preview-buf (point-max)))
               (ctx (etaf-md--preview-block-context
                     preview-buf (cdr last-bounds) pmax pos nil))
               (candidates (etaf-md--preview-anchor-candidates preview-buf pos ctx))
               (lb (plist-get last-entry :block))
               (lbeg (or (and lb (plist-get lb :begin)) 0))
               (lend (or (and lb (plist-get lb :end)) lbeg)))
          (list :begin 0
                :end nil
                :frac (etaf-md--preview-line-frac
                       preview-buf (cdr last-bounds) pmax pos)
                :hfrac (plist-get ctx :hfrac)
                :p-text (plist-get ctx :p-text)
                :p-frac (plist-get ctx :p-frac)
                :zone 'footnote
                :fallback-begin lbeg
                :fallback-end lend
                :candidates candidates)))
       ;; Cursor inside or near a body block.
       (t
        (let* ((entry (or best-entry prev-entry first-entry))
               (bounds (or best-bounds prev-bounds first-bounds))
               (block (and entry (plist-get entry :block)))
               (src-beg (and block (plist-get block :begin)))
               (src-end (and block (plist-get block :end))))
          (when (and (integerp src-beg) (integerp src-end))
            (let* ((table-like (etaf-md--block-table-like-p block))
                   (ctx (when (and bounds (> (cdr bounds) (car bounds)))
                          (etaf-md--preview-block-context
                           preview-buf (car bounds) (cdr bounds) pos table-like)))
                   (candidates (etaf-md--preview-anchor-candidates preview-buf pos ctx))
                   (frac (if (and best-bounds (> (cdr bounds) (car bounds))
                                  (> src-end src-beg))
                             (etaf-md--preview-line-frac
                              preview-buf (car bounds) (cdr bounds) pos)
                           0.0)))
              (list :begin src-beg
                    :end src-end
                    :frac frac
                    :hfrac (or (and ctx (plist-get ctx :hfrac)) 0.0)
                    :p-text (and ctx (plist-get ctx :p-text))
                    :p-frac (or (and ctx (plist-get ctx :p-frac)) frac)
                    :table-like table-like
                    :table-col (and ctx (plist-get ctx :table-col))
                    :cursor-table-col (and ctx (plist-get ctx :cursor-table-col))
                    :col-text (and ctx (plist-get ctx :col-text))
                    :col-frac (or (and ctx (plist-get ctx :col-frac)) frac)
                    :prefer-left (and ctx
                                      (let ((ih (etaf-md--preview-isearch-hit
                                                 (plist-get ctx :line)
                                                 (plist-get ctx :col))))
                                        (and ih (> (nth 1 ih) 0))))
                    :zone 'block
                    :block-type (plist-get block :type)
                    :candidates candidates)))))))))

(defun etaf-md--source-buffer-for (session)
  "Return a live source buffer for SESSION (opening its file if needed), or nil."
  (let ((file (plist-get session :file)))
    (or (let ((sb (plist-get session :source-buffer)))
          (and (buffer-live-p sb) sb))
        (and file (or (find-buffer-visiting file)
                      (and (file-readable-p file)
                           (find-file-noselect file)))))))

(defun etaf-md--in-footnote-def-p ()
  "Return non-nil when point in the current buffer lies in a footnote def."
  (save-excursion
    (beginning-of-line)
    (cond
     ((looking-at-p "^\\[\\^[^]\n]+\\]:") t)
     ((looking-at-p "^[ \t]+[^ \t\n]")
      (let ((found nil)
            (stop nil))
        (while (and (not stop) (zerop (forward-line -1)))
          (cond
           ((looking-at-p "^\\[\\^[^]\n]+\\]:")
            (setq found t stop t))
           ((not (looking-at-p "^[ \t]+"))
            (setq stop t))))
        found))
     (t nil))))

(defun etaf-md--src-find-closing-backticks (src pos end ticks)
  "Find start index of a run of exactly TICKS backticks in SRC[POS..END)."
  (let ((i pos)
        (found nil))
    (while (and (< i end) (null found))
      (if (eq (aref src i) ?`)
          (let ((start i))
            (while (and (< i end) (eq (aref src i) ?`))
              (setq i (1+ i)))
            (when (= (- i start) ticks)
              (setq found start)))
        (setq i (1+ i))))
    found))

(defun etaf-md--src-find-matching-bracket (src pos end)
  "Find the `]' matching `[' at POS inside SRC[POS..END), or nil."
  (let ((i (1+ pos))
        (depth 1)
        (found nil))
    (while (and (< i end) (null found))
      (let ((ch (aref src i)))
        (cond
         ((and (eq ch ?\\) (< (1+ i) end))
          (setq i (+ i 2)))
         ((eq ch ?`)
          (let ((s i))
            (while (and (< i end) (eq (aref src i) ?`))
              (setq i (1+ i)))
            (let ((close (etaf-md--src-find-closing-backticks
                          src i end (- i s))))
              (when close
                (setq i (+ close (- i s)))))))
         ((eq ch ?\[)
          (setq depth (1+ depth) i (1+ i)))
         ((eq ch ?\])
          (setq depth (1- depth))
          (if (zerop depth)
              (setq found i)
            (setq i (1+ i))))
         (t (setq i (1+ i))))))
    found))

(defun etaf-md--src-skip-link-dest (src pos end)
  "If SRC at POS starts a Markdown `(...)' or `[...]' destination, return its end."
  (when (< pos end)
    (let ((ch (aref src pos)))
      (cond
       ((eq ch ?\()
        (let ((i (1+ pos))
              (depth 1)
              (found nil))
          (while (and (< i end) (null found))
            (let ((c (aref src i)))
              (cond
               ((and (eq c ?\\) (< (1+ i) end))
                (setq i (+ i 2)))
               ((eq c ?\()
                (setq depth (1+ depth) i (1+ i)))
               ((eq c ?\))
                (setq depth (1- depth))
                (if (zerop depth)
                    (setq found (1+ i))
                  (setq i (1+ i))))
               (t (setq i (1+ i))))))
          found))
       ((eq ch ?\[)
        (when-let* ((rb (etaf-md--src-find-matching-bracket src pos end)))
          (1+ rb)))))))

(defun etaf-md--src-split-pipe-cells (src line-start line-end)
  "Split a Markdown pipe-table row SRC[LINE-START..LINE-END) into cell spans.
Respects escaped pipes and inline backtick code spans; trims empty outer spans
before a leading `|' and after a trailing `|'.  Returns list of `(BEG . END)'."
  (let ((i line-start)
        (pipes nil))
    (while (< i line-end)
      (let ((ch (aref src i)))
        (cond
         ((and (eq ch ?\\) (< (1+ i) line-end))
          (setq i (+ i 2)))
         ((eq ch ?`)
          (let ((s i))
            (while (and (< i line-end) (eq (aref src i) ?`))
              (setq i (1+ i)))
            (let ((close (etaf-md--src-find-closing-backticks
                          src i line-end (- i s))))
              (when close
                (setq i (+ close (- i s)))))))
         ((eq ch ?|)
          (push i pipes)
          (setq i (1+ i)))
         (t (setq i (1+ i))))))
    (when pipes
      (setq pipes (nreverse pipes))
      (let ((spans nil)
            (prev line-start))
        (dolist (p pipes)
          (push (cons prev p) spans)
          (setq prev (1+ p)))
        (push (cons prev line-end) spans)
        (setq spans (nreverse spans))
        (when (and spans
                   (string-blank-p (substring src (caar spans) (cdar spans))))
          (setq spans (cdr spans)))
        (when spans
          (let ((last-span (car (last spans))))
            (when (string-blank-p (substring src (car last-span) (cdr last-span)))
              (setq spans (butlast spans)))))
        spans))))

(defun etaf-md--src-pipe-separator-line-p (line)
  "Return non-nil when LINE is a Markdown pipe-table delimiter row (`|---|---|')."
  (and (string-match-p "-" line)
       (string-match-p
        "\\`[ \t]*|?[ \t]*:?\\(?:-\\{3,\\}\\|-\\{1,\\}:\\|:-\\{1,\\}\\)[ \t]*\\(?:|[ \t]*:?\\(?:-\\{3,\\}\\|-\\{1,\\}:\\|:-\\{1,\\}\\)[ \t]*\\)*|?[ \t]*\\'"
        line)))

(defun etaf-md--src-alnum-char-p (ch)
  "Return non-nil when CH is an ASCII letter or digit."
  (or (and (>= ch ?a) (<= ch ?z))
      (and (>= ch ?A) (<= ch ?Z))
      (and (>= ch ?0) (<= ch ?9))))

(defun etaf-md--source-visible-projection (source-buf b e table-like-p block-type)
  "Project SOURCE-BUF[B..E) into rendered visible text with exact source positions.
Returns a plist `(:text STRING :pos VECTOR :col VECTOR)' where `:pos' maps each
visible character back to its 1-based buffer position in SOURCE-BUF and `:col'
records its 0-based pipe-table column index (or nil), or nil when too large."
  (when (and (< b e) (<= (- e b) etaf-md--source-projection-max-chars))
    (with-current-buffer source-buf
      (let* ((src (buffer-substring-no-properties b e))
             (len (length src))
             (out-chars nil)
             (out-pos nil)
             (out-col nil)
             (pending-space nil)
             (pending-col nil))
        (cl-labels
            ((emit-space (idx col)
               (when (and out-chars (null pending-space))
                 (setq pending-space (+ b idx)
                       pending-col col)))
             (emit-char (ch idx col)
               (when pending-space
                 (push ?\s out-chars)
                 (push pending-space out-pos)
                 (push pending-col out-col)
                 (setq pending-space nil pending-col nil))
               (push ch out-chars)
               (push (+ b idx) out-pos)
               (push col out-col))
             (emit-verbatim (beg end col)
               (let ((k beg))
                 (while (< k end)
                   (let ((ch (aref src k)))
                     (if (memq ch '(?\s ?\t ?\r ?\n))
                         (emit-space k col)
                       (emit-char ch k col)))
                   (setq k (1+ k)))))
             (scan-inline (beg end col)
               (let ((i beg))
                 (while (< i end)
                   (let ((ch (aref src i)))
                     (cond
                      ;; Whitespace normalization.
                      ((memq ch '(?\s ?\t ?\r ?\n))
                       (emit-space i col)
                       (setq i (1+ i)))
                      ;; Backslash escape of ASCII punctuation.
                      ((and (eq ch ?\\)
                            (< (1+ i) end)
                            (let ((nx (aref src (1+ i))))
                              (and (>= nx ?!) (<= nx ?~)
                                   (not (etaf-md--src-alnum-char-p nx)))))
                       (emit-char (aref src (1+ i)) (1+ i) col)
                       (setq i (+ i 2)))
                      ;; Inline code span.
                      ((eq ch ?`)
                       (let ((s i))
                         (while (and (< i end) (eq (aref src i) ?`))
                           (setq i (1+ i)))
                         (let* ((ticks (- i s))
                                (close (etaf-md--src-find-closing-backticks
                                        src i end ticks)))
                           (if close
                               (let ((cb i)
                                     (ce close))
                                 (when (and (>= (- ce cb) 2)
                                            (eq (aref src cb) ?\s)
                                            (eq (aref src (1- ce)) ?\s)
                                            (not (string-blank-p (substring src cb ce))))
                                   (setq cb (1+ cb) ce (1- ce)))
                                 (emit-verbatim cb ce col)
                                 (setq i (+ close ticks)))
                             (emit-verbatim s i col)))))
                      ;; Image `![alt](url)' or `![alt][ref]': keep alt, drop URL.
                      ((and (eq ch ?!)
                            (< (1+ i) end)
                            (eq (aref src (1+ i)) ?\[)
                            (let ((rb (etaf-md--src-find-matching-bracket
                                       src (1+ i) end)))
                              (when-let* ((rb)
                                          (dend (etaf-md--src-skip-link-dest
                                                 src (1+ rb) end)))
                                (scan-inline (+ i 2) rb col)
                                (setq i dend)
                                t))))
                      ;; Footnote reference `[^id]'.
                      ((and (eq ch ?\[)
                            (< (1+ i) end)
                            (eq (aref src (1+ i)) ?^)
                            (let ((rb (etaf-md--src-find-matching-bracket src i end)))
                              (when (and rb
                                         (not (and (< (1+ rb) end)
                                                   (eq (aref src (1+ rb)) ?:)))
                                         (not (string-match-p
                                               "[ \t\r\n]"
                                               (substring src (+ i 2) rb))))
                                (setq i (1+ rb))
                                t))))
                      ;; Link `[label](url)' or `[label][ref]': keep label, drop URL.
                      ((and (eq ch ?\[)
                            (let ((rb (etaf-md--src-find-matching-bracket src i end)))
                              (when-let* ((rb)
                                          (dend (etaf-md--src-skip-link-dest
                                                 src (1+ rb) end)))
                                (scan-inline (1+ i) rb col)
                                (setq i dend)
                                t))))
                      ;; Double inline delimiters: `**', `__', `~~', `=='.
                      ((and (memq ch '(?* ?_ ?~ ?=))
                            (< (1+ i) end)
                            (eq (aref src (1+ i)) ch))
                       (setq i (+ i 2)))
                      ;; Single emphasis `*` (keep spaces-surrounded `*` like `2 * 3`).
                      ((and (eq ch ?*)
                            (not (and (> i beg)
                                      (< (1+ i) end)
                                      (memq (aref src (1- i)) '(?\s ?\t))
                                      (memq (aref src (1+ i)) '(?\s ?\t)))))
                       (setq i (1+ i)))
                      ;; Single emphasis `_' (preserve snake_case between alnums).
                      ((and (eq ch ?_)
                            (not (and (> i beg)
                                      (< (1+ i) end)
                                      (etaf-md--src-alnum-char-p (aref src (1- i)))
                                      (etaf-md--src-alnum-char-p (aref src (1+ i))))))
                       (setq i (1+ i)))
                      ;; Inline HTML tags `<tag ...>` / `</tag>`.
                      ((and (eq ch ?<)
                            (< (1+ i) end)
                            (let ((nx (aref src (1+ i))))
                              (or (eq nx ?/)
                                  (and (>= nx ?a) (<= nx ?z))
                                  (and (>= nx ?A) (<= nx ?Z))))
                            (let ((gt (string-search ">" src (1+ i))))
                              (when (and gt (< gt end))
                                (let ((tag (downcase (substring src (1+ i) gt))))
                                  (when (string-prefix-p "br" tag)
                                    (emit-space i col)))
                                (setq i (1+ gt))
                                t))))
                      ;; Ordinary visible character.
                      (t
                       (emit-char ch i col)
                       (setq i (1+ i)))))))))
          (let ((pos 0)
                (line-idx 0))
            (while (< pos len)
              (let* ((nl (or (string-search "\n" src pos) len))
                     (line (substring src pos nl))
                     (next-pos (min len (1+ nl))))
                (cond
                 ((string-blank-p line)
                  (emit-space pos nil))
                 ((eq block-type 'code-block)
                  (let ((is-open (and (zerop line-idx)
                                      (string-match-p "\\`[ \t]*\\(?:```+\\|~~~+\\)" line)))
                        (is-close (and (>= next-pos len)
                                       (string-match-p "\\`[ \t]*\\(?:```+\\|~~~+\\)[ \t]*\\'" line))))
                    (unless (or is-open is-close)
                      (emit-verbatim pos nl nil)
                      (emit-space nl nil))))
                 ((eq block-type 'front-matter)
                  (unless (string-match-p "\\`[ \t]*\\(?:---\\|\\.\\.\\.\\)[ \t]*\\'" line)
                    (emit-verbatim pos nl nil)
                    (emit-space nl nil)))
                 ;; Bare closing container fence `:::'.
                 ((string-match-p "\\`[ \t]*:::[ \t]*\\'" line)
                  (emit-space pos nil))
                 ;; Pipe-table delimiter row `|---|---|'.
                 ((and table-like-p (etaf-md--src-pipe-separator-line-p line))
                  (emit-space pos nil))
                 ;; Pipe-table row `| cell0 | cell1 |'.
                 ((and table-like-p
                       (let ((cells (etaf-md--src-split-pipe-cells src pos nl)))
                         (when (and cells (>= (length cells) 2))
                           (let ((cidx 0))
                             (dolist (span cells)
                               (scan-inline (car span) (cdr span) cidx)
                               (emit-space (cdr span) nil)
                               (setq cidx (1+ cidx))))
                           t))))
                 ;; Ordinary Markdown line: strip block markers, then scan inline.
                 (t
                  (let ((ls pos))
                    (while (and (< ls nl) (memq (aref src ls) '(?\s ?\t)))
                      (setq ls (1+ ls)))
                    ;; Strip blockquote prefixes.
                    (while (and (< ls nl) (eq (aref src ls) ?>))
                      (setq ls (1+ ls))
                      (while (and (< ls nl) (memq (aref src ls) '(?\s ?\t)))
                        (setq ls (1+ ls))))
                    (let ((rest (substring src ls nl)))
                      (cond
                       ((string-match "\\`#\\{1,6\\}[ \t]+" rest)
                        (setq ls (+ ls (match-end 0))))
                       ((string-match
                         "\\`\\(?:[-*+]\\|[0-9]+[.)]\\)[ \t]+\\(?:\\[[ xX]\\][ \t]+\\)?"
                         rest)
                        (setq ls (+ ls (match-end 0))))
                       ((string-match "\\`:::[A-Za-z0-9_-]+[ \t]*" rest)
                        (setq ls (+ ls (match-end 0))))
                       ((string-match "\\`\\[\\^[^]\n]+\\]:[ \t]*" rest)
                        (setq ls (+ ls (match-end 0))))))
                    (scan-inline ls nl nil)
                    (emit-space nl nil))))
                (setq pos next-pos
                      line-idx (1+ line-idx))))))
        (list :text (apply #'string (nreverse out-chars))
              :pos (vconcat (nreverse out-pos))
              :col (vconcat (nreverse out-col)))))))

(defun etaf-md--projection-for-column (proj col-idx)
  "Extract a sub-projection from PROJ containing only table column COL-IDX."
  (let* ((text (plist-get proj :text))
         (pos-vec (plist-get proj :pos))
         (col-vec (plist-get proj :col))
         (n (length text))
         (i 0)
         (chars nil)
         (positions nil)
         (saw-gap nil))
    (while (< i n)
      (if (eql (aref col-vec i) col-idx)
          (progn
            (when (and saw-gap chars)
              (push ?\s chars)
              (push (aref pos-vec i) positions))
            (setq saw-gap nil)
            (push (aref text i) chars)
            (push (aref pos-vec i) positions))
        (when chars
          (setq saw-gap t)))
      (setq i (1+ i)))
    (when chars
      (list :text (apply #'string (nreverse chars))
            :pos (vconcat (nreverse positions))))))

(defun etaf-md--count-literal-occurrence (haystack needle start-pos)
  "Return `(OCC . TOTAL)' of NEEDLE in HAYSTACK at START-POS.
Counts all (including overlapping) occurrences in the same order as
`etaf-md--find-all-matches-in-string' so repeated self-overlapping windows such
as `foo bar test foo bar' never miss an occurrence."
  (when (and (stringp haystack) (stringp needle) (> (length needle) 0)
             (integerp start-pos))
    (let ((re (regexp-quote needle))
          (nlen (length needle))
          (res nil))
      (catch 'done
        (dolist (fold '(nil t))
          (let ((case-fold-search fold)
                (pos 0)
                (occ 0)
                (total 0)
                (matched nil))
            (while (and (<= pos (length haystack))
                        (string-match re haystack pos))
              (let ((mb (match-beginning 0)))
                (when (< mb start-pos)
                  (setq occ (1+ occ)))
                (when (and (<= mb start-pos) (< start-pos (+ mb nlen)))
                  (setq matched t))
                (setq total (1+ total)
                      pos (1+ mb))))
            (when (and (> total 0) (or matched fold))
              (setq res (cons (min occ (1- total)) total))
              (throw 'done res)))))
      res)))

(defun etaf-md--find-all-matches-in-string (haystack kind pattern group)
  "Find all `(BEG . END)' matches of KIND/PATTERN/GROUP inside HAYSTACK."
  (let ((re (if (eq kind :regex) pattern (regexp-quote pattern)))
        (grp (or group 0))
        (literal-p (eq kind :literal))
        (matches nil))
    (catch 'done
      (dolist (fold '(nil t))
        (let ((case-fold-search fold)
              (pos 0)
              (found nil))
          (while (and (<= pos (length haystack))
                      (string-match re haystack pos))
            (let ((mb (match-beginning grp))
                  (me (match-end grp))
                  (m0b (match-beginning 0))
                  (m0e (match-end 0)))
              (when (and mb me)
                (push (cons mb me) found))
              (setq pos (if (or literal-p (= m0e m0b))
                            (1+ m0b)
                          m0e))))
          (when found
            (setq matches (nreverse found))
            (throw 'done matches)))))
    matches))

(defun etaf-md--search-in-projection (proj cand p-start p-text p-frac
                                           &optional prefer-left)
  "Resolve CAND against visible projection PROJ using occurrence & 2D position.
When PREFER-LEFT is non-nil (for example after `C-s'), landing on a skipped
inline-markup boundary prefers the position immediately after the preceding
visible character rather than after closing markup.
Returns the exact 1-based source buffer position, or nil."
  (when-let* ((text (and proj (plist-get proj :text)))
              (pos-vec (and proj (plist-get proj :pos)))
              ((> (length text) 0)))
    (let* ((kind (nth 0 cand))
           (pattern (nth 1 cand))
           (offset (nth 2 cand))
           (group (or (nth 3 cand) 0))
           (matches (etaf-md--find-all-matches-in-string text kind pattern group)))
      (when matches
        (let* ((chosen
                (cond
                 ((= (length matches) 1)
                  (car matches))
                 ((and (eq kind :literal) p-start p-text
                       (let ((ot (etaf-md--count-literal-occurrence
                                  p-text pattern p-start)))
                         (when (and ot (= (length matches) (cdr ot))
                                    (< (car ot) (length matches)))
                           (nth (car ot) matches)))))
                 (t
                  (let ((est-idx (round (* (or p-frac 0.0) (length text))))
                        (best nil)
                        (best-dist most-positive-fixnum))
                    (dolist (m matches)
                      (let* ((tgt (+ (car m) (min offset (- (cdr m) (car m)))))
                             (dist (abs (- tgt est-idx))))
                        (when (< dist best-dist)
                          (setq best m best-dist dist))))
                    best))))
               (mb (car chosen))
               (me (cdr chosen))
               (mlen (- me mb))
               (clamped (max 0 (min offset mlen)))
               (idx (+ mb clamped)))
          (cond
           ((and (> mlen 0) (= clamped mlen))
            (1+ (aref pos-vec (1- me))))
           ((< idx (length pos-vec))
            (let ((next-pos (aref pos-vec idx)))
              (if (and (> idx 0)
                       (let ((prev-pos (aref pos-vec (1- idx)))
                             (prev-ch (aref text (1- idx)))
                             (cur-ch (aref text idx)))
                         (and (> next-pos (1+ prev-pos))
                              (not (memq prev-ch '(?\s ?\t)))
                              (or prefer-left
                                  (memq cur-ch
                                        '(?\s ?\t ?, ?. ?\; ?: ?! ?? ?\) ?\]
                                              ?、 ?， ?。 ?； ?： ?！ ?？ ?） ?】))))))
                  (1+ (aref pos-vec (1- idx)))
                next-pos)))
           (t
            (1+ (aref pos-vec (1- (length pos-vec)))))))))))

(defun etaf-md--search-nearest-in-range (cand b e est-pos &optional footnote-only-p)
  "Find the occurrence of CAND inside [B, E] closest to EST-POS, or nil."
  (let* ((kind (nth 0 cand))
         (pattern (nth 1 cand))
         (offset (nth 2 cand))
         (group (or (nth 3 cand) 0))
         (regex-p (eq kind :regex))
         (best nil)
         (best-dist most-positive-fixnum))
    (catch 'done
      (dolist (fold '(nil t))
        (let ((case-fold-search fold))
          (save-excursion
            (goto-char b)
            (while (if regex-p
                       (re-search-forward pattern e t)
                     (search-forward pattern e t))
              (let ((mb (match-beginning group))
                    (me (match-end group)))
                (when (and mb me
                           (or (not footnote-only-p)
                               (save-excursion
                                 (goto-char mb)
                                 (etaf-md--in-footnote-def-p))))
                  (let* ((target (+ mb (min offset (- me mb))))
                         (dist (abs (- target est-pos))))
                    (when (< dist best-dist)
                      (setq best target best-dist dist)))))
              ;; Guard against zero-length regex matches.
              (when (= (match-beginning 0) (match-end 0))
                (forward-char 1))))
          (when best
            (throw 'done best)))))
    best))

(defun etaf-md--fallback-table-cell-pos (source-buf est-bol cursor-table-col b e)
  "When CURSOR-TABLE-COL is non-nil, land on that pipe cell near EST-BOL."
  (when (integerp cursor-table-col)
    (with-current-buffer source-buf
      (save-excursion
        (goto-char est-bol)
        ;; Skip a table delimiter row (`|---|---|') if vertical frac landed on it.
        (let ((line (buffer-substring-no-properties
                     (line-beginning-position) (line-end-position))))
          (when (and (etaf-md--src-pipe-separator-line-p line)
                     (< (line-end-position) e))
            (forward-line 1)))
        (let* ((lb (max b (line-beginning-position)))
               (le (min e (line-end-position)))
               (row (buffer-substring-no-properties lb le))
               (cells (etaf-md--src-split-pipe-cells row 0 (length row))))
          (when (and cells (< cursor-table-col (length cells)))
            (let* ((span (nth cursor-table-col cells))
                   (pos (+ lb (car span)))
                   (end (+ lb (cdr span))))
              (while (and (< pos end) (memq (char-after pos) '(?\s ?\t)))
                (setq pos (1+ pos)))
              pos)))))))

(defun etaf-md--target-pos-in-source (source-buf loc)
  "Return the 1-based position in SOURCE-BUF corresponding to LOC.
Prefers visible-text source projection with column scoping and exact occurrence
ordinal disambiguation (handling duplicate text in table columns, inline markup
and long lines), falling back to 2D raw search and line/column estimate."
  (with-current-buffer source-buf
    (if (null loc)
        (point-min)
      (let* ((src-beg (plist-get loc :begin))
             (src-end (plist-get loc :end))
             (frac (or (plist-get loc :frac) 0.0))
             (hfrac (or (plist-get loc :hfrac) 0.0))
             (zone (plist-get loc :zone))
             (block-type (plist-get loc :block-type))
             (table-like (plist-get loc :table-like))
             (table-col (plist-get loc :table-col))
             (cursor-table-col (plist-get loc :cursor-table-col))
             (p-text (plist-get loc :p-text))
             (p-frac (or (plist-get loc :p-frac) frac))
             (col-text (plist-get loc :col-text))
             (col-frac (or (plist-get loc :col-frac) frac))
             (prefer-left (plist-get loc :prefer-left))
             (candidates (plist-get loc :candidates))
             (pmin (point-min))
             (pmax (point-max))
             (b (max pmin (min pmax (+ pmin (or src-beg 0)))))
             (e (if (integerp src-end)
                    (max b (min pmax (+ pmin src-end)))
                  pmax))
             ;; Trim trailing blank/newline characters from E so `frac = 1.0'
             ;; lands on the last content line instead of a trailing blank line.
             (e-trim (save-excursion
                       (goto-char e)
                       (skip-chars-backward " \t\r\n" b)
                       (max b (point))))
             (start-bol (save-excursion (goto-char b) (line-beginning-position)))
             (end-bol (save-excursion (goto-char e-trim) (line-beginning-position)))
             (steps (count-lines start-bol end-bol))
             (step (min steps (max 0 (round (* frac steps)))))
             (est-bol (save-excursion
                        (goto-char b)
                        (when (> step 0) (forward-line step))
                        (line-beginning-position)))
             (est-pos (save-excursion
                        (goto-char est-bol)
                        (let ((le (min e (line-end-position))))
                          (+ est-bol (round (* hfrac (max 0 (- le est-bol))))))))
             (proj (when (and candidates (memq zone '(block front-matter)))
                     (etaf-md--source-visible-projection
                      source-buf b e table-like block-type)))
             (col-proj (when (and proj (integerp table-col))
                         (etaf-md--projection-for-column proj table-col))))
        (or
         ;; For footnotes, prefer matches inside `[^label]:' definitions first.
         (when (eq zone 'footnote)
           (cl-loop for cand in candidates
                    thereis (etaf-md--search-nearest-in-range
                             cand b e est-pos t)))
         ;; For multi-column tables, resolve within the exact pipe column first
         ;; so identical cells across columns (and wrapped multi-line cells)
         ;; never jump to an earlier column.
         (when col-proj
           (cl-loop for cand in candidates
                    thereis (etaf-md--search-in-projection
                             col-proj cand (nth 5 cand) col-text col-frac
                             prefer-left)))
         ;; Visible-text block projection handles inline markup (`**test**',
         ;; `` `test` ``, `[test](url)'), soft wraps and same-line duplicates
         ;; deterministically by exact occurrence index and 2D position.
         (when proj
           (cl-loop for cand in candidates
                    thereis (etaf-md--search-in-projection
                             proj cand (nth 4 cand) p-text p-frac
                             prefer-left)))
         ;; Raw fallback inside [b, e] closest to 2D est-pos.
         (cl-loop for cand in candidates
                  thereis (etaf-md--search-nearest-in-range
                           cand b e est-pos nil))
         ;; Fallback when point is on a divider, image or blank margin.
         (when (and table-like (integerp cursor-table-col))
           (etaf-md--fallback-table-cell-pos
            source-buf est-bol cursor-table-col b e))
         (if (and (eq zone 'footnote)
                  (integerp (plist-get loc :fallback-begin)))
             (save-excursion
               (goto-char (max pmin (min pmax (+ pmin (plist-get loc :fallback-begin)))))
               (line-beginning-position))
           est-pos))))))

(defun etaf-md-goto-source ()
  "Jump from the current preview point to the matching line in the source file.
Selects the source window when already visible; otherwise switches to the
source buffer in the current window without creating an unexpected split.
Returns the target buffer position, or signals `user-error' when the preview
has no backing source."
  (declare (completion etaf-md--preview-command-p))
  (interactive)
  (let* ((session (etaf-md--current-session))
         (preview-buf (current-buffer))
         (pos (point))
         (source-buf (etaf-md--source-buffer-for session)))
    (unless (buffer-live-p source-buf)
      (user-error "This preview has no source file or buffer"))
    (let* ((loc (etaf-md--source-offset-at-point session preview-buf pos))
           (target-pos (etaf-md--target-pos-in-source source-buf loc))
           (win (get-buffer-window source-buf t)))
      (if (window-live-p win)
          (select-window win)
        (switch-to-buffer source-buf))
      (with-current-buffer source-buf
        (goto-char target-pos)
        (recenter)
        (etaf-md--pulse-line (point)))
      target-pos)))

(defun etaf-md--anchor-for-pos (session preview-buf runtime pos)
  "Return a block-relative viewport anchor plist for POS in PREVIEW-BUF."
  (let* ((entries (plist-get session :entries))
         (found (and entries (etaf-md--locate-entry-at entries runtime pos))))
    (if (null found)
        (list :zone 'top)
      (let ((match (plist-get found :match))
            (mb (plist-get found :match-bounds))
            (fb (plist-get found :first-bounds))
            (lb (plist-get found :last-bounds))
            (next-entry (plist-get found :next)))
        (cond
         ((and match mb)
          (list :zone 'block
                :ref (plist-get match :ref)
                :frac (etaf-md--preview-line-frac
                       preview-buf (car mb) (cdr mb) pos)))
         ((or (null fb) (< pos (car fb)))
          (list :zone 'top))
         ((and lb (> pos (cdr lb)))
          (list :zone 'tail
                :frac (etaf-md--preview-line-frac
                       preview-buf (cdr lb)
                       (with-current-buffer preview-buf (point-max)) pos)))
         (next-entry
          (list :zone 'block :ref (plist-get next-entry :ref) :frac 0.0))
         (t (list :zone 'top)))))))

(defun etaf-md--follow-source-window (session)
  "Return live source window when SESSION has follow-scroll enabled, else nil."
  (when (plist-get session :follow-scroll)
    (let ((source (plist-get session :source-buffer)))
      (and (buffer-live-p source) (get-buffer-window source t)))))

(defun etaf-md--capture-viewport-anchor (session preview-buf window)
  "Capture WINDOW's current scroll and cursor block anchors in PREVIEW-BUF.
Skips the lookup when follow-scroll has a visible source window, because
realignment syncs directly from the source window."
  (when (and (not (etaf-md--follow-source-window session))
             (buffer-live-p preview-buf)
             (window-live-p window)
             (eq (window-buffer window) preview-buf))
    (when-let* ((runtime (etaf-runtime-for-buffer preview-buf))
                ((etaf-runtime-mounted-p runtime)))
      (let* ((start (window-start window))
             (pt (window-point window))
             (start-a (etaf-md--anchor-for-pos session preview-buf runtime start)))
        (list :start start-a
              :point (if (= pt start)
                         start-a
                       (etaf-md--anchor-for-pos session preview-buf runtime pt)))))))

(defun etaf-md--resolve-anchor-position (session preview-buf runtime anchor)
  "Resolve ANCHOR to a column-0 buffer position in PREVIEW-BUF, or nil."
  (when (and anchor (buffer-live-p preview-buf) runtime)
    (with-current-buffer preview-buf
      (save-excursion
        (pcase (plist-get anchor :zone)
          ('top (point-min))
          ('block
           (when-let* ((ref (plist-get anchor :ref))
                       (bounds (etaf-host-ref-bounds runtime ref))
                       (pbeg (car bounds))
                       (pend (cdr bounds)))
             (let* ((lo (max (point-min) (min (point-max) pbeg)))
                    (content-end (etaf-md--block-content-end preview-buf lo pend))
                    (start-bol (progn (goto-char lo) (line-beginning-position)))
                    (end-bol (progn (goto-char content-end) (line-beginning-position)))
                    (total (count-lines start-bol end-bol))
                    (frac (or (plist-get anchor :frac) 0.0))
                    (step (min total (max 0 (round (* frac total))))))
               (goto-char start-bol)
               (when (> step 0) (forward-line step))
               (line-beginning-position))))
          ('tail
           (let ((last-end nil))
             (dolist (entry (plist-get session :entries))
               (when-let* ((ref (plist-get entry :ref))
                           (bounds (etaf-host-ref-bounds runtime ref)))
                 (setq last-end (cdr bounds))))
             (let* ((lo (max (point-min) (min (point-max) (or last-end (point-min)))))
                    (content-end (etaf-md--block-content-end preview-buf lo (point-max)))
                    (start-bol (progn (goto-char lo) (line-beginning-position)))
                    (end-bol (progn (goto-char content-end) (line-beginning-position)))
                    (total (count-lines start-bol end-bol))
                    (frac (or (plist-get anchor :frac) 0.0))
                    (step (min total (max 0 (round (* frac total))))))
               (goto-char start-bol)
               (when (> step 0) (forward-line step))
               (line-beginning-position)))))))))

(defun etaf-md--restore-viewport-anchor (session preview-buf window anchor)
  "Restore WINDOW's scroll and point in PREVIEW-BUF from ANCHOR."
  (when (and anchor (buffer-live-p preview-buf)
             (window-live-p window)
             (eq (window-buffer window) preview-buf))
    (when-let* ((runtime (etaf-runtime-for-buffer preview-buf))
                ((etaf-runtime-mounted-p runtime))
                (new-start (etaf-md--resolve-anchor-position
                            session preview-buf runtime
                            (plist-get anchor :start))))
      (let* ((raw-pt (or (etaf-md--resolve-anchor-position
                          session preview-buf runtime
                          (plist-get anchor :point))
                         new-start))
             (max-rows (max 0 (- (window-body-height window) 2)))
             (new-pt (with-current-buffer preview-buf
                       (save-excursion
                         (goto-char new-start)
                         (let* ((limit (progn
                                         (when (> max-rows 0)
                                           (forward-line max-rows))
                                         (line-beginning-position))))
                           (if (and (>= raw-pt new-start) (<= raw-pt limit))
                               raw-pt
                             new-start))))))
        (set-window-start window new-start nil)
        (set-window-point window new-pt)
        (when (eq (current-buffer) preview-buf)
          (goto-char new-pt))
        (force-window-update window)
        new-start))))

(defun etaf-md--realign-after-resize (session preview-buf window anchor)
  "Keep PREVIEW-BUF aligned with its source or prior reading position in WINDOW.
When follow-scroll is active with a visible source window, re-syncs directly to
the source window's visible top line; otherwise restores ANCHOR."
  (let* ((source (plist-get session :source-buffer))
         (source-win (and (plist-get session :follow-scroll)
                          (buffer-live-p source)
                          (get-buffer-window source t))))
    (cond
     ((window-live-p source-win)
      (etaf-md--follow-scroll-sync session t source-win))
     (anchor
      (etaf-md--restore-viewport-anchor session preview-buf window anchor)))))

(defun etaf-md--on-fit (session window)
  "Fit SESSION's viewport width to WINDOW and keep alignment.
Only writes `:viewport-width' before initial mount; once mounted,
`etaf-canvas-columns' already tracks viewport changes reactively inside Ebox's
single refit pass, avoiding a redundant full re-render on every drag settle."
  (when (window-live-p window)
    (let* ((cols (window-body-width window))
           (px-w (window-body-width window t))
           (prev-cols (plist-get session :fit-cols))
           (prev-px-w (plist-get session :fit-pixel-width))
           (buf (plist-get session :buffer))
           (rt (and (buffer-live-p buf) (etaf-runtime-for-buffer buf)))
           (mounted (and rt (etaf-runtime-mounted-p rt)))
           (char-w (and mounted
                        (plist-get (ignore-errors (etaf-display-metrics rt))
                                   :char-width)))
           (prev-char-w (plist-get session :fit-char-width))
           (width-changed (or (and prev-cols (not (equal cols prev-cols)))
                              (and prev-px-w (not (equal px-w prev-px-w)))
                              (and prev-char-w char-w (not (equal char-w prev-char-w))))))
      (plist-put session :fit-cols cols)
      (plist-put session :fit-pixel-width px-w)
      (when char-w (plist-put session :fit-char-width char-w))
      (unless mounted
        (unless (equal cols (etaf-md--read session :viewport-width))
          (etaf-md--write session :viewport-width cols)))
      (when mounted
        (let ((anchor (plist-get session :resize-anchor))
              (gen (plist-get session :locate-gen)))
          (plist-put session :resize-anchor nil)
          (when (or width-changed anchor)
            (etaf-next-tick
             (lambda ()
               (when (and (eql gen (plist-get session :locate-gen))
                          (buffer-live-p buf) (window-live-p window)
                          (eq (window-buffer window) buf))
                 (etaf-md--realign-after-resize session buf window anchor))))))))))

(defun etaf-md--adjust-width-preserving-view (session delta)
  "Adjust SESSION's width by DELTA while keeping visible position stable."
  (let* ((buf (plist-get session :buffer))
         (win (and (buffer-live-p buf) (get-buffer-window buf t)))
         (rt (and (buffer-live-p buf) (etaf-runtime-for-buffer buf)))
         (anchor (and (window-live-p win)
                      (etaf-md--capture-viewport-anchor session buf win)))
         (cap (etaf-md-adjust-width session delta)))
    (when (and rt (etaf-runtime-mounted-p rt) (window-live-p win))
      (etaf-runtime-flush rt)
      (etaf-md--realign-after-resize session buf win anchor))
    cap))

(defun etaf-md-wider ()
  "Widen the current preview's reading column."
  (declare (completion etaf-md--preview-command-p))
  (interactive)
  (let* ((session (etaf-md--current-session))
         (cap (etaf-md--adjust-width-preserving-view session 4)))
    (message "Reading width: %d (max %d)"
             (etaf-md--effective-width session) cap)))

(defun etaf-md-narrower ()
  "Narrow the current preview's reading column."
  (declare (completion etaf-md--preview-command-p))
  (interactive)
  (let* ((session (etaf-md--current-session))
         (cap (etaf-md--adjust-width-preserving-view session -4)))
    (message "Reading width: %d (max %d)"
             (etaf-md--effective-width session) cap)))

(defun etaf-md--reading-heading-index (session)
  "Return the index of SESSION's heading at or before point's line, or 0."
  (let* ((buf (plist-get session :buffer))
         (eol (if (buffer-live-p buf)
                  (with-current-buffer buf (line-end-position))
                1))
         (found 0))
    (dolist (cell (etaf-md--heading-positions session))
      (when (<= (cdr cell) eol)
        (setq found (car cell))))
    found))

(defun etaf-md--sync-active-heading (session)
  "Sync SESSION's `:toc-active' ref to point when the TOC side window is open."
  (when (and session (etaf-md--read session :toc-open))
    (let ((idx (etaf-md--reading-heading-index session)))
      (unless (eql idx (etaf-md--read session :toc-active))
        (etaf-md--write session :toc-active idx)
        (etaf-md--sync-outline-viewport session idx nil)))))

(defun etaf-md--outline-buffer-name (session)
  "Return the side-window outline buffer name for SESSION."
  (let ((count (length (etaf-md-outline session))))
    (if (> count 0)
        (format "*ETAF Outline* (%d)" count)
      "*ETAF Outline*")))

(defun etaf-md--outline-background (session)
  "Return the canvas background color for SESSION's outline side window.
Uses `:panel' for fixed palettes (`dark', `light', `sepia') so the sidebar
keeps a calm distinct tint from top to bottom, and nil for `auto' so the
active Emacs theme background stays intact."
  (when (eq (etaf-md--read session :theme-source) 'palette)
    (etaf-md--palette-value (etaf-md--session-palette session) :panel)))

(defun etaf-md--outline-close (session)
  "Close and clean up SESSION's independent TOC side window."
  (when session
    (let* ((preview-buf (plist-get session :buffer))
           (preview-win (and (buffer-live-p preview-buf)
                             (get-buffer-window preview-buf t)))
           (buf (plist-get session :toc-buffer))
           (win (and (buffer-live-p buf) (get-buffer-window buf t)))
           (was-selected (and (window-live-p win) (eq win (selected-window)))))
      (when (etaf-md--ref session :toc-open)
        (etaf-md--write session :toc-open nil))
      (plist-put session :toc-buffer nil)
      (when (buffer-live-p buf)
        (when (and (window-live-p win) (not (one-window-p t)))
          (ignore-errors (delete-window win)))
        (when-let* ((rt (etaf-runtime-for-buffer buf)))
          (ignore-errors (etaf-unmount rt)))
        (ignore-errors (kill-buffer buf)))
      (when (and was-selected (window-live-p preview-win))
        (select-window preview-win)))))

(etaf-define-component etaf-md--outline-app (&key session)
  "Independent side-window TOC panel synced reactively with SESSION."
  :setup
  (etaf-theme-provide
   (etaf-computed
    (lambda ()
      (etaf-md-theme-tokens (etaf-md--read session :theme)
                            (etaf-md--session-palette session)))))
  :render
  (let* ((env (etaf-md--env session))
         (outline (etaf-md-outline session))
         (active (or (etaf-md--read session :toc-active) 0))
         (ink (etaf-md--env-color env :ink))
         (muted (etaf-md--env-color env :muted))
         (faint (or (etaf-md--palette-value (plist-get env :palette) :faint) muted))
         (border (etaf-md--env-color env :border))
         (accent (etaf-md--env-color env :accent))
         (accent-soft (etaf-md--env-color env :accent-soft))
         (hover (when (if (plist-member env :link-hover) (plist-get env :link-hover) t)
                  (etaf-md--env-color env :panel2)))
         (min-lv (if outline (apply #'min (mapcar #'car outline)) 1))
         (count (length outline))
         (bg (etaf-md--outline-background session))
         (rest-border (or bg (etaf-md--env-color env :bg))))
    (etaf-node
     'column
     (append
      (list :width '(vw 100)
            :color ink
            :item-gap '(lh 0)
            :aria-label "文档目录"
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
      (when bg (list :background-color bg)))
     (append
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
                                 :help-echo "关闭目录侧窗（T 或 q）"
                                 :on-press (lambda () (etaf-md--outline-close session)))
                           (when hover (list :hover-style (list :background-color hover))))
                          (list "×")))))
       (etaf-node 'box (list :width 'stretch :height '(lh 1)) nil))
      (if (null outline)
          (list (etaf-node 'box (list :width 'stretch :padding '((lh 0) (ch 2)))
                           (list (etaf-node 'text (list :color muted)
                                            (list "（文档暂无标题）")))))
        (cl-loop for entry in outline
                 for idx from 0
                 for lv = (nth 0 entry)
                 for text = (nth 1 entry)
                 for is-active = (eql idx active)
                 for indent = (* 2 (min 3 (max 0 (- lv min-lv))))
                 collect
                 (let ((target-idx idx))
                   (etaf-node
                    'box
                    (append
                     (list :key target-idx
                           :ref (etaf-md--toc-row-ref target-idx)
                           :width 'stretch
                           :box-sizing 'border-box
                           :padding (list '(lh 0) '(ch 1) '(lh 0) (list 'ch (+ 2 indent)))
                           :border-left (list '(px 2) 'solid
                                              (if is-active accent rest-border))
                           :wrap-mode 'word
                           :color (cond (is-active accent)
                                        ((= lv min-lv) ink)
                                        (t muted))
                           :font-weight (when (or is-active (= lv min-lv)) 'bold)
                           :role 'link :tab-index 0
                           :pointer (unless is-active 'hand)
                           :aria-selected (when is-active t)
                           :help-echo (format "跳转到 %s" text)
                           :on-press (lambda ()
                                       (let ((etaf-md--locating-from-outline t))
                                         (etaf-md-locate session target-idx))))
                     (when is-active (list :background-color accent-soft))
                     (when (and hover (not is-active))
                       (list :hover-style (list :background-color hover))))
                    (list (etaf-node 'text nil (list text)))))))))))

(defun etaf-md--outline-clamp-point (win new-start)
  "Keep WIN's `window-point' inside its scrolled viewport from NEW-START.
Prevents wheel or pixel-scroll drivers from leaving an off-screen point that
would snap the outline back on the next hover or reactive repaint."
  (when (and (window-live-p win)
             (eq (window-buffer win) (current-buffer)))
    (let ((pt (window-point win))
          (end (window-end win nil)))
      (when (or (< pt new-start) (and end (> end new-start) (> pt end)))
        (set-window-point win new-start)))))

(defun etaf-md--outline-open (session)
  "Open SESSION's independent TOC side window on `etaf-md-toc-side'."
  (let* ((preview-buf (plist-get session :buffer))
         (preview-win (or (and (buffer-live-p preview-buf)
                               (get-buffer-window preview-buf t))
                          (selected-window)))
         (side (if (eq etaf-md-toc-side 'right) 'right 'left))
         (width (etaf-md--clamp-toc-width etaf-md-toc-width))
         (alist `((side . ,side) (slot . 0) (window-width . ,width)
                  (preserve-size . (t . nil))))
         (existing (plist-get session :toc-buffer))
         (active-idx (etaf-md--reading-heading-index session))
         (toc-keys (list (list "q" (lambda () (interactive) (etaf-md--outline-close session)) "关闭目录侧窗")
                         (list "T" #'etaf-md-toggle-toc "开关目录侧窗")
                         (list "n" #'etaf-md-next-heading "下一个标题")
                         (list "p" #'etaf-md-previous-heading "上一个标题")
                         (list "t" #'etaf-md-cycle-theme "切换配色"))))
    (etaf-md--write session :toc-active active-idx)
    (etaf-md--write session :toc-open t)
    (let ((buf (if (buffer-live-p existing)
                   (progn
                     (display-buffer-in-side-window existing alist)
                     existing)
                 (let ((b (etaf-app-open
                           (generate-new-buffer-name
                            (etaf-md--outline-buffer-name session))
                           (etaf-view (etaf-md--outline-app :session session
                                                            :keys toc-keys))
                           :state session
                           :mode-line t
                           :display (lambda (obuf)
                                      (display-buffer-in-side-window obuf alist))
                           :background (lambda () (etaf-md--outline-background session))
                           :on-close (lambda ()
                                       (when (etaf-md--ref session :toc-open)
                                         (etaf-md--write session :toc-open nil))
                                       (plist-put session :toc-buffer nil)))))
                   (with-current-buffer b
                     (setq-local cursor-in-non-selected-windows nil)
                     (setq-local left-fringe-width 0)
                     (setq-local right-fringe-width 0)
                     (add-hook 'window-scroll-functions
                               #'etaf-md--outline-clamp-point nil t))
                   (plist-put session :toc-buffer b)
                   b))))
      (when-let* ((owin (get-buffer-window buf t)))
        (set-window-fringes owin 0 0))
      (when (window-live-p preview-win)
        (select-window preview-win))
      (etaf-md--sync-outline-viewport session active-idx nil)
      buf)))

(defun etaf-md-toggle-toc (&optional arg)
  "Toggle the independent `*ETAF Outline*' side window for the current preview.
Opens on `etaf-md-toc-side' (default `left') with width `etaf-md-toc-width'.
With prefix ARG, open when positive and close otherwise.  Returns non-nil when
open and nil when closed."
  (declare (completion etaf-md--preview-command-p))
  (interactive "P")
  (let* ((session (etaf-md--current-session))
         (effective (or arg current-prefix-arg))
         (open-p (and (etaf-md--read session :toc-open)
                      (buffer-live-p (plist-get session :toc-buffer))
                      (get-buffer-window (plist-get session :toc-buffer) t)))
         (next (if effective (> (prefix-numeric-value effective) 0)
                 (not open-p))))
    (if next
        (progn
          (etaf-md--outline-open session)
          (message "目录侧窗：已打开")
          t)
      (etaf-md--outline-close session)
      (message "目录侧窗：已关闭")
      nil)))

(defun etaf-md-toggle-spoilers (&optional arg)
  "Reveal or hide all `!!spoiler!!' spans in the current preview.
With prefix ARG (or interactive prefix argument), reveal when positive and
hide otherwise.  Return new state."
  (declare (completion etaf-md--preview-command-p))
  (interactive "P")
  (let* ((session (etaf-md--current-session))
         (effective (or arg current-prefix-arg))
         (next (if effective (> (prefix-numeric-value effective) 0)
                 (not (etaf-md--read session :reveal-spoilers)))))
    (etaf-md--write session :reveal-spoilers (and next t))
    (message "所有遮罩内容：%s" (if next "已显示" "已隐藏"))
    (and next t)))

(defun etaf-md--help-at-point ()
  "Return resolved `help-echo' string at point, or nil."
  (let ((help (get-text-property (point) 'help-echo)))
    (cond
     ((stringp help) help)
     ((functionp help)
      (ignore-errors (funcall help (selected-window) (current-buffer) (point)))))))

(defun etaf-md-preview-link ()
  "Preview the link, wiki-link, anchor or Emacs symbol at point in-place.
Calling again while the preview card is open dismisses it if point has no
previewable target.  Returns the preview plist or nil."
  (declare (completion etaf-md--preview-command-p))
  (interactive)
  (let* ((session (etaf-md--current-session))
         (help (etaf-md--help-at-point))
         (preview nil))
    (cond
     ;; Emacs symbol chip (`Emacs 符号：NAME（...）')
     ((and (stringp help)
           (string-match "\\`Emacs 符号：\\([^（\n]+\\)" help))
      (let* ((name (string-trim (match-string 1 help)))
             (info (etaf-md-assets--compute-symbol (list :name name)))
             (sig (plist-get info :signature))
             (doc (or (plist-get info :doc)
                      (and (plist-get info :missing) "当前 Emacs 中未定义该符号")
                      "（无文档字符串）")))
        (setq preview
              (list :title (format "ƒ %s" name)
                    :kind (or (plist-get info :kind) "符号")
                    :body (if sig (format "%s\n%s" sig doc) doc)
                    :on-open (lambda () (etaf-md-assets-open-symbol session name))))))
     ;; Wiki-link (`[[target#anchor]]')
     ((and (stringp help)
           (string-match "\\`\\[\\[\\([^]#|]+\\)\\(?:#\\([^]|]+\\)\\)?\\]\\]\\'" help))
      (let* ((raw-target (match-string 1 help))
             (anchor (match-string 2 help))
             (target (string-trim raw-target))
             (dir (or (plist-get session :dir) default-directory))
             (file (cl-find-if #'file-readable-p
                               (list (expand-file-name target dir)
                                     (expand-file-name (concat target ".md") dir)
                                     (expand-file-name (concat target ".markdown") dir))))
             (snippet (if file
                          (with-temp-buffer
                            (insert-file-contents file nil 0 800)
                            (string-trim (buffer-string)))
                        (format "未找到本地文档：%s" target))))
        (setq preview
              (list :title (if anchor (format "%s #%s" target anchor) target)
                    :kind "双链"
                    :body (if (> (length snippet) 360)
                              (concat (substring snippet 0 357) "...")
                            snippet)
                    :on-open (when file (lambda () (etaf-md--open-url session file)))))))
     ;; Anchor link (`#slug')
     ((and (stringp help) (string-prefix-p "#" help))
      (let* ((slug (substring help 1))
             (outline (etaf-md-outline session))
             (idx (cl-position slug outline :key (lambda (e) (nth 2 e)) :test #'equal)))
        (when idx
          (let ((entry (nth idx outline)))
            (setq preview
                  (list :title (nth 1 entry)
                        :kind (format "H%d 锚点" (nth 0 entry))
                        :body (format "文内标题锚点 #%s（点击「打开」跳转）" slug)
                        :on-open (lambda () (etaf-md-locate session idx))))))))
     ;; Local markdown/file link or remote URL
     ((and (stringp help) (not (string-blank-p help)))
      (let* ((clean (car (split-string help "#")))
             (local (and (not (etaf-md--remote-url-p clean))
                         (etaf-md-assets--safe-path session clean))))
        (cond
         ((and local (file-readable-p local) (not (file-directory-p local)))
          (let ((snippet (with-temp-buffer
                           (insert-file-contents local nil 0 800)
                           (string-trim (buffer-string)))))
            (setq preview
                  (list :title (file-name-nondirectory local)
                        :kind "本地文档"
                        :body (if (> (length snippet) 360)
                                  (concat (substring snippet 0 357) "...")
                                snippet)
                        :on-open (lambda () (etaf-md--open-url session help))))))
         ((etaf-md--remote-url-p help)
          (setq preview
                (list :title help
                      :kind "外部链接"
                      :body (format "点击「打开」将在系统浏览器中访问 %s" help)
                      :on-open (lambda () (etaf-md--open-url session help)))))))))
    (let ((current (etaf-md--read session :link-preview)))
      (cond
       ((and preview current (equal (plist-get current :key) help))
        (etaf-md--write session :link-preview nil)
        (when-let* ((buf (plist-get session :buffer))
                    (rt (and (buffer-live-p buf) (etaf-runtime-for-buffer buf))))
          (etaf-runtime-flush rt))
        (message "已关闭链接预览")
        nil)
       (preview
        (let ((tagged (plist-put (copy-sequence preview) :key help)))
          (etaf-md--write session :link-preview tagged)
          (when-let* ((buf (plist-get session :buffer))
                      (rt (and (buffer-live-p buf) (etaf-runtime-for-buffer buf))))
            (etaf-runtime-flush rt))
          tagged))
       (current
        (etaf-md--write session :link-preview nil)
        (when-let* ((buf (plist-get session :buffer))
                    (rt (and (buffer-live-p buf) (etaf-runtime-for-buffer buf))))
          (etaf-runtime-flush rt))
        (message "已关闭链接预览")
        nil)
       (t
        (message "光标处没有可预览的链接、双链或符号")
        nil)))))

(defun etaf-md--cleanup-source-kill-hook (session)
  "Remove the preview teardown hook from SESSION's source buffer, if live."
  (when-let* ((src (plist-get session :source-buffer))
              ((buffer-live-p src)))
    (with-current-buffer src
      (remove-hook 'kill-buffer-hook #'etaf-md--preview-source-killed t))))

(defun etaf-md-close ()
  "Unmount the current preview, kill its buffer and restore the window cleanly.
When opened in a split created by `etaf-md-preview' or `etaf-md-toggle-split',
removes only that split window so unrelated panes stay intact.  When opened in
a single window via `etaf-md-open', restores the originating buffer in the same
window without deleting it.  Signals `user-error' when the current buffer is
not a preview."
  (declare (completion etaf-md--preview-command-p))
  (interactive)
  (let* ((session (etaf-md--current-session))
         (preview-buf (current-buffer))
         (window (or (get-buffer-window preview-buf t) (selected-window)))
         (split-p (and (window-live-p window)
                       (window-parameter window 'etaf-md-preview-split)))
         (source-buf (plist-get session :source-buffer))
         (source-win (and (buffer-live-p source-buf)
                          (get-buffer-window source-buf t)))
         (source-split-p (and (window-live-p source-win)
                              (window-parameter source-win 'etaf-md-source-split)))
         (origin-buf (or (let ((ob (plist-get session :origin-buffer)))
                           (and (buffer-live-p ob)
                                (not (eq ob preview-buf))
                                ob))
                         (and (buffer-live-p source-buf)
                              (not (eq source-buf preview-buf))
                              source-buf))))
    (etaf-md--outline-close session)
    (etaf-md--cleanup-source-kill-hook session)
    (etaf-md--cancel-asset-timer session)
    (etaf-app-close)
    (cond
     ((and (or split-p source-split-p)
           (window-live-p window)
           (not (one-window-p t)))
      (when (window-live-p source-win)
        (set-window-parameter source-win 'etaf-md-source-split nil))
      (ignore-errors (delete-window window)))
     ((and (window-live-p window) (buffer-live-p origin-buf))
      (set-window-buffer window origin-buf)))))

(defun etaf-md-toggle-split ()
  "Toggle between single-window full reading view and side-by-side editing.
From a single-window preview, splits the source buffer on the left synced to
the current line with follow-scroll enabled.  When the source is already shown
beside the preview, collapses back to a full-width reading window.  Returns
non-nil when side-by-side split is active."
  (declare (completion etaf-md--preview-command-p))
  (interactive)
  (let* ((session (etaf-md--current-session))
         (preview-buf (current-buffer))
         (preview-win (selected-window))
         (source-buf (etaf-md--source-buffer-for session)))
    (unless (buffer-live-p source-buf)
      (user-error "This preview has no source file or buffer"))
    (let ((src-win (get-buffer-window source-buf)))
      (if (and (window-live-p src-win) (not (eq src-win preview-win)))
          ;; Currently split: collapse back to single-window full preview.
          (let ((was-split (or (window-parameter src-win 'etaf-md-source-split)
                               (window-parameter preview-win 'etaf-md-preview-split))))
            (etaf-md--cleanup-source-kill-hook session)
            (plist-put session :follow-scroll nil)
            (set-window-parameter preview-win 'etaf-md-preview-split nil)
            (set-window-parameter src-win 'etaf-md-source-split nil)
            (when (and was-split (not (one-window-p t)))
              (ignore-errors (delete-window src-win)))
            (when (window-live-p preview-win)
              (select-window preview-win))
            (message "已切回单窗阅读")
            nil)
        ;; Currently single-window: open source buffer on the left beside preview.
        (let* ((loc (etaf-md--source-offset-at-point session preview-buf (point)))
               (target-pos (etaf-md--target-pos-in-source source-buf loc))
               (left-win (split-window preview-win nil 'left)))
          (set-window-parameter left-win 'etaf-md-source-split t)
          (set-window-buffer left-win source-buf)
          (plist-put session :source-buffer source-buf)
          (etaf-md--live-start session source-buf)
          (with-current-buffer source-buf
            (add-hook 'kill-buffer-hook #'etaf-md--preview-source-killed nil t))
          (with-selected-window left-win
            (goto-char target-pos)
            (recenter))
          (plist-put session :follow-scroll t)
          (when (window-live-p preview-win)
            (select-window preview-win))
          (message "已开启双栏对照（再按 v 收起源码，按 e 跳去编辑）")
          t)))))

;;; ---------------------------------------------------------------------------
;;; Window fitting
;;; ---------------------------------------------------------------------------

(defun etaf-md--effective-width (session)
  "Return the reading width the window actually gives SESSION.
The session's `:width' is the maximum measure; a narrower window fills the
available columns minus side gutters instead."
  (let* ((buffer (plist-get session :buffer))
         (window (and (buffer-live-p buffer) (get-buffer-window buffer t)))
         (cap (etaf-md--read session :width)))
    (if (window-live-p window)
        (min cap (max 24 (- (window-body-width window)
                            (* 2 etaf-md--measure-gutter))))
      cap)))

;;; ---------------------------------------------------------------------------
;;; Following the source file
;;; ---------------------------------------------------------------------------

(defconst etaf-md--follow-tick 0.016
  "Seconds between a source change and its repaint (one frame at 60 Hz).
A change only schedules a repaint when none is pending, so a burst of
keystrokes coalesces into one repaint per frame.")

(defconst etaf-md--follow-max-wait 0.06
  "Maximum seconds to defer a live repaint while keyboard input is pending.
Yielding when `(input-pending-p)' keeps rapid typing bursts and IME preedit
completely smooth while guaranteeing at least ~16 fps live updates.")

(defconst etaf-md--follow-retry 0.2
  "Seconds between attempts to watch a file that is temporarily missing.")

(defvar etaf-md--follow-sessions (make-hash-table :test #'equal)
  "Displayed preview sessions by canonical source file name.")

(defvar etaf-md--follow-watches (make-hash-table :test #'equal)
  "Change watches by canonical source file name.")

(defvar etaf-md--follow-timers (make-hash-table :test #'equal)
  "Pending repaint timers by canonical source file name.")

(defvar etaf-md--follow-deadlines (make-hash-table :test #'equal)
  "Maximum defer timestamps for pending repaints by canonical file name.")

(defvar etaf-md--live-sources (make-hash-table :test #'equal)
  "Visiting buffers followed for unsaved edits by canonical source file name.")

(defun etaf-md--record-dirty-span (session beg end old-len)
  "Merge an `after-change-functions' edit (BEG END OLD-LEN) into SESSION.
Positions BEG and END are 1-based buffer coordinates in the updated buffer;
accumulates 0-based `(MIN-BEG OLD-END NEW-END)' relative to last published text."
  (let* ((b (max 0 (1- beg)))
         (e (max b (1- end)))
         (prev (plist-get session :dirty-span)))
    (plist-put
     session :dirty-span
     (if (null prev)
         (list b (+ b old-len) e)
       (pcase-let* ((`(,p-beg ,p-old-end ,p-new-end) prev)
                    (min-beg (min p-beg b))
                    (after-old (+ b old-len)))
         (if (<= after-old p-new-end)
             (list min-beg p-old-end (+ p-new-end (- (- e b) old-len)))
           (list min-beg (+ p-old-end (- after-old p-new-end)) e)))))))

(defun etaf-md--live-changed (beg end old-len)
  "Record a source buffer edit (BEG END OLD-LEN) and schedule preview repaint."
  (when buffer-file-name
    (let ((file (etaf-md--canonical-file buffer-file-name)))
      (when-let* ((session (gethash file etaf-md--follow-sessions)))
        (etaf-md--record-dirty-span session beg end old-len)
        (etaf-md--follow-schedule file)))))

(defun etaf-md--live-start (session &optional source-buffer)
  "Make SESSION follow unsaved edits and scrolls of its visiting buffer.
When SOURCE-BUFFER is given, attach directly to it; otherwise look up any
buffer visiting SESSION's canonical or literal file path (resolving symlinks)."
  (when-let* ((path (plist-get session :file))
              (file (etaf-md--canonical-file path))
              (buffer (or (and (buffer-live-p source-buffer) source-buffer)
                          (find-buffer-visiting file)
                          (find-buffer-visiting path))))
    (puthash file buffer etaf-md--live-sources)
    (plist-put session :source-buffer buffer)
    (with-current-buffer buffer
      (plist-put session :live-tick (buffer-chars-modified-tick))
      (add-hook 'after-change-functions #'etaf-md--live-changed nil t)
      (add-hook 'post-command-hook #'etaf-md--follow-scroll-command nil t)
      (add-hook 'window-scroll-functions #'etaf-md--follow-scroll-window nil t))))

(defun etaf-md--live-stop (file)
  "Stop following unsaved edits of FILE and drop its visiting buffer."
  (when-let* ((file (etaf-md--canonical-file file))
              (buffer (gethash file etaf-md--live-sources)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (remove-hook 'after-change-functions #'etaf-md--live-changed t)
        (remove-hook 'post-command-hook #'etaf-md--follow-scroll-command t)
        (remove-hook 'window-scroll-functions #'etaf-md--follow-scroll-window t)))
    (remhash file etaf-md--live-sources)))

(defun etaf-md--follow-visit ()
  "Start following the file the buffer just opened, when a preview shows it.
A preview can be opened before its markdown is, and a reader who opens the
file afterwards expects the preview to follow that buffer as they type.  The
hook is buffer-local where it lands, so closing the file takes it away."
  (when-let* ((file (and buffer-file-name
                         (etaf-md--canonical-file buffer-file-name)))
              (session (gethash file etaf-md--follow-sessions)))
    (etaf-md--live-start session (current-buffer))))

(defconst etaf-md--follow-attempts 3
  "Times to retry a watch while its file is missing.
An editor that saves atomically deletes the old file before it renames the
new one over the name, and the watch must be re-armed once the name exists
again; each retry waits `etaf-md--follow-retry'.")

(defun etaf-md--follow-saved ()
  "Repaint the preview of the file being saved, when one is open."
  (when buffer-file-name
    (let ((file (etaf-md--canonical-file buffer-file-name)))
      (when-let* ((session (gethash file etaf-md--follow-sessions)))
        ;; Saving settles any provisional live unclosed fence with exact parse.
        (plist-put session :live-tick nil)
        (plist-put session :dirty-span nil)
        (etaf-md--follow-schedule file t)))))

(defun etaf-md--follow-watch (file)
  "Arm, or re-arm, FILE's change watch and return its descriptor.
Return nil when the file cannot be watched right now, for example because it
is missing; the caller retries.  The watch follows the file's own node, so an
atomic replace leaves it watching a node nothing writes again, and every event
re-arms it."
  (when-let* ((old (gethash file etaf-md--follow-watches)))
    (ignore-errors (file-notify-rm-watch old))
    (remhash file etaf-md--follow-watches))
  (when-let* ((watch
               (condition-case nil
                   (file-notify-add-watch
                    file '(change)
                    (lambda (event)
                      (etaf-md--follow-event file event)))
                 (file-error nil))))
    (puthash file watch etaf-md--follow-watches)
    watch))

(defun etaf-md--follow-event (file event)
  "Repaint FILE's preview for EVENT, and re-arm the watch only when it died."
  (let ((action (nth 1 event)))
    (when (memq action '(changed created renamed))
      (when-let* ((session (gethash file etaf-md--follow-sessions)))
        (plist-put session :live-tick nil)
        (plist-put session :dirty-span nil))
      (etaf-md--follow-schedule file))
    (when (memq action '(stopped deleted))
      (etaf-md--follow-rearm file etaf-md--follow-attempts))))

(defun etaf-md--follow-rearm (file attempts)
  "Watch FILE again, retrying ATTEMPTS times while it is missing."
  (when (gethash file etaf-md--follow-sessions)
    (unless (etaf-md--follow-watch file)
      (when (> attempts 0)
        (run-with-timer etaf-md--follow-retry nil
                        #'etaf-md--follow-rearm file (1- attempts))))))

(defun etaf-md--follow-register (session)
  "Make the displayed SESSION follow its source file.
A session created from text has no file, so it never follows anything."
  (when-let* ((path (plist-get session :file)))
    (let ((file (etaf-md--canonical-file path)))
      (puthash file session etaf-md--follow-sessions)
      (etaf-md--follow-watch file)
      (etaf-md--live-start session)
      ;; The mount already published this text, so a follow that finds it
      ;; unchanged has nothing to repaint.
      (plist-put session :live-text (etaf-md--session-text session))
      (add-hook 'after-save-hook #'etaf-md--follow-saved t)
      (add-hook 'find-file-hook #'etaf-md--follow-visit))))

(defun etaf-md--follow-unregister (file)
  "Stop following FILE: drop its watch, pending repaint and session."
  (when-let* ((file (etaf-md--canonical-file file)))
    (when-let* ((session (gethash file etaf-md--follow-sessions)))
      (etaf-md--cancel-asset-timer session)
      (when-let* ((m (plist-get session :follow-scroll-marker)))
        (when (markerp m) (set-marker m nil))
        (plist-put session :follow-scroll-marker nil))
      (when-let* ((tm (plist-get session :follow-scroll-timer)))
        (when (timerp tm) (cancel-timer tm))
        (plist-put session :follow-scroll-timer nil))
      (plist-put session :follow-scroll-pending nil))
    (etaf-md--live-stop file)
    (when-let* ((watch (gethash file etaf-md--follow-watches)))
      (ignore-errors (file-notify-rm-watch watch))
      (remhash file etaf-md--follow-watches))
    (when-let* ((timer (gethash file etaf-md--follow-timers)))
      (cancel-timer timer)
      (remhash file etaf-md--follow-timers))
    (remhash file etaf-md--follow-deadlines)
    (remhash file etaf-md--follow-sessions)
    (when (zerop (hash-table-count etaf-md--follow-sessions))
      (remove-hook 'after-save-hook #'etaf-md--follow-saved)
      (remove-hook 'find-file-hook #'etaf-md--follow-visit))))

;;; ---------------------------------------------------------------------------
;;; Following the source's scroll
;;; ---------------------------------------------------------------------------

(defun etaf-md--follow-scroll-session ()
  "Return the preview session the current buffer scrolls for, or nil.
Run from the markdown buffer, this is the preview following its file; run from
the preview, it is the preview itself."
  (or (let ((state (etaf-app-state)))
        (and (listp state)
             (etaf-ref-p (plist-get state :document))
             state))
      (and buffer-file-name
           (gethash (etaf-md--canonical-file buffer-file-name)
                    etaf-md--follow-sessions))))

(defun etaf-md-follow-scroll (&optional arg)
  "Toggle scrolling the preview along with its source buffer.
While it is on, scrolling the source window moves the preview proportionally to
the matching block and line.  Only the source's scrolling follows; scrolling
the preview itself stays free.  Run it from the markdown buffer or from its
preview.  With prefix ARG (or interactive prefix argument), turn the follow on
when positive and off otherwise.  Return the new state.  Signal `user-error'
when no preview shows the current buffer."
  (declare (completion etaf-md--follow-command-p))
  (interactive "P")
  (let ((session (or (etaf-md--follow-scroll-session)
                     (user-error "No preview shows the current buffer")))
        (effective (or arg current-prefix-arg)))
    (let ((on (if effective
                  (> (prefix-numeric-value effective) 0)
                (not (plist-get session :follow-scroll)))))
      (plist-put session :follow-scroll (and on t))
      (when-let* ((m (plist-get session :follow-scroll-marker)))
        (when (markerp m) (set-marker m nil)))
      (when-let* ((tm (plist-get session :follow-scroll-timer)))
        (when (timerp tm) (cancel-timer tm)))
      (plist-put session :follow-scroll-timer nil)
      (plist-put session :follow-scroll-pending nil)
      (plist-put session :follow-scroll-marker nil)
      (plist-put session :follow-scroll-line nil)
      (when on
        (etaf-md--follow-scroll-sync session t))
      (message "Preview follows the source scroll: %s" (if on "on" "off"))
      (plist-get session :follow-scroll))))

(defun etaf-md--follow-scroll-command ()
  "Move the current buffer's preview along with its source window.
Runs from the source buffer's `post-command-hook' in O(1) using a buffer
marker so typing bursts never scan line numbers from buffer start."
  (when buffer-file-name
    (when-let* ((session (gethash (etaf-md--canonical-file buffer-file-name)
                                  etaf-md--follow-sessions))
                ((plist-get session :follow-scroll)))
      (etaf-md--follow-scroll-sync session))))

(defun etaf-md--follow-scroll-window (window new-start)
  "Move the preview along when source WINDOW scrolls to NEW-START.
Runs from buffer-local `window-scroll-functions', covering mouse wheel and
trackpad scrolling as well as keyboard commands.  Defers the cross-window
`set-window-start' to a 0-second coalesced timer so it runs outside
`redisplay_internal' and macOS/GUI ports always repaint the unselected
preview window."
  (when (and buffer-file-name (window-live-p window))
    (when-let* ((session (gethash (etaf-md--canonical-file buffer-file-name)
                                  etaf-md--follow-sessions))
                ((plist-get session :follow-scroll)))
      (plist-put session :follow-scroll-pending (cons window new-start))
      (unless (timerp (plist-get session :follow-scroll-timer))
        (plist-put
         session :follow-scroll-timer
         (run-with-timer
          0 nil
          (lambda ()
            (plist-put session :follow-scroll-timer nil)
            (when-let* ((pending (plist-get session :follow-scroll-pending)))
              (plist-put session :follow-scroll-pending nil)
              (when (and (plist-get session :follow-scroll)
                         (window-live-p (car pending)))
                (etaf-md--follow-scroll-sync
                 session nil (car pending) (cdr pending)))))))))))

(defun etaf-md--follow-scroll-same-line-p (source marker pos)
  "Return non-nil when MARKER and POS sit on the same line of SOURCE in O(1)."
  (and (markerp marker)
       (eq (marker-buffer marker) source)
       (let ((mpos (marker-position marker)))
         (and (integerp mpos)
              (or (= mpos pos)
                  (with-current-buffer source
                    (= (save-excursion (goto-char mpos) (line-beginning-position))
                       (save-excursion (goto-char pos) (line-beginning-position)))))))))

(defun etaf-md--follow-scroll-sync (session &optional force source-win start-pos)
  "Scroll SESSION's window to match its source window's visible top line.
When FORCE is non-nil, syncs even if the source line marker did not move.
Interpolates proportionally inside tall blocks and always snaps
`set-window-start' to column 0 of the target row so the left gutter stays
intact."
  (let* ((source (plist-get session :source-buffer))
         (buffer (plist-get session :buffer))
         (source-window (or source-win
                            (and (buffer-live-p source)
                                 (get-buffer-window source t))))
         (window (and (buffer-live-p buffer) (get-buffer-window buffer t)))
         (start (or start-pos (and source-window (window-start source-window)))))
    (when (and start window (buffer-live-p source)
               (eq (window-buffer window) buffer))
      (let ((marker (plist-get session :follow-scroll-marker)))
        (when (or force (not (etaf-md--follow-scroll-same-line-p source marker start)))
          (with-current-buffer source
            (let ((bol (save-excursion (goto-char start) (line-beginning-position))))
              (if (and (markerp marker) (eq (marker-buffer marker) source))
                  (set-marker marker bol)
                (plist-put session :follow-scroll-marker (copy-marker bol)))))
          (let* ((offset (max 0 (1- start)))
                 (match (etaf-md--block-entry-at session offset)))
            (cond
             ((eq match 'top)
              (let ((top (with-current-buffer buffer (point-min))))
                (set-window-start window top nil)
                (set-window-point window top)
                (force-window-update window)
                top))
             ((consp match)
              (let* ((entry (car match))
                     (ref (plist-get entry :ref))
                     (block (plist-get entry :block))
                     (runtime (etaf-runtime-for-buffer buffer))
                     (bounds (and runtime ref (etaf-host-ref-bounds runtime ref)))
                     (position (or (car-safe bounds)
                                   (and runtime ref (etaf-host-ref-position runtime ref)))))
                (when position
                  (let* ((src-beg (plist-get block :begin))
                         (src-end (plist-get block :end))
                         (extra-lines
                          (if (and (consp bounds)
                                   (integerp src-beg) (integerp src-end)
                                   (> offset src-beg) (< offset src-end))
                              (let* ((pmin (with-current-buffer source (point-min)))
                                     (pmax (with-current-buffer source (point-max)))
                                     (sb (max pmin (min pmax (+ pmin src-beg))))
                                     (se (max sb (min pmax (+ pmin src-end))))
                                     (sp (max sb (min se start)))
                                     (src-frac
                                      (with-current-buffer source
                                        (save-excursion
                                          (let* ((se-trim (progn
                                                            (goto-char se)
                                                            (skip-chars-backward " \t\r\n" sb)
                                                            (max sb (point))))
                                                 (sb-bol (progn (goto-char sb)
                                                                (line-beginning-position)))
                                                 (sp-bol (progn (goto-char sp)
                                                                (line-beginning-position)))
                                                 (se-bol (progn (goto-char se-trim)
                                                                (line-beginning-position)))
                                                 (total (count-lines sb-bol se-bol))
                                                 (off (count-lines sb-bol sp-bol)))
                                            (if (<= total 0)
                                                0.0
                                              (min 1.0 (/ (float off) (float total))))))))
                                     (prev-steps
                                      (with-current-buffer buffer
                                        (save-excursion
                                          (let* ((pb (car bounds))
                                                 (pe (etaf-md--block-content-end
                                                      buffer pb (cdr bounds)))
                                                 (pb-bol (progn (goto-char pb)
                                                                (line-beginning-position)))
                                                 (pe-bol (progn (goto-char pe)
                                                                (line-beginning-position))))
                                            (count-lines pb-bol pe-bol))))))
                                (if (> prev-steps 0)
                                    (min prev-steps (round (* src-frac prev-steps)))
                                  0))
                            0))
                         (row-start
                          (with-current-buffer buffer
                            (save-excursion
                              (goto-char position)
                              (when (> extra-lines 0)
                                (forward-line extra-lines))
                              (line-beginning-position)))))
                    (set-window-start window row-start nil)
                    ;; Keep window-point at the synced row and force a window
                    ;; update so GUI redisplay repaints the unselected preview.
                    (set-window-point window row-start)
                    (force-window-update window)
                    row-start)))))))))))

(defun etaf-md--block-entry-at (session offset)
  "Return `(ENTRY . t)' at 0-based source OFFSET, `top' before block 0, or nil."
  (let ((first nil)
        (last nil)
        (found nil))
    (dolist (entry (plist-get session :entries))
      (let* ((block (plist-get entry :block))
             (begin (plist-get block :begin))
             (end (plist-get block :end)))
        (when (and (not found)
                   (integerp begin)
                   (integerp end))
          (setq first (or first begin))
          (setq last entry)
          (when (< offset end)
            (setq found entry)))))
    (cond ((and first (< offset first)) 'top)
          (found (cons found t))
          (last (cons last t))
          (t nil))))

(defun etaf-md--block-ref-at (session position)
  "Return ref symbol of SESSION's block at 1-based source POSITION, or `top'."
  (let ((match (etaf-md--block-entry-at session (max 0 (1- position)))))
    (cond ((eq match 'top) 'top)
          ((consp match) (plist-get (car match) :ref))
          (t nil))))

(defun etaf-md--follow-schedule (file &optional immediate)
  "Schedule a live repaint for canonical FILE.
Coalesces keystroke bursts onto a 16 ms frame tick and yields while
`(input-pending-p)' up to `etaf-md--follow-max-wait'.  When IMMEDIATE is
non-nil (e.g. on save), clears the defer deadline so exact parsing runs soon."
  (when (gethash file etaf-md--follow-sessions)
    (when immediate
      (puthash file 0 etaf-md--follow-deadlines))
    (unless (gethash file etaf-md--follow-timers)
      (unless (gethash file etaf-md--follow-deadlines)
        (puthash file (+ (float-time) etaf-md--follow-max-wait)
                 etaf-md--follow-deadlines))
      (puthash file
               (run-with-timer etaf-md--follow-tick nil
                               #'etaf-md--follow-repaint file)
               etaf-md--follow-timers))))

(defun etaf-md--follow-repaint (file)
  "Repaint canonical FILE's preview after its source changed.
Defers one frame when keyboard input is pending (up to the burst deadline) so
typing and IME composition never stall."
  (remhash file etaf-md--follow-timers)
  (let ((deadline (or (gethash file etaf-md--follow-deadlines) 0)))
    (if (and (not noninteractive)
             (input-pending-p)
             (< (float-time) deadline))
        (puthash file
                 (run-with-timer etaf-md--follow-tick nil
                                 #'etaf-md--follow-repaint file)
                 etaf-md--follow-timers)
      (remhash file etaf-md--follow-deadlines)
      (when-let* ((session (gethash file etaf-md--follow-sessions))
                  (buffer (plist-get session :buffer))
                  ((buffer-live-p buffer)))
        (condition-case error
            (let* ((source (plist-get session :source-buffer))
                   (live-buf (and (buffer-live-p source) source))
                   (tick (and live-buf
                              (with-current-buffer live-buf
                                (buffer-chars-modified-tick))))
                   (live-p (and live-buf
                                (with-current-buffer live-buf
                                  (buffer-modified-p))))
                   (dirty-span (plist-get session :dirty-span)))
              (plist-put session :dirty-span nil)
              ;; Fast O(1) skip when the source buffer's char tick has not
              ;; moved and no provisional fence needs settling.
              (unless (and tick
                           (eql tick (plist-get session :live-tick))
                           (or live-p (null (plist-get session :provisional-fence-span))))
                (let ((text (etaf-md--session-text session)))
                  (when tick (plist-put session :live-tick tick))
                  (when (or (not (equal text (plist-get session :live-text)))
                            (and (not live-p)
                                 (plist-get session :provisional-fence-span)))
                    (etaf-md--live-refresh session text dirty-span live-p)))))
          (etaf-md-error
           (message "Preview kept its last render: %s"
                    (error-message-string error))))))))

(etaf-define-component etaf-md-app (&key session)
  "Render the markdown preview for SESSION and own its lifecycle.
SESSION must come from `etaf-md-create'.  Mounting provides the palette for its
subtree and subscribes to `:page-structure' rather than raw `:document', so
editing inside an existing block wakes only that block's Component."
  :bindings ((preview (or session
                          (signal 'etaf-md-error
                                  '("etaf-md-app needs the :session from `etaf-md-create'"))))
             (structure (etaf-md--ref preview :page-structure))
             (theme (etaf-md--ref preview :theme))
             (mode (etaf-md--ref preview :theme-mode))
             (tokens (etaf-computed
                      (lambda ()
                        (etaf-md-theme-tokens
                         (etaf-value theme)
                         (etaf-md--session-palette preview)))
                      :name 'etaf-md-theme-tokens)))
  :setup
  (progn
    (etaf-theme-provide tokens)
    (when-let* ((rt (etaf-current-runtime))
                (buf (etaf-runtime-buffer rt)))
      (unless (buffer-live-p (plist-get preview :buffer))
        (plist-put preview :buffer buf)
        (etaf-md--schedule-async-assets preview nil)
        (etaf-on-unmounted
         (lambda ()
           (etaf-md--cancel-asset-timer preview)
           (when (eq (plist-get preview :buffer) buf)
             (plist-put preview :buffer nil)))))
      (etaf-watch-effect
       (lambda ()
         (when (etaf-runtime-mounted-p rt)
           (let* ((vp (etaf-runtime-viewport rt))
                  (vw (car-safe vp))
                  (prev-vw (plist-get preview :last-canvas-width)))
             (plist-put preview :last-canvas-width vw)
             (when (and prev-vw vw (not (equal vw prev-vw)))
               (let ((gen (plist-get preview :locate-gen)))
                 (etaf-next-tick
                  (lambda ()
                    (when (eql gen (plist-get preview :locate-gen))
                      (when-let* ((pbuf (plist-get preview :buffer))
                                  ((buffer-live-p pbuf))
                                  (win (get-buffer-window pbuf t)))
                        (let ((anchor (plist-get preview :resize-anchor)))
                          (plist-put preview :resize-anchor nil)
                          (etaf-md--realign-after-resize preview pbuf win anchor)))))))))))
       :name 'etaf-md-viewport-realign))
    ;; One appearance state: `auto' resolves to the frame's faces, a named
    ;; mode paints its fixed page, and a panel's title-bar switch writes the
    ;; same cell as `t', so the document and the panel chrome follow it.
    (etaf-watch mode
                (lambda (mode _old)
                  (etaf-batch
                    (etaf-md--write preview :theme
                                             (if (eq mode 'auto)
                                                 (etaf-md-auto-theme)
                                               mode))
                    (etaf-md--write preview :theme-source
                                             (if (eq mode 'auto) 'frame 'palette)))
                  ;; The page's pictures are drawn for a palette too, so a
                  ;; switch publishes again to attach the ones it needs.
                  (etaf-md--republish preview))
                :immediate t :name 'etaf-md-mode)
    (when-let* ((surface (etaf-surface-host)))
      (etaf-surface-declare surface :theme tokens :mode mode
                            :modes etaf-md--surface-modes)))
  :render
  (etaf-md--view-document
   preview
   (etaf-value structure)
   (etaf-md--base-env preview)))

(defun etaf-md-view (&optional session)
  "Return the preview View for SESSION.
SESSION defaults to a new session over an empty document; pass a session from
`etaf-md-create' to mount a real one."
  (etaf-view (etaf-md-app
              :session (or session (etaf-md-create :text "")))))

(defun etaf-md--sync-preview-to-source-pos (session source-buf pos)
  "Position SESSION's preview buffer near the block matching POS in SOURCE-BUF."
  (when (and session (buffer-live-p source-buf) (integerp pos))
    (let* ((preview-buf (plist-get session :buffer))
           (win (and (buffer-live-p preview-buf)
                     (get-buffer-window preview-buf t)))
           (offset (max 0 (1- pos)))
           (match (etaf-md--block-entry-at session offset)))
      (when (and (buffer-live-p preview-buf) (consp match))
        (let* ((entry (car match))
               (ref (plist-get entry :ref))
               (runtime (etaf-runtime-for-buffer preview-buf))
               (bounds (and runtime ref (etaf-host-ref-bounds runtime ref)))
               (target (or (car-safe bounds)
                           (and runtime ref (etaf-host-ref-position runtime ref)))))
          (when (integerp target)
            (with-current-buffer preview-buf
              (let ((bol (save-excursion (goto-char target) (line-beginning-position))))
                (goto-char bol)
                (when (window-live-p win)
                  (set-window-point win bol)
                  (with-selected-window win (recenter)))))))))))

;;; `etaf-md' autoloads this command from the entry file, which loads the
;;; typesetter too; a second cookie here would skip it and leave a code block
;;; calling an undefined renderer.
(defun etaf-md-open (&optional source)
  "Open a full-width Markdown reading view in the current window.
SOURCE is a file path, a session from `etaf-md-create', or nil to prompt for a
file.  Interactively, when the current buffer visits a Markdown file and no
prefix argument is given, opens it directly in the current window without
prompting or splitting windows; with a prefix argument (`C-u') or from any
other buffer, prompts for a file.  Reuses an existing preview buffer visiting
the same canonical file and returns the preview buffer."
  (interactive
   (list
    (cond
     (current-prefix-arg
      (read-file-name
       "Markdown file: " nil nil t
       (when (and buffer-file-name
                  (string-match-p etaf-md--markdown-file-regexp buffer-file-name))
         (file-relative-name buffer-file-name default-directory))))
     ((and (etaf-app-state) (etaf-ref-p (plist-get (etaf-app-state) :document)))
      (etaf-app-state))
     ((and buffer-file-name
           (string-match-p etaf-md--markdown-file-regexp buffer-file-name))
      (expand-file-name buffer-file-name))
     (t
      (read-file-name "Markdown file: " nil nil t)))))
  (let* ((origin-buf (current-buffer))
         (origin-pos (point))
         (origin-file (and buffer-file-name
                           (etaf-md--canonical-file buffer-file-name))))
    (if (and (listp source) (etaf-ref-p (plist-get source :document)))
        (let ((existing (plist-get source :buffer)))
          (if (buffer-live-p existing)
              (progn (switch-to-buffer existing) existing)
            (let ((buf (etaf-md--display source
                                         (etaf-md--buffer-name-for-session source))))
              (unless (eq origin-buf buf)
                (plist-put source :origin-buffer origin-buf))
              buf)))
      (let* ((file (etaf-md--canonical-file source))
             (from-source-p (and origin-file (equal origin-file file)))
             (existing (etaf-md--find-preview-buffer file))
             (buf (if existing
                      (progn (switch-to-buffer existing) existing)
                    (etaf-md--display (etaf-md-create :file file)
                                      (etaf-md--buffer-name file)))))
        (when-let* ((session (and (buffer-live-p buf) (etaf-app-state buf))))
          (unless (eq origin-buf buf)
            (plist-put session :origin-buffer origin-buf))
          (when (and from-source-p (> origin-pos 1))
            (etaf-md--sync-preview-to-source-pos session origin-buf origin-pos)))
        buf))))

(defun etaf-md--open-preview-split (source-buf)
  "Open a right-side live preview split beside SOURCE-BUF and return its buffer."
  (let* ((file (etaf-md--canonical-file (buffer-file-name source-buf)))
         (source-win (or (get-buffer-window source-buf) (selected-window)))
         (existing-preview (etaf-md--find-preview-buffer file))
         (existing-win (and existing-preview (get-buffer-window existing-preview)))
         (preview-buf nil))
    (select-window source-win)
    (unless (eq (window-buffer source-win) source-buf)
      (switch-to-buffer source-buf))
    (if (and (window-live-p existing-win) (not (eq existing-win source-win)))
        (setq preview-buf existing-preview)
      (let ((right-win (split-window-right)))
        (set-window-parameter right-win 'etaf-md-preview-split t)
        (select-window right-win)
        (setq preview-buf (etaf-md-open file))))
    (when (window-live-p source-win)
      (select-window source-win))
    (with-current-buffer source-buf
      (add-hook 'kill-buffer-hook #'etaf-md--preview-source-killed nil t))
    (when-let* ((session (and (buffer-live-p preview-buf)
                              (etaf-app-state preview-buf))))
      (plist-put session :follow-scroll t)
      (etaf-md--follow-scroll-sync session t source-win))
    preview-buf))

(defun etaf-md--close-preview-split (source-buf)
  "Close the live preview split attached to SOURCE-BUF, keeping SOURCE-BUF."
  (when-let* ((path (and (buffer-live-p source-buf)
                         (buffer-file-name source-buf)))
              (file (etaf-md--canonical-file path))
              (preview-buf (etaf-md--find-preview-buffer file)))
    (let ((src-win (get-buffer-window source-buf))
          (prev-win (get-buffer-window preview-buf)))
      (when (and (window-live-p src-win)
                 (window-parameter src-win 'etaf-md-source-split)
                 (window-live-p prev-win)
                 (not (eq prev-win src-win)))
        ;; Promote preview-win as the split to delete so source-win survives.
        (set-window-parameter src-win 'etaf-md-source-split nil)
        (set-window-parameter prev-win 'etaf-md-preview-split t))
      (with-current-buffer preview-buf
        (etaf-md-close))
      (when (window-live-p src-win)
        (select-window src-win)))))

(defun etaf-md--preview-source-killed ()
  "Tear down the live preview split when its source buffer is killed."
  (etaf-md--close-preview-split (current-buffer)))

;;; Autoloaded from `etaf-md' for the same reason as `etaf-md-open'.
(defun etaf-md-preview (&optional file)
  "Toggle a live side-by-side ETAF Markdown preview beside the source buffer.
When called from a preview buffer with no FILE, delegates to
`etaf-md-toggle-split'.  Otherwise previews FILE (defaulting to the current
buffer's visited file, or prompting for a file interactively when the buffer
visits none): if a live preview window is already visible beside the source
window, closes it and removes only the split it created; otherwise opens a
non-destructive right split without closing unrelated panes, enables
proportional scroll-follow synced to the current source line, and leaves point
in the source buffer.  Returns the preview buffer when opened, or nil when
closed."
  (interactive
   (list
    (unless (or (etaf-md--preview-buffer-p)
                buffer-file-name)
      (read-file-name "Markdown file: " nil nil t))))
  (if (and (null file) (etaf-md--preview-buffer-p))
      (etaf-md-toggle-split)
    (let* ((source-buf (if file
                           (or (find-buffer-visiting file)
                               (find-file-noselect file))
                         (current-buffer)))
           (path (or file (buffer-file-name source-buf))))
      (unless path
        (user-error "Save this buffer to a file before opening a live preview"))
      (let* ((canonical (etaf-md--canonical-file path))
             (existing-preview (etaf-md--find-preview-buffer canonical))
             (source-win (or (get-buffer-window source-buf) (selected-window)))
             (existing-win (and existing-preview
                                (get-buffer-window existing-preview))))
        (if (and (window-live-p existing-win)
                 (not (eq existing-win source-win)))
            (progn
              (etaf-md--close-preview-split source-buf)
              nil)
          (etaf-md--open-preview-split source-buf))))))

(defun etaf-md--buffer-name-for-session (session)
  "Return the preview buffer name for SESSION."
  (if-let* ((file (plist-get session :file)))
      (etaf-md--buffer-name file)
    "*ETAF Markdown*"))

(defun etaf-md--display (session name)
  "Open SESSION as the application buffer NAME and return that buffer.
The reading measure stays capped at `:width' while stretching cleanly inside
narrower windows, so resizing a split up to a full frame never gets trapped at
the initial split width."
  (let ((buffer
         (etaf-app-open
          name
          (etaf-view (etaf-md-app :session session :keys etaf-md-keys))
          :state session
          :mode-line t
          :on-fit (lambda (window)
                    (etaf-md--on-fit session window))
          :background (lambda () (etaf-md--page-background session))
          :on-close (lambda ()
                      (etaf-md--outline-close session)
                      (etaf-md--cleanup-source-kill-hook session)
                      (etaf-md--follow-unregister (plist-get session :file))
                      (plist-put session :resize-anchor nil)
                      (plist-put session :buffer nil)))))
    (plist-put session :buffer buffer)
    (etaf-md--follow-register session)
    (etaf-md--schedule-async-assets session nil)
    (with-current-buffer buffer
      (add-hook 'kill-buffer-hook
                (lambda ()
                  (etaf-md--outline-close session)
                  (etaf-md--cleanup-source-kill-hook session)
                  (etaf-md--follow-unregister (plist-get session :file)))
                t t)
      (add-hook 'post-command-hook
                (lambda () (etaf-md--sync-active-heading session))
                nil t)
      ;; Snapshot the pre-resize block anchor on the first size-change event
      ;; before Ebox's debounced refit re-wraps the buffer; `:on-fit' restores
      ;; it (or re-syncs to source when follow-scroll is active) once settled.
      (let ((capture-anchor
             (lambda (&optional _frame-or-win)
               (when-let* ((buf (plist-get session :buffer))
                           ((buffer-live-p buf))
                           (win (get-buffer-window buf t)))
                 (let ((cols (window-body-width win)))
                   (when (and (null (plist-get session :resize-anchor))
                              (not (etaf-md--follow-source-window session))
                              (or (and (plist-get session :fit-cols)
                                       (not (equal cols (plist-get session :fit-cols))))
                                  (and (plist-get session :fit-pixel-width)
                                       (not (equal (window-body-width win t)
                                                   (plist-get session :fit-pixel-width))))))
                     (plist-put session :resize-anchor
                                (etaf-md--capture-viewport-anchor session buf win))))))))
        (add-hook 'window-size-change-functions capture-anchor -10 t))
      (setq-local imenu-create-index-function
                  (lambda ()
                    (let ((outline (etaf-md-outline session)))
                      (mapcar (lambda (cell)
                                (cons (nth 1 (nth (car cell) outline))
                                      (cdr cell)))
                              (etaf-md--heading-positions session))))))
    (etaf-runtime-flush (etaf-runtime-for-buffer buffer))
    buffer))

(provide 'etaf-md-app)
;;; etaf-md-app.el ends here
