;;; etaf-org-live.el --- O(Δ) live-editing, file watching & scroll sync -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; Follows an Org source buffer at frame rate (16 ms coalescing with
;; `input-pending-p' yield up to a 60 ms deadline) and follows external file
;; changes via `filenotify' and `after-save-hook'.
;;
;; When an edit stays inside a single section's body without introducing a
;; headline, global `#+KEYWORD:' or footnote definition, `etaf-org-live'
;; splice-parses only that section's body (`etaf-org--parse-body-slice') and,
;; when a single block changed in place, updates only that block's reactive
;; `:cell' ref — O(Δ) with zero full-document re-parse or parent repaint.
;; Structural edits automatically fall back to incremental keyed re-publish.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'filenotify)
(require 'etaf)
(require 'etaf-org-parse)
(require 'etaf-org-model)

(defconst etaf-org--live-frame-delay 0.016
  "Frame coalescing delay in seconds for source-buffer live edits.")

(defconst etaf-org--live-max-delay 0.060
  "Maximum yield deadline in seconds while `input-pending-p' is non-nil.")

(defconst etaf-org--follow-delay 0.25
  "Seconds to wait before an external file change repaints its preview.")

(defvar etaf-org--follow-sessions (make-hash-table :test #'equal)
  "Displayed preview sessions keyed by canonical source file path.")

(defvar etaf-org--follow-watches (make-hash-table :test #'equal)
  "File-notify watch descriptors keyed by canonical source file path.")

(defvar etaf-org--follow-timers (make-hash-table :test #'equal)
  "Pending file-change repaint timers keyed by canonical source file path.")

(defvar-local etaf-org--live-state nil
  "Buffer-local live-editing link plist `(:session SESSION ...)'.")

;;; ---------------------------------------------------------------------------
;;; O(Δ) Single-section splice-parse fast path
;;; ---------------------------------------------------------------------------

(defun etaf-org--structural-edit-p (slice)
  "Return non-nil when SLICE introduces headlines, global directives or footnotes."
  (let ((case-fold-search t))
    (or (string-match-p "^\\*+[ \t]" slice)
        (string-match-p "^[ \t]*#\\+\\(?:TITLE\\|SUBTITLE\\|AUTHOR\\|DATE\\|TODO\\|SEQ_TODO\\|TYP_TODO\\|OPTIONS\\|SETUPFILE\\|BIBLIOGRAPHY\\|ETAF_FLAVOR\\|MACRO\\|LINK\\|FILETAGS\\|KEYWORDS\\):" slice)
        (string-match-p "^\\[fn:" slice)
        (string-match-p "^[ \t]*:\\(?:PROPERTIES\\|LOGBOOK\\):[ \t]*$" slice))))

(defun etaf-org--find-enclosing-section (sections line-a line-b)
  "Return the innermost section in SECTIONS strictly enclosing LINE-A..LINE-B."
  (let ((found nil))
    (cl-labels ((walk (secs)
                  (dolist (sec secs)
                    (let ((s (etaf-org-section-line-start sec))
                          (e (etaf-org-section-line-end sec)))
                      (when (and (> line-a s) (<= line-b e))
                        (setq found sec)
                        (walk (etaf-org-section-children sec)))))))
      (walk sections))
    found))

(defun etaf-org--section-body-span (section)
  "Return `(FIRST-LINE . LAST-LINE)' of SECTION's own body blocks, or nil."
  (let* ((body (cl-remove-if (lambda (b) (eq (plist-get b :type) 'footnote-def))
                             (etaf-org-section-body section)))
         (first-b (car body))
         (last-b (car (last body)))
         (first-child (car (etaf-org-section-children section))))
    (when (and first-b last-b)
      (let ((start (or (plist-get first-b :line-start) (1+ (etaf-org-section-line-start section))))
            (end (if first-child
                     (1- (etaf-org-section-line-start first-child))
                   (etaf-org-section-line-end section))))
        (when (<= start end)
          (cons start end))))))

(defun etaf-org--try-splice-edit (session buffer text)
  "Attempt an O(Δ) single-block reactive update for SESSION from BUFFER TEXT.
Return non-nil when the splice succeeded and repainted in place; nil when a
full incremental publish is required."
  (let* ((doc (etaf-org--read session :document))
         (dirty-beg (plist-get session :dirty-beg))
         (dirty-end (plist-get session :dirty-end))
         (line-delta (or (plist-get session :dirty-line-delta) 0)))
    (when (and doc (zerop line-delta) (integerp dirty-beg) (integerp dirty-end)
               (buffer-live-p buffer))
      (let* ((line-a (with-current-buffer buffer (line-number-at-pos (min dirty-beg (point-max)))))
             (line-b (with-current-buffer buffer (line-number-at-pos (min dirty-end (point-max)))))
             (sec (etaf-org--find-enclosing-section (plist-get doc :sections) line-a line-b))
             (span (and sec (etaf-org--section-body-span sec))))
        (when (and sec span (>= line-a (car span)) (<= line-b (cdr span)))
          (let* ((all-lines (etaf-org--split-lines text))
                 (total (length all-lines))
                 (start-idx (max 0 (1- (car span))))
                 (end-idx (min total (cdr span))))
            (when (< start-idx end-idx)
              (let ((slice (mapconcat #'identity
                                      (cl-subseq (append all-lines nil) start-idx end-idx)
                                      "\n")))
                (unless (etaf-org--structural-edit-p slice)
                  (let* ((new-blocks
                          (cl-remove-if
                           (lambda (b) (eq (plist-get b :type) 'footnote-def))
                           (etaf-org--parse-body-slice
                            slice
                            :file (plist-get session :file)
                            :flavor (plist-get doc :flavor)
                            :todo-keywords (plist-get doc :todo-keywords)
                            :options (plist-get doc :options)
                            :macros (plist-get doc :macros)
                            :link-abbrevs (plist-get doc :link-abbrevs)
                            :line-offset (car span)
                            :live-p t)))
                         (slots-ht (plist-get session :slots-by-section))
                         (entries (and (hash-table-p slots-ht)
                                       (gethash (etaf-org-section-id sec) slots-ht))))
                    (when (and entries (= (length new-blocks) (length entries)))
                      (let ((env (etaf-org--env session))
                            (diffs nil)
                            (idx 0))
                        (cl-mapc
                         (lambda (nb entry)
                           (let* ((attached (etaf-org--attach-block-assets
                                             session doc nb env sec))
                                  (slot (plist-get entry :slot))
                                  (cell (plist-get slot :cell))
                                  (cur (etaf-value cell)))
                             (unless (equal attached cur)
                               (push (list entry slot cell attached) diffs)))
                           (cl-incf idx))
                         new-blocks entries)
                        (when (= (length diffs) 1)
                          (let* ((d (car diffs))
                                 (entry (nth 0 d))
                                 (cell (nth 2 d))
                                 (attached (nth 3 d)))
                            (plist-put session :live-text text)
                            (plist-put entry :block attached)
                            (etaf-set-value cell attached)
                            (etaf-org--request-async-assets session)
                            t))))))))))))))

;;; ---------------------------------------------------------------------------
;;; Coalesced 16 ms Frame Scheduler with input-pending-p Yield
;;; ---------------------------------------------------------------------------

(defun etaf-org--live-flush (session)
  "Repaint SESSION from its source buffer (O(Δ) splice or incremental install)."
  (plist-put session :live-timer nil)
  (plist-put session :live-deadline nil)
  (let* ((buffer (plist-get session :source-buffer))
         (text (if (buffer-live-p buffer)
                   (with-current-buffer buffer
                     (buffer-substring-no-properties (point-min) (point-max)))
                 (etaf-org--current-text session))))
    (unless (equal text (plist-get session :live-text))
      (condition-case err
          (unless (etaf-org--try-splice-edit session buffer text)
            (etaf-org--install session text nil t))
        (error
         (message "Org preview kept its last render: %s"
                  (error-message-string err)))))
    (plist-put session :dirty-beg nil)
    (plist-put session :dirty-end nil)
    (plist-put session :dirty-line-delta 0)))

(defun etaf-org--live-tick (session)
  "Timer callback: yield while typing is active up to 60 ms deadline, else flush."
  (plist-put session :live-timer nil)
  (let ((deadline (plist-get session :live-deadline))
        (now (float-time)))
    (if (and (input-pending-p) deadline (< now deadline))
        (plist-put session :live-timer
                   (run-with-timer etaf-org--live-frame-delay nil
                                   #'etaf-org--live-tick session))
      (etaf-org--live-flush session))))

(defun etaf-org--live-schedule (session)
  "Schedule SESSION to flush after `etaf-org--live-frame-delay'."
  (unless (plist-get session :live-deadline)
    (plist-put session :live-deadline (+ (float-time) etaf-org--live-max-delay)))
  (when-let* ((old (plist-get session :live-timer)))
    (cancel-timer old))
  (plist-put session :live-timer
             (run-with-timer etaf-org--live-frame-delay nil
                             #'etaf-org--live-tick session)))

(defun etaf-org--live-changed (beg end old-len)
  "Record dirty span BEG..END (replacing OLD-LEN chars) and schedule repaint."
  (when-let* ((state (buffer-local-value 'etaf-org--live-state (current-buffer)))
              (session (plist-get state :session)))
    (let* ((prev-beg (plist-get session :dirty-beg))
           (prev-end (plist-get session :dirty-end))
           (inserted (buffer-substring-no-properties beg end))
           (new-nl (cl-count ?\n inserted))
           (prev-delta (or (plist-get session :dirty-line-delta) 0)))
      (plist-put session :dirty-beg (if prev-beg (min prev-beg beg) beg))
      (plist-put session :dirty-end (if prev-end (max prev-end end) end))
      ;; Conservative: mark non-zero line delta whenever newline count may differ.
      (when (or (> new-nl 0) (> old-len 0))
        (let* ((doc (etaf-org--read session :document))
               (old-lines (or (plist-get doc :line-count) 0))
               (cur-lines (line-number-at-pos (point-max))))
          (plist-put session :dirty-line-delta (+ prev-delta (- cur-lines old-lines))))))
    (etaf-org--live-schedule session)))

(defun etaf-org--live-register (session buffer)
  "Make SESSION follow unsaved edits in BUFFER."
  (when (buffer-live-p buffer)
    (etaf-org--live-unregister session)
    (plist-put session :source-buffer buffer)
    (let ((kill-fn (lambda ()
                     (plist-put session :source-buffer nil)
                     (etaf-org--live-schedule session))))
      (plist-put session :live-kill-fn kill-fn)
      (with-current-buffer buffer
        (setq-local etaf-org--live-state (list :session session))
        (add-hook 'after-change-functions #'etaf-org--live-changed nil t)
        (add-hook 'kill-buffer-hook kill-fn nil t))
      (plist-put session :live-text
                 (with-current-buffer buffer
                   (buffer-substring-no-properties (point-min) (point-max)))))))

(defun etaf-org--live-unregister (session)
  "Stop SESSION from following its source buffer."
  (let ((buffer (plist-get session :source-buffer)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (remove-hook 'after-change-functions #'etaf-org--live-changed t)
        (when-let* ((kfn (plist-get session :live-kill-fn)))
          (remove-hook 'kill-buffer-hook kfn t))
        (kill-local-variable 'etaf-org--live-state)))
    (when-let* ((timer (plist-get session :live-timer)))
      (cancel-timer timer))
    (plist-put session :live-timer nil)
    (plist-put session :live-deadline nil)
    (plist-put session :live-kill-fn nil)
    (plist-put session :source-buffer nil)))

;;; ---------------------------------------------------------------------------
;;; Proportional Follow-Scroll Synchronization (source -> preview)
;;; ---------------------------------------------------------------------------

(defun etaf-org--follow-scroll-session ()
  "Return the active preview session for the current buffer, or nil.
Works from either the preview buffer itself or a source Org buffer whose
preview is currently open."
  (or (let ((st (etaf-app-state)))
        (and (listp st) (etaf-ref-p (plist-get st :document)) st))
      (when-let* ((state (buffer-local-value 'etaf-org--live-state (current-buffer)))
                  (s (plist-get state :session))
                  ((buffer-live-p (plist-get s :buffer))))
        s)
      (when buffer-file-name
        (when-let* ((s (gethash (etaf-org--canonical-file buffer-file-name)
                                etaf-org--follow-sessions))
                    ((buffer-live-p (plist-get s :buffer))))
          s))))

(defun etaf-org--sync-preview-scroll (session &optional force source-win)
  "Align SESSION's preview window to the source buffer's visible line.
When FORCE is non-nil, syncs even before `:follow-scroll' is consulted."
  (let ((src (plist-get session :source-buffer))
        (prv (plist-get session :buffer)))
    (when (and (or force (plist-get session :follow-scroll))
               (buffer-live-p src) (buffer-live-p prv)
               (or force (not (eq (current-buffer) prv))))
      (when-let* ((pwin (get-buffer-window prv t)))
        (let* ((swin (or (and (window-live-p source-win) source-win)
                         (get-buffer-window src t)))
               (src-line (with-current-buffer src
                           (line-number-at-pos
                            (if (and swin (eq (window-buffer swin) src))
                                (window-point swin)
                              (point)))))
               (rt (etaf-runtime-for-buffer prv))
               (target-ref (and (etaf-org--read session :toc-open)
                                rt (etaf-runtime-mounted-p rt)
                                (etaf-org--ref-for-source-line session src-line))))
          (if (and target-ref (etaf-org--scrollable-ancestor-p rt target-ref))
              (progn
                (etaf-scroll-into-view rt target-ref 'start)
                (etaf-runtime-flush rt))
            (when-let* ((target-pos (etaf-org--position-for-source-line session src-line)))
              (let ((bol (with-current-buffer prv
                           (save-excursion
                             (goto-char target-pos)
                             (line-beginning-position)))))
                (set-window-point pwin bol)
                (with-selected-window pwin
                  (goto-char bol)
                  (recenter 2))))))))))

(defun etaf-org--follow-scroll-hook (&rest _)
  "Post-command / window-scroll hook syncing source scroll to preview."
  (when-let* ((session (etaf-org--follow-scroll-session)))
    (when (plist-get session :follow-scroll)
      (etaf-org--sync-preview-scroll session))))

(defun etaf-org--set-follow-scroll (session enable)
  "Enable or disable proportional follow-scroll on SESSION's source buffer."
  (plist-put session :follow-scroll (and enable t))
  (when-let* ((src (plist-get session :source-buffer))
              ((buffer-live-p src)))
    (with-current-buffer src
      (if enable
          (progn
            (add-hook 'post-command-hook #'etaf-org--follow-scroll-hook nil t)
            (add-hook 'window-scroll-functions #'etaf-org--follow-scroll-hook nil t)
            (etaf-org--sync-preview-scroll session t))
        (remove-hook 'post-command-hook #'etaf-org--follow-scroll-hook t)
        (remove-hook 'window-scroll-functions #'etaf-org--follow-scroll-hook t))))
  (and enable t))

;;; ---------------------------------------------------------------------------
;;; Following the source file on disk (`filenotify' + `after-save-hook')
;;; ---------------------------------------------------------------------------

(defun etaf-org--canonical-file (file)
  "Return canonical truename of FILE for watch table keys."
  (when file
    (or (ignore-errors (file-truename file)) (expand-file-name file))))

(defun etaf-org--follow-saved ()
  "Repaint the preview of the file being saved, when one is open."
  (when buffer-file-name
    (etaf-org--follow-schedule (etaf-org--canonical-file buffer-file-name))))

(defun etaf-org--follow-visit ()
  "Attach live editing when the user opens a file already shown in a preview."
  (when-let* ((file (and buffer-file-name
                         (etaf-org--canonical-file buffer-file-name)))
              (session (gethash file etaf-org--follow-sessions)))
    (etaf-org--live-register session (current-buffer))))

(defun etaf-org--follow-watch (file)
  "Arm or re-arm FILE's change watch and return its descriptor."
  (when-let* ((old (gethash file etaf-org--follow-watches)))
    (ignore-errors (file-notify-rm-watch old))
    (remhash file etaf-org--follow-watches))
  (when-let* ((watch
               (condition-case nil
                   (file-notify-add-watch
                    file '(change)
                    (lambda (_event) (etaf-org--follow-schedule file)))
                 (file-error nil))))
    (puthash file watch etaf-org--follow-watches)
    watch))

(defun etaf-org--follow-register (session)
  "Make displayed SESSION follow external changes to its source file."
  (when-let* ((file (etaf-org--canonical-file (plist-get session :file))))
    (puthash file session etaf-org--follow-sessions)
    (etaf-org--follow-watch file)
    (add-hook 'after-save-hook #'etaf-org--follow-saved t)
    (add-hook 'find-file-hook #'etaf-org--follow-visit)))

(defun etaf-org--follow-unregister (file)
  "Stop following FILE: drop its watch, pending repaint and session."
  (when-let* ((key (etaf-org--canonical-file file)))
    (when-let* ((watch (gethash key etaf-org--follow-watches)))
      (ignore-errors (file-notify-rm-watch watch))
      (remhash key etaf-org--follow-watches))
    (when-let* ((timer (gethash key etaf-org--follow-timers)))
      (cancel-timer timer)
      (remhash key etaf-org--follow-timers))
    (remhash key etaf-org--follow-sessions)
    (when (zerop (hash-table-count etaf-org--follow-sessions))
      (remove-hook 'after-save-hook #'etaf-org--follow-saved)
      (remove-hook 'find-file-hook #'etaf-org--follow-visit))))

(defun etaf-org--follow-schedule (file)
  "Repaint FILE's preview once the source changes settle."
  (when (gethash file etaf-org--follow-sessions)
    (when-let* ((pending (gethash file etaf-org--follow-timers)))
      (cancel-timer pending))
    (puthash file
             (run-with-timer etaf-org--follow-delay nil
                             #'etaf-org--follow-repaint file)
             etaf-org--follow-timers)))

(defun etaf-org--follow-repaint (file)
  "Repaint FILE's preview and keep the reader in the same section."
  (remhash file etaf-org--follow-timers)
  (when-let* ((session (gethash file etaf-org--follow-sessions))
              (buffer (plist-get session :buffer))
              ((buffer-live-p buffer)))
    (let ((section (etaf-org--reading-section session)))
      (condition-case err
          (progn
            (etaf-org-refresh session)
            (etaf-org--flush session)
            (when section
              (etaf-org--locate-id session section)))
        (etaf-org-error
         (message "Preview kept its last render: %s"
                  (error-message-string err)))))))

(provide 'etaf-org-live)
;;; etaf-org-live.el ends here
