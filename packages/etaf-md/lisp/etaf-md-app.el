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
  "Return the preview buffer name for FILE."
  (format "*ETAF Markdown: %s*" (file-name-nondirectory file)))

(declare-function etaf-md--live-refresh "etaf-md-live" (session text))

(defconst etaf-md--keys
  '(("n" etaf-md-next-heading "下一个标题")
    ("p" etaf-md-previous-heading "上一个标题")
    ("C-c j" etaf-md-goto-heading "选择标题")
    ("r" etaf-md-reload "重新加载文档")
    ("t" etaf-md--cycle-theme-command "切换主题")
    ("[" etaf-md-narrower "缩窄阅读栏")
    ("]" etaf-md-wider "加宽阅读栏")
    ("C-c h" etaf-help "查看快捷键")
    ("q" etaf-md-close "关闭预览"))
  "Root keys of a preview opened by `etaf-md-open'.
The page is a rendering, so the markdown is edited in its own buffer and these
keys only move around the view.  Native scrolling, isearch and link activation
stay available as they are.")

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

(defun etaf-md--current-session ()
  "Return the preview session of the current buffer."
  (or (etaf-app-state)
      (user-error "Not an ETAF markdown preview buffer")))

;;; ---------------------------------------------------------------------------
;;; Navigation and display commands
;;; ---------------------------------------------------------------------------

(defun etaf-md-next-heading ()
  "Move to the next outline heading of the current preview."
  (interactive)
  (let ((session (etaf-md--current-session)))
    (unless (etaf-md--adjacent-heading session 1)
      (message "No further heading"))))

(defun etaf-md-previous-heading ()
  "Move to the previous outline heading of the current preview."
  (interactive)
  (let ((session (etaf-md--current-session)))
    (unless (etaf-md--adjacent-heading session -1)
      (message "No earlier heading"))))

(defun etaf-md-goto-heading ()
  "Choose an outline heading of the current preview and move to it."
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
  (interactive)
  (let ((session (etaf-md--current-session)))
    (etaf-md-refresh session)
    (message "Reloaded %s" (etaf-md--read session :title))))

(defun etaf-md--cycle-theme-command ()
  "Switch the current preview to the next palette."
  (interactive)
  (let ((session (etaf-md--current-session)))
    (etaf-md-cycle-theme session)
    (message "Theme: %s" (etaf-md--read session :theme))))

(defun etaf-md-wider ()
  "Widen the current preview's reading column."
  (interactive)
  (let* ((session (etaf-md--current-session))
         (cap (etaf-md-adjust-width session 4)))
    (message "Reading width: %d (max %d)"
             (etaf-md--effective-width session) cap)))

(defun etaf-md-narrower ()
  "Narrow the current preview's reading column."
  (interactive)
  (let* ((session (etaf-md--current-session))
         (cap (etaf-md-adjust-width session -4)))
    (message "Reading width: %d (max %d)"
             (etaf-md--effective-width session) cap)))

