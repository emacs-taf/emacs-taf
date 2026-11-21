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
(require 'etaf-web-views)

(defvar etaf-web--url-history nil
  "Global MRU list of visited URLs used for address-bar completion.")

(defconst etaf-web--anim-interval 0.06
  "Seconds between smooth progress-bar easing frames (retained span patch).")

(defconst etaf-web--keys
  '(("RET"       etaf-web--activate-at-point "激活当前链接或控件")
    ("<return>"  etaf-web--activate-at-point "激活当前链接或控件")
    ("M-<left>"  etaf-web-back "后退")
    ("B"         etaf-web-back "后退")
    ("M-<right>" etaf-web-forward "前进")
    ("F"         etaf-web-forward "前进")
    ("r"         etaf-web-reload "刷新页面")
    ("x"         etaf-web-stop "停止加载")
    ("g"         etaf-web-focus-address "编辑地址栏")
    ("C-l"       etaf-web-focus-address "编辑地址栏")
    ("o"         etaf-web-open-external "外部浏览器打开")
    ("n"         etaf-web--next-heading "下一个标题")
    ("p"         etaf-web--previous-heading "上一个标题")
    ("C-c j"     etaf-web--goto-heading "选择标题")
    ("t"         etaf-web--cycle-theme "切换主题")
    ("["         etaf-web--narrower "缩窄阅读栏")
    ("]"         etaf-web--wider "加宽阅读栏")
    ("C-c h"     etaf-help "查看快捷键")
    ("q"         etaf-web-close "关闭页面"))
  "Root Host key bindings for an `etaf-web' browser buffer.")

