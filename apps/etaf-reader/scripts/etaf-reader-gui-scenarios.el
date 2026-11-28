;;; etaf-reader-gui-scenarios.el --- Native reader acceptance -*- lexical-binding: t; -*-

;;; Commentary:
;; Drive the installed reader through keys and catalog controls. Use an
;; isolated copy of the library database in a dedicated graphical instance.
;; The shared verifier owns timing, screenshots and failure evidence.

;;; Code:
(require 'etaf-reader)
(require 'emacs-gui-verifier)

(defun etaf-reader-gui--text (context)
  "Return the current visible buffer text for CONTEXT."
  (with-current-buffer (etaf-gui-verifier-context-target-buffer context)
    (buffer-substring-no-properties (point-min) (point-max))))

(defun etaf-reader-gui--keys (context keys)
  "Send KEYS through the native command loop in CONTEXT."
  (let* ((buffer (etaf-gui-verifier-context-target-buffer context))
         (window (get-buffer-window buffer t)))
    (unless (window-live-p window) (error "Reader window disappeared"))
    (with-selected-window window
      (execute-kbd-macro (kbd keys)))))

(defun etaf-reader-gui--activate (context label)
  "Focus and activate the displayed catalog control with LABEL."
  (let* ((buffer (etaf-gui-verifier-context-target-buffer context))
         (runtime (etaf-runtime-for-buffer buffer))
         (entry (seq-find (lambda (item)
                            (and (equal (plist-get (cdr item) :aria-label) label)
                                 (plist-get (cdr item) :on-press)
                                 (not (plist-get (cdr item) :disabled))))
                          (etaf-runtime-host-props-entries runtime))))
    (unless entry (error "Enabled control not found: %s" label))
    (with-current-buffer buffer (etaf-focus runtime (car entry)))
    (etaf-reader-gui--keys context "RET")))

(defun etaf-reader-gui--input (context keys answer)
  "Run KEYS and answer its native minibuffer with ANSWER."
  (minibuffer-with-setup-hook
      (lambda ()
        (delete-minibuffer-contents)
        (insert answer)
        ;; Setup runs before read-from-minibuffer installs its exit catch on
        ;; some Emacs builds. Deliver RET through the command loop instead.
        (setq unread-command-events (cons ?\r unread-command-events)))
    (etaf-reader-gui--keys context keys)))

(defun etaf-reader-gui-run (directory file title query &optional screenshots)
  "Verify real FILE, its TITLE and library QUERY, recording into DIRECTORY.
DIRECTORY must be fresh. SCREENSHOTS requests window captures for review.
Use a disposable database copy: this scenario changes theme and adds a
bookmark/annotation. It never changes FILE. No application focus is requested."
  (let ((export (expand-file-name "notes.md" directory)))
    (etaf-gui-verifier-run
     (etaf-gui-verifier-scenario-create
      :name "reader-native-workflow"
      :claim "Real local book through library, navigation, settings and annotation controls"
      :initialize
      (lambda (context)
        (etaf-gui-verifier-context-select-buffer context (etaf-reader-open file)))
      :invariants
      (lambda (context)
        (let* ((buffer (etaf-gui-verifier-context-target-buffer context))
               (window (get-buffer-window buffer t)))
          (list (etaf-gui-verifier-assert
                 "reader remains mounted"
                 (not (null (etaf-runtime-for-buffer buffer))))
                (etaf-gui-verifier-assert
                 "canvas is not horizontally scrolled"
                 (and (window-live-p window) (= (window-hscroll window) 0))))))
      :actions
      (mapcar
       (lambda (spec)
         (let ((id (nth 0 spec)) (execute (nth 1 spec)) (expected (nth 2 spec)))
           (etaf-gui-verifier-action-create
            :id id :execute execute :screenshot screenshots
            :settled-p (lambda (context)
                         (not (null (string-match-p (regexp-quote expected)
                                                    (etaf-reader-gui--text context)))))
            :assertions
            (lambda (context)
              (list (etaf-gui-verifier-assert
                     expected (not (null (string-match-p
                                          (regexp-quote expected)
                                          (etaf-reader-gui--text context))))))))))
       (list
        (list "real-book" #'ignore title)
        (list "next-page" (lambda (c) (etaf-reader-gui--keys c "SPC")) title)
        (list "previous-page" (lambda (c) (etaf-reader-gui--keys c "DEL")) title)
        (list "contents" (lambda (c) (etaf-reader-gui--keys c "c")) "目录")
        (list "contents-page" (lambda (c) (etaf-reader-gui--activate c "下一页")) "目录")
        (list "close-contents" (lambda (c) (etaf-reader-gui--keys c "<escape>")) title)
        (list "settings" (lambda (c) (etaf-reader-gui--keys c "o")) "阅读设置")
        (list "paper-theme" (lambda (c) (etaf-reader-gui--activate c "纸色")) "阅读设置")
        (list "compact-paragraphs" (lambda (c) (etaf-reader-gui--activate c "紧凑")) "阅读设置")
        (list "close-settings" (lambda (c) (etaf-reader-gui--activate c "关闭")) title)
        (list "bookmark" (lambda (c) (etaf-reader-gui--keys c "b B")) "书签")
        (list "close-bookmarks" (lambda (c) (etaf-reader-gui--keys c "<escape>")) title)
        (list "shelf" (lambda (c) (etaf-reader-gui--keys c "f")) "本地书库")
        (list "shelf-next-page" (lambda (c) (etaf-reader-gui--activate c "下一页")) "本地书库")
        (list "library-search" (lambda (c) (etaf-reader-gui--input c "s" query)) title)
        (list "resume-book" (lambda (c) (etaf-reader-gui--activate c title)) title)
        (list "selection" (lambda (c) (etaf-reader-gui--keys c "v <right> <right> <right> RET")) "高亮")
        (list "highlight" (lambda (c) (etaf-reader-gui--activate c "高亮")) title)
        (list "notes" (lambda (c) (etaf-reader-gui--keys c "a")) "笔记与划线")
        (list "close-notes" (lambda (c) (etaf-reader-gui--keys c "<escape>")) title)
        (list "export"
              (lambda (c)
                (etaf-reader-gui--input c "E" export)
                (unless (and (file-exists-p export)
                             (> (file-attribute-size (file-attributes export)) 0))
                  (error "Export did not create Markdown"))) title))))
     directory)))

(defun etaf-reader-gui-layout-run (directory file &optional screenshots)
  "Verify reading, navigation and library layouts at four frame sizes.
Use real FILE and fresh DIRECTORY in an owned graphical instance. Restore its
original size even after a failed checkpoint; do not change application focus."
  (let ((frame (selected-frame)) (old-width (frame-width)) (old-height (frame-height))
        actions)
    (dolist (size '((160 42) (90 34) (60 28) (112 18)))
      (let ((width (car size)) (height (cadr size)))
        (dolist (spec '((reader . nil) (contents . "c") (settings . "<escape> o")
                        (shelf . "<escape> f")))
          (let ((kind (car spec)) (keys (cdr spec)))
            (push
             (etaf-gui-verifier-action-create
              :id (format "%s-%dx%d" kind width height) :screenshot screenshots
              :execute
              (lambda (context)
                (if keys
                    (etaf-reader-gui--keys context keys)
                  (etaf-gui-verifier-context-select-buffer context (etaf-reader-open file))
                  (set-frame-size frame width height)))
              :settled-p
              (lambda (context)
                (and (= (frame-width frame) width) (= (frame-height frame) height)
                     (let* ((buffer (etaf-gui-verifier-context-target-buffer context))
                            (window (get-buffer-window buffer t))
                            (viewport (etaf-runtime-viewport (etaf-runtime-for-buffer buffer))))
                       ;; ETAF's display-safe width may reserve two edge cells.
                       (and (= (cdr viewport) (window-body-height window))
                            (<= (abs (- (car viewport) (window-body-width window t)))
                                (* 2 (frame-char-width frame)))))
                     (string-match-p
                      (pcase kind ('contents "目录") ('settings "阅读设置")
                             ('shelf "本地书库") (_ "书库"))
                      (etaf-reader-gui--text context))))
              :assertions
              (lambda (context)
                (let* ((buffer (etaf-gui-verifier-context-target-buffer context))
                       (window (get-buffer-window buffer t))
                       (pixels (with-current-buffer buffer
                                 (window-text-pixel-size window (point-min) (point-max)))))
                  (list
                   (etaf-gui-verifier-assert "position and percentage remain visible"
                                             (or (not (eq kind 'reader))
                                                 (string-match-p "第 [0-9]+/[0-9]+ [页行].*[0-9]+\\.[0-9]+%"
                                                                 (etaf-reader-gui--text context))))
                   (etaf-gui-verifier-assert "no horizontal scrolling" (= (window-hscroll window) 0))
                   (etaf-gui-verifier-assert "no horizontal overflow"
                                             (<= (car pixels) (window-body-width window t)))
                   (etaf-gui-verifier-assert "no clipped rows"
                                             (<= (cdr pixels) (window-body-height window t))
                                             (format "painted=%s window=%s" (cdr pixels)
                                                     (window-body-height window t)))))))
             actions)))))
    (unwind-protect
        (etaf-gui-verifier-run
         (etaf-gui-verifier-scenario-create
          :name "reader-layout-matrix"
          :claim "Wide, medium, narrow and short native reading/library layouts"
          :initialize (lambda (context)
                        (etaf-gui-verifier-context-select-buffer context (etaf-reader-open file)))
          :actions (nreverse actions)) directory)
      (set-frame-size frame old-width old-height))))

(provide 'etaf-reader-gui-scenarios)
;;; etaf-reader-gui-scenarios.el ends here