(defun etaf-md-close ()
  "Unmount the current preview, kill its buffer and free its window.
The current window goes away when the frame has another window to spare, so a
preview opened beside its source closes back onto the source instead of leaving
a second copy of it.  Signals `user-error' when the current buffer is not a
preview."
  (interactive)
  (etaf-md--current-session)
  (let ((window (selected-window)))
    (etaf-app-close)
    (when (and (window-live-p window) (not (one-window-p t)))
      (ignore-errors (delete-window window)))))

;;; ---------------------------------------------------------------------------
;;; Window fitting
;;; ---------------------------------------------------------------------------

(defun etaf-md--effective-width (session)
  "Return the reading width the window actually gives SESSION.
The session's `:width' is the maximum measure; a narrower window fills the
available columns instead, so this reports what is on screen outside the
column's side gutters."
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
  "Seconds between a source change and its repaint.
One frame at 60 Hz.  A change only schedules a repaint when none is pending,
so a burst of keystrokes coalesces into one repaint per frame instead of one
per keystroke, and typing never waits for the keys to stop.")

(defconst etaf-md--follow-retry 0.2
  "Seconds between attempts to watch a file that is temporarily missing.")

(defvar etaf-md--writing-back nil
  "Non-nil while the preview writes an edit back into its source buffer.
The change hook runs inside that write, which comes from the preview itself:
following it would republish the document and replace the block the live edit
session is editing.")

(defvar etaf-md--follow-sessions (make-hash-table :test #'equal)
  "Displayed preview sessions by absolute source file name.")

(defvar etaf-md--follow-watches (make-hash-table :test #'equal)
  "Change watches by absolute source file name.")

(defvar etaf-md--follow-timers (make-hash-table :test #'equal)
  "Pending repaints by absolute source file name.")

(defvar etaf-md--live-sources (make-hash-table :test #'equal)
  "Visiting buffers followed for unsaved edits by absolute source file name.")

(defun etaf-md--live-changed (&rest _)
  "Repaint the preview of the file being edited on the next frame.
The hook runs on every buffer change; scheduling keeps one pending repaint
per file, so a keystroke joins the frame that is already coming."
  (when (and buffer-file-name (not etaf-md--writing-back))
    (etaf-md--follow-schedule (expand-file-name buffer-file-name))))

(defun etaf-md--live-start (session)
  "Make SESSION follow unsaved edits of its visiting buffer, when it has one.
A file with no visiting buffer has nothing to follow until it is opened, and a
session built from text never follows a buffer."
  (when-let* ((path (plist-get session :file))
              (buffer (get-file-buffer (expand-file-name path))))
    (puthash (expand-file-name path) buffer etaf-md--live-sources)
    (plist-put session :source-buffer buffer)
    (with-current-buffer buffer
      (add-hook 'after-change-functions #'etaf-md--live-changed nil t)
      (add-hook 'post-command-hook #'etaf-md--follow-scroll-command nil t))))

(defun etaf-md--live-stop (file)
  "Stop following unsaved edits of FILE and drop its visiting buffer."
  (when-let* ((file (and file (expand-file-name file)))
              (buffer (gethash file etaf-md--live-sources)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (remove-hook 'after-change-functions #'etaf-md--live-changed t)
        (remove-hook 'post-command-hook #'etaf-md--follow-scroll-command t)))
    (remhash file etaf-md--live-sources)))

(defun etaf-md--follow-visit ()
  "Start following the file the buffer just opened, when a preview shows it.
A preview can be opened before its markdown is, and a reader who opens the
file afterwards expects the preview to follow that buffer as they type.  The
hook is buffer-local where it lands, so closing the file takes it away."
  (when-let* ((file (and buffer-file-name (expand-file-name buffer-file-name)))
              (session (gethash file etaf-md--follow-sessions)))
    (etaf-md--live-start session)))

(defconst etaf-md--follow-attempts 3
  "Times to retry a watch while its file is missing.
An editor that saves atomically deletes the old file before it renames the
new one over the name, and the watch must be re-armed once the name exists
again; each retry waits `etaf-md--follow-retry'.")

(defun etaf-md--follow-saved ()
  "Repaint the preview of the file being saved, when one is open."
  (when (and buffer-file-name (not etaf-md--writing-back))
    (etaf-md--follow-schedule (expand-file-name buffer-file-name))))

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
  "Repaint FILE's preview for EVENT, and re-arm the watch only when it died.
A watch is re-armed for `stopped' and `deleted' alone: an editor that saves by
replacing the file takes the watched node away, so the name has to be watched
again.  Re-arming on every event instead re-adds a watch from inside its own
callback, and the backend reports the same write again, which never settles."
  (let ((action (nth 1 event)))
    (when (memq action '(changed created renamed))
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
    (let ((file (expand-file-name path)))
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
  (when-let* ((file (and file (expand-file-name file))))
    (etaf-md--live-stop file)
    (when-let* ((watch (gethash file etaf-md--follow-watches)))
      (ignore-errors (file-notify-rm-watch watch))
      (remhash file etaf-md--follow-watches))
    (when-let* ((timer (gethash file etaf-md--follow-timers)))
      (cancel-timer timer)
      (remhash file etaf-md--follow-timers))
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
  (or (etaf-app-state)
      (and buffer-file-name
           (gethash (expand-file-name buffer-file-name)
                    etaf-md--follow-sessions))))

(defun etaf-md-follow-scroll (&optional arg)
  "Toggle scrolling the preview along with its source buffer.
While it is on, a command that scrolls the source window moves the preview so
that the block at the top of that window becomes the first row of the
preview: a reader keeping the two side by side sees the same place in each.
Only the source's scrolling follows; scrolling the preview itself stays free,
and typing follows as far as the source window scrolls.
Run it from the markdown buffer or from its preview.  With prefix ARG, turn
the follow on when ARG is positive and off otherwise.  Return the new state.
Signal `user-error' when no preview shows the current buffer."
  (interactive "P")
  (let ((session (or (etaf-md--follow-scroll-session)
                     (user-error "No preview shows the current buffer"))))
    (let ((on (if arg
                  (> (prefix-numeric-value arg) 0)
                (not (plist-get session :follow-scroll)))))
      (plist-put session :follow-scroll (and on t))
      (plist-put session :follow-scroll-line nil)
      (when on
        (etaf-md--follow-scroll-sync session))
      (message "Preview follows the source scroll: %s" (if on "on" "off"))
      (plist-get session :follow-scroll))))

(defun etaf-md--follow-scroll-command ()
  "Move the current buffer's preview along with its source window.
Runs from the source buffer's `post-command-hook'.  A command that leaves the
window where it was costs one lookup: the preview only moves when the source
window starts on a different line than the one it followed before."
  (when buffer-file-name
    (when-let* ((session (gethash (expand-file-name buffer-file-name)
                                  etaf-md--follow-sessions))
                ((plist-get session :follow-scroll)))
      (etaf-md--follow-scroll-sync session))))

(defun etaf-md--follow-scroll-sync (session)
  "Scroll SESSION's window to the block its source window now starts with.
Return the preview position it moved to, or nil when the source or the
preview is not on screen, or when the window already starts there."
  (let* ((source (plist-get session :source-buffer))
         (buffer (plist-get session :buffer))
         (source-window (and (buffer-live-p source)
                             (get-buffer-window source t)))
         (window (and (buffer-live-p buffer) (get-buffer-window buffer t)))
         (start (and source-window (window-start source-window))))
    (when (and start window (eq (window-buffer window) buffer))
      ;; The window's start moves whenever text is inserted above it, so a
      ;; position says "scrolled" on every keystroke near the top: the page
      ;; jumped, repainted, and the reader's typing stalled for the repaint.
      ;; The line the window starts on is what a scroll actually changes.
      (let ((line (with-current-buffer source (line-number-at-pos start))))
        (unless (eql (plist-get session :follow-scroll-line) line)
          (plist-put session :follow-scroll-line line)
        (let ((ref (etaf-md--block-ref-at session start)))
          (cond
           ((eq ref 'top)
            ;; The page opens on its front matter header, which no block
            ;; owns; POSITION is read in the preview buffer, not in the
            ;; source the hook runs in.
            (let ((top (with-current-buffer buffer (point-min))))
              (set-window-start window top)
              top))
           (ref
            (when-let* ((runtime (etaf-runtime-for-buffer buffer))
                        (position (etaf-host-ref-position runtime ref)))
              (set-window-start window position)
              position)))))))))

(defun etaf-md--block-ref-at (session position)
  "Return what SESSION's page shows at source POSITION.
The answer is the ref of the block holding POSITION, or of the next block when
POSITION falls in the blank lines between two blocks.  A position above the
first block answers `top', because the page opens on the front matter header
that no block owns; a position past the last block answers with that block.
A page whose blocks carry no source range answers nil."
  (let ((first nil)
        (last nil)
        (found nil))
    (dolist (entry (plist-get (etaf-md--read session :document) :children))
      (let* ((block (plist-get entry :block))
             (begin (plist-get block :begin))
             (end (plist-get block :end)))
        (when (and (not found)
                   (integerp begin)
                   (integerp end)
                   (not (eq (plist-get block :type) 'blank)))
          (setq first (or first begin))
          (setq last (plist-get entry :ref))
          (when (< position end)
            (setq found last)))))
    (cond ((and first (< position first)) 'top)
          (found)
          (t last))))

(defun etaf-md--follow-schedule (file)
  "Repaint FILE's preview on the next frame.
A repaint already scheduled for FILE is kept rather than replaced, so the
delay measures from the first change of the burst and the preview follows a
typing hand instead of going quiet until it stops."
  (when (and (gethash file etaf-md--follow-sessions)
             (not (gethash file etaf-md--follow-timers)))
    (puthash file
             (run-with-timer etaf-md--follow-tick nil
                             #'etaf-md--follow-repaint file)
             etaf-md--follow-timers)))

(defun etaf-md--follow-repaint (file)
  "Repaint FILE's preview after its source changed.
The repaint republishes the document and lets the framework draw it the way
any other reactive change does: forcing a flush or moving the reading window
from the timer that runs here re-enters the update while a redisplay is
pending, and that spins instead of settling."
  (remhash file etaf-md--follow-timers)
  (when-let* ((session (gethash file etaf-md--follow-sessions))
              (buffer (plist-get session :buffer))
              ((buffer-live-p buffer)))
    (condition-case error
        (let ((text (etaf-md--session-text session)))
          ;; A repaint already made from the same text leaves nothing to draw:
          ;; the page shows what the source now holds.
          (unless (equal text (plist-get session :live-text))
            (etaf-md--live-refresh session text)))
      (etaf-md-error
       (message "Preview kept its last render: %s"
                (error-message-string error))))))

(etaf-define-component etaf-md-app (&key session)
  "Render the markdown preview for SESSION and own its lifecycle.
SESSION must come from `etaf-md-create'.  Mounting provides the
palette for its subtree; every displayed value is read from the session's
reactive sources, so a refresh, a width change or a theme change repaints the
whole preview without a remount."
  :bindings ((preview (or session
                          (signal 'etaf-md-error
                                  '("etaf-md-app needs the :session from `etaf-md-create'"))))
             (document (etaf-md--ref preview :document))
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
   (etaf-value document)
   (etaf-md--env preview)))

(defun etaf-md-view (&optional session)
  "Return the preview View for SESSION.
SESSION defaults to a new session over an empty document; pass a session from
`etaf-md-create' to mount a real one."
  (etaf-view (etaf-md-app
              :session (or session (etaf-md-create :text "")))))

;;; `etaf-md' autoloads this command from the entry file, which loads the
;;; typesetter too; a second cookie here would skip it and leave a code block
;;; calling an undefined renderer.
(defun etaf-md-open (&optional source)
  "Open a markdown preview and return its buffer.
SOURCE is a file path, a session from `etaf-md-create', or nil to
prompt for a file.  Interactively it defaults to the current buffer's
markdown file and then to a file prompt.  Opening a file that already has a
preview buffer selects it instead of rendering a second copy; opening a
session mounts that session, which lets scripts render a document they built
themselves."
  (interactive
   (list (read-file-name
          "Markdown file: " nil nil t
          (when (and buffer-file-name
                     (string-match-p etaf-md--markdown-file-regexp buffer-file-name))
            (file-relative-name buffer-file-name default-directory)))))
  (if (and (listp source) (etaf-ref-p (plist-get source :document)))
      (etaf-md--display source
                                (etaf-md--buffer-name-for-session source))
    (let* ((file (expand-file-name source))
           (name (etaf-md--buffer-name file))
           (existing (get-buffer name)))
      (if (and existing (etaf-app-state existing))
          (switch-to-buffer existing)
        (etaf-md--display (etaf-md-create :file file) name)))))

;;; Autoloaded from `etaf-md' for the same reason as `etaf-md-open'.
(defun etaf-md-preview (&optional source)
  "Show SOURCE's preview beside its source: source on the left, preview right.
SOURCE is a file path.  Interactively it is the current buffer's Markdown
file, and a buffer that visits no Markdown file prompts for one.  Any previous
window layout gives way to those two panes, the point stays in the source, and
`etaf-md-close' gives the layout back to the source alone."
  (interactive
   (list (or (and buffer-file-name
                  (string-match-p etaf-md--markdown-file-regexp
                                  buffer-file-name)
                  (expand-file-name buffer-file-name))
             (expand-file-name
              (read-file-name "Markdown file: " nil nil t
                              (and buffer-file-name
                                   (file-relative-name buffer-file-name
                                                       default-directory)))))))
  (let* ((file (expand-file-name source))
         (buffer (or (get-file-buffer file) (find-file-noselect file))))
    (delete-other-windows)
    (switch-to-buffer buffer)
    (select-window (split-window-right))
    ;; The preview beside the source is the same page as one opened alone, so
    ;; the window arrangement is the only difference; opening it editable is
    ;; the mount path's job.
    (etaf-md-open file)
    (when-let* ((window (get-buffer-window buffer t)))
      (select-window window))))

(defun etaf-md--buffer-name-for-session (session)
  "Return the preview buffer name for SESSION."
  (if-let* ((file (plist-get session :file)))
      (etaf-md--buffer-name file)
    "*ETAF Markdown*"))

(defun etaf-md--display (session name)
  "Open SESSION as the application buffer NAME and return that buffer.
The session starts on the mount path every entry command shares, which is what
makes opening a preview mean the same thing however it was called.
The showing window sets the initial reading measure only; later resizes
reflow the viewport-relative column without changing it, so a width chosen
with `[' and `]' survives them.  Cells the page does not paint, such as the
sub-cell remainder at the window edge, take the page background, and a
session without one lets the Emacs theme show through."
  (let* ((measured nil)
         (buffer
          (etaf-app-open
           name
           (etaf-view (etaf-md-app :session session :keys etaf-md--keys))
           :state session
           :mode-line t
           :background (lambda () (etaf-md--page-background session))
           :on-fit (lambda (_window)
                     (unless measured
                       (setq measured t)
                       (plist-put session :buffer (current-buffer))
                       (etaf-md--fit-width session)))
           :on-close (lambda ()
                       (etaf-md--follow-unregister (plist-get session :file))
                       (plist-put session :buffer nil)))))
    (plist-put session :buffer buffer)
    (etaf-md--follow-register session)
    (add-hook 'kill-buffer-hook
              (lambda ()
                (etaf-md--follow-unregister (plist-get session :file)))
              t t)
    (with-current-buffer buffer
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