(defconst etaf-web--toolbar-focus-refs
  '(web-back web-forward web-reload web-stop web-address web-address-input)
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

(defun etaf-web--save-scroll-position (session)
  "Record current window scroll start and point on SESSION's active history item."
  (let* ((buf (plist-get session :buffer))
         (idx (plist-get session :history-index))
         (hist (plist-get session :history)))
    (when (and (buffer-live-p buf) (integerp idx) (>= idx 0) (< idx (length hist)))
      (let* ((entry (nth idx hist))
             (win (get-buffer-window buf t)))
        (with-current-buffer buf
          (plist-put entry :point (point))
          (plist-put entry :scroll-start (if (window-live-p win)
                                             (window-start win)
                                           (point))))))))

(defun etaf-web--restore-scroll-position (session scroll-start saved-point)
  "Restore SCROLL-START and SAVED-POINT in SESSION's live buffer after paint."
  (let ((buf (plist-get session :buffer)))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (let* ((win (get-buffer-window buf t))
               (pt (max (point-min) (min (point-max) (or saved-point (point-min)))))
               (st (max (point-min) (min (point-max) (or scroll-start (point-min))))))
          (goto-char pt)
          (when (window-live-p win)
            (set-window-start win st t)))))))

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
Skips row 1 (the sticky toolbar) so padding spaces on the toolbar never trigger
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
  (interactive)
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
        (etaf-activate rt))))))

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
    (when (and rt (etaf-runtime-mounted-p rt))
      (let* ((vw (max 44 (or (etaf-value (plist-get session :viewport-width)) 96)))
             (narrow (< vw etaf-web--narrow-breakpoint))
             (prog (etaf-value (plist-get session :progress-display)))
             (phase (etaf-value (plist-get session :phase)))
             (stage (etaf-value (plist-get session :stage-label)))
             (elapsed (if (plist-get session :started-at)
                          (- (float-time) (plist-get session :started-at))
                        0.0))
             (status-str (etaf-web--status-text
                          phase stage elapsed prog
                          (etaf-value (plist-get session :cached))
                          narrow (plist-get session :spin-index))))
        (condition-case nil
            (etaf-runtime-update-host-contents
             rt (list (cons 'web-status status-str)))
          (etaf-runtime-error nil))))))

(defun etaf-web--anim-tick (session)
  "Advance inline text-progress easing via retained Host span-patch."
  (let ((buf (plist-get session :buffer)))
    (if (or (not (buffer-live-p buf))
            (not (eq (etaf-value (plist-get session :phase)) 'loading)))
        (etaf-web--stop-anim session)
      (let* ((cur (or (etaf-value (plist-get session :progress-display)) 0.0))
             (target (or (etaf-value (plist-get session :progress-target)) 0.15))
             ;; Ease smoothly toward target, with gentle creep up to 0.90 while waiting.
             (ceiling (max target (min 0.90 (+ target 0.35))))
             (step (if (< cur target)
                       (max 0.015 (* 0.22 (- target cur)))
                     (* 0.018 (- ceiling cur))))
             (next (min 0.96 (+ cur step))))
        (plist-put session :spin-index (1+ (or (plist-get session :spin-index) 0)))
        (etaf-set-value (plist-get session :progress-display) next)
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
  (etaf-set-value (plist-get session :progress-display) 1.0))

;;; ---------------------------------------------------------------------------
;;; Navigation, `#anchor' jump & `etaf-md' session creation
;;; ---------------------------------------------------------------------------

(defun etaf-web--jump-anchor (session fragment)
  "Jump point inside SESSION's buffer to heading matching FRAGMENT."
  (let ((buf (plist-get session :buffer))
        (md (etaf-value (plist-get session :md-session))))
    (when (and (buffer-live-p buf) md fragment (not (string-empty-p fragment)))
      (let* ((outline (etaf-md-outline md))
             (norm (downcase fragment))
             (match (cl-find-if
                     (lambda (entry)
                       (let ((text (or (nth 1 entry) ""))
                             (id (or (nth 2 entry) "")))
                         (or (equal (downcase id) norm)
                             (equal (downcase text) norm)
                             (string-match-p (regexp-quote norm) (downcase id)))))
                     outline)))
        (when match
          (let ((heading-text (nth 1 match)))
            (with-current-buffer buf
              (let ((pos (save-excursion
                           (goto-char (point-min))
                           (when (search-forward heading-text nil t)
                             (match-beginning 0)))))
                (when pos
                  (goto-char pos)
                  (when-let* ((win (get-buffer-window buf t)))
                    (set-window-point win pos)
                    (with-selected-window win (recenter 0)))
                  pos)))))))))

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
                  (browse-url (substring url (length "browser:")))
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

(cl-defun etaf-web--navigate (session source &key push force restore-scroll fragment)
  "Load SOURCE inside browser SESSION asynchronously.
When PUSH is non-nil, records a new history entry (truncating forward stack).
When FORCE is non-nil, bypasses cache.  RESTORE-SCROLL is `(SCROLL . POINT)'.
Optional FRAGMENT jumps to the matching heading after the page renders."
  (let* ((validated (etaf-web--validate-source source))
         (canonical (plist-get validated :canonical)))
    (etaf-web--save-scroll-position session)
    (when-let* ((old-job (plist-get session :active-job)))
      (etaf-web--cancel-job old-job)
      (plist-put session :active-job nil))
    (when push
      (let* ((hist (plist-get session :history))
             (idx (or (plist-get session :history-index) -1))
             (prefix (if (>= idx 0) (seq-take hist (1+ idx)) nil))
             (entry (list :url canonical :title nil :scroll-start nil :point nil)))
        (plist-put session :history (append prefix (list entry)))
        (plist-put session :history-index (length prefix))))
    (etaf-web--record-url-history canonical)
    (etaf-batch
      (etaf-set-value (plist-get session :url) canonical)
      (etaf-set-value (plist-get session :address-editing) nil)
      (etaf-set-value (plist-get session :address-draft) canonical)
      (etaf-set-value (plist-get session :error-info) nil)
      (etaf-set-value (plist-get session :phase) 'loading)
      (etaf-set-value (plist-get session :stage-label) "抓取中")
      (etaf-set-value (plist-get session :progress-target) 0.15)
      (etaf-set-value (plist-get session :progress-display) 0.08)
      (etaf-set-value (plist-get session :cached) nil))
    (etaf-web--sync-history-refs session)
    (etaf-web--start-anim session)
    (let ((gen (1+ (or (plist-get session :generation) 0))))
      (plist-put session :generation gen)
      (let ((job
             (etaf-web--load-page-async
              source
              :force force
              :on-stage
              (lambda (_stage label prog)
                (when (and (eql gen (plist-get session :generation))
                           (buffer-live-p (plist-get session :buffer)))
                  (etaf-set-value (plist-get session :stage-label) label)
                  (etaf-set-value (plist-get session :progress-target) prog)
                  ;; Skip out-of-band span patch for synchronous cache hits:
                  ;; `:on-ready' immediately follows in the same turn and
                  ;; commits the clean ready header (including sticky mirror).
                  (when (and (eq (etaf-value (plist-get session :phase)) 'loading)
                             (not (equal label "缓存")))
                    (etaf-web--patch-progress-hosts session))))
              :on-ready
              (lambda (info)
                (when (and (eql gen (plist-get session :generation))
                           (buffer-live-p (plist-get session :buffer)))
                  (let* ((index-file (plist-get info :index-file))
                         (title (or (plist-get info :title)
                                    (car (etaf-web--url-parts canonical))))
                         (cached (plist-get info :cached))
                         (md (etaf-web--make-md-session session index-file title))
                         (idx (plist-get session :history-index))
                         (hist (plist-get session :history)))
                    (when (and (integerp idx) (>= idx 0) (< idx (length hist)))
                      (plist-put (nth idx hist) :title title))
                    (etaf-batch
                      (etaf-set-value (plist-get session :title) title)
                      (etaf-set-value (plist-get session :cached) cached)
                      (etaf-set-value (plist-get session :md-session) md)
                      (etaf-set-value (plist-get session :md-gen)
                                      (1+ (or (etaf-value (plist-get session :md-gen)) 0)))
                      (etaf-set-value (plist-get session :stage-label)
                                (if cached "缓存" "完成"))
                      (etaf-set-value (plist-get session :progress-target) 1.0)
                      (etaf-set-value (plist-get session :phase) 'ready)
                      (etaf-web--bump-chrome-if-focused session))
                    (etaf-web--finish-progress-bar session)
                    (let ((buf (plist-get session :buffer)))
                      (when (buffer-live-p buf)
                        (let ((new-host (car (etaf-web--url-parts canonical))))
                          (when (and (stringp new-host)
                                     (not (string-empty-p new-host))
                                     (not (equal new-host (plist-get session :buffer-host))))
                            (plist-put session :buffer-host new-host)
                            (with-current-buffer buf
                              (rename-buffer (etaf-web--buffer-name-for-source canonical) t))))
                        (when-let* ((rt (etaf-runtime-for-buffer buf)))
                          (etaf-runtime-flush rt))
                        (etaf-web--patch-progress-hosts session)
                        (cond
                         (restore-scroll
                          (etaf-web--restore-scroll-position
                           session (car restore-scroll) (cdr restore-scroll)))
                         (fragment
                          (unless (etaf-web--jump-anchor session fragment)
                            (with-current-buffer buf
                              (goto-char (point-min)))))
                         (t
                          (with-current-buffer buf
                            (goto-char (point-min))
                            (when-let* ((win (get-buffer-window buf t)))
                              (set-window-start win (point-min) t))))))))))
              :on-images
              (lambda (_index-file)
                (when (and (eql gen (plist-get session :generation))
                           (buffer-live-p (plist-get session :buffer))
                           (eq (etaf-value (plist-get session :phase)) 'ready))
                  (let* ((buf (plist-get session :buffer))
                         (win (get-buffer-window buf t))
                         (pt (with-current-buffer buf (point)))
                         (ws (and (window-live-p win) (window-start win))))
                    (when-let* ((md (etaf-value (plist-get session :md-session))))
                      (ignore-errors (etaf-md-refresh md))
                      (when-let* ((rt (etaf-runtime-for-buffer buf)))
                        (ignore-errors (etaf-runtime-flush rt)))
                      (etaf-web--restore-scroll-position session ws pt)))))
              :on-error
              (lambda (err-info)
                (when (and (eql gen (plist-get session :generation))
                           (buffer-live-p (plist-get session :buffer)))
                  (etaf-web--stop-anim session)
                  (etaf-batch
                    (etaf-set-value (plist-get session :error-info) err-info)
                    (etaf-set-value (plist-get session :stage-label) "失败")
                    (etaf-set-value (plist-get session :phase) 'error)
                    (etaf-web--bump-chrome-if-focused session))
                  (when-let* ((rt (etaf-runtime-for-buffer (plist-get session :buffer))))
                    (etaf-runtime-flush rt))
                  (etaf-web--patch-progress-hosts session))))))
        (plist-put session :active-job job)
        job))))

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
                :progress-target (etaf-ref 0.15 :name 'web-progress-target)
                :progress-display (etaf-ref 0.08 :name 'web-progress-display)
                :cached (etaf-ref nil :name 'web-cached)
                :error-info (etaf-ref nil :name 'web-error)
                :md-session (etaf-ref nil :name 'web-md-session)
                :md-gen (etaf-ref 0 :name 'web-md-gen)
                :chrome-gen (etaf-ref 0 :name 'web-chrome-gen)
                :can-back (etaf-ref nil :name 'web-can-back)
                :can-forward (etaf-ref nil :name 'web-can-forward)
                :address-editing (etaf-ref nil :name 'web-address-editing)
                :address-draft (etaf-ref canonical :name 'web-address-draft)
                :viewport-width (etaf-ref 96 :name 'web-viewport-width)
                :theme-mode (etaf-ref 'auto :name 'web-theme-mode)
                :history nil
                :history-index -1
                :active-job nil
                :anim-timer nil
                :pre-edit-pos nil
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
                         (etaf-web--exit-address-editing session t))))
    (when other-window
      (etaf-web--select-other-window))
    (let ((buffer
           (etaf-app-open
            buf-name
            (etaf-view (etaf-web--browser-app :session session :keys etaf-web--keys))
            :state session
            :mode-line t
            :background (lambda ()
                          (let ((m (etaf-value (plist-get session :theme-mode))))
                            (unless (eq m 'auto)
                              (plist-get (etaf-web--palette m) :bg))))
            :on-fit (lambda (win)
                      (let ((w (if (window-live-p win) (window-body-width win) 96)))
                        (etaf-set-value (plist-get session :viewport-width) w)))
            :on-close (lambda ()
                        (etaf-web--stop-anim session)
                        (when-let* ((job (plist-get session :active-job)))
                          (etaf-web--cancel-job job)
                          (plist-put session :active-job nil))
                        (plist-put session :buffer nil)))))
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
             :restore-scroll (cons (plist-get entry :scroll-start)
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
             :restore-scroll (cons (plist-get entry :scroll-start)
                                   (plist-get entry :point)))))
      (message "已在历史终点"))))

(defun etaf-web--do-reload (session)
  "Re-fetch the current page of SESSION bypassing cache."
  (let ((url (etaf-value (plist-get session :url))))
    (when (and (stringp url) (not (string-empty-p url)))
      (etaf-web--navigate session url :push nil :force t))))

(defun etaf-web--do-stop (session)
  "Cancel any in-flight page load in SESSION cleanly."
  (when-let* ((job (plist-get session :active-job)))
    (etaf-web--cancel-job job)
    (plist-put session :active-job nil))
  (plist-put session :generation (1+ (or (plist-get session :generation) 0)))
  (etaf-web--stop-anim session)
  (let ((prev-md (etaf-value (plist-get session :md-session))))
    (etaf-batch
      (if prev-md
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
When RESTORE-SCROLL is non-nil and editing began while scrolled below the
sticky header, restores the pre-edit scroll position; otherwise keeps the top
viewport intact so the content start line never shifts."
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
      (with-current-buffer buf
        (let* ((win (get-buffer-window buf t))
               (saved-ws (car saved))
               (saved-pt (cdr saved)))
          (cond
           ((and (integer-or-marker-p saved-ws) (> saved-ws (point-min)))
            (etaf-web--restore-scroll-position session saved-ws saved-pt))
           ((window-live-p win)
            (set-window-start win (point-min) t)
            (when (integer-or-marker-p saved-pt)
              (goto-char (max (point-min) (min (point-max) saved-pt)))))))))))

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
        (let* ((win (get-buffer-window buf t))
               (ws (and (window-live-p win) (window-start win))))
          (plist-put session :pre-edit-pos (cons ws (point))))))
    (etaf-batch
      (etaf-set-value (plist-get session :address-draft) (or url ""))
      (etaf-set-value (plist-get session :address-editing) t))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (add-hook 'pre-command-hook #'etaf-web--address-pre-command -50 t))
      (when-let* ((rt (etaf-runtime-for-buffer buf)))
        (etaf-web--start-address-input session)
        ;; When invoked from an `:on-press' handler (clicking the URL, whether
        ;; inline or in the mirrored `:sticky top' header line), ETAF flushes
        ;; the newly mounted input after the press batch settles, so start
        ;; native editing on the next tick once the batch and any header-line
        ;; `save-excursion' have completed.
        (unless (etaf-text-input-active-p rt)
          (etaf-next-tick
           (lambda () (etaf-web--start-address-input session))))))))

(defun etaf-web--do-open-external (session)
  "Open SESSION's current URL in the user's external browser."
  (let ((url (etaf-value (plist-get session :url))))
    (when (and (stringp url) (not (string-empty-p url)))
      (browse-url url))))

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
`:history-length', `:address-editing', `:narrow' and `:width'."
  (let* ((session (etaf-web--current-session buffer))
         (vw (or (etaf-value (plist-get session :viewport-width)) 96))
         (err (etaf-value (plist-get session :error-info))))
    (list :url (etaf-value (plist-get session :url))
          :title (etaf-value (plist-get session :title))
          :phase (etaf-value (plist-get session :phase))
          :stage (etaf-value (plist-get session :stage-label))
          :progress (etaf-value (plist-get session :progress-display))
          :cached (etaf-value (plist-get session :cached))
          :error (and err (copy-sequence err))
          :can-back (etaf-value (plist-get session :can-back))
          :can-forward (etaf-value (plist-get session :can-forward))
          :history-length (length (plist-get session :history))
          :address-editing (etaf-value (plist-get session :address-editing))
          :narrow (< vw etaf-web--narrow-breakpoint)
          :width vw)))

;;; ---------------------------------------------------------------------------
;;; Reading navigation commands (delegating through public `etaf-md' API)
;;; ---------------------------------------------------------------------------

(defun etaf-web--heading-positions (session)
  "Return ordered list of `(INDEX TEXT POS)' for headings in SESSION's buffer."
  (let ((buf (plist-get session :buffer))
        (md (etaf-value (plist-get session :md-session))))
    (when (and (buffer-live-p buf) md)
      (with-current-buffer buf
        (save-excursion
          (goto-char (point-min))
          (cl-loop for entry in (etaf-md-outline md)
                   for idx from 0
                   for text = (nth 1 entry)
                   for pos = (when (and text (not (string-empty-p text))
                                        (search-forward text nil t))
                               (match-beginning 0))
                   when pos collect (list idx text pos)))))))

(defun etaf-web--next-heading ()
  "Move point to the next outline heading in the current ETAF Web page."
  (interactive)
  (let* ((session (etaf-web--current-session))
         (items (etaf-web--heading-positions session))
         (here (point))
         (next (cl-find-if (lambda (it) (> (nth 2 it) here)) items)))
    (if next
        (progn (goto-char (nth 2 next)) (recenter 0))
      (message "No further heading"))))

(defun etaf-web--previous-heading ()
  "Move point to the previous outline heading in the current ETAF Web page."
  (interactive)
  (let* ((session (etaf-web--current-session))
         (items (nreverse (etaf-web--heading-positions session)))
         (here (point))
         (prev (cl-find-if (lambda (it) (< (nth 2 it) here)) items)))
    (if prev
        (progn (goto-char (nth 2 prev)) (recenter 0))
      (message "No earlier heading"))))

(defun etaf-web--goto-heading ()
  "Choose an outline heading in the current ETAF Web page and jump to it."
  (interactive)
  (let* ((session (etaf-web--current-session))
         (items (etaf-web--heading-positions session)))
    (unless items
      (user-error "This page has no headings"))
    (let* ((cands (mapcar (lambda (it) (cons (nth 1 it) (nth 2 it))) items))
           (choice (completing-read "Heading: " cands nil t))
           (pos (cdr (assoc choice cands))))
      (when pos
        (goto-char pos)
        (recenter 0)))))

(defun etaf-web--cycle-theme ()
  "Cycle the browser shell and embedded page between palettes."
  (interactive)
  (let* ((session (etaf-web--current-session))
         (order '(auto dark light sepia))
         (cur (etaf-value (plist-get session :theme-mode)))
         (next (or (cadr (memq cur order)) 'auto)))
    (etaf-set-value (plist-get session :theme-mode) next)
    (when-let* ((md (etaf-value (plist-get session :md-session))))
      (etaf-md-set-theme md next))
    (message "Theme: %s" next)))

(defun etaf-web--wider ()
  "Widen the embedded reading column by 4 character cells."
  (interactive)
  (let ((session (etaf-web--current-session)))
    (when-let* ((md (etaf-value (plist-get session :md-session))))
      (message "Reading width: %d" (etaf-md-adjust-width md 4)))))

(defun etaf-web--narrower ()
  "Narrow the embedded reading column by 4 character cells."
  (interactive)
  (let ((session (etaf-web--current-session)))
    (when-let* ((md (etaf-value (plist-get session :md-session))))
      (message "Reading width: %d" (etaf-md-adjust-width md -4)))))

(provide 'etaf-web-app)
;;; etaf-web-app.el ends here
