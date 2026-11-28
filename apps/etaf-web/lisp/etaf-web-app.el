;;; etaf-web-app.el --- Interactive browser shell for etaf-web -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; Browser application shell built on `etaf-app-open' and `etaf-md-view'.
;; Each opened page owns its own buffer (`*Web: <host>*'), history stack with
;; scroll-position restore, non-blocking asynchronous loading with retained-Host
;; progress bar animation, editable address bar with history completion, error
;; recovery card, and keyboard shortcuts bound through the root Host's `:keys'.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'etaf)
(require 'etaf-ui)
(require 'etaf-md)
(require 'etaf-web-cache)
(require 'etaf-web-adapter)
(require 'etaf-web-router)
(require 'etaf-web-cdp)
(require 'etaf-web-live)
(require 'etaf-web-views)

(defcustom etaf-web-external-browser-function nil
  "Function called with URL when handing a page off to a pixel browser.
When nil, falls back to `browse-url'.  Set this to a function such as
`chromel' to open external or canvas-heavy pages inside an embedded browser."
  :type '(choice (const :tag "Use browse-url" nil)
                 function)
  :group 'etaf-web)

(defvar etaf-web--url-history nil
  "Global MRU list of visited URLs used for address-bar completion.")

(defconst etaf-web--anim-interval 0.06
  "Seconds between smooth progress-bar easing frames (retained span patch).")

(defconst etaf-web--keys
  '(("RET"       etaf-web--activate-at-point "激活当前链接或控件")
    ("<return>"  etaf-web--activate-at-point "激活当前链接或控件")
    ("C-n"       etaf-web--cursor-next-line "光标下移")
    ("C-p"       etaf-web--cursor-previous-line "光标上移")
    ("C-f"       etaf-web--cursor-forward-char "光标右移")
    ("C-b"       etaf-web--cursor-backward-char "光标左移")
    ("C-a"       etaf-web--cursor-beginning-of-line "行首")
    ("C-e"       etaf-web--cursor-end-of-line "行尾")
    ("M-<"       etaf-web--beginning-of-page "页面顶部")
    ("<home>"    etaf-web--beginning-of-page "页面顶部")
    ("M->"       etaf-web--end-of-page "页面底部")
    ("<end>"     etaf-web--end-of-page "页面底部")
    ("w"         etaf-web--copy-url-at-point "复制链接或页面地址")
    ("M-<left>"  etaf-web-back "后退")
    ("B"         etaf-web-back "后退")
    ("M-<right>" etaf-web-forward "前进")
    ("F"         etaf-web-forward "前进")
    ("r"         etaf-web-reload "刷新页面")
    ("x"         etaf-web-stop "停止加载")
    ("g"         etaf-web-focus-address "编辑地址栏")
    ("C-l"       etaf-web-focus-address "编辑地址栏")
    ("m"         etaf-web-set-mode "切换渲染模式")
    ("o"         etaf-web-open-external "外部浏览器打开")
    ("C-v"       etaf-web-scroll-page-down "下一页")
    ("M-v"       etaf-web-scroll-page-up "上一页")
    ("<next>"    etaf-web-scroll-page-down "下一页")
    ("<prior>"   etaf-web-scroll-page-up "上一页")
    ("n"         etaf-web--next-heading "下一个标题")
    ("p"         etaf-web--previous-heading "上一个标题")
    ("C-c j"     etaf-web-goto-heading "选择标题")
    ("t"         etaf-web--cycle-theme "切换主题")
    ("["         etaf-web--narrower "缩窄阅读栏")
    ("]"         etaf-web--wider "加宽阅读栏")
    ("-"         etaf-web--narrower "缩窄阅读栏")
    ("+"         etaf-web--wider "加宽阅读栏")
    ("="         etaf-web--wider "加宽阅读栏")
    ("C-c h"     etaf-help "查看快捷键")
    ("q"         etaf-web-close "关闭页面"))
  "Root Host key bindings for an `etaf-web' browser buffer.")

(defvar-local etaf-web--goal-column nil
  "Preserved visual column across consecutive vertical cursor steps.")

(defconst etaf-web--toolbar-focus-refs
  '(web-back web-forward web-reload web-stop web-address
    web-address-input web-mode-button)
  "Toolbar Host references whose logical focus should not outlive navigation.")

;;; ---------------------------------------------------------------------------
;;; Session helpers
;;; ---------------------------------------------------------------------------

(defun etaf-web--current-session (&optional buffer)
  "Return the `etaf-web' browser session of BUFFER (default current), or error."
  (or (with-current-buffer (or buffer (current-buffer))
        (let ((st (ignore-errors (etaf-app-state))))
          (and (listp st) (eq (plist-get st :app) 'etaf-web) st)))
      (user-error "Not an ETAF Web browser buffer")))

(defun etaf-web--record-url-history (url)
  "Push URL to the front of `etaf-web--url-history', capped at 100 entries."
  (when (and (stringp url) (not (string-empty-p url)))
    (setq etaf-web--url-history
          (seq-take (cons url (delete url etaf-web--url-history)) 100))))

(defun etaf-web--buffer-name-for-source (canonical)
  "Generate a fresh unique buffer name `*Web: <host>*' for CANONICAL."
  (let* ((parts (etaf-web--url-parts canonical))
         (host (car parts))
         (path (cdr parts))
         (label (cond
                 ((and (not (string-empty-p host))
                       (not (equal host "file")))
                  host)
                 ((not (string-empty-p path))
                  (file-name-nondirectory path))
                 (t "page"))))
    (generate-new-buffer-name (format "*Web: %s*" label))))

(defun etaf-web--select-other-window ()
  "Select another window for `other-window' display, splitting if needed."
  (let ((target (if (one-window-p t)
                    (or (split-window-sensibly)
                        (ignore-errors (split-window-right))
                        (selected-window))
                  (next-window))))
    (when (window-live-p target)
      (select-window target))))

(defun etaf-web--current-scroll-offset (rt)
  "Return the current line scroll offset of `web-scroll' in RT, or 0."
  (if (and rt (etaf-runtime-mounted-p rt)
           (etaf-runtime-host-props-for rt 'web-scroll))
      (etaf-scroll-offset rt 'web-scroll)
    0))

(defun etaf-web--save-scroll-position (session)
  "Record viewport scroll offset and point on SESSION's active history item."
  (let* ((buf (plist-get session :buffer))
         (idx (plist-get session :history-index))
         (hist (plist-get session :history)))
    (when (and (buffer-live-p buf) (integerp idx) (>= idx 0) (< idx (length hist)))
      (let* ((entry (nth idx hist))
             (rt (etaf-runtime-for-buffer buf)))
        (with-current-buffer buf
          (plist-put entry :point (point))
          (plist-put entry :scroll-offset
                     (etaf-web--current-scroll-offset rt)))))))

(defun etaf-web--scroll-host-p (rt ref)
  "Return non-nil when Host REF in RT is an `:overflow scroll' viewport."
  (and rt ref
       (eq (plist-get (etaf-runtime-host-props-for rt ref) :overflow) 'scroll)))

(defun etaf-web--active-scroll-ref (rt &optional pos)
  "Return the scrollable Host ref at POS (default point) in RT, or `web-scroll'."
  (when (and rt (etaf-runtime-mounted-p rt))
    (or (etaf-host-ref-at rt (or pos (point))
                          (lambda (ref) (etaf-web--scroll-host-p rt ref)))
        (and (etaf-runtime-host-props-for rt 'web-scroll) 'web-scroll))))

(defun etaf-web--scroll-line-range (rt ref)
  "Return `(TOP-LINE . BOT-LINE)' painted line numbers of scroll Host REF in RT."
  (when-let* ((bounds (and rt ref (etaf-host-ref-bounds rt ref)))
              (beg (car bounds))
              (end (cdr bounds)))
    (cons (line-number-at-pos beg)
          (line-number-at-pos (max beg (1- end))))))

(defun etaf-web--pane-line-span (rt ref)
  "Return `(BEG . END)' on current line belonging to scroll Host REF in RT."
  (let ((bol (line-beginning-position))
        (eol (line-end-position)))
    (if (not (and rt ref (etaf-runtime-mounted-p rt)))
        (cons bol eol)
      (let* ((here (min (max (point) bol) (max bol (1- eol))))
             (pred (lambda (r) (eq r ref))))
        (if (not (eq (etaf-host-ref-at rt here pred) ref))
            (cons bol eol)
          (let ((left here)
                (right here))
            (while (and (> left bol)
                        (eq (etaf-host-ref-at rt (1- left) pred) ref))
              (setq left (1- left)))
            (while (and (< right eol)
                        (eq (etaf-host-ref-at rt right pred) ref))
              (setq right (1+ right)))
            (cons left right)))))))

(defun etaf-web--first-content-pos-in-pane (rt ref &optional from-end)
  "Return first (or last when FROM-END) non-blank position inside REF in RT."
  (when-let* ((bounds (and rt ref (etaf-host-ref-bounds rt ref)))
              (beg (car bounds))
              (end (cdr bounds)))
    (let ((pred (lambda (r) (eq r ref)))
          (found nil))
      (save-excursion
        (if from-end
            (let ((line-pos (save-excursion
                              (goto-char (max beg (1- end)))
                              (line-beginning-position))))
              (while (and (not found) (>= line-pos beg))
                (goto-char line-pos)
                (let ((p (line-beginning-position))
                      (leol (min end (line-end-position)))
                      (line-hit nil))
                  (while (< p leol)
                    (let ((ch (char-after p)))
                      (when (and ch (not (memq ch '(?\s ?\t ?\n)))
                                 (eq (etaf-host-ref-at rt p pred) ref))
                        (setq line-hit p p leol)))
                    (setq p (1+ p)))
                  (when line-hit (setq found line-hit)))
                (if (= line-pos (point-min))
                    (setq line-pos -1)
                  (goto-char line-pos)
                  (forward-line -1)
                  (setq line-pos (point)))))
          (let ((p beg))
            (while (and (not found) (< p end))
              (let ((ch (char-after p)))
                (when (and ch (not (memq ch '(?\s ?\t ?\n)))
                           (eq (etaf-host-ref-at rt p pred) ref))
                  (setq found p)))
              (setq p (1+ p))))))
      (or found beg))))

(defun etaf-web--body-initial-point (session)
  "Return initial body cursor position for SESSION's rendered page."
  (let* ((buf (plist-get session :buffer))
         (rt (and (buffer-live-p buf) (etaf-runtime-for-buffer buf))))
    (if (buffer-live-p buf)
        (with-current-buffer buf
          (or (and rt (etaf-runtime-mounted-p rt)
                   (etaf-runtime-host-props-for rt 'web-scroll)
                   (etaf-web--first-content-pos-in-pane rt 'web-scroll nil))
              (save-excursion
                (goto-char (point-min))
                (if (zerop (forward-line 1)) (point) (point-min)))))
      1)))

(defun etaf-web--sync-window-point (&optional pos)
  "Keep displaying window point synced to POS (default point) with fixed top."
  (let ((pt (or pos (point))))
    (when-let* ((win (get-buffer-window (current-buffer) t)))
      (set-window-point win pt)
      (set-window-start win (point-min) t))))

(defun etaf-web--filter-buffer-substring (beg end &optional _delete)
  "Return property-free text from BEG..END, stripping Ebox layout margin padding."
  (let ((text (buffer-substring-no-properties beg end)))
    (if (not (string-match-p "\n" text))
        text
      (let* ((lines (split-string text "\n"))
             (trimmed (mapcar (lambda (ln)
                                (replace-regexp-in-string "[ \t]+\\'" "" ln))
                              lines))
             (non-empty (cl-remove-if #'string-empty-p trimmed))
             (at-bol (save-excursion (goto-char beg) (bolp)))
             (min-indent
              (when (and non-empty
                         (or at-bol
                             (string-prefix-p " " (car trimmed))))
                (cl-loop for ln in non-empty
                         minimize (if (string-match "\\` +" ln)
                                      (match-end 0)
                                    0)))))
        (mapconcat (lambda (ln)
                     (if (and min-indent (> min-indent 0)
                              (>= (length ln) min-indent))
                         (substring ln min-indent)
                       ln))
                   trimmed "\n")))))

(defun etaf-web--restore-scroll-position (session scroll-offset saved-point)
  "Restore viewport SCROLL-OFFSET and SAVED-POINT in SESSION's live buffer."
  (let* ((buf (plist-get session :buffer))
         (rt (and (buffer-live-p buf) (etaf-runtime-for-buffer buf))))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (when (and rt (etaf-runtime-mounted-p rt)
                   (etaf-runtime-host-props-for rt 'web-scroll))
          (etaf-scroll-to rt 'web-scroll
                          (if (integerp scroll-offset)
                              (max 0 scroll-offset)
                            0)))
        (let* ((target (or saved-point (etaf-web--body-initial-point session)))
               (pt (max (point-min) (min (point-max) target))))
          (goto-char pt)
          (etaf-web--sync-window-point pt))))))

(defun etaf-web--bump-chrome-if-focused (session)
  "Bump SESSION's `:chrome-gen' when a toolbar Host holds stale logical focus.
Replacing the toolbar action group's `:key' releases stale toolbar focus via
ETAF's own lifecycle so subsequent `point + RET' on body links is never
redirected back to the toolbar."
  (let* ((buf (plist-get session :buffer))
         (rt (and (buffer-live-p buf) (etaf-runtime-for-buffer buf))))
    (when (and rt (etaf-runtime-mounted-p rt)
               (memq (etaf-focused-host-ref rt) etaf-web--toolbar-focus-refs))
      (etaf-set-value (plist-get session :chrome-gen)
                      (1+ (or (etaf-value (plist-get session :chrome-gen)) 0))))))

(defun etaf-web--ret-command-at (pos)
  "Return the RET command bound in the text-property keymap at POS, or nil."
  (when (and (integer-or-marker-p pos)
             (<= (point-min) pos) (< pos (point-max))
             (not (eq (char-after pos) ?\n)))
    (let* ((km (get-text-property pos 'keymap))
           (cmd (and (keymapp km) (lookup-key km (kbd "RET")))))
      (and (commandp cmd) cmd))))

(defun etaf-web--line-link-position ()
  "Return the nearest position on the current body line with a RET keymap, or nil.
Skips row 1 (the fixed toolbar) so padding spaces on the toolbar never trigger
accidental button activation, while leading/trailing padding on centered heading
links in the reading column resolves cleanly to the link run."
  (when (> (line-number-at-pos) 1)
    (let* ((here (point))
           (bol (line-beginning-position))
           (eol (line-end-position))
           (best nil)
           (best-dist most-positive-fixnum)
           (p bol))
      (while (< p eol)
        (let ((next (next-single-property-change p 'keymap nil eol)))
          (when (etaf-web--ret-command-at p)
            (let ((dist (cond ((< here p) (- p here))
                              ((>= here next) (1+ (- here next)))
                              (t 0))))
              (when (< dist best-dist)
                (setq best p best-dist dist))))
          (setq p next)))
      best)))

(defun etaf-web--activate-at-point ()
  "Activate the link or control at point, or the link on the current body line.
When point rests on leading or trailing padding of a centered heading link
(where the inner link run's keymap does not paint padding cells), resolves to
that line's link run instead of failing with `No Ebox RET command at position'."
  (let* ((session (etaf-web--current-session))
         (buf (plist-get session :buffer))
         (rt (and (buffer-live-p buf) (etaf-runtime-for-buffer buf)))
         (focused (and rt (etaf-runtime-mounted-p rt) (etaf-focused-host-ref rt)))
         (at-focused (and focused
                          (eql (point) (etaf-host-ref-position rt focused)))))
    (cond
     (at-focused
      (etaf-activate rt))
     ((etaf-web--ret-command-at (point))
      (when (memq focused etaf-web--toolbar-focus-refs)
        (etaf-web--bump-chrome-if-focused session)
        (when rt (etaf-runtime-flush rt)))
      (let ((cmd (etaf-web--ret-command-at (point))))
        (if cmd
            (let ((last-input-event ?\r))
              (command-execute cmd))
          (etaf-activate rt))))
     (t
      (if-let* ((target (etaf-web--line-link-position)))
          (progn
            (when (memq focused etaf-web--toolbar-focus-refs)
              (etaf-web--bump-chrome-if-focused session)
              (when rt (etaf-runtime-flush rt)))
            (goto-char target)
            (let ((cmd (etaf-web--ret-command-at target)))
              (if cmd
                  (let ((last-input-event ?\r))
                    (command-execute cmd))
                (etaf-activate rt))))
        (message "当前位置没有可激活的链接或控件"))))))

(defun etaf-web--vertical-command-p (cmd)
  "Return non-nil when CMD is a vertical cursor-movement command."
  (or (memq cmd '(etaf-web--cursor-next-line
                  etaf-web--cursor-previous-line
                  next-line previous-line))
      (and (symbolp cmd)
           (equal (symbol-name cmd) "etaf-key-direction"))))

(defun etaf-web--cursor-move-char (delta)
  "Move cursor horizontally by DELTA characters, clamping within buffer bounds."
  (setq etaf-web--goal-column nil)
  (let ((target (max (point-min) (min (point-max) (+ (point) delta)))))
    (goto-char target)
    (etaf-web--sync-window-point target)))

(defun etaf-web--cursor-step-line (delta)
  "Move cursor vertically by DELTA lines, auto-scrolling enclosing viewport."
  (let* ((rt (etaf-runtime-for-buffer (current-buffer)))
         (col (or goal-column
                  (and (etaf-web--vertical-command-p last-command)
                       etaf-web--goal-column)
                  (current-column)))
         (step (if (< delta 0) -1 1))
         (count (abs delta)))
    (setq etaf-web--goal-column col)
    (dotimes (_ count)
      (let* ((sref (and rt (etaf-runtime-mounted-p rt)
                        (etaf-host-ref-at
                         rt (point)
                         (lambda (r) (etaf-web--scroll-host-p rt r)))))
             (range (and sref (etaf-web--scroll-line-range rt sref)))
             (top-line (car range))
             (bot-line (cdr range))
             (cur-line (line-number-at-pos (point))))
        (cond
         ;; At bottom edge of scrollable pane: scroll pane down 1 row.
         ((and (> step 0) sref bot-line (>= cur-line bot-line))
          (ignore-errors (etaf-scroll-by rt sref 1))
          (goto-char (point-min))
          (forward-line (max 0 (1- bot-line)))
          (move-to-column col))
         ;; Normal move down inside buffer.
         ((> step 0)
          (when (< (line-end-position) (point-max))
            (forward-line 1)
            (move-to-column col)))
         ;; At top edge of scrollable pane with scroll offset > 0: scroll up 1 row.
         ((and (< step 0) sref top-line (<= cur-line top-line)
               (> (or (ignore-errors (etaf-scroll-offset rt sref)) 0) 0))
          (ignore-errors (etaf-scroll-by rt sref -1))
          (goto-char (point-min))
          (forward-line (max 0 (1- top-line)))
          (move-to-column col))
         ;; Normal move up inside buffer.
         ((< step 0)
          (when (> cur-line 1)
            (forward-line -1)
            (move-to-column col))))))
    (etaf-web--sync-window-point (point))))

(defun etaf-web--cursor-next-line (&optional arg)
  "Move cursor down ARG lines (default 1), scrolling the viewport at bottom."
  (handle-shift-selection)
  (etaf-web--cursor-step-line (or arg (prefix-numeric-value current-prefix-arg))))

(defun etaf-web--cursor-previous-line (&optional arg)
  "Move cursor up ARG lines (default 1), scrolling the viewport at top."
  (handle-shift-selection)
  (etaf-web--cursor-step-line (- (or arg (prefix-numeric-value current-prefix-arg)))))

(defun etaf-web--cursor-forward-char (&optional arg)
  "Move cursor forward ARG characters (default 1)."
  (handle-shift-selection)
  (etaf-web--cursor-move-char (or arg (prefix-numeric-value current-prefix-arg))))

(defun etaf-web--cursor-backward-char (&optional arg)
  "Move cursor backward ARG characters (default 1)."
  (handle-shift-selection)
  (etaf-web--cursor-move-char (- (or arg (prefix-numeric-value current-prefix-arg)))))

(defun etaf-web--cursor-beginning-of-line ()
  "Move cursor to first non-space char in current pane line, or line start."
  (handle-shift-selection)
  (setq etaf-web--goal-column nil)
  (let* ((rt (etaf-runtime-for-buffer (current-buffer)))
         (sref (and rt (etaf-runtime-mounted-p rt)
                    (etaf-host-ref-at
                     rt (point)
                     (lambda (r) (etaf-web--scroll-host-p rt r)))))
         (span (etaf-web--pane-line-span rt sref))
         (beg (car span))
         (end (cdr span))
         (first-nonws
          (save-excursion
            (goto-char beg)
            (skip-chars-forward " \t" end)
            (if (< (point) end) (point) beg)))
         (bol (line-beginning-position))
         (target (cond
                  ((not (= (point) first-nonws)) first-nonws)
                  ((not (= (point) beg)) beg)
                  (t bol))))
    (goto-char target)
    (etaf-web--sync-window-point target)))

(defun etaf-web--cursor-end-of-line ()
  "Move cursor after last non-space char in current pane line, or line end."
  (handle-shift-selection)
  (setq etaf-web--goal-column nil)
  (let* ((rt (etaf-runtime-for-buffer (current-buffer)))
         (sref (and rt (etaf-runtime-mounted-p rt)
                    (etaf-host-ref-at
                     rt (point)
                     (lambda (r) (etaf-web--scroll-host-p rt r)))))
         (span (etaf-web--pane-line-span rt sref))
         (beg (car span))
         (end (cdr span))
         (last-nonws
          (save-excursion
            (goto-char end)
            (skip-chars-backward " \t" beg)
            (if (> (point) beg) (point) end)))
         (eol (line-end-position))
         (target (cond
                  ((not (= (point) last-nonws)) last-nonws)
                  ((not (= (point) end)) end)
                  (t eol))))
    (goto-char target)
    (etaf-web--sync-window-point target)))

(defun etaf-web--beginning-of-page ()
  "Scroll active pane to the top and place cursor on its first content line."
  (handle-shift-selection)
  (setq etaf-web--goal-column nil)
  (let* ((rt (etaf-runtime-for-buffer (current-buffer)))
         (sref (etaf-web--active-scroll-ref rt)))
    (when sref
      (ignore-errors (etaf-scroll-to rt sref 'start)))
    (let ((pt (or (and sref (etaf-web--first-content-pos-in-pane rt sref nil))
                  (point-min))))
      (goto-char pt)
      (etaf-web--sync-window-point pt))))

(defun etaf-web--end-of-page ()
  "Scroll active pane to the bottom and place cursor on its last content line."
  (handle-shift-selection)
  (setq etaf-web--goal-column nil)
  (let* ((rt (etaf-runtime-for-buffer (current-buffer)))
         (sref (etaf-web--active-scroll-ref rt)))
    (when sref
      (ignore-errors (etaf-scroll-to rt sref 'end)))
    (let ((pt (or (and sref (etaf-web--first-content-pos-in-pane rt sref t))
                  (point-max))))
      (goto-char pt)
      (etaf-web--sync-window-point pt))))

(defun etaf-web--handle-direction (session direction)
  "Handle arrow DIRECTION in SESSION as normal Emacs cursor movement.
Releases control when a text input is active or a splitter/slider holds focus."
  (let* ((buf (plist-get session :buffer))
         (rt (and (buffer-live-p buf) (etaf-runtime-for-buffer buf))))
    (if (or (not (and rt (etaf-runtime-mounted-p rt)))
            (etaf-text-input-active-p rt))
        'release
      (with-current-buffer buf
        (let* ((focused (etaf-focused-host-ref rt))
               (focused-props (and focused (etaf-runtime-host-props-for rt focused)))
               (focused-role (and focused-props (plist-get focused-props :role))))
          (if (and focused
                   (memq focused-role '(separator slider))
                   (eql (point) (etaf-host-ref-position rt focused)))
              'release
            (handle-shift-selection)
            (pcase direction
              ('right (etaf-web--cursor-move-char 1))
              ('left  (etaf-web--cursor-move-char -1))
              ('down  (etaf-web--cursor-step-line 1))
              ('up    (etaf-web--cursor-step-line -1)))
            'handled))))))

(defun etaf-web--copy-url-at-point ()
  "Copy link URL at point (if any) or the current page URL to the kill ring."
  (let* ((session (etaf-web--current-session))
         (help (get-text-property (point) 'help-echo))
         (link-url
          (when (stringp help)
            (cond
             ((string-match "https?://[^ \t\n\r\"'<>()（）]+" help)
              (match-string 0 help))
             ((string-match "file://[^ \t\n\r\"'<>()（）]+" help)
              (match-string 0 help)))))
         (url (or link-url (etaf-value (plist-get session :url)) "")))
    (if (string-empty-p url)
        (message "当前页面没有可复制的地址")
      (kill-new url)
      (message "已复制地址: %s" url))))

(defun etaf-web--scroll-page (step)
  "Scroll the active page viewport STEP screens in the current browser buffer."
  (when-let* ((buf (and (derived-mode-p 'fundamental-mode) (current-buffer)))
              (rt (and (etaf-app-state buf) (etaf-runtime-for-buffer buf)))
              (sref (etaf-web--active-scroll-ref rt)))
    (let* ((win (get-buffer-window buf t))
           (rows (if (window-live-p win) (window-body-height win) 24))
           (delta (* step (max 3 (- rows 3)))))
      (with-current-buffer buf
        (let ((pt (point)))
          (condition-case nil
              (etaf-scroll-by rt sref delta)
            (etaf-runtime-error nil))
          (goto-char (max (point-min) (min (point-max) pt)))
          (etaf-web--sync-window-point (point)))))))

(defun etaf-web-scroll-page-down ()
  "Scroll the page down by one screen."
  (etaf-web--scroll-page 1))

(defun etaf-web-scroll-page-up ()
  "Scroll the page up by one screen."
  (etaf-web--scroll-page -1))

(defun etaf-web--sync-history-refs (session)
  "Update reactive `:can-back' and `:can-forward' refs on SESSION."
  (let ((idx (or (plist-get session :history-index) -1))
        (len (length (plist-get session :history))))
    (etaf-batch
      (etaf-set-value (plist-get session :can-back) (> idx 0))
      (etaf-set-value (plist-get session :can-forward) (and (>= idx 0) (< idx (1- len)))))))

;;; ---------------------------------------------------------------------------
;;; Retained-Host smooth progress bar animation (zero full-view rerender)
;;; ---------------------------------------------------------------------------

(defun etaf-web--stop-anim (session)
  "Cancel any running inline progress easing timer on SESSION."
  (when-let* ((tm (plist-get session :anim-timer)))
    (when (timerp tm) (cancel-timer tm))
    (plist-put session :anim-timer nil)))

(defun etaf-web--patch-progress-hosts (session)
  "Update retained inline text-progress Host in-place without rerendering."
  (let* ((buf (plist-get session :buffer))
         (rt (and (buffer-live-p buf) (etaf-runtime-for-buffer buf))))
    (when (and rt (etaf-runtime-mounted-p rt)
               (not (etaf-value (plist-get session :address-editing)))
               (etaf-runtime-host-props-for rt 'web-status))
      (let* ((vw (max 44 (or (etaf-value (plist-get session :viewport-width)) 96)))
             (narrow (< vw etaf-web--narrow-breakpoint))
             (prog (or (plist-get session :progress-display) 0.0))
             (phase (etaf-value (plist-get session :phase)))
             (stage (etaf-value (plist-get session :stage-label)))
             (elapsed (if (plist-get session :started-at)
                          (- (float-time) (plist-get session :started-at))
                        0.0))
             (page (etaf-value (plist-get session :page)))
             (mode-label (and (listp page) (plist-get page :mode-label)))
             (status-str (etaf-web--status-text
                          phase stage elapsed prog
                          (etaf-value (plist-get session :cached))
                          narrow (plist-get session :spin-index) mode-label)))
        (etaf-runtime-update-host-contents
         rt (list (cons 'web-status status-str)))))))

(defun etaf-web--anim-tick (session)
  "Advance inline text-progress easing via retained Host span-patch."
  (let ((buf (plist-get session :buffer)))
    (if (or (not (buffer-live-p buf))
            (not (eq (etaf-value (plist-get session :phase)) 'loading)))
        (etaf-web--stop-anim session)
      (let* ((cur (or (plist-get session :progress-display) 0.0))
             (target (or (plist-get session :progress-target) 0.15))
             ;; Ease smoothly toward target, with gentle creep up to 0.90 while waiting.
             (ceiling (max target (min 0.90 (+ target 0.35))))
             (step (if (< cur target)
                       (max 0.015 (* 0.22 (- target cur)))
                     (* 0.018 (- ceiling cur))))
             (next (min 0.96 (+ cur step))))
        (plist-put session :spin-index (1+ (or (plist-get session :spin-index) 0)))
        (plist-put session :progress-display next)
        (etaf-web--patch-progress-hosts session)))))

(defun etaf-web--start-anim (session)
  "Start 60 ms retained-Host progress easing timer for SESSION."
  (etaf-web--stop-anim session)
  (plist-put session :spin-index 0)
  (plist-put session :started-at (float-time))
  (plist-put session :anim-timer
             (run-with-timer etaf-web--anim-interval etaf-web--anim-interval
                             #'etaf-web--anim-tick session)))

(defun etaf-web--finish-progress-bar (session)
  "Stop progress animation cleanly; idle header shows minimal status only."
  (etaf-web--stop-anim session)
  (plist-put session :progress-target 1.0)
  (plist-put session :progress-display 1.0))

;;; ---------------------------------------------------------------------------
;;; Navigation, `#anchor' jump & `etaf-md' session creation
;;; ---------------------------------------------------------------------------

(defun etaf-web--session-outline (session)
  "Return outline `(LEVEL TEXT ID)' list for SESSION from `etaf-md' or page."
  (let ((md (etaf-value (plist-get session :md-session)))
        (page (etaf-value (plist-get session :page))))
    (cond
     (md (etaf-md-outline md))
     ((listp page) (plist-get page :outline))
     (t nil))))

(defun etaf-web--locate-heading (session index)
  "Scroll SESSION's page viewport to outline heading INDEX and return position."
  (let ((buf (plist-get session :buffer))
        (md (etaf-value (plist-get session :md-session))))
    (when (buffer-live-p buf)
      (let ((pos
             (cond
              (md (etaf-md-locate md index))
              (t
               (when-let* ((outline (etaf-web--session-outline session))
                           (entry (nth index outline))
                           (id (nth 2 entry))
                           (ref (and (stringp id) (not (string-empty-p id))
                                     (intern (format "etaf-md-heading-%s" id))))
                           (rt (etaf-runtime-for-buffer buf)))
                 (when (and (etaf-runtime-mounted-p rt)
                            (etaf-runtime-host-props-for rt ref))
                   (etaf-scroll-into-view rt ref 'start)
                   (when-let* ((p (etaf-host-ref-position rt ref)))
                     (with-current-buffer buf
                       (goto-char p)
                       p))))))))
        (when pos
          (with-current-buffer buf
            (when-let* ((win (get-buffer-window buf t)))
              (set-window-point win pos)
              (set-window-start win (point-min) t)))
          (let ((rt (etaf-runtime-for-buffer buf)))
            (plist-put session :heading-index index)
            (plist-put session :heading-scroll
                       (etaf-web--current-scroll-offset rt))))
        pos))))

(defun etaf-web--jump-anchor (session fragment)
  "Scroll SESSION's page viewport to the heading matching FRAGMENT."
  (let ((buf (plist-get session :buffer))
        (outline (etaf-web--session-outline session)))
    (when (and (buffer-live-p buf) outline fragment (not (string-empty-p fragment)))
      (let* ((decoded (or (ignore-errors (url-unhex-string fragment)) fragment))
             (norm (downcase decoded))
             (norm-raw (downcase fragment))
             (idx (cl-position-if
                   (lambda (entry)
                     (let ((text (downcase (or (nth 1 entry) "")))
                           (id (downcase (or (nth 2 entry) ""))))
                       (or (equal id norm)
                           (equal id norm-raw)
                           (equal text norm)
                           (string-match-p (regexp-quote norm) id))))
                   outline)))
        (when idx
          (etaf-web--locate-heading session idx))))))

(defun etaf-web--open-in-external-browser (url)
  "Open URL via `etaf-web-external-browser-function' or `browse-url'."
  (when (and (stringp url) (not (string-empty-p url)))
    (if (functionp etaf-web-external-browser-function)
        (funcall etaf-web-external-browser-function url)
      (browse-url url))))

(defun etaf-web--make-md-session-from-text (session text title)
  "Build an `etaf-md-create' session from Markdown TEXT inside browser SESSION."
  (let ((theme-mode (etaf-value (plist-get session :theme-mode))))
    (etaf-md-create
     :text (or text "")
     :title title
     :theme (if (eq theme-mode 'auto) 'auto theme-mode)
     :link-hover nil
     :heading-underline nil
     :on-link
     (lambda (url)
       (cond
        ((string-prefix-p "browser:" url)
         (etaf-web--open-in-external-browser
          (substring url (length "browser:")))
         t)
        ((string-prefix-p "#" url)
         (etaf-web--jump-anchor session (substring url 1))
         t)
        ((etaf-web--http-url-p url)
         (let* ((frag (and (string-match "#\\(.+\\)\\'" url)
                           (match-string 1 url))))
           (etaf-web--navigate session url :push t :fragment frag))
         t)
        (t nil))))))

(defun etaf-web--make-md-session (session index-file title)
  "Build an `etaf-md-create' session for INDEX-FILE inside browser SESSION."
  (let* ((theme-mode (etaf-value (plist-get session :theme-mode)))
         (md (etaf-md-create
              :file index-file
              :title title
              :theme (if (eq theme-mode 'auto) 'auto theme-mode)
              :link-hover nil
              :heading-underline nil
              :on-link
              (lambda (url)
                (cond
                 ((string-prefix-p "browser:" url)
                  (etaf-web--open-in-external-browser
                   (substring url (length "browser:")))
                  t)
                 ((string-prefix-p "#" url)
                  (etaf-web--jump-anchor session (substring url 1))
                  t)
                 ((etaf-web--http-url-p url)
                  (let* ((frag (and (string-match "#\\(.+\\)\\'" url)
                                    (match-string 1 url))))
                    (etaf-web--navigate session url :push t :fragment frag))
                  t)
                 (t nil))))))
    md))

(defun etaf-web--make-reader-page (canonical title md)
  "Wrap Tier 1 `etaf-md' session MD in a uniform Page Controller."
  (etaf-web--make-page-controller
   :tier 't1
   :adapter nil
   :mode-label nil
   :url canonical
   :title title
   :md-session md
   :render (lambda (_ctx) (etaf-md-view md))
   :on-theme (lambda (next) (etaf-md-set-theme md next))
   :on-width (lambda (delta) (etaf-md-adjust-width md delta))))

(defun etaf-web--install-page (session gen canonical page cached restore-scroll fragment)
  "Commit ready PAGE controller onto SESSION if generation GEN is still current."
  (when (and (eql gen (plist-get session :generation))
             (buffer-live-p (plist-get session :buffer)))
    (let* ((old-page (etaf-value (plist-get session :page)))
           (page-url (or (plist-get page :url) canonical))
           (title (or (plist-get page :title)
                      (car (etaf-web--url-parts page-url))))
           (md (plist-get page :md-session))
           (idx (plist-get session :history-index))
           (hist (plist-get session :history)))
      (unless (eq old-page page)
        (etaf-web--dispose-page-controller old-page))
      (when (and (integerp idx) (>= idx 0) (< idx (length hist)))
        (plist-put (nth idx hist) :title title))
      (etaf-web--finish-progress-bar session)
      (etaf-batch
        (etaf-set-value (plist-get session :url) page-url)
        (etaf-set-value (plist-get session :title) title)
        (etaf-set-value (plist-get session :cached) cached)
        (etaf-set-value (plist-get session :page) page)
        (etaf-set-value (plist-get session :md-session) md)
        (etaf-set-value (plist-get session :md-gen)
                        (1+ (or (etaf-value (plist-get session :md-gen)) 0)))
        (etaf-set-value (plist-get session :stage-label)
                        (or (plist-get page :mode-label)
                            (if cached "缓存" "完成")))
        (etaf-set-value (plist-get session :phase) 'ready)
        (etaf-web--bump-chrome-if-focused session))
      (let ((buf (plist-get session :buffer)))
        (when (buffer-live-p buf)
          (let ((new-host (car (etaf-web--url-parts page-url))))
            (when (and (stringp new-host)
                       (not (string-empty-p new-host))
                       (not (equal new-host (plist-get session :buffer-host))))
              (plist-put session :buffer-host new-host)
              (with-current-buffer buf
                (rename-buffer (etaf-web--buffer-name-for-source page-url) t))))
          (when-let* ((rt (etaf-runtime-for-buffer buf)))
            (etaf-runtime-flush rt))
          (cond
           (restore-scroll
            (etaf-web--restore-scroll-position
             session (car restore-scroll) (cdr restore-scroll)))
           (fragment
            (unless (etaf-web--jump-anchor session fragment)
              (etaf-web--restore-scroll-position session 0 nil)))
           (t
            (etaf-web--restore-scroll-position session 0 nil))))))))

(defun etaf-web--commit-error (session gen err-info)
  "Commit error card ERR-INFO onto SESSION if generation GEN is still current."
  (when (and (eql gen (plist-get session :generation))
             (buffer-live-p (plist-get session :buffer)))
    (etaf-web--stop-anim session)
    (plist-put session :progress-display 0.0)
    (etaf-batch
      (etaf-set-value (plist-get session :error-info) err-info)
      (etaf-set-value (plist-get session :stage-label) "失败")
      (etaf-set-value (plist-get session :phase) 'error)
      (etaf-web--bump-chrome-if-focused session))
    (when-let* ((rt (etaf-runtime-for-buffer (plist-get session :buffer))))
      (etaf-runtime-flush rt))))

(defun etaf-web--make-link-handler (session)
  "Return standard link activation callback for browser SESSION."
  (lambda (url)
    (cond
     ((string-prefix-p "browser:" url)
      (etaf-web--open-in-external-browser
       (substring url (length "browser:")))
      t)
     ((string-prefix-p "#" url)
      (etaf-web--jump-anchor session (substring url 1))
      t)
     ((etaf-web--http-url-p url)
      (let* ((frag (and (string-match "#\\(.+\\)\\'" url)
                        (match-string 1 url))))
        (etaf-web--navigate session url :push t :fragment frag))
      t)
     (t nil))))

(defun etaf-web--start-adapter (session job gen adapter canonical headers html dom
                                        force restore-scroll fragment on-stage)
  "Launch Tier 2 ADAPTER for SESSION under JOB and generation GEN.
Returns non-nil when ADAPTER claimed the load, or nil to fall back to Tier 1."
  (let* ((adapter-name (plist-get adapter :name))
         (adapter-label (plist-get adapter :label))
         (open-fn (plist-get adapter :open))
         (ctx (list :url canonical
                    :headers headers
                    :html html
                    :dom dom
                    :force force
                    :buffer (plist-get session :buffer)
                    :theme-mode (plist-get session :theme-mode)
                    :sidebar-width-px (plist-get session :sidebar-width-px)
                    :docs-measure (plist-get session :docs-measure)
                    :open-link (etaf-web--make-link-handler session)
                    :make-md (lambda (text title &optional index-file)
                               (if (and index-file (file-readable-p index-file))
                                   (etaf-web--make-md-session session index-file title)
                                 (etaf-web--make-md-session-from-text session text title)))
                    :focus-input (lambda (ref)
                                   (when-let* ((buf (plist-get session :buffer))
                                               (rt (and (buffer-live-p buf)
                                                        (etaf-runtime-for-buffer buf))))
                                     (etaf-runtime-flush rt)
                                     (etaf-text-input-begin rt ref)))
                    :navigate (lambda (target &rest opts)
                                (apply #'etaf-web--navigate session target
                                       :push (if (plist-member opts :push)
                                                 (plist-get opts :push)
                                               t)
                                       opts))
                    :open-external #'etaf-web--open-in-external-browser
                    :on-stage on-stage
                    :on-ready
                    (lambda (spec)
                      (let ((page (if (and (listp spec) (plist-get spec :tier))
                                      spec
                                    (etaf-web--make-page-controller
                                     :tier 't2
                                     :adapter adapter-name
                                     :mode-label (or (plist-get spec :mode-label)
                                                     adapter-label)
                                     :url (or (plist-get spec :url) canonical)
                                     :title (plist-get spec :title)
                                     :render (plist-get spec :render)
                                     :keys (plist-get spec :keys)
                                     :own-scroll (plist-get spec :own-scroll)
                                     :outline (plist-get spec :outline)
                                     :on-reload (plist-get spec :on-reload)
                                     :on-theme (plist-get spec :on-theme)
                                     :on-width (plist-get spec :on-width)
                                     :on-headings (plist-get spec :on-headings)
                                     :dispose (plist-get spec :dispose)
                                     :md-session (plist-get spec :md-session)))))
                        (etaf-web--install-page
                         session gen canonical page
                         (plist-get spec :cached) restore-scroll fragment)))
                    :on-error
                    (lambda (err-info)
                      (etaf-web--commit-error
                       session gen
                       (if (stringp err-info)
                           (list :kind 'adapter :message err-info
                                 :url canonical :has-cache nil)
                         err-info))))))
    (when on-stage
      (funcall on-stage 'adapter adapter-label 0.45))
    (condition-case err
        (let ((result (funcall open-fn ctx)))
          (if (eq result 'fallback)
              nil
            (when (functionp result)
              (etaf-web--job-add-cancel job result))
            t))
      (error
       (etaf-web--commit-error
        session gen
        (list :kind 'adapter
              :message (format "站型适配器 %s 失败: %s"
                               adapter-label (error-message-string err))
              :url canonical
              :has-cache nil))
       t))))

(defconst etaf-web--content-ssg-regexp
  (concat
   "vuepress\\|vitepress\\|hexo\\|hugo\\|astro\\|jekyll\\|ghost\\|"
   "wordpress\\|docusaurus\\|nextra\\|gatsby\\|eleventy\\|pelican\\|"
   "zola\\|mkdocs\\|sphinx\\|starlight\\|gitbook\\|antora\\|fumadocs")
  "Generator metadata pattern identifying content/blog/documentation SSGs.")

(defun etaf-web--content-ssg-p (dom)
  "Return non-nil when DOM `<meta name=\"generator\">' names a content SSG."
  (cl-some (lambda (g)
             (string-match-p etaf-web--content-ssg-regexp (downcase g)))
           (etaf-web--meta-generators dom)))

(defun etaf-web--classify-hydrated-page
    (session job gen canonical html ir force restore-scroll fragment
             on-stage on-ready on-images)
  "Classify post-hydration HTML + IR in `auto' mode; return non-nil if claimed.
Routes hydrated pages with a matching Tier 2 archetype (e.g. SPA docs) to that
adapter, and routes hydrated content/blog/article pages (substantive prose with
no dominant interactive app controls in `<main>') to Tier 1 `etaf-md' reading
view with disk caching and async image backfill.  Returns nil for true
interactive web apps or canvas/challenge pages so Tier 3 Live CDP keeps them."
  (when (eql gen (plist-get session :generation))
    (let* ((canvas-ratio (or (and (listp ir) (plist-get ir :canvasRatio)) 0))
           (challenge (and (listp ir) (plist-get ir :challenge))))
      (unless (or (>= canvas-ratio 0.45) challenge)
        (let* ((route1 (etaf-web--route-html canonical nil html 'auto))
               (adapter (plist-get route1 :adapter))
               (dom (plist-get route1 :dom)))
          (or
           ;; 1. Post-hydration Tier 2 site-archetype match (e.g. JS-rendered docs).
           (and adapter
                (etaf-web--start-adapter
                 session job gen adapter canonical nil html dom
                 force restore-scroll fragment on-stage))
           ;; 2. Content/blog/article page vs interactive web application.
           (let* ((metrics (and (listp ir) (plist-get ir :appMetrics)))
                  (main-inputs (or (plist-get metrics :mainInputs) 0))
                  (main-widgets (or (plist-get metrics :mainWidgets) 0))
                  (main-buttons (or (plist-get metrics :mainButtons) 0))
                  (main-forms (or (plist-get metrics :mainForms) 0))
                  (interactive-score (+ main-inputs
                                        (* 2 main-widgets)
                                        main-forms
                                        (if (>= main-buttons 2) main-buttons 0)))
                  (page-dir (etaf-web--page-dir canonical))
                  (rewriter (etaf-web--make-local-image-rewriter page-dir))
                  (compiled (etaf-web--compile html :base-url canonical
                                               :image-rewriter rewriter))
                  (md (plist-get compiled :markdown))
                  (title (or (plist-get compiled :title)
                             (and (listp ir) (plist-get ir :title))
                             (car (etaf-web--url-parts canonical))))
                  (thin (etaf-web--markdown-thin-p md))
                  (prose-len (length (etaf-web--prose-text md)))
                  (ssg-p (etaf-web--content-ssg-p
                          (or dom (etaf-web--parse-html html)))))
             (when (and (not thin)
                        (or (zerop interactive-score)
                            (and ssg-p
                                 (zerop main-inputs)
                                 (zerop main-widgets)
                                 (>= prose-len 300))))
               (etaf-web--write-and-finish
                job canonical page-dir html md title nil
                on-stage on-ready on-images)
               t))))))))

(defun etaf-web--start-live (session job gen canonical restore-scroll fragment on-stage
                                     &optional on-hydrated)
  "Launch Tier 3 Live CDP view for SESSION under JOB and generation GEN.
When ON-HYDRATED is non-nil (in `auto' mode), invokes it with `(HTML IR)' after
initial hydration so content/docs pages can route to Tier 1/2."
  (let ((cancel
         (etaf-web-live--open
          (list :url canonical
                :buffer (plist-get session :buffer)
                :sidebar-width-px (plist-get session :sidebar-width-px)
                :open-external #'etaf-web--open-in-external-browser
                :on-hydrated on-hydrated
                :on-reader (lambda ()
                             (etaf-web--navigate session canonical
                                                 :push nil :force t :mode 'reader))
                :on-url-change (lambda (next-url next-title)
                                 (when (and (eql gen (plist-get session :generation))
                                            (buffer-live-p (plist-get session :buffer)))
                                   (etaf-batch
                                     (etaf-set-value (plist-get session :url) next-url)
                                     (when next-title
                                       (etaf-set-value (plist-get session :title) next-title)))))
                :on-stage on-stage
                :on-ready (lambda (page)
                            (etaf-web--install-page
                             session gen canonical page nil restore-scroll fragment))
                :on-error (lambda (err-info)
                            (etaf-web--commit-error session gen err-info))))))
    (when (functionp cancel)
      (etaf-web--job-add-cancel job cancel))
    t))

(cl-defun etaf-web--navigate (session source &key push force restore-scroll fragment mode)
  "Load SOURCE inside browser SESSION asynchronously.
When PUSH is non-nil, records a new history entry (truncating forward stack).
When FORCE is non-nil, bypasses cache.  RESTORE-SCROLL is `(SCROLL . POINT)'.
Optional FRAGMENT jumps to the matching heading after the page renders.
Optional MODE overrides rendering mode (`auto', `reader', `adapter', `live')."
  (let* ((validated (etaf-web--validate-source source))
         (canonical (plist-get validated :canonical))
         (route0 (etaf-web--route-url canonical mode))
         (eff-mode (plist-get route0 :mode))
         (url-adapter (plist-get route0 :adapter)))
    (when push
      (etaf-web--save-scroll-position session))
    (when-let* ((old-job (plist-get session :active-job)))
      (etaf-web--cancel-job old-job)
      (plist-put session :active-job nil))
    (when push
      (let* ((hist (plist-get session :history))
             (idx (or (plist-get session :history-index) -1))
             (prefix (if (>= idx 0) (seq-take hist (1+ idx)) nil))
             (entry (list :url canonical :title nil :scroll-offset 0 :point nil)))
        (plist-put session :history (append prefix (list entry)))
        (plist-put session :history-index (length prefix))))
    (etaf-web--record-url-history canonical)
    (plist-put session :heading-index nil)
    (plist-put session :heading-scroll nil)
    (plist-put session :progress-target 0.15)
    (plist-put session :progress-display 0.08)
    (etaf-batch
      (etaf-set-value (plist-get session :url) canonical)
      (etaf-set-value (plist-get session :render-mode) eff-mode)
      (etaf-set-value (plist-get session :address-editing) nil)
      (etaf-set-value (plist-get session :address-draft) canonical)
      (etaf-set-value (plist-get session :error-info) nil)
      (etaf-set-value (plist-get session :phase) 'loading)
      (etaf-set-value (plist-get session :stage-label) "抓取中")
      (etaf-set-value (plist-get session :cached) nil))
    (etaf-web--sync-history-refs session)
    (etaf-web--start-anim session)
    (let* ((gen (1+ (or (plist-get session :generation) 0)))
           (on-stage
            (lambda (_stage label prog)
              (when (and (eql gen (plist-get session :generation))
                         (buffer-live-p (plist-get session :buffer)))
                (plist-put session :progress-target prog)
                (unless (equal (etaf-value (plist-get session :stage-label)) label)
                  (etaf-set-value (plist-get session :stage-label) label))
                ;; Skip out-of-band span patch for synchronous cache hits:
                ;; `:on-ready' immediately follows in the same turn and
                ;; commits the clean ready header.
                (when (and (eq (etaf-value (plist-get session :phase)) 'loading)
                           (not (equal label "缓存")))
                  (etaf-web--patch-progress-hosts session)))))
           (job nil))
      (plist-put session :generation gen)
      (cond
       ((and (eq eff-mode 'live) (etaf-web--http-url-p canonical))
        (let ((ljob (etaf-web--load-job-create :url canonical)))
          (etaf-web--start-live
           session ljob gen canonical restore-scroll fragment on-stage)
          (setq job ljob)))
       (url-adapter
        (let ((ajob (etaf-web--load-job-create :url canonical)))
          (when (etaf-web--start-adapter
                 session ajob gen url-adapter canonical nil nil nil
                 force restore-scroll fragment on-stage)
            (setq job ajob)))))
      (unless job
        (let ((on-reader-ready
               (lambda (info)
                 (when (and (eql gen (plist-get session :generation))
                            (buffer-live-p (plist-get session :buffer)))
                   (let* ((index-file (plist-get info :index-file))
                          (title (or (plist-get info :title)
                                     (car (etaf-web--url-parts canonical))))
                          (cached (plist-get info :cached))
                          (md (etaf-web--make-md-session session index-file title))
                          (page (etaf-web--make-reader-page canonical title md)))
                     (etaf-web--install-page
                      session gen canonical page cached restore-scroll fragment)))))
              (on-reader-images
               (lambda (_index-file)
                 (when (and (eql gen (plist-get session :generation))
                            (buffer-live-p (plist-get session :buffer))
                            (eq (etaf-value (plist-get session :phase)) 'ready))
                   (let* ((buf (plist-get session :buffer))
                          (rt (etaf-runtime-for-buffer buf))
                          (pt (with-current-buffer buf (point)))
                          (off (etaf-web--current-scroll-offset rt)))
                     (when-let* ((md (etaf-value (plist-get session :md-session))))
                       (ignore-errors (etaf-md-refresh md))
                       (when rt
                         (ignore-errors (etaf-runtime-flush rt)))
                       (etaf-web--restore-scroll-position session off pt)))))))
          (setq job
                (etaf-web--load-page-async
                 source
                 :force force
                 :on-html
                 (unless (eq eff-mode 'reader)
                   (lambda (headers html url load-job)
                     (when (eql gen (plist-get session :generation))
                       (let* ((route1 (etaf-web--route-html url headers html eff-mode))
                              (adapter (plist-get route1 :adapter)))
                         (when adapter
                           (etaf-web--start-adapter
                            session load-job gen adapter url headers html
                            (plist-get route1 :dom)
                            force restore-scroll fragment on-stage))))))
                 :on-script-shell
                 (when (and (eq eff-mode 'auto)
                            (null etaf-web-render-command)
                            (etaf-web-cdp-available-p))
                   (lambda (url load-job)
                     (when (eql gen (plist-get session :generation))
                       (etaf-web--start-live
                        session load-job gen url restore-scroll fragment on-stage
                        (lambda (hyd-html hyd-ir)
                          (etaf-web--classify-hydrated-page
                           session load-job gen url hyd-html hyd-ir
                           force restore-scroll fragment on-stage
                           on-reader-ready on-reader-images))))))
                 :on-stage on-stage
                 :on-ready on-reader-ready
                 :on-images on-reader-images
                 :on-error
                 (lambda (err-info)
                   (etaf-web--commit-error session gen err-info))))))
      (plist-put session :active-job job)
      job)))

;;; ---------------------------------------------------------------------------
;;; Address bar completion
;;; ---------------------------------------------------------------------------

(defun etaf-web--address-capf ()
  "Completion-at-point function offering visited URL history in address bar."
  (let ((bounds (cons (line-beginning-position) (line-end-position))))
    (list (car bounds) (cdr bounds) etaf-web--url-history :exclusive 'no)))

;;; ---------------------------------------------------------------------------
;;; Public browser commands
;;; ---------------------------------------------------------------------------

(defun etaf-web-open (source &optional other-window)
  "Open web page or local HTML file SOURCE in its own ETAF Web browser buffer.
SOURCE is either a local HTML file path (or `file://' URL) or an `http://' /
`https://' URL.  Returns the newly created browser buffer (`*Web: <host>*')
immediately while HTTP fetching, optional headless rendering, and background
image caching run asynchronously without blocking Emacs.
With OTHER-WINDOW non-nil, displays the buffer in another window.
Signals `etaf-web-error' synchronously on invalid SOURCE or unreadable local
HTML files; network and HTTP errors render inside the page's error card."
  (interactive
   (list (read-string "Web URL or HTML file: " nil nil (car etaf-web--url-history))
         current-prefix-arg))
  (let* ((normalized (etaf-web--normalize-user-input source))
         (validated (etaf-web--validate-source normalized))
         (canonical (plist-get validated :canonical))
         (buf-name (etaf-web--buffer-name-for-source canonical))
         (session nil))
    (setq session
          (list :app 'etaf-web
                :buffer nil
                :buffer-host (car (etaf-web--url-parts canonical))
                :url (etaf-ref canonical :name 'web-url)
                :title (etaf-ref (car (etaf-web--url-parts canonical)) :name 'web-title)
                :phase (etaf-ref 'loading :name 'web-phase)
                :stage-label (etaf-ref "抓取中" :name 'web-stage)
                :progress-target 0.15
                :progress-display 0.08
                :cached (etaf-ref nil :name 'web-cached)
                :error-info (etaf-ref nil :name 'web-error)
                :page (etaf-ref nil :name 'web-page)
                :render-mode (etaf-ref 'auto :name 'web-render-mode)
                :md-session (etaf-ref nil :name 'web-md-session)
                :md-gen (etaf-ref 0 :name 'web-md-gen)
                :chrome-gen (etaf-ref 0 :name 'web-chrome-gen)
                :can-back (etaf-ref nil :name 'web-can-back)
                :can-forward (etaf-ref nil :name 'web-can-forward)
                :address-editing (etaf-ref nil :name 'web-address-editing)
                :address-draft (etaf-ref canonical :name 'web-address-draft)
                :viewport-width (etaf-ref 96 :name 'web-viewport-width)
                :viewport-height (etaf-ref 24 :name 'web-viewport-height)
                :viewport-px (etaf-ref nil :name 'web-viewport-px)
                :char-width (etaf-ref (car (etaf-web--cell-metrics)) :name 'web-char-width)
                :sidebar-width-px (etaf-ref nil :name 'web-sidebar-width-px)
                :docs-measure (etaf-ref 84 :name 'web-docs-measure)
                :theme-mode (etaf-ref 'auto :name 'web-theme-mode)
                :theme-rev (etaf-ref 0 :name 'web-theme-rev)
                :theme-hook nil
                :history nil
                :history-index -1
                :active-job nil
                :anim-timer nil
                :pre-edit-pos nil
                :heading-index nil
                :heading-scroll nil
                :started-at (float-time)
                :spin-index 0
                :generation 0))
    (plist-put
     session :callbacks
     (list
      :back (lambda () (etaf-web--do-back session))
      :forward (lambda () (etaf-web--do-forward session))
      :reload (lambda () (etaf-web--do-reload session))
      :stop (lambda () (etaf-web--do-stop session))
      :open-external (lambda () (etaf-web--do-open-external session))
      :set-mode (lambda ()
                  (when-let* ((buf (plist-get session :buffer)))
                    (when (buffer-live-p buf)
                      (with-current-buffer buf
                        (call-interactively #'etaf-web-set-mode)))))
      :help (lambda ()
              (when-let* ((buf (plist-get session :buffer))
                          (rt (and (buffer-live-p buf)
                                   (etaf-runtime-for-buffer buf))))
                (etaf-help rt)))
      :load-cached (lambda ()
                     (etaf-web--navigate session (etaf-value (plist-get session :url))
                                         :push nil :force nil))
      :focus-address (lambda () (etaf-web--do-focus-address session))
      :address-capf #'etaf-web--address-capf
      :address-submit (lambda (text)
                        (etaf-web--exit-address-editing session nil)
                        (let ((target (etaf-web--normalize-user-input text)))
                          (unless (string-empty-p target)
                            (condition-case err
                                (etaf-web--navigate session target :push t)
                              (etaf-web-error
                               (message "%s" (error-message-string err)))))))
      :address-cancel (lambda (_text)
                        (etaf-web--exit-address-editing session t))
      :address-focus-return (lambda ()
                              (etaf-web--maybe-exit-address-editing session))
      :address-dismiss (lambda ()
                         (etaf-web--exit-address-editing session t))
      :direction (lambda (dir)
                   (etaf-web--handle-direction session dir))))
    (when other-window
      (etaf-web--select-other-window))
    (let ((buffer
           (etaf-app-open
            buf-name
            (etaf-view (etaf-web--browser-app :session session :keys etaf-web--keys))
            :state session
            :mode-line t
            :mount-options '(:text-selection t)
            :background (lambda ()
                          (let ((m (etaf-value (plist-get session :theme-mode))))
                            (unless (eq m 'auto)
                              (plist-get (etaf-web--palette m) :bg))))
            :on-fit (lambda (win)
                      (let* ((live (window-live-p win))
                             (w (if live (window-body-width win) 96))
                             (h (if live (window-body-height win) 24))
                             (cell-w (car (etaf-web--cell-metrics)))
                             (px (if live (window-body-width win t) (* w cell-w)))
                             (cw (if (and live (> w 0) (> px 0))
                                     (/ (float px) w)
                                   (float cell-w))))
                        (etaf-batch
                          (etaf-set-value (plist-get session :viewport-width) w)
                          (etaf-set-value (plist-get session :viewport-height) h)
                          (etaf-set-value (plist-get session :viewport-px) px)
                          (etaf-set-value (plist-get session :char-width) cw))))
            :on-close (lambda ()
                        (etaf-web--stop-anim session)
                        (when-let* ((thook (plist-get session :theme-hook)))
                          (when (boundp 'enable-theme-functions)
                            (remove-hook 'enable-theme-functions thook))
                          (when (boundp 'disable-theme-functions)
                            (remove-hook 'disable-theme-functions thook))
                          (plist-put session :theme-hook nil))
                        (when-let* ((job (plist-get session :active-job)))
                          (etaf-web--cancel-job job)
                          (plist-put session :active-job nil))
                        (etaf-web--dispose-page-controller
                         (etaf-value (plist-get session :page)))
                        (plist-put session :buffer nil)))))
      (with-current-buffer buffer
        (setq-local etaf-cursor-follows-input-modality nil)
        (when (null cursor-type)
          (setq-local cursor-type (or (default-value 'cursor-type) t)))
        (setq-local filter-buffer-substring-function
                    #'etaf-web--filter-buffer-substring))
      (let ((thook (lambda (_theme)
                     (let ((b (plist-get session :buffer)))
                       (when (buffer-live-p b)
                         (let ((rev (plist-get session :theme-rev)))
                           (when rev
                             (etaf-set-value rev (1+ (or (etaf-value rev) 0))))))))))
        (plist-put session :theme-hook thook)
        (when (boundp 'enable-theme-functions)
          (add-hook 'enable-theme-functions thook))
        (when (boundp 'disable-theme-functions)
          (add-hook 'disable-theme-functions thook)))
      (plist-put session :buffer buffer)
      ;; Start loading AFTER mount so zero I/O occurs inside render/mount.
      (etaf-web--navigate session normalized :push t)
      buffer)))

(defun etaf-web--do-back (session)
  "Navigate SESSION one step backward in its history stack, restoring scroll."
  (let ((idx (plist-get session :history-index))
        (hist (plist-get session :history)))
    (if (and (integerp idx) (> idx 0))
        (progn
          (etaf-web--save-scroll-position session)
          (let* ((prev-idx (1- idx))
                 (entry (nth prev-idx hist)))
            (plist-put session :history-index prev-idx)
            (etaf-web--navigate
             session (plist-get entry :url)
             :push nil :force nil
             :restore-scroll (cons (plist-get entry :scroll-offset)
                                   (plist-get entry :point)))))
      (message "已在历史起点"))))

(defun etaf-web--do-forward (session)
  "Navigate SESSION one step forward in its history stack, restoring scroll."
  (let ((idx (plist-get session :history-index))
        (hist (plist-get session :history)))
    (if (and (integerp idx) (< idx (1- (length hist))))
        (progn
          (etaf-web--save-scroll-position session)
          (let* ((next-idx (1+ idx))
                 (entry (nth next-idx hist)))
            (plist-put session :history-index next-idx)
            (etaf-web--navigate
             session (plist-get entry :url)
             :push nil :force nil
             :restore-scroll (cons (plist-get entry :scroll-offset)
                                   (plist-get entry :point)))))
      (message "已在历史终点"))))

(defun etaf-web--do-reload (session)
  "Re-fetch the current page of SESSION bypassing cache."
  (when-let* ((rev (plist-get session :theme-rev)))
    (etaf-set-value rev (1+ (or (etaf-value rev) 0))))
  (let* ((page (etaf-value (plist-get session :page)))
         (custom-reload (and (listp page) (plist-get page :on-reload)))
         (url (etaf-value (plist-get session :url))))
    (cond
     ((functionp custom-reload)
      (funcall custom-reload))
     ((and (stringp url) (not (string-empty-p url)))
      (etaf-web--navigate session url :push nil :force t)))))

(defun etaf-web--do-stop (session)
  "Cancel any in-flight page load in SESSION cleanly."
  (when-let* ((job (plist-get session :active-job)))
    (etaf-web--cancel-job job)
    (plist-put session :active-job nil))
  (plist-put session :generation (1+ (or (plist-get session :generation) 0)))
  (etaf-web--stop-anim session)
  (let ((prev-page (or (etaf-value (plist-get session :page))
                       (etaf-value (plist-get session :md-session)))))
    (etaf-batch
      (if prev-page
          (progn
            (etaf-set-value (plist-get session :stage-label) "已取消")
            (etaf-set-value (plist-get session :phase) 'ready))
        (etaf-set-value (plist-get session :error-info)
                  (list :kind 'cancelled
                        :message "加载已被用户取消"
                        :url (etaf-value (plist-get session :url))
                        :has-cache nil))
        (etaf-set-value (plist-get session :stage-label) "已取消")
        (etaf-set-value (plist-get session :phase) 'error)))))

(defun etaf-web--exit-address-editing (session &optional restore-scroll)
  "Exit inline address editing in SESSION cleanly and release temporary hooks.
When RESTORE-SCROLL is non-nil, restores the pre-edit viewport scroll offset
and point; otherwise keeps the top viewport intact so the content start line
never shifts."
  (let* ((buf (plist-get session :buffer))
         (rt (and (buffer-live-p buf) (etaf-runtime-for-buffer buf)))
         (saved (plist-get session :pre-edit-pos)))
    (plist-put session :pre-edit-pos nil)
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (remove-hook 'pre-command-hook #'etaf-web--address-pre-command t)
        (remove-hook 'post-command-hook #'etaf-web--sync-address-editing t)))
    (when (and rt (etaf-text-input-active-p rt))
      (etaf-text-input-end 'blur))
    (when (etaf-value (plist-get session :address-editing))
      (etaf-batch
        (etaf-set-value (plist-get session :address-editing) nil)
        (etaf-web--bump-chrome-if-focused session))
      (when (and rt (etaf-runtime-mounted-p rt))
        (etaf-runtime-flush rt)))
    (when (and restore-scroll (buffer-live-p buf) saved)
      (etaf-web--restore-scroll-position session (car saved) (cdr saved)))))

(defun etaf-web--maybe-exit-address-editing (session)
  "Exit inline address editing if SESSION's native text-input session ended."
  (let* ((buf (plist-get session :buffer))
         (rt (and (buffer-live-p buf) (etaf-runtime-for-buffer buf))))
    (when (and (etaf-value (plist-get session :address-editing))
               (not (and rt (etaf-text-input-active-p rt))))
      (etaf-web--exit-address-editing session t))))

(defun etaf-web--address-pre-command ()
  "Clean up inline address editing before Emacs runs native `keyboard-quit'.
Does not bind or alter `C-g': Emacs keeps its native quit binding and
interruption semantics while temporary inline editing state is released."
  (when (memq this-command '(keyboard-quit keyboard-escape-quit))
    (let ((session (ignore-errors (etaf-web--current-session))))
      (if (not session)
          (remove-hook 'pre-command-hook #'etaf-web--address-pre-command t)
        (when (etaf-value (plist-get session :address-editing))
          (etaf-web--exit-address-editing session t))))))

(defun etaf-web--sync-address-editing ()
  "Exit inline address editing if the native text-input session ended."
  (let ((session (ignore-errors (etaf-web--current-session))))
    (if (not session)
        (remove-hook 'post-command-hook #'etaf-web--sync-address-editing t)
      (etaf-web--maybe-exit-address-editing session))))

(defun etaf-web--start-address-input (session)
  "Begin native text-input editing on SESSION's address field once mounted."
  (let* ((buf (plist-get session :buffer))
         (rt (and (buffer-live-p buf) (etaf-runtime-for-buffer buf))))
    (when (and rt (etaf-value (plist-get session :address-editing)))
      (unless (etaf-text-input-active-p rt)
        (etaf-runtime-flush rt)
        (etaf-text-input-begin rt 'web-address-input))
      (when (etaf-text-input-active-p rt)
        (with-current-buffer buf
          (when-let* ((win (get-buffer-window buf t)))
            (when (> (window-start win) (point-min))
              (set-window-start win (point-min) t)))
          (add-hook 'pre-command-hook #'etaf-web--address-pre-command -50 t)
          (add-hook 'post-command-hook #'etaf-web--sync-address-editing t t))))))

(defun etaf-web--do-focus-address (session)
  "Open the inline editable address bar in SESSION and begin editing."
  (let* ((url (etaf-value (plist-get session :url)))
         (buf (plist-get session :buffer)))
    (when (and (buffer-live-p buf)
               (not (etaf-value (plist-get session :address-editing))))
      (with-current-buffer buf
        (let* ((rt (etaf-runtime-for-buffer buf))
               (off (etaf-web--current-scroll-offset rt)))
          (plist-put session :pre-edit-pos (cons off (point))))))
    (etaf-batch
      (etaf-set-value (plist-get session :address-draft) (or url ""))
      (etaf-set-value (plist-get session :address-editing) t))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (add-hook 'pre-command-hook #'etaf-web--address-pre-command -50 t))
      (when-let* ((rt (etaf-runtime-for-buffer buf)))
        (etaf-web--start-address-input session)
        ;; When invoked from an `:on-press' handler on the toolbar URL, ETAF
        ;; flushes the newly mounted input after the press batch settles, so
        ;; start native editing on the next tick once the batch completes.
        (unless (etaf-text-input-active-p rt)
          (etaf-next-tick
           (lambda () (etaf-web--start-address-input session))))))))

(defun etaf-web--do-open-external (session)
  "Open SESSION's current URL in the user's configured external/pixel browser."
  (let ((url (etaf-value (plist-get session :url))))
    (etaf-web--open-in-external-browser url)))

(defun etaf-web-set-mode (mode)
  "Switch the current ETAF Web buffer's rendering MODE and reload the page.
MODE is one of the symbols `auto', `reader', `adapter' or `live' (or its name
string).  The choice is persisted per host under `etaf-web-cache-directory'.
Signals `etaf-web-error' on an unsupported mode."
  (interactive
   (list (intern (completing-read "Rendering mode: "
                                  '("auto" "reader" "adapter" "live")
                                  nil t))))
  (let ((sym (if (stringp mode) (intern mode) mode)))
    (unless (memq sym etaf-web--valid-modes)
      (signal 'etaf-web-error
              (list (format "Unsupported rendering mode: %S" mode))))
    (let* ((session (etaf-web--current-session))
           (url (etaf-value (plist-get session :url)))
           (host (car (etaf-web--url-parts url))))
      (when (and (stringp host) (not (string-empty-p host))
                 (not (equal host "file")))
        (etaf-web--site-pref-set host sym))
      (etaf-set-value (plist-get session :render-mode) sym)
      (when (and (stringp url) (not (string-empty-p url)))
        (etaf-web--navigate session url :push nil :force t :mode sym))
      sym)))

(defun etaf-web-back ()
  "Go back one entry in the current ETAF Web browser buffer's history."
  (interactive)
  (etaf-web--do-back (etaf-web--current-session)))

(defun etaf-web-forward ()
  "Go forward one entry in the current ETAF Web browser buffer's history."
  (interactive)
  (etaf-web--do-forward (etaf-web--current-session)))

(defun etaf-web-reload ()
  "Re-fetch and recompile the current ETAF Web page bypassing cache."
  (interactive)
  (etaf-web--do-reload (etaf-web--current-session)))

(defun etaf-web-stop ()
  "Stop any in-flight fetch or headless render in the current ETAF Web buffer."
  (interactive)
  (etaf-web--do-stop (etaf-web--current-session)))

(defun etaf-web-focus-address ()
  "Focus and edit the address bar of the current ETAF Web buffer."
  (interactive)
  (etaf-web--do-focus-address (etaf-web--current-session)))

(defun etaf-web-open-external ()
  "Open the current ETAF Web page URL in the external system browser."
  (interactive)
  (etaf-web--do-open-external (etaf-web--current-session)))

(defun etaf-web-close ()
  "Close the current ETAF Web browser buffer, cancelling active loads."
  (interactive)
  (etaf-web--current-session)
  (let ((win (selected-window)))
    (etaf-app-close)
    (when (and (window-live-p win) (not (one-window-p t)))
      (ignore-errors (delete-window win)))))

(defun etaf-web-state (&optional buffer)
  "Return a detached state plist snapshot for ETAF Web BUFFER (default current).
Keys are `:url', `:title', `:phase' (`loading', `ready' or `error'), `:stage',
`:progress', `:cached', `:error', `:can-back', `:can-forward',
`:history-length', `:address-editing', `:narrow', `:width', `:tier', `:mode'
and `:adapter'."
  (let* ((session (etaf-web--current-session buffer))
         (vw (or (etaf-value (plist-get session :viewport-width)) 96))
         (err (etaf-value (plist-get session :error-info)))
         (page (etaf-value (plist-get session :page))))
    (list :url (etaf-value (plist-get session :url))
          :title (etaf-value (plist-get session :title))
          :phase (etaf-value (plist-get session :phase))
          :stage (etaf-value (plist-get session :stage-label))
          :progress (or (plist-get session :progress-display) 0.0)
          :cached (etaf-value (plist-get session :cached))
          :error (and err (copy-sequence err))
          :can-back (etaf-value (plist-get session :can-back))
          :can-forward (etaf-value (plist-get session :can-forward))
          :history-length (length (plist-get session :history))
          :address-editing (etaf-value (plist-get session :address-editing))
          :narrow (< vw etaf-web--narrow-breakpoint)
          :width vw
          :tier (and (listp page) (plist-get page :tier))
          :mode (etaf-value (plist-get session :render-mode))
          :adapter (and (listp page) (plist-get page :adapter)))))

;;; ---------------------------------------------------------------------------
;;; Reading navigation commands (delegating through Page Controller / `etaf-md')
;;; ---------------------------------------------------------------------------

(defun etaf-web--visible-heading-positions (session outline)
  "Return visible `(INDEX TEXT POS)' triples in SESSION's current viewport."
  (let ((buf (plist-get session :buffer)))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (save-excursion
          (goto-char (point-min))
          (forward-line 1)
          (let ((start (point)))
            (cl-loop for entry in outline
                     for idx from 0
                     for text = (nth 1 entry)
                     for pos = (when (and (stringp text) (not (string-empty-p text)))
                                 (goto-char start)
                                 (when (search-forward text nil t)
                                   (setq start (match-end 0))
                                   (match-beginning 0)))
                     when pos collect (list idx text pos))))))))

(defun etaf-web--step-heading (session direction)
  "Move to the next (DIRECTION > 0) or previous (DIRECTION < 0) heading."
  (let* ((buf (plist-get session :buffer))
         (page (etaf-value (plist-get session :page)))
         (custom-fn (and (listp page) (plist-get page :on-headings)))
         (outline (etaf-web--session-outline session)))
    (cond
     ((functionp custom-fn)
      (let* ((items (funcall custom-fn buf))
             (here (point))
             (ordered (if (> direction 0) items (nreverse (copy-sequence items))))
             (target (cl-find-if (lambda (it)
                                   (if (> direction 0)
                                       (> (nth 2 it) here)
                                     (< (nth 2 it) here)))
                                 ordered)))
        (if target
            (goto-char (nth 2 target))
          (message (if (> direction 0) "No further heading" "No earlier heading")))))
     ((and (buffer-live-p buf) outline)
      (let* ((total (length outline))
             (vis (etaf-web--visible-heading-positions session outline))
             (here (point))
             (rt (etaf-runtime-for-buffer buf))
             (cur-scroll (etaf-web--current-scroll-offset rt))
             (last-idx (plist-get session :heading-index))
             (target-idx
              (if (> direction 0)
                  (cond
                   ((cl-find-if (lambda (it) (> (nth 2 it) here)) vis)
                    (car (cl-find-if (lambda (it) (> (nth 2 it) here)) vis)))
                   (vis (1+ (car (car (last vis)))))
                   ((integerp last-idx) (1+ last-idx))
                   ((zerop cur-scroll) 0)
                   (t nil))
                (let ((prev-vis (cl-find-if (lambda (it) (< (nth 2 it) here))
                                            (nreverse (copy-sequence vis)))))
                  (cond
                   (prev-vis (car prev-vis))
                   (vis (1- (car (car vis))))
                   ((integerp last-idx) (1- last-idx))
                   ((> cur-scroll 0) 0)
                   (t nil)))))
             (landed nil))
        (while (and (not landed)
                    (integerp target-idx)
                    (>= target-idx 0)
                    (< target-idx total))
          (setq landed (etaf-web--locate-heading session target-idx))
          (unless landed
            (setq target-idx (+ target-idx direction))))
        (unless landed
          (message (if (> direction 0) "No further heading" "No earlier heading")))))
     (t
      (message (if (> direction 0) "No further heading" "No earlier heading"))))))

(defun etaf-web--next-heading ()
  "Move point to the next outline heading in the current ETAF Web page."
  (etaf-web--step-heading (etaf-web--current-session) 1))

(defun etaf-web--previous-heading ()
  "Move point to the previous outline heading in the current ETAF Web page."
  (etaf-web--step-heading (etaf-web--current-session) -1))

(defun etaf-web-goto-heading ()
  "Choose an outline heading in the current ETAF Web page and scroll it into view."
  (interactive)
  (let* ((session (etaf-web--current-session))
         (buf (plist-get session :buffer))
         (page (etaf-value (plist-get session :page)))
         (custom-fn (and (listp page) (plist-get page :on-headings)))
         (outline (etaf-web--session-outline session)))
    (cond
     ((functionp custom-fn)
      (let ((items (funcall custom-fn buf)))
        (unless items
          (user-error "This page has no headings"))
        (let* ((cands (mapcar (lambda (it) (cons (nth 1 it) (nth 2 it))) items))
               (choice (completing-read "Heading: " cands nil t))
               (pos (cdr (assoc choice cands))))
          (when pos
            (goto-char pos)))))
     ((and (buffer-live-p buf) outline)
      (let ((seen (make-hash-table :test #'equal)))
        (let* ((cands
                (cl-loop for entry in outline
                         for idx from 0
                         for text = (or (nth 1 entry) "")
                         for count = (1+ (or (gethash text seen) 0))
                         do (puthash text count seen)
                         collect (cons (if (= count 1)
                                           text
                                         (format "%s (%d)" text count))
                                       idx)))
               (choice (completing-read "Heading: " cands nil t))
               (idx (cdr (assoc choice cands))))
          (when (integerp idx)
            (unless (etaf-web--locate-heading session idx)
              (message "Heading is not currently visible"))))))
     (t
      (user-error "This page has no headings")))))

(defun etaf-web--cycle-theme ()
  "Cycle the browser shell and embedded page between palettes."
  (let* ((session (etaf-web--current-session))
         (order '(auto dark light sepia))
         (cur (etaf-value (plist-get session :theme-mode)))
         (next (or (cadr (memq cur order)) 'auto))
         (page (etaf-value (plist-get session :page)))
         (on-theme (and (listp page) (plist-get page :on-theme))))
    (etaf-set-value (plist-get session :theme-mode) next)
    (cond
     ((functionp on-theme) (funcall on-theme next))
     ((etaf-value (plist-get session :md-session))
      (etaf-md-set-theme (etaf-value (plist-get session :md-session)) next)))
    (message "Theme: %s" next)))

(defun etaf-web--wider ()
  "Widen the embedded reading column by 4 character cells."
  (let* ((session (etaf-web--current-session))
         (page (etaf-value (plist-get session :page)))
         (on-width (and (listp page) (plist-get page :on-width))))
    (cond
     ((functionp on-width)
      (when-let* ((w (funcall on-width 4)))
        (message "Reading width: %d" w)))
     ((etaf-value (plist-get session :md-session))
      (message "Reading width: %d"
               (etaf-md-adjust-width (etaf-value (plist-get session :md-session)) 4))))))

(defun etaf-web--narrower ()
  "Narrow the embedded reading column by 4 character cells."
  (let* ((session (etaf-web--current-session))
         (page (etaf-value (plist-get session :page)))
         (on-width (and (listp page) (plist-get page :on-width))))
    (cond
     ((functionp on-width)
      (when-let* ((w (funcall on-width -4)))
        (message "Reading width: %d" w)))
     ((etaf-value (plist-get session :md-session))
      (message "Reading width: %d"
               (etaf-md-adjust-width (etaf-value (plist-get session :md-session)) -4))))))

(provide 'etaf-web-app)
;;; etaf-web-app.el ends here
