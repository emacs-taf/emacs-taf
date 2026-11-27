;;; etaf-md-tests.el --- Acceptance tests for etaf-md -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; Public behaviour tests.  Every scenario drives the previewer through the
;; interfaces declared in `etaf-md.el'.  Rendering scenarios mount a
;; real runtime in a batch Emacs and read the visible buffer back, so they
;; assert what a reader sees instead of internal parse structures.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'outline)
(require 'markdown-mode nil t)
(require 'etaf)
(require 'etaf-md)

(defconst etaf-md-tests--directory
  (file-name-directory (or load-file-name buffer-file-name))
  "Directory of this test file, resolved while it is loaded.")

(defun etaf-md-tests--fixture (name)
  "Return the absolute path of fixture NAME."
  (expand-file-name (concat "fixtures/" name) etaf-md-tests--directory))

(defun etaf-md-tests--mount (session)
  "Mount SESSION in a fresh buffer and return that buffer."
  (etaf-mount (generate-new-buffer " *md-preview-test*")
              (etaf-md-view session)
              '(:viewport-width 900 :viewport-height 60)))

(defmacro etaf-md-tests--with-mount (session &rest body)
  "Mount SESSION, run BODY in its buffer, and always kill the buffer."
  (declare (indent 1) (debug t))
  `(let ((buffer (etaf-md-tests--mount ,session)))
     (unwind-protect
         (with-current-buffer buffer ,@body)
       (when (buffer-live-p buffer) (kill-buffer buffer)))))

(defun etaf-md-tests--face-attribute (needle property)
  "Return PROPERTY of the face at the first occurrence of NEEDLE.
Ebox concatenates every contributing face, so the value may be a list of
plists or a single plist."
  (goto-char (point-min))
  (search-forward needle nil t)
  (let* ((face (or (get-text-property (match-beginning 0) 'face)
                   (plist-get (text-properties-at (match-beginning 0)) 'face)))
         (faces (cond ((null face) nil)
                      ((and (listp face) (keywordp (car face))) (list face))
                      ((listp face) face)
                      (t (list face)))))
    (cl-loop for entry in faces
             when (and (listp entry) (plist-get entry property))
             return (plist-get entry property))))

(defun etaf-md-tests--keymap-at (needle)
  "Return non-nil when the first occurrence of NEEDLE is clickable."
  (goto-char (point-min))
  (search-forward needle nil t)
  (or (get-text-property (match-beginning 0) 'keymap)
      (plist-get (text-properties-at (match-beginning 0)) 'keymap)))

(defun etaf-md-tests--media-grid-shape ()
  "Return the (COLUMNS . ROWS) of the media grid in the current buffer.
A converter prints one uniform block of `▀' characters; the monochrome
fallback prints the same shape as dots, so both are recognized.  The grid
sits inside the card border, so only the longest run of cells on a line
counts."
  (let ((best (cons 0 0))
         (columns 0)
         (rows 0))
    (save-excursion
      (goto-char (point-min))
      (while (not (eobp))
        (let* ((line (buffer-substring-no-properties
                      (line-beginning-position) (line-end-position)))
               (run (let ((start 0) (longest 0))
                      (while (string-match "[▀.]+" line start)
                        (setq longest (max longest (- (match-end 0) (match-beginning 0)))
                              start (match-end 0)))
                      longest))
               (cells (and (> run 1) run)))
          (if (and cells (= cells columns))
              (cl-incf rows)
            (progn
              (when (> rows (cdr best)) (setq best (cons columns rows)))
              (setq columns (or cells 0)
                    rows (if cells 1 0)))))
        (forward-line 1))
      (when (> rows (cdr best)) (setq best (cons columns rows))))
    best))

(ert-deftest etaf-md-tests-create-reports-document-state ()
  "Creating a session from text exposes title, outline and footnotes."
  (let* ((session (etaf-md-create
                   :text (concat "---\ntitle: 我的笔记\n---\n\n"
                                 "# 第一章\n\n正文[^a]。\n\n## 小节\n\n"
                                 "另一个脚注[^b]。\n\n[^a]: 甲\n\n[^b]: 乙\n")))
         (state (etaf-md-state session)))
    (should (equal (plist-get state :title) "我的笔记"))
    (should (equal (mapcar #'cadr (plist-get state :outline))
                   '("第一章" "小节")))
    (should (equal (plist-get state :footnotes) '("a" "b")))
    (should (eq (plist-get state :theme) 'dark))
    (should (> (plist-get state :blocks) 0))))

(ert-deftest etaf-md-tests-a-document-names-its-own-dialect ()
  "A `flavor:' line in front matter decides how the rest of that file parses.
The widest preset is the default, so a document that has to parse as GitHub
Flavored Markdown says so itself; a session's `:flavor' argument still wins."
  ;; The block has several keys, which is how front matter is written in
  ;; practice: the `flavor:' line sits among them, not at the block's edge.
  (let* ((text "---\ntitle: 方言\nflavor: gfm\nauthor: 林隐\n---\n\nH~2~O\n")
         (gfm (etaf-md-create :text text))
         (wide (etaf-md-create :text text :flavor 'etaf))
         (plain (etaf-md-create :text "H~2~O\n")))
    (unwind-protect
        (progn
          (should (eq 'gfm (plist-get (etaf-md-state gfm) :flavor)))
          (should (eq 'etaf (plist-get (etaf-md-state wide) :flavor)))
          (should-not (plist-get (etaf-md-state plain) :flavor))
          ;; The dialect decides the parse too, not only the reported value.
          (should (string-match-p "H~2~O" (etaf-md-tests--painted gfm)))
          (should (string-match-p "H₂O" (etaf-md-tests--painted wide)))
          (should (string-match-p "H₂O" (etaf-md-tests--painted plain))))
      nil)))

(defun etaf-md-tests--painted (session)
  "Return the page text SESSION renders, with SESSION mounted."
  (let ((buffer (etaf-md-tests--mount session)))
    (unwind-protect
        (with-current-buffer buffer
          (buffer-substring-no-properties (point-min) (point-max)))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(ert-deftest etaf-md-tests-render-inline-styles-and-links ()
  "A paragraph renders every run with its style and keeps links clickable."
  (let ((session (etaf-md-create
                  :text (concat "plain **bold** *italic* `code` "
                                "[site](https://example.com).\n"))))
    (etaf-md-tests--with-mount session
      (let ((text (substring-no-properties (buffer-string))))
        (should (string-match-p "plain bold italic code site" text)))
      (should (eq (etaf-md-tests--face-attribute "bold" :weight) 'bold))
      (should (eq (etaf-md-tests--face-attribute "italic" :slant) 'italic))
      (should (etaf-md-tests--keymap-at "site")))))

(ert-deftest etaf-md-tests-heading-links-override-heading-color ()
  "Links in every heading keep link color, heading weight and activation."
  (let ((session (etaf-md-create
                  :text (concat
                         (mapconcat
                          (lambda (level)
                            (format "%s Heading%d [Link%d](https://example.com/%d)"
                                    (make-string level ?#) level level level))
                          '(1 2 3 4 5 6) "\n\n")
                         "\n\n[Reference](https://example.com/)\n")
                  :theme 'dark))
        opened)
    (etaf-md-tests--with-mount session
      (let ((accent (etaf-md-tests--face-attribute "Reference" :foreground)))
        (dolist (level '(1 2 3 4 5 6))
          (let ((link (format "Link%d" level)))
            (should (string-match-p
                     (format "Heading%d Link%d" level level)
                     (buffer-substring-no-properties (point-min) (point-max))))
            (should (equal (etaf-md-tests--face-attribute link :foreground)
                           accent))
            (when (> level 1)
              (should-not (equal (etaf-md-tests--face-attribute
                                  (format "Heading%d" level) :foreground) accent)))
            (should (eq (etaf-md-tests--face-attribute link :weight) 'bold))
            (should (etaf-md-tests--keymap-at link))
            (goto-char (match-beginning 0))
            (cl-letf (((symbol-function 'browse-url)
                       (lambda (url &rest _) (push url opened))))
              (call-interactively (key-binding (kbd "RET"))))))))
    (should (equal (nreverse opened)
                   (mapcar (lambda (n) (format "https://example.com/%d" n))
                           '(1 2 3 4 5 6))))))

(ert-deftest etaf-md-tests-video-caption-activates-player ()
  "RET on a video caption starts playback inside the preview.
With a decoder the press must not leave the card for an external player, and
the repaint swaps the poster for the native canvas."
  (skip-unless (executable-find "ffmpeg"))
  (let* ((video (expand-file-name "../media/demo.mp4"
                                  etaf-md-tests--directory))
         (session (etaf-md-create :text (format "![Movie](%s)" video)))
         (real (symbol-function 'call-process))
         opened)
    (etaf-md-tests--with-mount session
      (should (etaf-md-tests--keymap-at "按 RET 播放"))
      (goto-char (match-beginning 0))
      (cl-letf (((symbol-function 'call-process)
                 (lambda (program &rest args)
                   (if (member program '("open" "xdg-open"))
                       (progn (push (car (last args)) opened) 0)
                     (apply real program args)))))
        (call-interactively (key-binding (kbd "RET"))))
      (sit-for 0.2)
      (goto-char (point-min))
      (should (search-forward "按 RET 播放/暂停" nil t)))
    (should-not opened)))

(ert-deftest etaf-md-tests-video-ret-toggles-playback-in-place ()
  "RET on the live player toggles playback without restarting it.
The canvas advances while playing, holds its last frame once paused, and
moves on from that frame when playback resumes."
  (skip-unless (executable-find "ffmpeg"))
  (let ((session (etaf-md-create
                  :text (format "![clip](%s)\n"
                                (etaf-md-tests--fixture "clip.mp4")))))
    (etaf-md-tests--with-mount session
      (goto-char (point-min))
      (search-forward "按 RET 播放" nil t)
      (goto-char (match-beginning 0))
      (call-interactively (key-binding (kbd "RET")))
      (let ((playing (buffer-string)))
        (sit-for 0.5)
        (should-not (equal playing (buffer-string))))
      (goto-char (point-min))
      (search-forward "按 RET 播放/暂停" nil t)
      (goto-char (match-beginning 0))
      (call-interactively (key-binding (kbd "RET")))
      (sit-for 0.4)
      (let ((paused (buffer-string)))
        (sit-for 0.5)
        (should (equal paused (buffer-string)))
        (call-interactively (key-binding (kbd "RET")))
        (sit-for 0.6)
        (should-not (equal paused (buffer-string)))))))

(ert-deftest etaf-md-tests-video-without-decoder-opens-externally ()
  "Without ffmpeg a local video card keeps the poster and opens externally.
The card renders once with whatever decoder the environment provides and
again with ffmpeg hidden; the second render must use its own poster probe
instead of the cached playback metadata."
  (skip-unless (memq system-type '(darwin gnu/linux)))
  (let* ((video (expand-file-name "../media/demo.mp4"
                                  etaf-md-tests--directory))
         (session (etaf-md-create :text (format "![Movie](%s)" video)))
         (real-process (symbol-function 'call-process))
         (real-find (symbol-function 'executable-find))
         opened)
    (etaf-md-tests--with-mount session)
    (cl-letf (((symbol-function 'executable-find)
               (lambda (program &optional remote)
                 (unless (equal program "ffmpeg")
                   (funcall real-find program remote)))))
      (etaf-md-tests--with-mount session
        (should (etaf-md-tests--keymap-at "按 RET 播放"))
        (goto-char (match-beginning 0))
        (cl-letf (((symbol-function 'call-process)
                   (lambda (program &rest args)
                     (if (member program '("open" "xdg-open"))
                         (progn (push (car (last args)) opened) 0)
                       (apply real-process program args)))))
          (call-interactively (key-binding (kbd "RET"))))))
    (should (equal opened (list video)))))

(defconst etaf-md-tests--documented-gutter 2
  "Cells the manual promises on each side of the reading measure.")

(defun etaf-md-tests--background-at (position)
  "Return the painted background at POSITION, or nil."
  (let ((face (get-text-property position 'face)))
    (cl-some (lambda (entry)
               (and (listp entry) (plist-get entry :background)))
             (if (keywordp (car-safe face)) (list face) face))))

(defun etaf-md-tests--page-margin-pixels ()
  "Return (LEADING . TRAILING) unpainted blank pixels of the current line.
A cell of the page margin is a space with no painted background; the table's
border and cell padding are spaces too, but they paint, so the walk stops at
them.  A displayed space counts its displayed width, not one character."
  (let* ((bol (line-beginning-position))
         (eol (line-end-position))
         (char (frame-char-width))
         (leading 0)
         (trailing 0)
         (painted-p (lambda (at)
                      (and (eq (char-after at) ?\s)
                           (not (null (get-text-property at 'display)))
                           (etaf-md-tests--background-at at))))
         (width-p (lambda (at)
                    (let ((display (get-text-property at 'display)))
                      (if (and (consp display) (plist-get (cdr display) :width))
                          (let ((width (plist-get (cdr display) :width)))
                            (if (numberp width) width (car width)))
                        char))))
         (position bol))
    ;; The page margin is one displayed space per side; a table line adds
    ;; painted cells after it, so take the unpainted run at each end.
    (while (and (< position eol) (eq (char-after position) ?\s))
      (if (funcall painted-p position)
          (setq position eol)
        (setq leading (+ leading (funcall width-p position))
              position (1+ position))))
    (setq position (1- eol))
    (while (and (>= position bol) (eq (char-after position) ?\s))
      (if (funcall painted-p position)
          (setq position bol)
        (setq trailing (+ trailing (funcall width-p position))
              position (1- position))))
    (cons leading trailing)))

(ert-deftest etaf-md-tests-narrow-window-keeps-the-measure-gutter ()
  "A narrow window keeps page margin on both sides of the reading measure.
Neither the text nor a table may reach the reading edge: the renderer
extends the last cell's paint into the window's sub-cell remainder, so a
table border on that edge would draw a bar across the gutter."
  (let ((session (etaf-md-create
                  :text (concat "## 非目标\n\n"
                                "| 不做 | 原因 |\n| --- | --- |\n"
                                "| 手机端 | ETAF 是 Emacs 内的界面 |\n")))
        (margin (* etaf-md-tests--documented-gutter (frame-char-width)))
        (char (frame-char-width)))
    (etaf-md-tests--with-mount session
      (dolist (cells (list 46 30))
        (etaf-runtime-refit (etaf-runtime-for-buffer (current-buffer))
                            (* char cells) 40)
        (dolist (needle '("不做" "手机端"))
          (goto-char (point-min))
          (search-forward needle)
          (let ((blank (etaf-md-tests--page-margin-pixels)))
            (should (>= (car blank) margin))
            (should (>= (cdr blank) margin))
            (should-not (etaf-md-tests--background-at
                         (1- (line-end-position))))))))))

(defun etaf-md-tests--foreground-at (needle)
  "Return the foreground color reported at the first NEEDLE, or nil."
  (goto-char (point-min))
  (search-forward needle)
  (let ((face (get-text-property (match-beginning 0) 'face)))
    (cl-some (lambda (entry)
               (and (listp entry) (plist-get entry :foreground)))
             (if (keywordp (car-safe face)) (list face) face))))

(defmacro etaf-md-tests--with-faces (faces &rest body)
  "Run BODY with FACES set on the default and outline-1 faces.
FACES is a plist of `:foreground', `:background' and `:outline'; every face
attribute it changes is restored afterwards, so a scenario that paints a theme
leaves the frame as it found it."
  (declare (indent 1))
  `(let ((etaf-md-tests--saved
          (list (face-attribute 'default :foreground nil t)
                (face-attribute 'default :background nil t)
                (face-attribute 'outline-1 :foreground nil t))))
     (unwind-protect
         (progn
           (set-face-attribute 'default nil
                               :foreground (or (plist-get ,faces :foreground) "#000000")
                               :background (or (plist-get ,faces :background) "#ffffff"))
           (set-face-attribute 'outline-1 nil
                               :foreground (or (plist-get ,faces :outline) 'unspecified))
           ,@body)
       (cl-destructuring-bind (foreground background outline) etaf-md-tests--saved
         (when (stringp foreground) (set-face-attribute 'default nil :foreground foreground))
         (when (stringp background) (set-face-attribute 'default nil :background background))
         (set-face-attribute 'outline-1 nil :foreground (or outline 'unspecified))))))

(ert-deftest etaf-md-tests-heading-color-separates-from-flat-themed-ink ()
  "A theme that paints its outline color as its body color gets a heading hue.
Several dark themes do that, and honoring them literally renders every heading
flat; the palette then derives the heading from the accent instead."
  (etaf-md-tests--with-faces
      '(:foreground "#ffffff" :background "#263238" :outline "#eceff1")
    (etaf-md-tests--with-mount (etaf-md-create :text "## Heading\n")
      (let ((heading (etaf-md-tests--foreground-at "Heading")))
        (should heading)
        (should-not (equal heading "#eceff1"))
        (should-not (equal heading "#ffffff"))))))

(ert-deftest etaf-md-tests-heading-keeps-a-distinct-theme-color ()
  "A theme whose heading color differs from its body text keeps that color.
The derivation only replaces a heading color that would read as plain text."
  (etaf-md-tests--with-faces
      '(:foreground "#383a42" :background "#fafafa" :outline "#0184bc")
    (etaf-md-tests--with-mount (etaf-md-create :text "## Heading\n")
      (should (equal "#0184bc"
                     (etaf-md-tests--foreground-at "Heading"))))))

(ert-deftest etaf-md-tests-auto-palette-follows-a-theme-switch ()
  "The face-derived palette follows an Emacs theme switch.
Ebox resolves colors into the buffer while a View renders, so the preview has
to render again after the switch Emacs reports through
`enable-theme-functions'; a palette derived once at mount left light text on a
light page."
  (let ((session (etaf-md-create :text "ThemeProbe"))
        (original (face-attribute 'default :foreground nil t)))
    (unwind-protect
        (progn
          (set-face-attribute 'default nil :foreground "#101010")
          (etaf-md-tests--with-mount session
            (should (equal "#101010"
                           (etaf-md-tests--face-attribute "ThemeProbe" :foreground)))
            (set-face-attribute 'default nil :foreground "#202020")
            (run-hooks 'enable-theme-functions)
            (sleep-for 0.05)
            (should (equal "#202020"
                           (etaf-md-tests--face-attribute "ThemeProbe" :foreground)))))
      (set-face-attribute 'default nil :foreground original))))

(ert-deftest etaf-md-tests-reading-measure-stays-centered-on-refit ()
  "A capped reading measure stays centered without stretching its content.
The measure gutter sits on both sides, so a column that fills the window
keeps its text one gutter in rather than on the edge."
  (let* ((session (etaf-md-create :text "CenterProbe"))
         (char (frame-char-width))
         (gutter (* char etaf-md-tests--documented-gutter))
         (cap (* char (plist-get (etaf-md-state session) :width))))
    (etaf-md-tests--with-mount session
      (dolist (width (list (+ cap 100) (+ cap 300) (max 40 (- cap 20)) (+ cap 100)))
        (etaf-runtime-refit (etaf-runtime-for-buffer (current-buffer)) width 60)
        (goto-char (point-min))
        (search-forward "CenterProbe")
        (let ((left (string-pixel-width
                     (buffer-substring (line-beginning-position) (match-beginning 0)))))
          (should (<= (abs (- left (max gutter (/ (max 0 (- width cap)) 2)))) 1)))))))

(ert-deftest etaf-md-tests-alerts-end-with-their-body ()
  "Callouts add no empty row after the final body line."
  (dolist (kind '("NOTE" "TIP" "IMPORTANT" "WARNING" "CAUTION"))
    (let ((session (etaf-md-create
                    :text (format "> [!%s]\n> First  \n> Last\n\nTail" kind))))
      (etaf-md-tests--with-mount session
        (goto-char (point-min))
        (search-forward "First")
        (forward-line 1)
        (should (search-forward "Last" (line-end-position) t))
        (forward-line 1)
        (should (string-blank-p
                 (buffer-substring-no-properties
                  (line-beginning-position) (line-end-position))))
        (forward-line 1)
        (should (search-forward "Tail" (line-end-position) t))))))

(ert-deftest etaf-md-tests-render-block-structure ()
  "Headings, lists, tasks, quotes, code and tables all reach the buffer."
  (let ((session (etaf-md-create
                  :text (concat "# Title\n\n- one\n- two\n  - nested\n\n"
                                "1. first\n\n- [x] done\n- [ ] todo\n\n"
                                "> quoted **text**\n\n"
                                "```elisp\n(defun hi ())\n```\n\n"
                                "| a | b |\n|:--|--:|\n| 1 | 2 |\n\n---\n"))))
    (etaf-md-tests--with-mount session
      (let ((text (substring-no-properties (buffer-string))))
        (should (string-match-p "Title" text))
        (should (string-match-p "one" text))
        (should (string-match-p "nested" text))
        (should (string-match-p "first" text))
        (should (string-match-p "■ done" text))
        (should (string-match-p "□ todo" text))
        (should (string-match-p "quoted text" text))
        (should (string-match-p "(defun hi ())" text))
        (should (string-match-p "elisp" text))
        (should (string-match-p "a" text))
        (should (string-match-p "2" text))))))

(ert-deftest etaf-md-tests-footnotes-numbered-and-defined ()
  "Footnote references render numbered and definitions appear at the end."
  (let ((session (etaf-md-create
                  :text "First[^one] and second[^two].\n\n[^one]: 甲\n\n[^two]: 乙\n")))
    (etaf-md-tests--with-mount session
      (let ((text (substring-no-properties (buffer-string))))
        (should (string-match-p "First\\[1\\] and second\\[2\\]" text))
        (should (string-match-p "\\[1\\] 甲" text))
        (should (string-match-p "\\[2\\] 乙" text))))))

(ert-deftest etaf-md-tests-media-cards-show-placeholders ()
  "Missing local media renders a labeled card instead of failing."
  (let ((session (etaf-md-create
                  :text (concat "![截图](/nonexistent/picture.png)\n\n"
                                "![录屏](/nonexistent/clip.mp4)\n\n"
                                "![远程](https://example.com/badge.svg)\n"))))
    (etaf-md-tests--with-mount session
      (let ((text (substring-no-properties (buffer-string))))
        (should (string-match-p "截图" text))
        (should (string-match-p "录屏" text))
        (should (string-match-p "https://example.com/badge.svg" text))))))

(ert-deftest etaf-md-tests-media-keeps-source-aspect-under-height-cap ()
  "A wide image narrows its grid with the height cap instead of squashing.
The fixture is 4:1; a card that only capped the rows would render it at
roughly 9:1 while the visible cell grid must stay close to the source."
  (let* ((image (etaf-md-tests--fixture "wide-400x100.png"))
         (session (etaf-md-create
                   :text (format "![wide](%s)\n" image))))
    (etaf-md-tests--with-mount session
      (let* ((shape (etaf-md-tests--media-grid-shape))
             (columns (car shape))
             (rows (cdr shape)))
        (should (> rows 1))
        (should (> columns 1))
        (should (< (abs (- (/ (* 1.0 columns) rows) 4.0)) 1.2))))))

(ert-deftest etaf-md-tests-video-card-plays-with-a-native-decoder ()
  "A local video card offers inline playback when ffmpeg can decode it.
The card starts as a poster and names the action that mounts the player."
  (skip-unless (executable-find "ffmpeg"))
  (let ((session (etaf-md-create
                  :text (format "![clip](%s)\n"
                                (etaf-md-tests--fixture "clip.mp4")))))
    (etaf-md-tests--with-mount session
      (let ((text (substring-no-properties (buffer-string))))
        (should (string-match-p "▶ clip" text))
        (should (string-match-p "按 RET 播放" text))))))

(ert-deftest etaf-md-tests-local-media-opens-with-the-desktop ()
  "RET on a local media card asks the desktop to open the file.
Emacs's browser plumbing would put a video in a buffer; the card must reach
the system opener instead."
  (skip-unless (memq system-type '(darwin gnu/linux)))
  (let* ((image (etaf-md-tests--fixture "wide-400x100.png"))
         (session (etaf-md-create
                   :text (format "![wide](%s)\n" image)))
         (opened nil)
         (real (symbol-function 'call-process)))
    (etaf-md-tests--with-mount session
      (goto-char (point-min))
      (search-forward "▀" nil t)
      (goto-char (match-beginning 0))
      (let ((binding (key-binding (kbd "RET"))))
        (cl-letf (((symbol-function 'call-process)
                   (lambda (program &rest args)
                     (if (member program '("open" "xdg-open"))
                         (progn (push (car (last args)) opened) 0)
                       (apply real program args)))))
          (when (commandp binding)
            (call-interactively binding)))))
    (should (equal opened (list image)))))

(ert-deftest etaf-md-tests-refresh-re-reads-a-file ()
  "Refresh re-reads the file and publishes the new outline."
  (let* ((file (make-temp-file "etaf-md-" nil ".md"))
         (session nil))
    (unwind-protect
        (progn
          (with-temp-file file (insert "# First\n"))
          (setq session (etaf-md-create :file file))
          (should (equal (mapcar #'cadr (plist-get (etaf-md-state session)
                                                   :outline))
                         '("First")))
          (with-temp-file file (insert "# Second\n\nbody\n"))
          (etaf-md-refresh session)
          (should (equal (mapcar #'cadr (plist-get (etaf-md-state session)
                                                   :outline))
                         '("Second"))))
      (delete-file file))))

(ert-deftest etaf-md-tests-entry-command-keeps-the-source-window ()
  "`etaf-md-preview' opens a right preview split while keeping the source window.
The source buffer keeps the selected window, invoking `etaf-md-preview' a
second time closes the split cleanly, closing via `etaf-md-close' removes the
split, and manual `delete-other-windows' lets `etaf-md-preview' re-open cleanly."
  (let* ((file (make-temp-file "etaf-md-" nil ".md"))
         (source nil))
    (unwind-protect
        (progn
          (with-temp-file file (insert "# Beside\n\nbody text\n"))
          (setq source (find-file-noselect file))
          (switch-to-buffer source)
          (delete-other-windows)
          ;; 1. First `etaf-md-preview' -> 2 windows (source left, preview right), source selected.
          (let ((preview-buf (etaf-md-preview)))
            (should (buffer-live-p preview-buf)))
          (let ((preview-window
                 (cl-find-if (lambda (window)
                               (string-prefix-p "*ETAF Markdown:"
                                                (buffer-name (window-buffer window))))
                             (window-list))))
            (should (= 2 (length (window-list))))
            (should (eq (window-buffer (selected-window)) source))
            (should preview-window)
            (should (< (car (window-edges (selected-window)))
                       (car (window-edges preview-window))))
            ;; 2. Closing from preview removes only the split window.
            (select-window preview-window)
            (etaf-md-close)
            (should (= 1 (length (window-list)))))
          ;; 3. Re-opening then toggling off directly from source cleans up split too.
          (with-current-buffer source
            (should (buffer-live-p (etaf-md-preview)))
            (should (= 2 (length (window-list))))
            (should-not (etaf-md-preview))
            (should (= 1 (length (window-list))))
            (should (eq (window-buffer (selected-window)) source))
            ;; 4. Manual C-x 1 leaves no stale state: next `etaf-md-preview' re-splits cleanly.
            (should (buffer-live-p (etaf-md-preview)))
            (delete-other-windows)
            (should (= 1 (length (window-list))))
            (should (buffer-live-p (etaf-md-preview)))
            (should (= 2 (length (window-list))))
            (should-not (etaf-md-preview))
            (should (= 1 (length (window-list))))))
      (dolist (buffer (buffer-list))
        (when (and (string-prefix-p "*ETAF Markdown:" (buffer-name buffer))
                   (buffer-live-p buffer))
          (kill-buffer buffer)))
      (when (buffer-live-p source) (kill-buffer source))
      (delete-file file))))

(ert-deftest etaf-md-tests-typing-keeps-the-followed-page-in-place ()
  "Typing near the top of the source does not move the page with it.
A window's start moves whenever text is inserted above it, so a follow that
compared positions scrolled the page on every keystroke and paid a repaint for
it.  The page moves only when the source window starts on another line."
  (let* ((file (make-temp-file "etaf-md-typing-" nil ".md"))
         (source nil)
         (preview nil)
         (top-line (lambda (window)
                     (with-current-buffer (window-buffer window)
                       (buffer-substring-no-properties
                        (window-start window)
                        (save-excursion
                          (goto-char (window-start window))
                          (line-end-position)))))))
    (unwind-protect
        (progn
          (with-temp-file file
            (insert "---\ntitle: 打字测试\n---\n\n")
            (dotimes (index 40)
              (insert (format "第 %d 段：一段用来测量跟随滚动的正文。\n\n" index))))
          (setq source (find-file-noselect file))
          (setq preview (etaf-md-open file))
          (let* ((source-window (selected-window))
                 (preview-window (split-window source-window)))
            (set-window-buffer source-window source)
            (set-window-buffer preview-window preview)
            (select-window source-window)
            (sit-for 0.2)
            (etaf-runtime-flush (etaf-runtime-for-buffer preview))
            (with-current-buffer source
              (should (etaf-md-follow-scroll 1))
              (goto-char (point-min))
              (search-forward "第 20 段")
              (set-window-start source-window (line-beginning-position))
              (run-hooks 'post-command-hook))
            (etaf-runtime-flush (etaf-runtime-for-buffer preview))
            (let ((before (funcall top-line preview-window)))
              (with-current-buffer source
                (goto-char (point-min))
                (insert "第一行打的一行字\n")
                (run-hooks 'post-command-hook))
              (etaf-runtime-flush (etaf-runtime-for-buffer preview))
              (should (equal (funcall top-line preview-window) before)))))
      (when (buffer-live-p preview) (kill-buffer preview))
      (when (buffer-live-p source)
        (with-current-buffer source (set-buffer-modified-p nil))
        (kill-buffer source))
      (delete-file file))))

(ert-deftest etaf-md-tests-follow-scroll-shows-the-source-top ()
  "The scroll follow puts the block at the source window's top at the page's top.
The preview is read-only and the source is edited in its own window, so a
reader keeping the two side by side needs the page to move with the source.
Turning it off leaves the page where the reader put it."
  (let* ((file (make-temp-file "etaf-md-scroll-" nil ".md"))
         (source nil)
         (preview nil)
         (top-line (lambda (window)
                     (with-current-buffer (window-buffer window)
                       (buffer-substring-no-properties
                        (window-start window)
                        (save-excursion
                          (goto-char (window-start window))
                          (line-end-position)))))))
    (unwind-protect
        (progn
          (with-temp-file file
            (insert "---\ntitle: 跟随测试\n---\n\n")
            (dotimes (index 40)
              (insert (format "第 %d 段：一段用来测量跟随滚动的正文。\n\n" index))))
          (setq source (find-file-noselect file))
          (setq preview (etaf-md-open file))
          (let* ((source-window (selected-window))
                 (preview-window (split-window source-window)))
            (set-window-buffer source-window source)
            (set-window-buffer preview-window preview)
            (select-window source-window)
            (sit-for 0.2)
            (etaf-runtime-flush (etaf-runtime-for-buffer preview))
            (should-not (string-match-p "第 20 段" (funcall top-line preview-window)))
            (with-current-buffer source
              (should (etaf-md-follow-scroll 1)))
            (with-current-buffer source
              (goto-char (point-min))
              (search-forward "第 20 段")
              (set-window-start source-window (line-beginning-position))
              ;; The page follows from the source buffer's command loop, so the
              ;; hook a command runs is what moves it.
              (run-hooks 'post-command-hook))
            (etaf-runtime-flush (etaf-runtime-for-buffer preview))
            (should (string-match-p "第 20 段" (funcall top-line preview-window)))
            ;; The window must start at column 0 of the block's first row so
            ;; the page container's left-padding cell is not clipped away.
            (let* ((start (window-start preview-window))
                   (bol (with-current-buffer preview
                          (save-excursion
                            (goto-char start)
                            (line-beginning-position))))
                   (gutter (with-current-buffer preview
                             (get-text-property start 'display))))
              (should (= start bol))
              (should (eq (car-safe gutter) 'space))
              ;; Keep window-point synced so GUI redisplay never snaps back to L1.
              (should (= (window-point preview-window) start)))
            ;; The command also runs from the preview, and turning the follow
            ;; off leaves the page where the source scroll last put it.
            (with-current-buffer preview
              (should-not (etaf-md-follow-scroll 0)))
            (with-current-buffer source
              (goto-char (point-min))
              (search-forward "第 35 段")
              (set-window-start source-window (line-beginning-position))
              ;; The page follows from the source buffer's command loop, so the
              ;; hook a command runs is what moves it.
              (run-hooks 'post-command-hook))
            (etaf-runtime-flush (etaf-runtime-for-buffer preview))
            (should (string-match-p "第 20 段" (funcall top-line preview-window)))
            ;; The first line of the source sits above the first block when
            ;; the document opens with front matter, and the page shows its
            ;; header there; the follow has to reach that header too.
            (with-current-buffer source
              (should (etaf-md-follow-scroll 1))
              (goto-char (point-min))
              (set-window-start source-window (point-min))
              (run-hooks 'post-command-hook))
            (etaf-runtime-flush (etaf-runtime-for-buffer preview))
            (should (= (window-start preview-window)
                       (with-current-buffer preview (point-min))))))
      (when (buffer-live-p preview) (kill-buffer preview))
      (when (buffer-live-p source)
        (with-current-buffer source (set-buffer-modified-p nil))
        (kill-buffer source))
      (delete-file file))))

(defun etaf-md-tests--rows (text)
  "Return TEXT's painted rows, one string per row, without properties."
  (let* ((session (etaf-md-create :text text))
         (buffer (generate-new-buffer " *etaf-md rows*"))
         (name (buffer-name buffer)))
    (unwind-protect
        (progn
          (etaf-mount name (etaf-md-view session))
          (sit-for 0.05)
          (with-current-buffer name
            (split-string (substring-no-properties (buffer-string)) "\n")))
      (when-let* ((runtime (etaf-runtime-for-buffer name)))
        (etaf-unmount runtime))
      (when (get-buffer name) (kill-buffer name)))))

(defun etaf-md-tests--gap (text from to)
  "Return how many blank rows sit between the rows holding FROM and TO."
  (let* ((rows (etaf-md-tests--rows text))
         (start (cl-position-if (lambda (row) (string-match-p (regexp-quote from) row)) rows))
         (end (cl-position-if (lambda (row) (string-match-p (regexp-quote to) row)) rows)))
    (cl-count-if #'string-blank-p (cl-subseq rows (1+ start) end))))

(defun etaf-md-tests--blank-rows-above (text needle)
  "Return the blank rows a page of TEXT paints above NEEDLE, less its top row."
  (let* ((rows (etaf-md-tests--rows text))
         (end (cl-position-if (lambda (row) (string-match-p (regexp-quote needle) row)) rows)))
    (1- (cl-count-if #'string-blank-p (cl-subseq rows 0 end)))))

(ert-deftest etaf-md-tests-a-theme-switch-keeps-a-closed-source-whole ()
  "Switching the palette keeps the page whole after its source buffer closed.
The republish a palette change asks for reads the session's source, and a
session whose file is no longer visited used to answer with no text at all: the
page collapsed to an empty document."
  (let* ((file (make-temp-file "etaf-md-palette-" nil ".md"))
         (source nil)
         (preview nil))
    (unwind-protect
        (progn
          (with-temp-file file
            (insert "# 标题\n\n正文一段，写在源文件里。\n\n第二段。\n"))
          (setq source (find-file-noselect file))
          (setq preview (etaf-md-open file))
          (should (> (with-current-buffer preview (buffer-size)) 40))
          (kill-buffer source)
          (setq source nil)
          (with-current-buffer preview
            (etaf-md-set-theme (etaf-app-state preview) 'light))
          (sit-for 0.3)
          (with-current-buffer preview
            (should (string-match-p "正文一段" (buffer-string)))
            (should (string-match-p "第二段" (buffer-string)))))
      (when (buffer-live-p preview) (kill-buffer preview))
      (when (buffer-live-p source)
        (with-current-buffer source (set-buffer-modified-p nil))
        (kill-buffer source))
      (delete-file file))))

(ert-deftest etaf-md-tests-breaks-follow-the-markdown-rules ()
  "A soft break folds into the paragraph; a hard break and a blank line paint rows.
CommonMark reads a source line end inside a paragraph as a space, so the page
flows the text at its own width; two trailing spaces or a backslash asks for a
line end, a blank line inside a fence stays a row inside the block, and blank
lines between blocks keep their count."
  (let ((row (lambda (text needle)
               (cl-position-if (lambda (line) (string-match-p (regexp-quote needle) line))
                               (etaf-md-tests--rows text)))))
    ;; One folded row holds both words of a soft break.
    (let ((rows (etaf-md-tests--rows "alpha\nbeta\n")))
      (should (= 1 (length (cl-remove-if-not
                            (lambda (line) (string-match-p "alpha" line)) rows))))
      (should (string-match-p "alpha beta"
                              (nth (funcall row "alpha\nbeta\n" "alpha") rows))))
    ;; A hard break of either spelling starts a row of its own.
    (dolist (text (list "alpha  \nbeta\n" "alpha\\\nbeta\n"))
      (should (= 1 (- (funcall row text "beta") (funcall row text "alpha")))))
    ;; A blank line inside a fence is a row inside the block.
    (let* ((text "```\nfirst\n\nsecond\n```\n")
           (first (funcall row text "first"))
           (second (funcall row text "second")))
      (should (= 2 (- second first)))
      (let ((between (nth (1+ first) (etaf-md-tests--rows text))))
        (should-not (string-match-p "first\\|second" between))))
    ;; Two blank lines between blocks paint two rows, not one and not none.
    (should (= 2 (etaf-md-tests--gap "a\n\n\nb\n" "a" "b")))
    (should (= 1 (etaf-md-tests--gap
                  "| a |\n| --- |\n| 1 |\n\nbody\n" "1" "body")))))

(ert-deftest etaf-md-tests-blank-lines-follow-the-source ()
  "The page paints one row per blank source line wherever the blank sits.
A blank line between blocks, inside a loose list item and after a line the
parser consumes without painting one all become rows the reader can type on,
and two blank lines become two rows instead of collapsing into one."
  (should (= 1 (etaf-md-tests--gap "a\n\nb\n" "a" "b")))
  (should (= 2 (etaf-md-tests--gap "a\n\n\nb\n" "a" "b")))
  (should (= 1 (etaf-md-tests--gap "- a\n\n  b\n" "a" "b")))
  (should (= 1 (etaf-md-tests--gap "1. a\n\n   b\n" "a" "b")))
  ;; The definition line paints nothing, so the blank after it is the gap the
  ;; page keeps; before the fix the whole leading stretch was skipped.
  (should (= 1 (etaf-md-tests--blank-rows-above
                "*[HTML]: HyperText Markup Language\n\nHTML 是标记\n" "HTML 是标记")))
  (should (= 1 (etaf-md-tests--blank-rows-above
                "[r]: https://example.com\n\nuse [r]\n" "use")))
  ;; The front matter becomes the header, and its blank line stays.
  (should (= 1 (etaf-md-tests--gap
                "---\ntitle: T\n---\n\nbody\n" "T" "body"))))

(ert-deftest etaf-md-tests-saving-the-source-repaints-the-preview ()
  "Saving a source file republishes its open preview without a manual reload."
  (let* ((file (make-temp-file "etaf-md-follow-" nil ".md"))
         (source nil)
         (preview nil))
    (unwind-protect
        (progn
          (with-temp-file file (insert "# Document\n\nold body\n"))
          (setq source (find-file-noselect file))
          (setq preview (etaf-md-open file))
          (should (with-current-buffer preview
                    (string-match-p "old body" (buffer-string))))
          (with-current-buffer source
            (goto-char (point-max))
            (insert "\n## Added\n\nnew body here\n")
            (save-buffer))
          (sit-for 0.5)
          ;; the framework draws the republished document in its next update
          (etaf-runtime-flush (etaf-runtime-for-buffer preview))
          (with-current-buffer preview
            (should (string-match-p "new body here" (buffer-string)))))
      (when (buffer-live-p preview) (kill-buffer preview))
      (when (buffer-live-p source) (kill-buffer source))
      (delete-file file))))

(ert-deftest etaf-md-tests-unsaved-edits-reach-the-preview ()
  "Editing the source buffer repaints the preview without saving it.
The preview follows the visiting buffer, so a reader comparing a paragraph
with its render does not have to save first; closing the preview stops
following the buffer, so a later edit cannot bring it back."
  (let* ((file (make-temp-file "etaf-md-live-" nil ".md"))
         (source nil)
         (preview nil))
    (unwind-protect
        (progn
          (with-temp-file file (insert "# Live\n\nold text\n"))
          (setq source (find-file-noselect file))
          (setq preview (etaf-md-open file))
          (should (with-current-buffer preview
                    (string-match-p "old text" (buffer-string))))
          (with-current-buffer source
            (goto-char (point-max))
            (insert "fresh words never saved\n"))
          (should (buffer-modified-p source))
          (sit-for 0.5)
          (etaf-runtime-flush (etaf-runtime-for-buffer preview))
          (with-current-buffer preview
            (should (string-match-p "fresh words never saved" (buffer-string))))
          (let ((name (buffer-name preview)))
            (with-current-buffer preview (etaf-md-close))
            (should-not (get-buffer name))
            ;; an edit after closing must not bring the preview back
            (with-current-buffer source
              (goto-char (point-max))
              (insert "after the preview closed\n"))
            (sit-for 0.3)
            (should-not (get-buffer name))))
      (when (buffer-live-p preview) (kill-buffer preview))
      (when (buffer-live-p source)
        (with-current-buffer source (set-buffer-modified-p nil))
        (kill-buffer source))
      (delete-file file))))

(ert-deftest etaf-md-tests-a-file-opened-later-is-followed ()
  "Opening the markdown after its preview still makes the preview follow it.
A reader may open the preview first; typing in the file afterwards has to reach
the page without saving, so the visiting buffer is picked up when it appears
rather than only when the preview mounts."
  (let* ((file (make-temp-file "etaf-md-later-" nil ".md"))
         (source nil)
         (preview nil))
    (unwind-protect
        (progn
          (with-temp-file file (insert "# Later\n\noriginal text\n"))
          (setq preview (etaf-md-open file))
          (should-not (get-file-buffer file))
          (should (with-current-buffer preview
                    (string-match-p "original text" (buffer-string))))
          (setq source (find-file-noselect file))
          (with-current-buffer source
            (goto-char (point-max))
            (insert "typed after the preview opened\n"))
          (should (buffer-modified-p source))
          (sit-for 0.5)
          (etaf-runtime-flush (etaf-runtime-for-buffer preview))
          (with-current-buffer preview
            (should (string-match-p "typed after the preview opened"
                                    (buffer-string)))))
      (when (buffer-live-p preview) (kill-buffer preview))
      (when (buffer-live-p source)
        (with-current-buffer source (set-buffer-modified-p nil))
        (kill-buffer source))
      (delete-file file))))

(ert-deftest etaf-md-tests-editing-beside-a-definition-list-repaints ()
  "An unsaved edit repaints a document that holds a definition list.
The paragraph above a definition list and the list itself are two blocks read
by one clause, so the parse keeps a range for each.  An edit elsewhere in the
document is spliced against those ranges, and a missing one stopped the follow
repaint before the page could show the new text."
  (let* ((file (make-temp-file "etaf-md-definition-" nil ".md"))
         (source nil)
         (preview nil))
    (unwind-protect
        (progn
          (with-temp-file file
            (insert "# 术语\n\n前言一行\n术语行\n: 定义一行\n\n旧段落\n"))
          (setq source (find-file-noselect file))
          (setq preview (etaf-md-open file))
          (should (with-current-buffer preview
                    (string-match-p "旧段落" (buffer-string))))
          (with-current-buffer source
            (goto-char (point-max))
            (delete-region (line-beginning-position) (point))
            (insert "新段落，刚改过\n"))
          (sit-for 0.5)
          (etaf-runtime-flush (etaf-runtime-for-buffer preview))
          (with-current-buffer preview
            (should (string-match-p "新段落，刚改过" (buffer-string)))
            (should (string-match-p "术语行" (buffer-string)))))
      (when (buffer-live-p preview) (kill-buffer preview))
      (when (buffer-live-p source)
        (with-current-buffer source (set-buffer-modified-p nil))
        (kill-buffer source))
      (delete-file file))))

(ert-deftest etaf-md-tests-one-edit-repaints-one-block ()
  "One edited paragraph repaints that paragraph, not the document.
Every top-level block is its own Component, so a publish hands the runtime the
published blocks it already has.  The edited block's lines are the whole buffer
patch, and the paragraphs far from the edit keep their text byte for byte."
  (let* ((file (make-temp-file "etaf-md-blocks-" nil ".md"))
         (source nil)
         (preview nil))
    (unwind-protect
        (progn
          (with-temp-file file
            (insert "# Blocks\n\n")
            (dotimes (index 40)
              (insert (format "第 %d 段：一段用来测量块级重画的正文。\n\n" index))))
          (setq source (find-file-noselect file))
          (setq preview (etaf-md-open file))
          (let ((before (with-current-buffer preview
                          (substring-no-properties (buffer-string)))))
            (should (string-match-p "第 20 段" before))
            (with-current-buffer source
              (goto-char (point-min))
              (search-forward "第 20 段")
              (let ((start (line-beginning-position)))
                (goto-char start)
                (delete-region start (line-end-position))
                (insert "第 20 段：这一段刚刚被改写。")))
            (sit-for 0.5)
            (etaf-runtime-flush (etaf-runtime-for-buffer preview))
            (let* ((after (with-current-buffer preview
                            (string-match-p "这一段刚刚被改写。"
                                            (buffer-string))))
                   (report (with-current-buffer preview
                             (etaf-runtime-update-report))))
              (should after)
              (should (eq 'lines (plist-get report :strategy)))
              (should (<= (plist-get report :edits) 2))
              (should (<= (plist-get report :lines) 4))
              ;; The published patch covers few lines while the document is
              ;; long, so the flush is one block rather than a rewrite.
              (should (< (plist-get report :lines)
                         (/ (with-current-buffer preview
                              (count-lines (point-min) (point-max)))
                            4)))
              ;; Text far from the edit is untouched, not merely re-rendered.
              (should (with-current-buffer preview
                        (string-match-p "第 0 段：一段用来测量块级重画的正文。"
                                        (buffer-string))))
              (should (with-current-buffer preview
                        (string-match-p "第 39 段：一段用来测量块级重画的正文。"
                                        (buffer-string)))))))
      (when (buffer-live-p preview) (kill-buffer preview))
      (when (buffer-live-p source)
        (with-current-buffer source (set-buffer-modified-p nil))
        (kill-buffer source))
      (delete-file file))))

(ert-deftest etaf-md-tests-theme-changes-and-rejects-unknown ()
  "Themes cycle in order and unknown palettes are rejected."
  (let ((session (etaf-md-create :text "# x\n" :theme 'dark)))
    (should (equal (etaf-md-set-theme session 'light) session))
    (should (eq (plist-get (etaf-md-state session) :theme) 'light))
    (should (eq (plist-get (etaf-md-state session) :background) 'palette))
    (should (eq (etaf-md-cycle-theme session) 'sepia))
    (should-error (etaf-md-set-theme session 'neon)
                  :type 'etaf-md-error)))

(defun etaf-md-tests--row-painting (buffer color)
  "Return the first position in BUFFER whose face paints COLOR as background."
  (with-current-buffer buffer
    (let ((pos (point-min))
          found)
      (while (and (< pos (point-max)) (not found))
        (when (equal color
                     (plist-get (get-text-property pos 'face) :background))
          (setq found pos))
        (setq pos (1+ pos)))
      found)))

(defun etaf-md-tests--painted-background (buffer position)
  "Return the background BUFFER paints at POSITION."
  (with-current-buffer buffer
    (plist-get (get-text-property position 'face) :background)))

(etaf-define-component etaf-md-tests--framing-host (&key surface session)
  "Provide SURFACE to the preview SESSION and render it below."
  :setup (etaf-surface-provide surface)
  :render (etaf-md-view session))

(ert-deftest etaf-md-tests-declares-its-surface-to-a-host ()
  "A host frames the preview from the surface the preview declares.
The panel's title-bar switch writes the session's theme cell, so the document
repaints with the chosen page instead of only the frame chrome."
  (let* ((session (etaf-md-create :text "# Title\n\nBody text.\n"))
         (surface (etaf-surface-create))
         (buffer (generate-new-buffer " *etaf-md framing host*")))
    (unwind-protect
        (progn
          (etaf-mount buffer
                      (etaf-view (etaf-md-tests--framing-host
                                  :surface surface :session session))
                      (list :viewport-width 900 :viewport-height 60))
          (etaf-runtime-flush (etaf-runtime-for-buffer buffer))
          (should (equal '((light . "亮") (auto . "随") (dark . "暗") (sepia . "纸"))
                         (etaf-surface-modes surface)))
          (should (eq 'auto (etaf-value (etaf-surface-mode surface))))
          (etaf-set-value (etaf-surface-mode surface) 'light)
          (etaf-runtime-flush (etaf-runtime-for-buffer buffer))
          (should (eq 'light (plist-get (etaf-md-state session) :theme)))
          (let* ((light (plist-get (etaf-value (etaf-surface-theme surface)) :ui-bg))
                 (pos (etaf-md-tests--row-painting buffer light)))
            (should (equal light "#ffffff"))
            (should pos)
            (etaf-set-value (etaf-surface-mode surface) 'dark)
            (etaf-runtime-flush (etaf-runtime-for-buffer buffer))
            (let ((dark (plist-get (etaf-value (etaf-surface-theme surface)) :ui-bg)))
              (should (equal dark "#191a1c"))
              (should (equal dark
                             (etaf-md-tests--painted-background
                              buffer pos))))))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer)))
        (etaf-unmount runtime))
      (kill-buffer buffer))))

(ert-deftest etaf-md-tests-auto-theme-keeps-the-emacs-background ()
  "The default theme paints no page background; an explicit one does."
  (let* ((auto (etaf-md-create
                :text "plain text here\n" :theme 'auto))
         (explicit (etaf-md-create
                    :text "plain text here\n" :theme 'dark))
         (auto-buffer (etaf-md-tests--mount auto))
         (dark-buffer (etaf-md-tests--mount explicit)))
    (unwind-protect
        (progn
          (should-not (plist-get (etaf-md-state auto) :background))
          (should (eq (plist-get (etaf-md-state explicit) :background)
                      'palette))
          (with-current-buffer auto-buffer
            (should-not (etaf-md-tests--face-attribute
                         "plain" :background)))
          (with-current-buffer dark-buffer
            ;; The dark palette's page background, as shipped.
            (should (equal (etaf-md-tests--face-attribute
                            "plain" :background)
                           "#191a1c"))))
      (kill-buffer auto-buffer)
      (kill-buffer dark-buffer))))

(ert-deftest etaf-md-tests-auto-theme-derives-surfaces-from-faces ()
  "The auto theme blends panels from the active frame's own faces."
  (let* ((background (face-attribute 'default :background nil t))
         (foreground (face-attribute 'default :foreground nil t))
         (session (etaf-md-create :text "plain `code` here\n"))
         buffer
         dark-surface
         light-surface)
    (unwind-protect
        (progn
          (set-face-attribute 'default nil
                              :background "#101820" :foreground "#e0e0e0")
          (setq buffer (etaf-md-tests--mount session))
          (setq dark-surface
                (with-current-buffer buffer
                  (etaf-md-tests--face-attribute "code" :background)))
          (kill-buffer buffer)
          (setq buffer nil)
          (set-face-attribute 'default nil
                              :background "#fdf6e3" :foreground "#2b2b2b")
          (setq buffer (etaf-md-tests--mount session))
          (setq light-surface
                (with-current-buffer buffer
                  (etaf-md-tests--face-attribute "code" :background))))
      (when (buffer-live-p buffer) (kill-buffer buffer))
      (set-face-attribute 'default nil
                          :background background :foreground foreground))
    (should (stringp dark-surface))
    (should (stringp light-surface))
    ;; The surface follows the frame, not a fixed palette.
    (should-not (equal dark-surface light-surface))
    (should-not (equal dark-surface "#161b22"))
    (should-not (equal light-surface "#161b22"))))

(ert-deftest etaf-md-tests-custom-defaults-select-theme-flavor-and-bounds ()
  "The defcustoms choose the initial palette, dialect and measure bounds."
  (let ((etaf-md-theme 'sepia)
        (etaf-md-flavor 'commonmark)
        (etaf-md-width-min 30)
        (etaf-md-width-max 50))
    (let* ((session (etaf-md-create :text "~~strike~~\n"))
           (state (etaf-md-state session)))
      (should (eq (plist-get state :theme) 'sepia))
      (should (eq (plist-get state :background) 'palette))
      (should (eq (plist-get state :flavor) 'commonmark))
      (etaf-md-tests--with-mount session
        (should (string-match-p "~~strike~~"
                                (substring-no-properties (buffer-string)))))
      (should (= (etaf-md-adjust-width session -100) 30))
      (should (= (etaf-md-adjust-width session 100) 50)))))

(ert-deftest etaf-md-tests-locate-follows-the-outline ()
  "Locate moves point to the heading band and next/previous walk the outline."
  (let* ((session (etaf-md-create
                   :text "# Alpha\n\nbody\n\n## Beta\n\nmore\n\n### Gamma\n\nend\n"))
         (buffer (etaf-md-open session)))
    (unwind-protect
        (with-current-buffer buffer
          (should (etaf-md-locate session 1))
          (should (looking-at-p "Beta"))
          (etaf-md-next-heading)
          (should (looking-at-p "Gamma"))
          (etaf-md-previous-heading)
          (should (looking-at-p "Beta"))
          (should (etaf-md-locate session 0))
          (should (looking-at-p "Alpha")))
      (when (buffer-live-p buffer)
        (with-current-buffer buffer (etaf-md-close))))))

(ert-deftest etaf-md-tests-close-releases-and-reopens ()
  "Closing kills the buffer and the same session mounts again."
  (let* ((session (etaf-md-create :text "# Again\n"))
         (buffer (etaf-md-open session)))
    (with-current-buffer buffer
      (etaf-md-close))
    (should-not (buffer-live-p buffer))
    (let ((second (etaf-md-open session)))
      (unwind-protect
          (with-current-buffer second
            (should (string-match-p "Again" (substring-no-properties (buffer-string)))))
        (when (buffer-live-p second)
          (with-current-buffer second (etaf-md-close)))))))

(ert-deftest etaf-md-tests-flavor-commonmark-keeps-extensions-literal ()
  "The CommonMark flavor leaves GFM-only syntax as literal text."
  (let ((session (etaf-md-create
                  :flavor 'commonmark
                  :text (concat "~~strike~~ and https://example.com\n\n"
                                "| a | b |\n|:--|--:|\n| 1 | 2 |\n\n"
                                "- [ ] task\n\n> [!NOTE]\n> body\n\n"
                                "note[^f]\n"))))
    (etaf-md-tests--with-mount session
      (let ((text (substring-no-properties (buffer-string))))
        (should (string-match-p "~~strike~~" text))
        (should (string-match-p "| a | b |" text))
        (should (string-match-p "\\[ \\] task" text))
        (should (string-match-p "\\[!NOTE\\]" text))
        (should (string-match-p "\\[\\^f\\]" text))))))

(ert-deftest etaf-md-tests-flavor-gfm-converts-extensions ()
  "The GFM flavor converts the extensions the previewer defaults to."
  (let ((session (etaf-md-create
                  :flavor 'gfm
                  :text (concat "~~strike~~ see https://example.com\n\n"
                                "| a | b |\n|:--|--:|\n| 1 | 2 |\n\n"
                                "- [ ] task\n\n> [!TIP]\n> helper\n\n"
                                "note[^f]\n\n[^f]: def\n"))))
    (etaf-md-tests--with-mount session
      (let ((text (substring-no-properties (buffer-string))))
        (should-not (string-match-p "~~" text))
        (should (string-match-p "strike" text))
        (should (string-match-p "□ task" text))
        (should (string-match-p "提示" text))
        (should (string-match-p "\\[1\\]" text))
        (should (etaf-md-tests--keymap-at "https://example.com"))))))

(ert-deftest etaf-md-tests-flavor-rejects-unknown-name ()
  "An unknown dialect name is reported instead of guessed."
  (should-error (etaf-md-create :text "# x\n" :flavor 'markdown-extras)
                :type 'etaf-md-error))

(ert-deftest etaf-md-tests-front-matter-is-metadata ()
  "Front matter is stripped from the body and feeds the title."
  (let ((session (etaf-md-create
                  :text "---\ntitle: Meta Title\ntags: [a, b]\n---\n\n# Real Title\n")))
    (should (equal (plist-get (etaf-md-state session) :title) "Meta Title"))
    (etaf-md-tests--with-mount session
      (should-not (string-match-p "tags" (substring-no-properties (buffer-string)))))))

(ert-deftest etaf-md-tests-open-prompt-defaults-to-the-relative-file ()
  "`etaf-md-open' opens a visiting Markdown buffer directly in-place without prompting,
restores it on `etaf-md-close' without deleting the window, and prompts with a
relative default when given a prefix argument (`C-u')."
  (let ((dir (make-temp-file "etaf-md-prompt" t))
        (source nil)
        (prompted nil)
        (default nil))
    (unwind-protect
        (let ((file (expand-file-name "note.md" dir)))
          (with-temp-file file (insert "# Note\n\nHello.\n"))
          (setq source (find-file-noselect file))
          (delete-other-windows)
          (switch-to-buffer source)
          ;; 1. Without prefix arg in a visiting .md buffer: opens directly with zero prompt, single window.
          (cl-letf (((symbol-function 'read-file-name)
                     (lambda (&rest _)
                       (setq prompted t)
                       file)))
            (let ((current-prefix-arg nil))
              (call-interactively #'etaf-md-open)))
          (should-not prompted)
          (should (= 1 (length (window-list))))
          (should (string-prefix-p "*ETAF Markdown:" (buffer-name (current-buffer))))
          ;; Closing a single-window preview restores the originating source buffer without deleting the window.
          (etaf-md-close)
          (should (= 1 (length (window-list))))
          (should (eq (current-buffer) source))
          ;; 2. With prefix arg (C-u): prompts with relative default "note.md".
          (with-current-buffer source
            (setq default-directory (file-name-as-directory dir))
            (cl-letf (((symbol-function 'read-file-name)
                       (lambda (_prompt &optional _directory _predicate _mustmatch
                                preset &rest _)
                         (setq default preset)
                         file)))
              (let ((current-prefix-arg '(4)))
                (call-interactively #'etaf-md-open))))
          (should default)
          (should-not (file-name-absolute-p default))
          (should (equal "note.md" default)))
      (dolist (buffer (buffer-list))
        (when (string-prefix-p "*ETAF Markdown" (buffer-name buffer))
          (with-current-buffer buffer (ignore-errors (etaf-md-close)))))
      (when (buffer-live-p source) (kill-buffer source))
      (delete-directory dir t))))

(ert-deftest etaf-md-tests-help-stays-in-preview ()
  "Help is searchable in place and preserves the preview's reading state."
  (save-window-excursion
    (let* ((session (etaf-md-create :text "# Help acceptance\n\nKeep reading here.\n"))
           (buffer (etaf-md-open session))
           (runtime (etaf-runtime-for-buffer buffer)))
      (unwind-protect
          (with-current-buffer buffer
            (let ((windows (window-list))
                  (before (etaf-md-state session)))
              (dolist (key '("?"))
                (execute-kbd-macro (kbd key))
                (let* ((data (etaf-help-data runtime))
                       (entries (apply #'append (mapcar (lambda (group) (plist-get group :entries))
                                                        (plist-get data :groups))))
                       (reload (cl-find "重新加载文档" entries
                                        :key (lambda (entry) (plist-get entry :label))
                                        :test #'equal))
                       (same-runtime (eq runtime (etaf-runtime-for-buffer buffer))))
                  (should same-runtime)
                  (should (equal windows (window-list)))
                  (should (eq (window-buffer) buffer))
                  (should (equal (plist-get reload :label) "重新加载文档")))
                (execute-kbd-macro (kbd "/"))
                (execute-kbd-macro "?")
                (execute-kbd-macro (kbd "<escape>"))
                (let ((editing (etaf-text-input-active-p runtime)))
                  (should-not editing))
                (should (string-match-p "快捷键 · 只读"
                                        (buffer-substring-no-properties (point-min) (point-max))))
                (execute-kbd-macro (kbd "<escape>"))
                (let ((state (etaf-md-state session))
                      (text (buffer-substring-no-properties (point-min) (point-max))))
                  (should (equal state before))
                  (should (string-match-p "Help acceptance" text))))))
        (when (buffer-live-p buffer)
          (with-current-buffer buffer (etaf-md-close)))))))

;; The outline keys are root Host keys and sit on the `C-c' prefix: a page
;; that accepts typing cannot give a bare letter to navigation.
(ert-deftest etaf-md-tests-palette-paints-the-canvas ()
  "Choosing a palette paints unpainted cells with its page background."
  (let* ((session (etaf-md-create :text "# Canvas\n"))
         (buffer (etaf-md-open session))
         colors)
    (unwind-protect
        (with-current-buffer buffer
          (dolist (theme '(dark light sepia))
            (etaf-md-set-theme session theme)
            (etaf-runtime-flush (etaf-runtime-for-buffer buffer))
            (let ((painted (delete-dups
                            (mapcar (lambda (spec) (plist-get spec :background))
                                    (alist-get 'default face-remapping-alist)))))
              ;; The base remap and the root's own canvas agree on one color.
              (should (= (length painted) 1))
              (push (car painted) colors)))
          (should (cl-every #'stringp colors))
          (should (= (length (delete-dups colors)) 3)))
      (when (buffer-live-p buffer)
        (with-current-buffer buffer (etaf-md-close))))))

;;; ---------------------------------------------------------------------------
;;; Editing a block in place
;;; ---------------------------------------------------------------------------

(defmacro etaf-md-tests--with-preview-source (contents &rest body)
  "Visit a temporary markdown file holding CONTENTS and run BODY.
BODY runs with `file', `source' and `preview' bound; the preview buffer, the
visiting buffer and the file are removed afterwards."
  (declare (indent 1) (debug t))
  `(let* ((file (make-temp-file "etaf-md-edit-" nil ".md"))
          (source nil)
          (preview nil))
     (unwind-protect
         (progn
           (with-temp-file file (insert ,contents))
           (setq source (find-file-noselect file))
           (setq preview (etaf-md-open file))
           (with-current-buffer preview
             (etaf-runtime-flush (etaf-runtime-for-buffer preview)))
           ,@body)
       (when (buffer-live-p preview) (kill-buffer preview))
       (when (buffer-live-p source) (kill-buffer source))
       (delete-file file))))

(defun etaf-md-tests--goto-rendered (needle)
  "Move the point to the start of the rendered line holding NEEDLE."
  (goto-char (point-min))
  (unless (search-forward needle nil t)
    (error "Rendered text is missing %S" needle))
  (beginning-of-line))

(defun etaf-md-tests--page-rows (buffer)
  "Return BUFFER's painted rows, keeping every one of them.
The page repaints on the next frame, so the rows are read after a flush."
  (with-current-buffer buffer
    (etaf-runtime-flush (etaf-runtime-for-buffer buffer))
    (let ((rows nil))
      (goto-char (point-min))
      (while (not (eobp))
        (push (string-trim-right
               (buffer-substring-no-properties (line-beginning-position)
                                               (line-end-position)))
              rows)
        (forward-line 1))
      (nreverse rows))))

(defun etaf-md-tests--lines (buffer)
  "Return BUFFER's text without properties."
  (with-current-buffer buffer
    (buffer-substring-no-properties (point-min) (point-max))))


(ert-deftest etaf-md-tests-front-matter-labels-join-without-gaps ()
  "A key the front matter omits leaves no separator in the metadata line.
The line is one run of labels; printing a separator for a missing value shows
a row of floating dots between the labels a document did write."
  (let ((text (concat "---\ntitle: 手记\nauthor: 林隐\nstatus: 稳定\n---\n\n"
                      "正文。\n")))
    (let ((buffer (etaf-md-tests--mount
                   (etaf-md-create :text text :theme 'dark))))
      (unwind-protect
          (let ((page (etaf-md-tests--lines buffer)))
            (should (string-match-p "作者 林隐" page))
            (should (string-match-p "状态 稳定" page))
            (should (string-match-p (regexp-quote "作者 林隐  ·  状态 稳定") page))
            (should-not (string-match-p "·  ·" page)))
        (kill-buffer buffer)))))

(ert-deftest etaf-md-tests-front-matter-is-not-painted-as-blank-rows ()
  "Metadata at the head of the file does not open the page with empty rows.
Front matter is shown as the document's title and subtitle, not as lines, so
the rows the file spends on it must not be painted as blank ones."
  (let ((text (concat "---\ntitle: 手记\nauthor: 林隐\n---\n\n"
                      "# 一年运维手记\n\n正文。\n")))
    (let ((buffer (etaf-md-tests--mount
                   (etaf-md-create :text text :theme 'dark))))
      (unwind-protect
          (progn
            (etaf-runtime-flush (etaf-runtime-for-buffer buffer))
            (let* ((rows (etaf-md-tests--page-rows buffer))
                   (leading (cl-loop for row in rows
                                     while (string-empty-p row)
                                     count row)))
              (should (<= leading 2))
              (should-not (cl-some (lambda (row) (string-match-p "title:" row)) rows))))
        (kill-buffer buffer)))))

(ert-deftest etaf-md-tests-pictures-fall-back-to-their-source ()
  "Without the drawing program a diagram and a formula keep their source.
The page is readable as text: the fence paints as a code block, and the
formula paints the plain-text rendering, so nothing depends on a program."
  (let ((etaf-md-typeset nil)
        (text (concat "```mermaid\ngraph TD; A-->B\n```\n\n"
                      "$$\n\\frac{a}{b}\n$$\n")))
    (let ((buffer (etaf-md-tests--mount
                   (etaf-md-create :text text :theme 'dark))))
      (unwind-protect
          (let ((page (etaf-md-tests--lines buffer)))
            (should (string-match-p "graph TD; A-->B" page))
            (should (string-match-p "a/b" page)))
        (kill-buffer buffer)))))

(ert-deftest etaf-md-tests-a-metadata-line-keeps-the-blank-rows-around-it ()
  "A line the parser consumes without a block keeps its surrounding blank rows.
A link reference definition and an abbreviation definition paint nothing, but
the blank lines next to them are lines the page must still show; dropping them
pulled the next block up against the one before."
  (let ((text (concat "术语\n: 定义\n\n"
                      "*[HTML]: HyperText Markup Language\n\n"
                      "## 下一节\n\n正文。\n")))
    (let ((buffer (etaf-md-tests--mount
                   (etaf-md-create :text text :theme 'dark))))
      (unwind-protect
          (let* ((rows (etaf-md-tests--page-rows buffer))
                 (definition (cl-position-if (lambda (row) (string-match-p "定义" row)) rows))
                 (heading (cl-position-if (lambda (row) (string-match-p "下一节" row)) rows)))
            (should definition)
            (should heading)
            (should (< definition heading))
            ;; One blank row between them, and the abbreviation definition
            ;; itself never paints.
            (should (string-empty-p (nth (1+ definition) rows)))
            (should (nth (1+ definition) rows))
            (should-not (cl-some (lambda (row) (string-match-p "HyperText" row)) rows))
            (should (string-empty-p (nth (1- heading) rows))))
        (kill-buffer buffer)))))

(ert-deftest etaf-md-tests-a-thematic-break-paints-a-rule ()
  "A horizontal rule paints the rule, not the dashes that wrote it.
A rule carries no text, so judging it by its content would call it empty and
paint `---' where the page should open a gap in the prose."
  (etaf-md-tests--with-preview-source "above\n\n---\n\nbelow\n"
    (etaf-runtime-flush (etaf-runtime-for-buffer preview))
    (let ((lines (etaf-md-tests--lines preview)))
      (should (string-match-p "below" lines))
      ;; The rule itself is paint, not glyphs: what must not appear is the
      ;; source dashes standing in for it.
      (should-not (string-match-p "---" lines)))))

(ert-deftest etaf-md-tests-empty-block-paints-its-source-skeleton ()
  "A block whose text is gone paints the markup that is still in the source.
Without it the page shows a gap where the block sits, and the caret has nowhere
to stand, so an emptied heading or table could not be typed back."
  (etaf-md-tests--with-preview-source
      "# \n\nbody\n\n- \n\n> \n\n```elisp\n```\n\n|  |\n|---|\n|  |\n"
    (etaf-runtime-flush (etaf-runtime-for-buffer preview))
    (let ((lines (etaf-md-tests--lines preview)))
      (should (string-match-p "^ *# *$" lines))
      (should (string-match-p "•" lines))
      (should (string-match-p "^ *> *$" lines))
      (should (string-match-p "```elisp" lines))
      (should (string-match-p "|-----|" lines))
      (should (string-match-p "body" lines)))))

(ert-deftest etaf-md-tests-empty-block-does-not-hide-a-full-table ()
  "A table that still holds text paints its cells, not its skeleton.
The empty test has to read the cells the renderer was given; a table judged by
a session text that is not published yet would paint a skeleton over its data."
  (etaf-md-tests--with-preview-source
      "| 名称 | 数量 |\n|---|---|\n| 磁盘 | 10 |\n"
    (etaf-runtime-flush (etaf-runtime-for-buffer preview))
    (let ((lines (etaf-md-tests--lines preview)))
      (should (string-match-p "名称" lines))
      (should (string-match-p "磁盘" lines))
      (should-not (string-match-p "|-----|" lines)))))

(provide 'etaf-md-tests)
;;; etaf-md-tests.el ends here

;;; ---------------------------------------------------------------------------
;;; Node definitions
;;; ---------------------------------------------------------------------------

(ert-deftest etaf-md-tests-a-definition-declares-both-attribute-tables ()
  (unwind-protect
      (progn
        (etaf-md-define-node 'probe
          :name "probe"
          :summary "A probe type"
          :attrs '((title  :type string  :required t :pattern "\\S")
                   (width  :type length)
                   (accent :type accent  :default neutral))
          :derived '((level :type number :min 1 :max 6 :integer t))
          :view (lambda (_env) nil))
        (should (equal '(level) (etaf-md-derived-attributes 'probe)))
        (let ((text (etaf-md-describe-nodes 'probe)))
          (should (string-match-p "probe" text))
          (should (string-match-p "文档写法 :::probe" text))
          (should (string-match-p "derived   level" text))
          (should (string-match-p "ordinary  title  width  accent" text))))
    (etaf-md-undefine-node 'probe)))

(ert-deftest etaf-md-tests-a-second-definition-needs-extends-or-replace ()
  (unwind-protect
      (progn
        (etaf-md-define-node 'probe :attrs '((title :type string)) :view #'ignore)
        (should-error (etaf-md-define-node 'probe :attrs '((title :type string)))
                      :type 'etaf-md-error)
        (etaf-md-define-node 'probe :extends t
          :attrs '((accent :type accent :default neutral)))
        (should (string-match-p "ordinary  title  accent"
                                (etaf-md-describe-nodes 'probe))))
    (etaf-md-undefine-node 'probe)))

(ert-deftest etaf-md-tests-extends-refuses-a-second-declaration-of-one-name ()
  (unwind-protect
      (progn
        (etaf-md-define-node 'probe :attrs '((title :type string)) :view #'ignore)
        (should-error (etaf-md-define-node 'probe :extends t
                        :attrs '((title :type string)))
                      :type 'etaf-md-error))
    (etaf-md-undefine-node 'probe)))

(ert-deftest etaf-md-tests-a-declaration-must-be-usable ()
  (should-error (etaf-md-define-node 'probe
                  :attrs '((kind :type enum)) :view #'ignore)
                :type 'etaf-md-error)
  (should-error (etaf-md-define-node 'probe
                  :derived '((level :type number :default 1)) :view #'ignore)
                :type 'etaf-md-error)
  (should-error (etaf-md-define-node 'probe
                  :attrs '((title :type string :required t :default "x"))
                  :view #'ignore)
                :type 'etaf-md-error)
  (should-error (etaf-md-define-node 'probe
                  :attrs '((width :type length :pattern "x")) :view #'ignore)
                :type 'etaf-md-error))

(ert-deftest etaf-md-tests-a-rule-set-is-replaced-per-selector ()
  (unwind-protect
      (progn
        (etaf-md-set-attr '(probe) '((:width "2ch")))
        (etaf-md-set-attr '(probe) '((:width "4ch")))
        (should (= 1 (length etaf-md-styles)))
        (etaf-md-set-attr '(probe) nil)
        (should (null etaf-md-styles)))
    (etaf-md-set-attr '(probe) nil)))

;;; ---------------------------------------------------------------------------
;;; Container syntax and node definitions
;;; ---------------------------------------------------------------------------

(ert-deftest etaf-md-tests-a-container-is-painted-by-its-definition ()
  (etaf-md-tests--with-preview-source
      ":::card {title=\"缓存命中\" accent=warning}\n正文一段。\n:::\n\n\
:::columns {columns=2}\n:::col\n左栏。\n:::\n:::col\n右栏。\n:::\n:::\n"
    (with-current-buffer preview
      (etaf-runtime-flush (etaf-runtime-for-buffer preview))
      (should (string-match-p "缓存命中" (buffer-string)))
      (should (string-match-p "正文一段" (buffer-string)))
      (should (string-match-p "左栏" (buffer-string)))
      (should (string-match-p "右栏" (buffer-string)))
      (should-not (string-match-p "没有" (buffer-string))))))

(ert-deftest etaf-md-tests-a-container-with-no-definition-keeps-its-source ()
  (etaf-md-tests--with-preview-source
      ":::nope {title=\"不存在\"}\n这一段原样出现。\n:::\n"
    (with-current-buffer preview
      (etaf-runtime-flush (etaf-runtime-for-buffer preview))
      (should (string-match-p "这一段原样出现" (buffer-string)))
      (should (string-match-p "没有 nope 的定义" (buffer-string))))))

(ert-deftest etaf-md-tests-a-user-definition-replaces-a-shipped-one ()
  (unwind-protect
      (progn
        (etaf-md-define-node 'card :replace t
          :name "card"
          :attrs '((title :type string :required t))
          :view (lambda (env)
                  (etaf-view
                   (text (expr (concat "替换：" (etaf-md-attr env :title)))))))
        (etaf-md-tests--with-preview-source
            ":::card {title=\"缓存命中\"}\n正文。\n:::\n"
          (with-current-buffer preview
            (etaf-runtime-flush (etaf-runtime-for-buffer preview))
            (should (string-match-p "替换：缓存命中" (buffer-string)))
            (should-not (string-match-p "正文。" (buffer-string))))))
    (etaf-md-undefine-node 'card)))

(ert-deftest etaf-md-tests-a-block-that-breaks-its-declaration-shows-a-line ()
  (etaf-md-tests--with-preview-source
      ":::card {description=\"没有标题\"}\n正文。\n:::\n"
    (with-current-buffer preview
      (etaf-runtime-flush (etaf-runtime-for-buffer preview))
      (should (string-match-p "title is required" (buffer-string)))
      (should (string-match-p ":::card" (buffer-string))))))

;;; ---------------------------------------------------------------------------
;;; The definition API on its own
;;; ---------------------------------------------------------------------------

(defun etaf-md-tests--probe-view (env)
  "Paint ENV's :value so a test can read what resolution produced."
  (etaf-view (text (expr (format "%s" (etaf-md-attr env :value))))))

(ert-deftest etaf-md-tests-value-order-ends-at-the-shipped-default ()
  (unwind-protect
      (progn
        (etaf-md-define-node 'probe
          :name "probe"
          :attrs '((value :type string :default "base"))
          :view #'etaf-md-tests--probe-view)
        (etaf-md-set-attr '(probe) '((:value :default)))
        (etaf-md-tests--with-preview-source ":::probe {value=doc}\n:::\n"
          (with-current-buffer preview
            (etaf-runtime-flush (etaf-runtime-for-buffer preview))
            (should (string-match-p "base" (buffer-string))))))
    (etaf-md-undefine-node 'probe)))

(ert-deftest etaf-md-tests-a-rule-that-names-no-attribute-is-reported ()
  (unwind-protect
      (progn
        (etaf-md-define-node 'probe
          :name "probe"
          :attrs '((value :type string :default "base"))
          :view #'etaf-md-tests--probe-view)
        (etaf-md-set-attr '(probe) '((:nope 1)))
        (etaf-md-tests--with-preview-source ":::probe\n:::\n"
          (with-current-buffer preview
            (etaf-runtime-flush (etaf-runtime-for-buffer preview))
            (should (string-match-p "nope is not an attribute of probe"
                                    (buffer-string))))))
    (etaf-md-undefine-node 'probe)))


(ert-deftest etaf-md-tests-tabs-draw-only-the-selected-page ()
  (etaf-md-tests--with-preview-source
      ":::tabs\n@tab 第一页\n第一页正文。\n@tab 第二页\n第二页正文。\n:::\n"
    (with-current-buffer preview
      (etaf-runtime-flush (etaf-runtime-for-buffer preview))
      (should (string-match-p "第一页" (buffer-string)))
      (should (string-match-p "第二页" (buffer-string)))
      (should (string-match-p "第一页正文" (buffer-string)))
      (should-not (string-match-p "第二页正文" (buffer-string)))
      (should-not (string-match-p "没有" (buffer-string))))))

(ert-deftest etaf-md-tests-the-site-components-paint ()
  "The site components paint their parts into one page.
Every container's own text, the inline marks' text and an image card's
caption all reach the buffer, so a page using the whole catalog renders
through the same mount as a plain document."
  (let ((session (etaf-md-create
                  :text (concat
                         "==高亮=={.warning}\n\n"
                         ":::home-box {title=\"首屏标题\" description=\"首屏摘要\"}\n"
                         "首屏正文。\n:::\n\n"
                         ":::link-card {href=\"https://etaf.top/\" title=\"链接标题\""
                         " description=\"链接说明\"}\n:::\n\n"
                         ":::npm-badge {name=\"etaf-md\" version=\"0.1.0\"}\n:::\n\n"
                         ":::swiper\n@slide {title=\"第一张\"}\n第一页正文。\n:::\n\n"
                         ":::code-tree {title=\"源码\"}\n@file demo.el\n```elisp\n(require 'etaf-md)\n```\n:::\n\n"
                         ":::npm-to {tabs=\"npm,pnpm\"}\n```sh\nnpm install foo\n```\n:::\n")
                  :theme 'dark)))
    (etaf-md-tests--with-mount session
      (switch-to-buffer (current-buffer))
      (etaf-runtime-flush (etaf-runtime-for-buffer (current-buffer)))
      (let ((text (buffer-string)))
        (should (string-match-p "高亮" text))
        (should (string-match-p "首屏标题" text))
        (should (string-match-p "链接说明" text))
        (should (string-match-p "etaf-md" text))
        (should (string-match-p "第一页正文" text))
        (should (string-match-p "demo.el" text))
        (should (string-match-p "npm install foo" text))))))

(ert-deftest etaf-md-tests-a-command-card-follows-its-attribute ()
  "A command card names the managers its attribute lists.
The list is input syntax, not content: only the named managers appear, and
the code below keeps the command it rewrote."
  (let ((session (etaf-md-create
                  :text (concat
                         ":::npm-to {tabs=\"npm, yarn\"}\n```sh\nnpm run build\n```\n:::\n")
                  :theme 'dark)))
    (etaf-md-tests--with-mount session
      (let ((text (buffer-string)))
        (should (string-match-p "yarn" text))
        (should (string-match-p "npm run build" text))
        (should-not (string-match-p "\\tabs" text))))))

(ert-deftest etaf-md-tests-a-card-grid-lays-cards-side-by-side ()
  "Two equal columns put two card titles on the same row.
The grid is `columns` with card children, so a row of the painted page
carries both titles and each card keeps its own body."
  (let ((session (etaf-md-create
                  :text (concat ":::columns {columns=2}\n"
                                ":::col\n:::card {title=\"卡片甲\"}\n左栏正文。\n:::\n:::\n"
                                ":::col\n:::card {title=\"卡片乙\"}\n右栏正文。\n:::\n:::\n"
                                ":::\n")
                  :theme 'dark)))
    (etaf-md-tests--with-mount session
      (switch-to-buffer (current-buffer))
      (etaf-runtime-flush (etaf-runtime-for-buffer (current-buffer)))
      (let ((text (buffer-string)))
        (should (string-match-p "卡片甲" text))
        (should (string-match-p "卡片乙" text))
        (should (string-match-p "卡片甲.*卡片乙" text))
        (should (string-match-p "左栏正文" text))
        (should (string-match-p "右栏正文" text))))))

(ert-deftest etaf-md-tests-folds-details-and-alignment-paint ()
  "The catalog's later containers paint their own text.
The eight callout names share one view, a details block starts closed and
opens when its attribute says so, an alignment container paints its body,
and the window's spacing attributes do not break its content."
  (let ((session (etaf-md-create
                  :text (concat
                         ":::info\n信息正文。\n:::\n\n"
                         ":::danger\n危险正文。\n:::\n\n"
                         ":::details {title=\"收起的详情\"}\n详情正文。\n:::\n\n"
                         ":::details {title=\"展开的详情\" open=true}\n展开的正文。\n:::\n\n"
                         ":::center\n居中正文。\n:::\n\n"
                         ":::right\n靠右正文。\n:::\n\n"
                         ":::window {title=\"示例窗口\" gap=\"1lh\" height=\"3lh\" no-padding=true}\n窗口正文。\n:::\n")
                  :theme 'dark)))
    (etaf-md-tests--with-mount session
      (switch-to-buffer (current-buffer))
      (etaf-runtime-flush (etaf-runtime-for-buffer (current-buffer)))
      (let ((text (buffer-string)))
        (should (string-match-p "Info" text))
        (should (string-match-p "Danger" text))
        (should (string-match-p "信息正文" text))
        (should (string-match-p "危险正文" text))
        (should (string-match-p "收起的详情" text))
        (should-not (string-match-p "详情正文" text))
        (should (string-match-p "展开的正文" text))
        (should (string-match-p "居中正文" text))
        (should (string-match-p "靠右正文" text))
        (should (string-match-p "示例窗口" text))
        (should (string-match-p "窗口正文" text))))))

(ert-deftest etaf-md-tests-a-child-boolean-set-to-false-is-off ()
  "A collapse written `open=false' starts closed.
The attribute belongs to the container's `:accepts', so its type is read
there; a raw string would open the section instead."
  (let ((session (etaf-md-create
                  :text (concat ":::accordion\n"
                                ":::collapse {title=\"甲\" open=false}\n隐藏正文。\n:::\n"
                                ":::collapse {title=\"乙\" open=true}\n可见正文。\n:::\n"
                                ":::\n")
                  :theme 'dark)))
    (etaf-md-tests--with-mount session
      (switch-to-buffer (current-buffer))
      (etaf-runtime-flush (etaf-runtime-for-buffer (current-buffer)))
      (let ((text (buffer-string)))
        (should (string-match-p "可见正文" text))
        (should-not (string-match-p "隐藏正文" text))))))

(ert-deftest etaf-md-tests-an-attribute-field-paints-its-metadata ()
  "A field written with its attributes paints every part of the card.
The name, the three state chips, the type, the default and since values, the
extra notes and the body all reach the page, and the list form still paints
its name and value rows."
  (let ((session (etaf-md-create
                  :text (concat
                         ":::field {name=\"text\" type=\"string\" default=\"空字符串\" required=true"
                         " since=\"0.1\" enum=\"a | b\" unit=\"列\" format=\"整数\""
                         " constraint=\"x > 0\" deprecated=\"0.2\" experimental=\"1.0\"}\n"
                         "字段正文。\n:::\n\n"
                         ":::field\n- 版本：12.3.0\n- 缓存：cache\n:::\n")
                  :theme 'dark)))
    (etaf-md-tests--with-mount session
      (switch-to-buffer (current-buffer))
      (etaf-runtime-flush (etaf-runtime-for-buffer (current-buffer)))
      (let ((text (buffer-string)))
        (should (string-match-p "text" text))
        (should (string-match-p "必填" text))
        (should (string-match-p "已弃用 0.2" text))
        (should (string-match-p "实验性 1.0" text))
        (should (string-match-p "string" text))
        (should (string-match-p "默认" text))
        (should (string-match-p "自 0.1" text))
        (should (string-match-p "可选值 a / b" text))
        (should (string-match-p "单位 列" text))
        (should (string-match-p "格式 整数" text))
        (should (string-match-p "约束 x > 0" text))
        (should (string-match-p "字段正文" text))
        (should (string-match-p "版本" text))
        (should (string-match-p "12.3.0" text))))))

(ert-deftest etaf-md-tests-a-panel-carries-its-title-on-the-edge ()
  "A panel paints its title, its status and its body from one container."
  (let ((session (etaf-md-create
                  :text (mapconcat #'identity
                                   '(":::panel {title=\"读取设置\" status=\"12.3.0\"}"
                                     "面板把标题与状态画在顶边上。"
                                     ":::")
                                   "\n")
                  :theme 'dark)))
    (etaf-md-tests--with-mount session
      (etaf-runtime-flush (etaf-runtime-for-buffer (current-buffer)))
      (let ((text (buffer-string)))
        (should (string-match-p "读取设置" text))
        (should (string-match-p "12.3.0" text))
        (should (string-match-p "标题与状态" text))))))

(ert-deftest etaf-md-tests-a-tab-panel-shows-one-page ()
  "A tab panel keeps its frame and swaps only the body of the chosen tab."
  (let ((session (etaf-md-create
                  :text (mapconcat #'identity
                                   '(":::tab-panel"
                                     "@tab 概览"
                                     "第一页的正文。"
                                     "@tab {title=\"配置\" selected=true}"
                                     "第二页的正文。"
                                     ":::")
                                   "\n")
                  :theme 'dark)))
    (etaf-md-tests--with-mount session
      (etaf-runtime-flush (etaf-runtime-for-buffer (current-buffer)))
      (let ((text (buffer-string)))
        (should (string-match-p "概览" text))
        (should (string-match-p "配置" text))
        (should (string-match-p "第二页的正文" text))
        (should-not (string-match-p "第一页的正文" text))))))

(ert-deftest etaf-md-tests-a-form-lines-up-labels-and-values ()
  "A form paints each row's label above its value."
  (let ((session (etaf-md-create
                  :text (mapconcat #'identity
                                   '(":::form"
                                     "- 仓库地址：github.com/emacs-taf"
                                     "- 渲染器：Ebox"
                                     ":::")
                                   "\n")
                  :theme 'dark)))
    (etaf-md-tests--with-mount session
      (etaf-runtime-flush (etaf-runtime-for-buffer (current-buffer)))
      (let ((text (buffer-string)))
        (should (string-match-p "仓库地址" text))
        (should (string-match-p "github.com/emacs-taf" text))
        (should (string-match-p "渲染器" text))
        (should (string-match-p "Ebox" text))))))

(ert-deftest etaf-md-tests-a-chat-groups-its-marked-messages ()
  "A chat groups its blocks by sender markers and hides the markers.
Plume writes a sender as `{name}', the reader as `{.}' and a date as
`{:date}'; the reader sees the name, the date and the words, not the braces."
  (let ((session (etaf-md-create
                  :text (concat ":::chat
"
                                "{:2026-11-14 14:20}\n\n"
                                "{问}\n"
                                "预览为什么不刷新？\n\n"
                                "{.}\n"
                                "保存之后才刷新。\n"
                                ":::\n")
                  :theme 'dark)))
    (etaf-md-tests--with-mount session
      (etaf-runtime-flush (etaf-runtime-for-buffer (current-buffer)))
      (let ((text (buffer-string)))
        (should (string-match-p "2026-11-14 14:20" text))
        (should (string-match-p "问" text))
        (should (string-match-p "预览为什么不刷新？" text))
        (should (string-match-p "保存之后才刷新。" text))
        (should-not (string-match-p "{\\." text))))))

(ert-deftest etaf-md-tests-a-steps-list-becomes-numbered-steps ()
  "A steps container written as an ordered list keeps every item's text."
  (let ((session (etaf-md-create
                  :text (concat ":::steps
"
                                "1. 先抓栈，别先猜
"
                                "2. 改产生现象的那一层
"
                                ":::
")
                  :theme 'dark)))
    (etaf-md-tests--with-mount session
      (etaf-runtime-flush (etaf-runtime-for-buffer (current-buffer)))
      (let ((text (buffer-string)))
        (should (string-match-p "先抓栈，别先猜" text))
        (should (string-match-p "改产生现象的那一层" text))))))

(ert-deftest etaf-md-tests-a-timeline-event-shows-its-status ()
  "A timeline event with `status' paints that state as a badge."
  (let ((session (etaf-md-create
                  :text (concat ":::timeline
"
                                ":::event {title=\"定位\" status=\"success\" time=\"今天\"}
"
                                "改好了。
"
                                ":::
"
                                ":::
")
                  :theme 'dark)))
    (etaf-md-tests--with-mount session
      (etaf-runtime-flush (etaf-runtime-for-buffer (current-buffer)))
      (let ((text (buffer-string)))
        (should (string-match-p "定位" text))
        (should (string-match-p "成功" text))
        (should (string-match-p "今天" text))))))

(ert-deftest etaf-md-tests-a-table-copies-itself-when-asked ()
  "A table written `copy=true' offers a line that copies it as TSV.
The table keeps its cells and the copy line puts the header and the rows on
the kill ring as tab separated text, which is what a spreadsheet pastes."
  (let ((session (etaf-md-create
                  :text (concat ":::table {title=\"耗时\" copy=true}\n"
                                "| 版本 | 耗时 |\n"
                                "| --- | --- |\n"
                                "| 0.1.9 | 5.4 s |\n"
                                "| 0.2.0 | 0.33 s |\n"
                                ":::\n")
                  :theme 'dark)))
    (etaf-md-tests--with-mount session
      (switch-to-buffer (current-buffer))
      (etaf-runtime-flush (etaf-runtime-for-buffer (current-buffer)))
      (let ((text (buffer-string)))
        (should (string-match-p "复制表格" text))
        (should (string-match-p "0.33 s" text)))
      (execute-kbd-macro (kbd "TAB"))
      (execute-kbd-macro (kbd "RET"))
      (should (equal (current-kill 0)
                     (concat "版本\t耗时\n"
                             "0.1.9\t5.4 s\n"
                             "0.2.0\t0.33 s"))))))

(ert-deftest etaf-md-tests-tab-keys-open-the-next-page ()
  "TAB enters the strip, Right moves focus, RET opens the page."
  (let ((session (etaf-md-create
                  :text ":::tabs\n@tab 第一页\n第一页正文。\n@tab 第二页\n第二页正文。\n:::\n"
                  :theme 'dark)))
    (etaf-md-tests--with-mount session
      (switch-to-buffer (current-buffer))
      (etaf-runtime-flush (etaf-runtime-for-buffer (current-buffer)))
      (execute-kbd-macro (kbd "TAB"))
      (execute-kbd-macro (kbd "<right>"))
      (execute-kbd-macro (kbd "RET"))
      (etaf-runtime-flush (etaf-runtime-for-buffer (current-buffer)))
      (should (string-match-p "第二页正文" (buffer-string)))
      (should-not (string-match-p "第一页正文" (buffer-string))))))

(ert-deftest etaf-md-tests-a-marker-attribute-selects-a-page ()
  (etaf-md-tests--with-preview-source
      ":::tabs\n@tab 第一页\n第一页正文。\n\
@tab {title=\"第二页\" selected=true}\n第二页正文。\n:::\n"
    (with-current-buffer preview
      (etaf-runtime-flush (etaf-runtime-for-buffer preview))
      (should-not (string-match-p "第一页正文" (buffer-string)))
      (should (string-match-p "第二页正文" (buffer-string))))))

(ert-deftest etaf-md-tests-a-tab-body-keeps-a-marker-inside-a-fence ()
  (let ((session (etaf-md-create
                  :text ":::tabs\n@tab 只有一页\n```\n@tab 不是标记\n```\n:::\n"
                  :theme 'dark)))
    (etaf-md-tests--with-mount session
      (should (string-match-p "@tab 不是标记" (buffer-string)))
      (should-not (string-match-p "没有" (buffer-string))))))

(ert-deftest etaf-md-tests-a-tab-body-can-hold-a-block-container ()
  (let ((session (etaf-md-create
                  :text ":::tabs\n@tab 一\n:::note\n提示正文。\n:::\n:::\n"
                  :theme 'dark)))
    (etaf-md-tests--with-mount session
      (should (string-match-p "提示正文" (buffer-string)))
      (should (string-match-p "Note" (buffer-string)))
      (should-not (string-match-p "没有" (buffer-string))))))

(ert-deftest etaf-md-tests-a-marker-container-rejects-a-block-child ()
  (should-error
   (etaf-md-create
    :text ":::tabs\n:::tab {title=\"一\"}\n正文。\n:::\n:::\n")
   :type 'etaf-md-error))

(ert-deftest etaf-md-tests-prose-before-the-first-marker-is-an-error ()
  (should-error
   (etaf-md-create
    :text ":::tabs\n先说话。\n@tab 一\n正文。\n:::\n")
   :type 'etaf-md-error))

(ert-deftest etaf-md-tests-markers-mean-nothing-in-a-block-container ()
  (let ((session (etaf-md-create
                  :text ":::note\n@tab 只是文字\n:::\n"
                  :theme 'dark)))
    (etaf-md-tests--with-mount session
      (should (string-match-p "@tab 只是文字" (buffer-string))))))

(ert-deftest etaf-md-tests-a-fenced-sample-cannot-open-a-container ()
  "A `:::' inside a code fence is the sample's text, not a container edge."
  (let ((session (etaf-md-create
                  :text (concat ":::note\n提示正文。\n:::\n\n"
                                "```markdown\n"
                                ":::card {title=\"这是代码\"}\n"
                                ":::\n"
                                "```\n")
                  :theme 'dark)))
    (etaf-md-tests--with-mount session
      (should (string-match-p "提示正文" (buffer-string)))
      (should (string-match-p ":::card {title=\"这是代码\"}" (buffer-string)))
      (should (string-match-p "Note" (buffer-string)))
      (should-not (string-match-p "没有" (buffer-string))))))

(ert-deftest etaf-md-tests-a-fence-inside-a-container-does-not-close-it ()
  "A fence in a container body keeps its `:::' and the container its close."
  (let ((session (etaf-md-create
                  :text (concat ":::note\n"
                                "```markdown\n"
                                ":::\n"
                                "```\n"
                                ":::\n")
                  :theme 'dark)))
    (etaf-md-tests--with-mount session
      (should (string-match-p "Note" (buffer-string)))
      (should (string-match-p ":::" (buffer-string)))
      (should-not (string-match-p "没有" (buffer-string))))))

(ert-deftest etaf-md-tests-a-definition-declares-its-child-syntax ()
  (unwind-protect
      (progn
        (etaf-md-define-node 'marker-probe
          :name "marker-probe"
          :accepts '((item :attrs ((title :type string :required t))))
          :child-syntax 'markers
          :view (lambda (env)
                  (etaf-view
                   (text (expr (number-to-string
                                (length (etaf-md-children env))))))))
        (let ((session (etaf-md-create
                        :text ":::marker-probe\n@item 甲\n正文甲。\n@item 乙\n正文乙。\n:::\n"
                        :theme 'dark)))
          (etaf-md-tests--with-mount session
            (should (string-match-p "2" (buffer-string)))))
        ;; An extension keeps the grammar it did not restate.
        (etaf-md-define-node 'marker-probe :extends t :summary "still markers")
        (let ((session (etaf-md-create
                        :text ":::marker-probe\n@item 甲\n正文甲。\n:::\n"
                        :theme 'dark)))
          (etaf-md-tests--with-mount session
            (should (string-match-p "1" (buffer-string)))))
        (should-error
         (etaf-md-create
          :text ":::marker-probe\n:::item {title=\"甲\"}\n正文。\n:::\n:::\n")
         :type 'etaf-md-error))
    (etaf-md-undefine-node 'marker-probe)))

(ert-deftest etaf-md-tests-a-fence-keeps-its-body-and-a-heading-its-text ()
  "A fence paints its code and a heading paints its words.
Both keep their content in the block's own fields, and a walk that asked the
inline children of a block read nothing there: the page showed the fence line
alone and the heading's marker alone."
  (etaf-md-tests--with-preview-source
      "# 标题文字\n\n```elisp\n(+ 1 2)\n```\n"
    (with-current-buffer preview
      (should (string-match-p "标题文字" (buffer-string)))
      (should (string-match-p (regexp-quote "(+ 1 2)") (buffer-string)))
      (should-not (string-match-p "```elisp" (buffer-string))))))

(ert-deftest etaf-md-tests-code-tabs-name-pages-by-fence-language ()
  (etaf-md-tests--with-preview-source
      ":::code-tabs\n@tab\n```elisp\n(open)\n```\n\
@tab\n```python\nprint(1)\n```\n:::\n"
    (with-current-buffer preview
      (etaf-runtime-flush (etaf-runtime-for-buffer preview))
      (should (string-match-p "elisp" (buffer-string)))
      (should (string-match-p "python" (buffer-string)))
      (should (string-match-p "(open)" (buffer-string)))
      (should-not (string-match-p "print(1)" (buffer-string))))))

;;;; Opening what a link names

(ert-deftest etaf-md-tests-doctor-names-each-optional-program ()
  "Every program a block may need is reported with a remedy.
A reader whose diagram or code block kept its source text asks `doctor' why,
so a program the page can use but never names is a blind spot."
  (let ((optional (plist-get (etaf-md-doctor) :optional)))
    (should (equal (mapcar #'car optional)
                   '("typeset-native" "ffmpeg" "qrencode" "git")))
    (dolist (entry optional)
      (should (= 3 (length entry)))
      (should (stringp (nth 2 entry))))))

(ert-deftest etaf-md-tests-a-mailto-link-goes-to-the-browser ()
  "A link with a scheme is handed to the browser, not read as a file name.
`mailto:' carries no `//', so a test for one treated it as a relative path and
the preview reported a file that did not exist."
  (let ((session (etaf-md-create :text "[写信](mailto:someone@example.com)\n")))
    (etaf-md-tests--with-mount session
      (goto-char (point-min))
      (should (search-forward "写信" nil t))
      (goto-char (match-beginning 0))
      (let ((opened nil))
        (cl-letf (((symbol-function 'browse-url)
                   (lambda (url &rest _) (push url opened))))
          (call-interactively (key-binding (kbd "RET"))))
        (should (equal opened '("mailto:someone@example.com")))))))

(ert-deftest etaf-md-tests-a-link-to-a-document-opens-its-preview ()
  "A relative link to a markdown file opens that document as a preview.
The reader follows a link inside a page, so landing in the file's raw source
would lose the rendering the link was written for; a fragment names the
heading to start at."
  (let* ((dir (make-temp-file "etaf-md-doc-link" t))
         (other (expand-file-name "other.md" dir))
         (source (expand-file-name "source.md" dir)))
    (unwind-protect
        (progn
          (with-temp-file other
            (insert "# 第一节\n\n正文\n\n## 第二节\n\n内容\n"))
          (with-temp-file source
            (insert "[别的文档](other.md#第二节)\n"))
          (let ((session (etaf-md-create :file source)))
            (etaf-md-tests--with-mount session
              (goto-char (point-min))
              (should (search-forward "别的文档" nil t))
              (goto-char (match-beginning 0))
              (call-interactively (key-binding (kbd "RET")))
              ;; The heading is applied once the new page has been painted,
              ;; which this preview reaches after the command returns.
              (sit-for 0.1)
              (let ((preview (get-buffer "*ETAF Markdown: other.md*")))
                (unwind-protect
                    (progn
                      (should preview)
                      (with-current-buffer preview
                        (should (etaf-app-state))
                        (should (string-match-p
                                 "第二节"
                                 (buffer-substring-no-properties
                                  (line-beginning-position) (line-end-position))))))
                  (when (buffer-live-p preview) (kill-buffer preview)))))))
      (delete-directory dir t))))

;;;; Containers, line grid, activation callbacks, tables and columns

(ert-deftest etaf-md-tests-container-outline-keeps-document-order-and-locate ()
  "Headings before, inside and after containers appear in order with unique ids.
Locate and `#anchor' links land on the matching heading, including headings
painted inside bordered containers."
  (let* ((text (concat "# Before\n\n"
                       "[Jump inside](#inside) "
                       "[Jump column](#right-col) "
                       "[Jump repeat](#same-2)\n\n"
                       "## Same\n\n"
                       ":::card {title=\"x\"}\n"
                       "## Inside\n"
                       "content\n\n"
                       "### Same\n"
                       ":::\n\n"
                       ":::columns {columns=\"1fr 1fr\"}\n"
                       ":::col\n## Left Col\n:::\n"
                       ":::col\n## Right Col\n:::\n"
                       ":::\n\n"
                       "## After\n"
                       "more\n"))
         (session (etaf-md-create :text text :theme 'dark))
         (outline (etaf-md-outline session))
         (titles (mapcar #'cadr outline))
         (ids (mapcar #'cl-caddr outline)))
    (should (equal titles '("Before" "Same" "Inside" "Same"
                            "Left Col" "Right Col" "After")))
    (should (equal ids '("before" "same" "inside" "same-2"
                         "left-col" "right-col" "after")))
    (let ((buffer (etaf-md-open session)))
      (unwind-protect
          (with-current-buffer buffer
            (let ((pos-before (etaf-md-locate session 0)))
              (should pos-before)
              (should (looking-at-p "Before")))
            (let ((pos-inside (etaf-md-locate session 2)))
              (should pos-inside)
              (should (looking-at-p "Inside")))
            (let ((pos-right (etaf-md-locate session 5)))
              (should pos-right)
              (should (looking-at-p "Right Col")))
            (let ((pos-after (etaf-md-locate session 6)))
              (should pos-after)
              (should (looking-at-p "After")))
            ;; Follow `#inside' link to jump into the container heading.
            (goto-char (point-min))
            (should (search-forward "Jump inside" nil t))
            (goto-char (match-beginning 0))
            (call-interactively (key-binding (kbd "RET")))
            (should (looking-at-p "Inside"))
            ;; Follow `#right-col' link to jump into the second column heading.
            (goto-char (point-min))
            (should (search-forward "Jump column" nil t))
            (goto-char (match-beginning 0))
            (call-interactively (key-binding (kbd "RET")))
            (should (looking-at-p "Right Col"))
            ;; Follow `#same-2' link to jump to the deduplicated heading.
            (goto-char (point-min))
            (should (search-forward "Jump repeat" nil t))
            (goto-char (match-beginning 0))
            (call-interactively (key-binding (kbd "RET")))
            (should (looking-at-p "Same"))
            (should (> (point) (etaf-md-locate session 2))))
        (when (buffer-live-p buffer)
          (with-current-buffer buffer (etaf-md-close)))))))

(ert-deftest etaf-md-tests-container-footnotes-resolve-across-boundaries ()
  "Footnote references outside and inside containers resolve in document order.
Definitions written either outside or inside containers collect into the
document footnote list and paint at the end of the page."
  (let* ((text (concat "Before[^a].\n\n"
                       ":::card {title=\"x\"}\n"
                       "Inside[^b] and local[^c].\n\n"
                       "[^c]: 容器内脚注\n"
                       ":::\n\n"
                       "After[^d].\n\n"
                       "[^a]: 外部前脚注\n\n"
                       "[^b]: 跨容器脚注\n\n"
                       "[^d]: 外部后脚注\n"))
         (session (etaf-md-create :text text :theme 'dark))
         (labels (plist-get (etaf-md-state session) :footnotes)))
    (should (equal labels '("a" "b" "c" "d")))
    (etaf-md-tests--with-mount session
      (let ((painted (buffer-substring-no-properties (point-min) (point-max))))
        (should (string-match-p "Before\\[1\\]" painted))
        (should (string-match-p "Inside\\[2\\] and local\\[3\\]" painted))
        (should (string-match-p "After\\[4\\]" painted))
        (should (string-match-p "\\[1\\] 外部前脚注" painted))
        (should (string-match-p "\\[2\\] 跨容器脚注" painted))
        (should (string-match-p "\\[3\\] 容器内脚注" painted))
        (should (string-match-p "\\[4\\] 外部后脚注" painted))))))

(defun etaf-md-tests--scaled-chars ()
  "Return any characters in the current buffer whose face carries `:height'."
  (let ((scaled nil))
    (dotimes (index (buffer-size))
      (let* ((face (get-text-property (1+ index) 'face))
             (faces (cond ((null face) nil)
                          ((and (listp face) (keywordp (car face))) (list face))
                          ((listp face) face)
                          (t (list face)))))
        (when (cl-some (lambda (entry)
                         (and (listp entry) (plist-get entry :height)))
                       faces)
          (push (char-after (1+ index)) scaled))))
    (concat (nreverse scaled))))

(ert-deftest etaf-md-tests-headings-scale-with-level ()
  "Front-matter title and body headings scale above body text again.
The document header keeps the largest size, and every heading level draws
larger than the paragraphs below it, so a page is not a wall of equal text."
  (let* ((page (concat "---\ntitle: 文档标题\nauthor: 作者\n---\n\n"
                       "### 小节\n\n正文。\n"))
         (all-levels (concat "---\ntitle: 页面标题\n---\n\n"
                             "# 一级标题\n\n"
                             "## 二级标题\n\n"
                             "### 三级标题\n\n"
                             "正文[^n]。\n\n"
                             "[^n]: 脚注内容\n"))
         (s1 (etaf-md-create :text page :theme 'dark))
         (s2 (etaf-md-create :text all-levels :theme 'dark)))
    (etaf-md-tests--with-mount s1
      (let ((scaled (etaf-md-tests--scaled-chars)))
        ;; The front-matter title and the body heading are both above body size.
        (should (string-match-p "文档标题" scaled))
        (should (string-match-p "小节" scaled))
        (should (eq (etaf-md-tests--face-attribute "文档标题" :weight) 'bold))))
    (etaf-md-tests--with-mount s2
      (let ((scaled (etaf-md-tests--scaled-chars)))
        (dolist (heading '("一级标题" "二级标题" "三级标题"))
          (should (string-match-p heading scaled)))
        (should (eq (etaf-md-tests--face-attribute "一级标题" :weight) 'bold))
        (should (eq (etaf-md-tests--face-attribute "三级标题" :weight) 'bold))))))

(ert-deftest etaf-md-tests-on-link-intercepts-or-falls-back ()
  "`:on-link' intercepts link press on non-nil and falls back on nil."
  (let* ((seen nil)
         (browsed nil)
         (session
          (etaf-md-create
           :text (concat "# Target\n\n"
                         "[Handled](https://app.example/doc) "
                         "[Fallback](https://other.example/page) "
                         "[Anchor](#target)\n\n"
                         ":::card {title=\"CardLink\" href=\"https://app.example/card\"}\n"
                         "Body\n:::\n")
           :theme 'dark
           :on-link (lambda (url)
                      (push url seen)
                      (string-prefix-p "https://app.example/" url))))
         (buffer (etaf-md-open session)))
    (unwind-protect
        (with-current-buffer buffer
          (cl-letf (((symbol-function 'browse-url)
                     (lambda (url &rest _) (push url browsed))))
            ;; Handled link: callback returns non-nil, browse-url not called.
            (goto-char (point-min))
            (should (search-forward "Handled" nil t))
            (goto-char (match-beginning 0))
            (call-interactively (key-binding (kbd "RET")))
            ;; Fallback link: callback returns nil, browse-url called.
            (goto-char (point-min))
            (should (search-forward "Fallback" nil t))
            (goto-char (match-beginning 0))
            (call-interactively (key-binding (kbd "RET")))
            ;; Fallback anchor: callback returns nil, jumps to heading.
            (goto-char (point-min))
            (should (search-forward "Anchor" nil t))
            (goto-char (match-beginning 0))
            (call-interactively (key-binding (kbd "RET")))
            (should (looking-at-p "Target"))
            ;; Container card href also routes through `:on-link'.
            (goto-char (point-min))
            (should (search-forward "CardLink" nil t))
            (goto-char (match-beginning 0))
            (call-interactively (key-binding (kbd "RET")))))
      (when (buffer-live-p buffer)
        (with-current-buffer buffer (etaf-md-close))))
    (should (equal (nreverse seen)
                   '("https://app.example/doc"
                     "https://other.example/page"
                     "#target"
                     "https://app.example/card")))
    (should (equal browsed '("https://other.example/page")))))

(ert-deftest etaf-md-tests-on-media-intercepts-or-falls-back ()
  "`:on-media' receives `(KIND PATH)' on press; non-nil handles, nil falls back."
  (skip-unless (memq system-type '(darwin gnu/linux)))
  (let* ((image (etaf-md-tests--fixture "wide-400x100.png"))
         (video (etaf-md-tests--fixture "clip.mp4"))
         (handled-events nil)
         (fallback-events nil)
         (opened-desktop nil)
         (real-process (symbol-function 'call-process)))
    ;; 1. Intercept both image and video (returning non-nil).
    (let ((session (etaf-md-create
                    :text (format "![wide](%s)\n\n![clip](%s)\n" image video)
                    :theme 'dark
                    :on-media (lambda (kind path)
                                (push (list kind path) handled-events)
                                t))))
      (etaf-md-tests--with-mount session
        (cl-letf (((symbol-function 'call-process)
                   (lambda (program &rest args)
                     (if (member program '("open" "xdg-open"))
                         (progn (push (car (last args)) opened-desktop) 0)
                       (apply real-process program args)))))
          (goto-char (point-min))
          (should (search-forward "▀" nil t))
          (goto-char (match-beginning 0))
          (call-interactively (key-binding (kbd "RET")))
          (goto-char (point-min))
          (should (search-forward "按 RET 播放" nil t))
          (goto-char (match-beginning 0))
          (call-interactively (key-binding (kbd "RET")))
          ;; Returning non-nil must not mount the inline player either.
          (goto-char (point-min))
          (should-not (search-forward "按 RET 播放/暂停" nil t)))))
    (should (equal (nreverse handled-events)
                   (list (list 'image image) (list 'video video))))
    (should-not opened-desktop)
    ;; 2. Returning nil falls back to the desktop opener for a local image.
    (let ((session (etaf-md-create
                    :text (format "![wide](%s)\n" image)
                    :theme 'dark
                    :on-media (lambda (kind path)
                                (push (list kind path) fallback-events)
                                nil))))
      (etaf-md-tests--with-mount session
        (cl-letf (((symbol-function 'call-process)
                   (lambda (program &rest args)
                     (if (member program '("open" "xdg-open"))
                         (progn (push (car (last args)) opened-desktop) 0)
                       (apply real-process program args)))))
          (goto-char (point-min))
          (should (search-forward "▀" nil t))
          (goto-char (match-beginning 0))
          (call-interactively (key-binding (kbd "RET"))))))
    (should (equal fallback-events (list (list 'image image))))
    (should (equal opened-desktop (list image)))))

(ert-deftest etaf-md-tests-table-container-preserves-inline-runs ()
  "`:::table' cells keep bold, italic, code spans and clickable links."
  (let* ((opened nil)
         (session
          (etaf-md-create
           :text (concat ":::table {title=\"特性\"}\n"
                         "| 样式 | 链接 |\n"
                         "| --- | --- |\n"
                         "| **粗体** *斜体* `代码` | [文档](https://example.com/doc) |\n"
                         ":::\n")
           :theme 'dark
           :on-link (lambda (url) (push url opened) t))))
    (etaf-md-tests--with-mount session
      (let ((bold-weight (etaf-md-tests--face-attribute "粗体" :weight))
            (italic-slant (etaf-md-tests--face-attribute "斜体" :slant))
            (code-bg (etaf-md-tests--face-attribute "代码" :background))
            (link-keymap (etaf-md-tests--keymap-at "文档")))
        (should (eq bold-weight 'bold))
        (should (eq italic-slant 'italic))
        (should (stringp code-bg))
        (should-not (equal code-bg "#191a1c"))
        (should link-keymap)
        (goto-char (point-min))
        (should (search-forward "文档" nil t))
        (goto-char (match-beginning 0))
        (call-interactively (key-binding (kbd "RET")))))
    (should (equal opened '("https://example.com/doc")))))

(ert-deftest etaf-md-tests-columns-counts-explicit-tracks ()
  "`:::columns' with an explicit track list uses the track count as column count.
A 3-track list lays three columns on one row instead of falling back to two,
and a single-track list stacks its columns one per row."
  (let ((three (etaf-md-create
                :text (concat ":::columns {columns=\"2fr 1fr 1fr\"}\n"
                              ":::col\nColA\n:::\n"
                              ":::col\nColB\n:::\n"
                              ":::col\nColC\n:::\n"
                              ":::\n")
                :theme 'dark))
        (one (etaf-md-create
              :text (concat ":::columns {columns=\"1fr\"}\n"
                            ":::col\nFirstRow\n:::\n"
                            ":::col\nSecondRow\n:::\n"
                            ":::\n")
              :theme 'dark)))
    (etaf-md-tests--with-mount three
      (let ((text (buffer-substring-no-properties (point-min) (point-max))))
        (should (string-match-p "ColA.*ColB.*ColC" text))))
    (etaf-md-tests--with-mount one
      (let ((text (buffer-substring-no-properties (point-min) (point-max))))
        (should (string-match-p "FirstRow" text))
        (should (string-match-p "SecondRow" text))
        (should-not (string-match-p "FirstRow.*SecondRow" text))))))

(ert-deftest etaf-md-tests-card-with-image-wraps-paragraph-inside-columns ()
  "A multi-column card holding an image and a long paragraph wraps without clipping.
All three cards remain side by side on one row at the same column width as the
text-only control, every word of the paragraph appears intact wrapped across
multiple lines inside the card width, and the image frame stays inside the card."
  (let* ((fixture (etaf-md-tests--fixture "wide-400x100.png"))
         (body "video as sharp image frames with sound, subtitles and a queue that keeps playing")
         (doc (format (concat ":::columns {columns=\"3\" min-width=\"22ch\" divider=false}\n"
                              ":::col\n:::card {title=\"card-one\"}\n"
                              "![](%s)\n\n%s\n:::\n:::\n"
                              ":::col\n:::card {title=\"card-two\"}\nshort body\n:::\n:::\n"
                              ":::col\n:::card {title=\"card-three\"}\nshort body\n:::\n:::\n"
                              ":::\n")
                      fixture body))
         (ctrl-doc (format (concat ":::columns {columns=\"3\" min-width=\"22ch\" divider=false}\n"
                                   ":::col\n:::card {title=\"card-one\"}\n%s\n:::\n:::\n"
                                   ":::col\n:::card {title=\"card-two\"}\nshort body\n:::\n:::\n"
                                   ":::col\n:::card {title=\"card-three\"}\nshort body\n:::\n:::\n"
                                   ":::\n")
                           body))
         (session (etaf-md-create :text doc :theme 'dark))
         (ctrl-session (etaf-md-create :text ctrl-doc :theme 'dark))
         (ctrl-border nil))
    (etaf-md-tests--with-mount ctrl-session
      (let ((lines (split-string (buffer-substring-no-properties (point-min) (point-max)) "\n")))
        (setq ctrl-border (cl-find-if (lambda (l) (string-match-p "┌─+┐" l)) lines))))
    (etaf-md-tests--with-mount session
      (let* ((rendered (buffer-substring-no-properties (point-min) (point-max)))
             (lines (split-string rendered "\n"))
             (top-border (cl-find-if (lambda (l) (string-match-p "┌─+┐" l)) lines))
             (title-line (cl-find-if (lambda (l) (string-match-p "card-one" l)) lines))
             (body-words (split-string body " " t))
             (para-lines (cl-remove-if-not
                          (lambda (l)
                            (string-match-p
                             "video\\|image\\|frames\\|sound\\|subtitles\\|queue\\|playing"
                             l))
                          lines)))
        ;; Column count and exact top border geometry match the no-image control.
        (should ctrl-border)
        (should (equal top-border ctrl-border))
        (should title-line)
        (should (string-match-p "card-one.*card-two.*card-three" title-line))
        ;; Paragraph wraps across multiple lines (>= 3) with zero clipped words.
        (should (>= (length para-lines) 3))
        (let ((joined (mapconcat #'identity para-lines " ")))
          (dolist (word body-words)
            (should (string-match-p (regexp-quote word) joined))))
        ;; Image right border renders intact inside the card column.
        (should (cl-some (lambda (l) (string-match-p "│▀+│" l)) lines))))))

(ert-deftest etaf-md-tests-html-img-declared-dimensions-bound-render-size ()
  "HTML `<img>' `width'/`height' attributes bound rendered grid size instead of intrinsic size.
A compact declared icon backed by a much larger image renders small and
left-aligned without a blank caption row, and a single-axis `width' scales
proportionally below the unsized width."
  (let* ((fixture (etaf-md-tests--fixture "wide-400x100.png"))
         (measure
          (lambda (doc)
            (let ((session (etaf-md-create :text doc :theme 'dark))
                  (width 0)
                  (indent 0)
                  (has-caption nil))
              (etaf-md-tests--with-mount session
                (let* ((text (buffer-substring-no-properties (point-min) (point-max)))
                       (lines (split-string text "\n"))
                       (img-line (cl-find-if (lambda (l) (string-match-p "│▀+│" l)) lines)))
                  (when (and img-line (string-match "^\\( *\\)│\\(▀+\\)│" img-line))
                    (setq indent (length (match-string 1 img-line))
                          width (length (match-string 2 img-line))))
                  (setq has-caption (and (string-match-p "▲" text) t))))
              (list width indent has-caption))))
         (unsized (funcall measure (format "![](%s)\n" fixture)))
         (compact (funcall measure
                           (format "<img src=\"%s\" alt=\"\" width=\"48\" height=\"48\">\n"
                                   fixture)))
         (scaled (funcall measure
                          (format "<img src=\"%s\" alt=\"Thumb\" width=\"96\">\n"
                                  fixture))))
    ;; Unsized 400x100 image renders wide; declared 48x48 renders compact & left-aligned.
    (should (>= (nth 0 unsized) 24))
    (should (> (nth 0 compact) 0))
    (should (<= (nth 0 compact) 12))
    (should (< (nth 0 compact) (nth 0 unsized)))
    (should (< (nth 1 compact) (nth 1 unsized)))
    (should-not (nth 2 compact))
    ;; Single-axis declared width sits between compact and unsized, keeping caption.
    (should (> (nth 0 scaled) (nth 0 compact)))
    (should (< (nth 0 scaled) (nth 0 unsized)))
    (should (nth 2 scaled))))

(ert-deftest etaf-md-tests-link-hover-option-disables-mouse-face ()
  "Passing `:link-hover nil' to `etaf-md-create' suppresses link `mouse-face' while keeping activation."
  (let* ((clicks nil)
         (session (etaf-md-create :text "See [Example](https://example.com) now.\n"
                                  :link-hover nil
                                  :on-link (lambda (u) (push u clicks) t)))
         (buf (etaf-md-open session)))
    (unwind-protect
        (with-current-buffer buf
          (goto-char (point-min))
          (should (search-forward "Example" nil t))
          (let ((pos (match-beginning 0)))
            (should-not (get-text-property pos 'mouse-face))
            (should (eq 'hand (get-text-property pos 'pointer)))
            (goto-char pos)
            (call-interactively (key-binding (kbd "RET")))
            (should (equal clicks '("https://example.com")))))
      (when (buffer-live-p buf)
        (with-current-buffer buf (etaf-md-close))))))

(ert-deftest etaf-md-tests-container-blocks-keep-blank-line-separation ()
  "Multi-block containers keep one blank line between paragraph, code and list blocks."
  (let* ((doc (concat ":::details {title=\"Section\" open=true}\n"
                      "First paragraph inside details.\n\n"
                      "```css\n.box { display: flex; }\n```\n\n"
                      "- Alpha item\n"
                      "- Beta item\n"
                      ":::\n"))
         (session (etaf-md-create :text doc :theme 'dark)))
    (etaf-md-tests--with-mount session
      (let* ((lines (split-string
                     (buffer-substring-no-properties (point-min) (point-max))
                     "\n"))
             (idx-para (cl-position-if
                        (lambda (l) (string-match-p "First paragraph inside details\\." l))
                        lines))
             (idx-code (cl-position-if
                        (lambda (l) (string-match-p "display: flex" l))
                        lines))
             (idx-list (cl-position-if
                        (lambda (l) (string-match-p "Alpha item" l))
                        lines)))
        (should idx-para)
        (should idx-code)
        (should idx-list)
        ;; At least one blank interior line between paragraph and code block,
        ;; and between code block and list (not smashed onto consecutive rows).
        (should (cl-some (lambda (i)
                           (string-match-p "\\`[ \t│]*\\'" (nth i lines)))
                         (number-sequence (1+ idx-para) (1- idx-code))))
        (should (cl-some (lambda (i)
                           (string-match-p "\\`[ \t│]*\\'" (nth i lines)))
                         (number-sequence (1+ idx-code) (1- idx-list))))))))

(ert-deftest etaf-md-tests-svg-viewbox-preserves-aspect-and-caps-height ()
  "ViewBox-only SVGs preserve natural aspect ratio (not a square) and cap tall height."
  (let* ((dir (make-temp-file "etaf-md-svg-" t))
         (wide-svg (expand-file-name "wide.svg" dir))
         (tall-svg (expand-file-name "tall.svg" dir)))
    (unwind-protect
        (progn
          (with-temp-file wide-svg
            (insert "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 490 225.27\"><rect width=\"490\" height=\"225\"/></svg>"))
          (with-temp-file tall-svg
            (insert "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 490 820\"><rect width=\"490\" height=\"820\"/></svg>"))
          (let ((measure
                 (lambda (svg-path)
                   (let ((session (etaf-md-create
                                   :text (format "<img src=\"%s\" alt=\"Diagram\" width=\"350\">\n"
                                                 svg-path)
                                   :theme 'dark)))
                     (etaf-md-tests--with-mount session
                       (etaf-md-tests--media-grid-shape))))))
            (let* ((wide (funcall measure wide-svg))
                   (tall (funcall measure tall-svg))
                   (wide-cols (car wide))
                   (wide-rows (cdr wide))
                   (tall-cols (car tall))
                   (tall-rows (cdr tall)))
              (should (> wide-cols 0))
              (should (> wide-rows 0))
              ;; Wide 490x225 SVG with width=350 must stay compact landscape, not ~20-row square.
              (should (<= wide-rows 14))
              (should (> wide-cols (* 2 wide-rows)))
              ;; Tall 490x820 portrait SVG caps rows at <= 20 and narrows columns proportionally.
              (should (> tall-rows wide-rows))
              (should (<= tall-rows 20))
              (should (< tall-cols wide-cols)))))
      (delete-directory dir t))))

(ert-deftest etaf-md-tests-heading-underline-option-suppresses-heading-rules-and-link-underlines ()
  "Passing `:heading-underline nil' drops H1/H2 rules and heading link underlines while keeping body links underlined."
  (cl-labels ((face-underlined-p (f)
                (cond
                 ((not (listp f)) nil)
                 ((keywordp (car f)) (and (plist-get f :underline) t))
                 (t (cl-some #'face-underlined-p f)))))
    (let* ((clicks nil)
           (doc (concat "# Main Title\n\n"
                        "## [Linked Section](https://example.com/sec)\n\n"
                        "Read [Body Link](https://example.com/body) carefully.\n"))
           (session (etaf-md-create :text doc
                                    :heading-underline nil
                                    :on-link (lambda (u) (push u clicks) t)))
           (buf (etaf-md-open session)))
      (unwind-protect
          (with-current-buffer buf
            (let ((plain (buffer-substring-no-properties (point-min) (point-max))))
              ;; No H1/H2 bottom border rule line drawn under headings.
              (should-not (string-match-p "^[ \t]*─\\{8,\\}[ \t]*$" plain)))
            ;; Heading link stays clickable with hand pointer, but carries no underline.
            (goto-char (point-min))
            (should (search-forward "Linked Section" nil t))
            (let* ((hpos (match-beginning 0))
                   (hface (get-text-property hpos 'face)))
              (should-not (face-underlined-p hface))
              (should (eq 'hand (get-text-property hpos 'pointer)))
              (goto-char hpos)
              (call-interactively (key-binding (kbd "RET")))
              (should (equal clicks '("https://example.com/sec"))))
            ;; Body paragraph link still carries underline.
            (goto-char (point-min))
            (should (search-forward "Body Link" nil t))
            (let* ((bpos (match-beginning 0))
                   (bface (get-text-property bpos 'face)))
              (should (face-underlined-p bface))))
        (when (buffer-live-p buf)
          (with-current-buffer buf (etaf-md-close)))))))

(ert-deftest etaf-md-tests-locate-scrolls-enclosing-viewport-preserving-header ()
  "`etaf-md-locate' scrolls an enclosing `:overflow scroll' viewport to off-screen headings."
  (let* ((doc (concat "# First Heading\n\n"
                      (mapconcat (lambda (i)
                                   (format "Paragraph %d with enough text to extend past one viewport.\n\n" i))
                                 (number-sequence 1 35) "")
                      "## Deep Target Heading\n\nTail prose below target heading.\n"))
         (session (etaf-md-create :text doc :theme 'dark))
         (buf (generate-new-buffer " *etaf-md-scroll-locate*")))
    (unwind-protect
        (progn
          (etaf-mount
           buf
           (etaf-view
            (flex :flex-direction 'column :width '(vw 100) :height '(vh 100)
                  :min-height '(lh 0) :overflow 'hidden
              (box :flex-shrink 0 (text "FIXED-TOP-BAR"))
              (box :ref 'outer-scroll :width 'stretch :flex-grow 1
                   :flex-basis '(lh 0) :min-height '(lh 0) :overflow 'scroll
                (column :width 'stretch :height 'auto
                  (expr (etaf-md-view session))))))
           '(:viewport-width 720 :viewport-height 16))
          (let ((rt (etaf-runtime-for-buffer buf)))
            (with-current-buffer buf
              (should (= 0 (etaf-scroll-offset rt 'outer-scroll)))
              ;; Up/down arrows scroll the enclosing reading viewport 1 line at a time
              ;; rather than leaping between focusable controls.
              (goto-char (etaf-host-ref-position rt 'outer-scroll))
              (etaf-direction 'down rt)
              (should (= 1 (etaf-scroll-offset rt 'outer-scroll)))
              (etaf-direction 'down rt)
              (should (= 2 (etaf-scroll-offset rt 'outer-scroll)))
              (etaf-direction 'up rt)
              (should (= 1 (etaf-scroll-offset rt 'outer-scroll)))
              (etaf-direction 'up rt)
              (should (= 0 (etaf-scroll-offset rt 'outer-scroll)))
              (should-not (string-match-p "Deep Target Heading"
                                          (buffer-substring-no-properties (point-min) (point-max))))
              (let ((pos (etaf-md-locate session 1)))
                (should (integerp pos))
                (should (= (point) pos))
                (should (looking-at-p "Deep Target Heading"))
                (should (> (etaf-scroll-offset rt 'outer-scroll) 0))
                (should (string-match-p
                         "FIXED-TOP-BAR"
                         (save-excursion
                           (goto-char (point-min))
                           (buffer-substring-no-properties
                            (line-beginning-position) (line-end-position)))))))))
      (when-let* ((rt (and (buffer-live-p buf) (etaf-runtime-for-buffer buf))))
        (etaf-unmount rt))
      (when (buffer-live-p buf) (kill-buffer buf)))))

(ert-deftest etaf-md-tests-top-block-and-structural-edits-stay-incremental ()
  "Top-block edits, blank-line inserts and paragraph splits stay on line-level patches."
  (let* ((file (make-temp-file "etaf-md-top-inc-" nil ".md"))
         (source nil)
         (preview nil))
    (unwind-protect
        (progn
          (with-temp-file file
            (insert "---\ntitle: Top Inc\n---\n\n")
            (dotimes (i 35)
              (insert (format "第 %d 段：正文内容用来检验顶部增量重排。\n\n" i))))
          (setq source (find-file-noselect file))
          (setq preview (etaf-md-open file))
          ;; 1. Edit block 0 directly.
          (with-current-buffer source
            (goto-char (point-min))
            (search-forward "第 0 段")
            (insert "（已改）"))
          (sit-for 0.15)
          (etaf-runtime-flush (etaf-runtime-for-buffer preview))
          (let ((rep (with-current-buffer preview (etaf-runtime-update-report)))
                (txt (with-current-buffer preview
                       (buffer-substring-no-properties (point-min) (point-max)))))
            (should (string-match-p "第 0 段（已改）" txt))
            (should (eq 'lines (plist-get rep :strategy)))
            (should (<= (plist-get rep :lines) 6)))
          ;; 2. Insert a blank line right after block 0.
          (with-current-buffer source
            (goto-char (point-min))
            (search-forward "第 0 段")
            (end-of-line)
            (insert "\n"))
          (sit-for 0.15)
          (etaf-runtime-flush (etaf-runtime-for-buffer preview))
          (let ((rep (with-current-buffer preview (etaf-runtime-update-report))))
            (should (eq 'lines (plist-get rep :strategy)))
            (should (<= (plist-get rep :lines) 6)))
          ;; 3. Split block 0 into two paragraphs.
          (with-current-buffer source
            (goto-char (point-min))
            (search-forward "第 0 段")
            (end-of-line)
            (insert "\n\n新拆出来的段落。"))
          (sit-for 0.15)
          (etaf-runtime-flush (etaf-runtime-for-buffer preview))
          (let ((rep (with-current-buffer preview (etaf-runtime-update-report)))
                (txt (with-current-buffer preview
                       (buffer-substring-no-properties (point-min) (point-max)))))
            (should (string-match-p "新拆出来的段落。" txt))
            (should (eq 'lines (plist-get rep :strategy)))
            (should (<= (plist-get rep :lines) 8))))
      (when (buffer-live-p preview) (kill-buffer preview))
      (when (buffer-live-p source)
        (with-current-buffer source (set-buffer-modified-p nil))
        (kill-buffer source))
      (delete-file file))))

(ert-deftest etaf-md-tests-unclosed-live-fence-keeps-trailing-blocks-and-settles ()
  "An unclosed code fence while typing stays local and settles on close or save."
  (let* ((file (make-temp-file "etaf-md-fence-live-" nil ".md"))
         (source nil)
         (preview nil))
    (unwind-protect
        (progn
          (with-temp-file file
            (insert "# Live Fence\n\n")
            (dotimes (i 20)
              (insert (format "Paragraph %d **bold-%d**.\n\n" i i))))
          (setq source (find-file-noselect file))
          (setq preview (etaf-md-open file))
          ;; Type an unclosed code fence in the middle without saving.
          (with-current-buffer source
            (goto-char (point-min))
            (search-forward "Paragraph 8")
            (end-of-line)
            (insert "\n\n```elisp\n(message \"hi\")"))
          (sit-for 0.15)
          (etaf-runtime-flush (etaf-runtime-for-buffer preview))
          (let ((rep (with-current-buffer preview (etaf-runtime-update-report))))
            (should (eq 'lines (plist-get rep :strategy)))
            (should (<= (plist-get rep :lines) 12)))
          ;; Trailing paragraph still renders bold (not swallowed into code).
          (with-current-buffer preview
            (should (eq (etaf-md-tests--face-attribute "bold-18" :weight) 'bold)))
          ;; Typing another character inside the provisional fence stays incremental.
          (with-current-buffer source
            (insert " ; ok"))
          (sit-for 0.15)
          (etaf-runtime-flush (etaf-runtime-for-buffer preview))
          (let ((rep (with-current-buffer preview (etaf-runtime-update-report))))
            (should (eq 'lines (plist-get rep :strategy)))
            (should (<= (plist-get rep :lines) 12)))
          ;; Closing the fence keeps trailing prose intact and incremental.
          (with-current-buffer source
            (insert "\n```"))
          (sit-for 0.15)
          (etaf-runtime-flush (etaf-runtime-for-buffer preview))
          (let ((rep (with-current-buffer preview (etaf-runtime-update-report))))
            (should (eq 'lines (plist-get rep :strategy)))
            (should (<= (plist-get rep :lines) 12)))
          (with-current-buffer preview
            (should (eq (etaf-md-tests--face-attribute "bold-18" :weight) 'bold)))
          ;; Saving an unclosed fence settles to exact CommonMark (swallows tail).
          (with-current-buffer source
            (goto-char (point-min))
            (search-forward "; ok\n```")
            (delete-region (- (point) 4) (point))
            (save-buffer))
          (sit-for 0.2)
          (etaf-runtime-flush (etaf-runtime-for-buffer preview))
          (with-current-buffer preview
            (let ((plain (buffer-substring-no-properties (point-min) (point-max))))
              (should (string-match-p "\\*\\*bold-18\\*\\*" plain)))))
      (when (buffer-live-p preview) (kill-buffer preview))
      (when (buffer-live-p source)
        (with-current-buffer source (set-buffer-modified-p nil))
        (kill-buffer source))
      (delete-file file))))

(ert-deftest etaf-md-tests-live-edits-keep-outline-and-doc-wide-references-fresh ()
  "Incremental live edits update outline headings and keep reference links resolving."
  (let* ((file (make-temp-file "etaf-md-outline-live-" nil ".md"))
         (source nil)
         (preview nil)
         (opened nil))
    (unwind-protect
        (progn
          (with-temp-file file
            (insert "## Intro\n\nAlpha line.\n\n## Middle\n\nTarget prose.\n\n## End\n\nTail.\n\n"
                    "[ref]: https://example.com/live-ref\n"))
          (setq source (find-file-noselect file))
          (setq preview (etaf-md-open file))
          (with-current-buffer source
            (goto-char (point-min))
            (search-forward "Target prose.")
            (replace-match "## Added Heading\n\nClick [Ref Link][ref] now."))
          (sit-for 0.15)
          (etaf-runtime-flush (etaf-runtime-for-buffer preview))
          (let* ((session (with-current-buffer preview (etaf-app-state)))
                 (titles (mapcar #'cadr (etaf-md-outline session))))
            (should (equal titles '("Intro" "Middle" "Added Heading" "End")))
            (with-current-buffer preview
              (let ((pos (etaf-md-locate session 2)))
                (should (integerp pos))
                (should (looking-at-p "Added Heading")))
              (should (etaf-md-tests--keymap-at "Ref Link"))
              (goto-char (match-beginning 0))
              (cl-letf (((symbol-function 'browse-url)
                         (lambda (u &rest _) (push u opened))))
                (call-interactively (key-binding (kbd "RET"))))
              (should (equal opened '("https://example.com/live-ref"))))))
      (when (buffer-live-p preview) (kill-buffer preview))
      (when (buffer-live-p source)
        (with-current-buffer source (set-buffer-modified-p nil))
        (kill-buffer source))
      (delete-file file))))

(ert-deftest etaf-md-tests-narrow-viewport-wraps-without-clipping-and-widens-back ()
  "Prose wraps cleanly in narrow windows without right-edge clipping and widens back."
  (let* ((sentence (concat "AlphaWord BravoWord CharlieWord DeltaWord EchoWord "
                           "FoxtrotWord GolfWord HotelWord IndiaWord JulietWord "
                           "KiloWord LimaWord MikeWord NovemberWord"))
         (session (etaf-md-create :text (concat sentence "\n") :theme 'dark))
         (char (frame-char-width)))
    (etaf-md-tests--with-mount session
      (let ((rt (etaf-runtime-for-buffer (current-buffer))))
        ;; Narrow to 48 columns: every word must survive wrapped across multiple lines.
        (etaf-runtime-refit rt (* 48 char) 40)
        (let* ((narrow-text (buffer-substring-no-properties (point-min) (point-max)))
               (narrow-lines (count-lines (point-min) (point-max))))
          (should (string-match-p "AlphaWord" narrow-text))
          (should (string-match-p "NovemberWord" narrow-text))
          (should (>= narrow-lines 3))
          ;; Widening back to 120 columns must reflow into fewer lines.
          (etaf-runtime-refit rt (* 120 char) 40)
          (let* ((wide-text (buffer-substring-no-properties (point-min) (point-max)))
                 (wide-lines (count-lines (point-min) (point-max))))
            (should (string-match-p "NovemberWord" wide-text))
            (should (< wide-lines narrow-lines))))))))

(ert-deftest etaf-md-tests-same-basename-files-open-distinct-previews ()
  "Two files sharing a basename in different directories get distinct preview buffers."
  (let* ((root (make-temp-file "etaf-md-samebase-" t))
         (dir-a (expand-file-name "alpha" root))
         (dir-b (expand-file-name "beta" root))
         (file-a (expand-file-name "README.md" dir-a))
         (file-b (expand-file-name "README.md" dir-b))
         buf-a buf-b)
    (unwind-protect
        (progn
          (make-directory dir-a t)
          (make-directory dir-b t)
          (with-temp-file file-a (insert "# Alpha Doc\n\nContent from alpha.\n"))
          (with-temp-file file-b (insert "# Beta Doc\n\nContent from beta.\n"))
          (setq buf-a (etaf-md-open file-a))
          (setq buf-b (etaf-md-open file-b))
          (should-not (eq buf-a buf-b))
          (should-not (equal (buffer-name buf-a) (buffer-name buf-b)))
          (should (string-match-p "Content from alpha"
                                  (with-current-buffer buf-a
                                    (buffer-substring-no-properties (point-min) (point-max)))))
          (should (string-match-p "Content from beta"
                                  (with-current-buffer buf-b
                                    (buffer-substring-no-properties (point-min) (point-max))))))
      (when (buffer-live-p buf-a) (kill-buffer buf-a))
      (when (buffer-live-p buf-b) (kill-buffer buf-b))
      (delete-directory root t))))

(ert-deftest etaf-md-tests-symlink-edits-sync-to-preview ()
  "Editing through a symlink updates a preview opened via the real path."
  (let* ((dir (make-temp-file "etaf-md-sym-" t))
         (real (expand-file-name "real.md" dir))
         (link (expand-file-name "alias.md" dir))
         source preview)
    (unwind-protect
        (progn
          (with-temp-file real (insert "# Symlink\n\nOriginal body.\n"))
          (make-symbolic-link real link)
          (setq preview (etaf-md-open real))
          (setq source (find-file-noselect link))
          (with-current-buffer source
            (goto-char (point-max))
            (insert "\nEdited via symlink.\n"))
          (sit-for 0.2)
          (etaf-runtime-flush (etaf-runtime-for-buffer preview))
          (let ((txt (with-current-buffer preview
                       (buffer-substring-no-properties (point-min) (point-max)))))
            (should (string-match-p "Edited via symlink" txt))))
      (when (buffer-live-p preview) (kill-buffer preview))
      (when (buffer-live-p source)
        (with-current-buffer source (set-buffer-modified-p nil))
        (kill-buffer source))
      (delete-directory dir t))))

(ert-deftest etaf-md-tests-footnote-jump-lands-on-definition-and-returns ()
  "Activating a footnote reference jumps to the definition and `↩' returns."
  (let* ((doc (concat "Read the note[^1] right here.\n\n"
                      (mapconcat (lambda (i) (format "Filler paragraph %d.\n\n" i))
                                 (number-sequence 1 12) "")
                      "[^1]: Footnote explanation body.\n"))
         (session (etaf-md-create :text doc :theme 'dark))
         (buf (etaf-md-open session)))
    (unwind-protect
        (with-current-buffer buf
          (goto-char (point-min))
          (should (search-forward "[1]" nil t))
          (let ((ref-pos (match-beginning 0)))
            (goto-char ref-pos)
            (call-interactively (key-binding (kbd "RET")))
            ;; Point must land on the bottom definition, not stay on body `[1]'.
            (should (> (point) ref-pos))
            (should (string-match-p
                     "Footnote explanation body"
                     (buffer-substring-no-properties
                      (line-beginning-position) (line-end-position))))
            ;; Mark was pushed at the pre-jump position.
            (should (= (mark t) ref-pos))
            ;; Activate the `↩' back-link on the same footnote line.
            (should (search-forward "↩" (line-end-position) t))
            (goto-char (match-beginning 0))
            (call-interactively (key-binding (kbd "RET")))
            (should (= (point) ref-pos))))
      (when (buffer-live-p buf)
        (with-current-buffer buf (etaf-md-close))))))

(ert-deftest etaf-md-tests-container-state-isolated-and-survives-edits-above ()
  "Interactive container state stays isolated per block and survives edits above."
  (let* ((file (make-temp-file "etaf-md-state-" nil ".md"))
         source preview)
    (unwind-protect
        (progn
          (with-temp-file file
            (insert "Top intro.\n\n"
                    ":::details {title=\"Alpha Box\"}\nSecret alpha text.\n:::\n\n"
                    ":::details {title=\"Beta Box\"}\nSecret beta text.\n:::\n"))
          (setq source (find-file-noselect file))
          (setq preview (etaf-md-open file))
          ;; Open Alpha Box only.
          (with-current-buffer preview
            (should-not (string-match-p "Secret alpha text"
                                        (buffer-substring-no-properties (point-min) (point-max))))
            (goto-char (point-min))
            (search-forward "Alpha Box")
            (goto-char (match-beginning 0))
            (call-interactively (key-binding (kbd "RET")))
            (let ((txt (buffer-substring-no-properties (point-min) (point-max))))
              (should (string-match-p "Secret alpha text" txt))
              (should-not (string-match-p "Secret beta text" txt))))
          ;; Insert new blocks above Alpha Box so its byte offset shifts.
          (with-current-buffer source
            (goto-char (point-min))
            (insert "Inserted paragraph one.\n\nInserted paragraph two.\n\n"))
          (sit-for 0.2)
          (etaf-runtime-flush (etaf-runtime-for-buffer preview))
          ;; Alpha Box must remain open and Beta Box must remain closed.
          (let ((txt (with-current-buffer preview
                       (buffer-substring-no-properties (point-min) (point-max)))))
            (should (string-match-p "Inserted paragraph two" txt))
            (should (string-match-p "Secret alpha text" txt))
            (should-not (string-match-p "Secret beta text" txt))))
      (when (buffer-live-p preview) (kill-buffer preview))
      (when (buffer-live-p source)
        (with-current-buffer source (set-buffer-modified-p nil))
        (kill-buffer source))
      (delete-file file))))

(ert-deftest etaf-md-tests-malformed-chart-degrades-to-failure-view ()
  "A malformed `:::chart' container degrades cleanly instead of signaling uncaught error."
  (let ((session (etaf-md-create :text ":::chart {values=\"1\"}\n:::\n\nAfter chart.\n")))
    (etaf-md-tests--with-mount session
      (let ((txt (buffer-substring-no-properties (point-min) (point-max))))
        (should (string-match-p "After chart" txt))
        (should (string-match-p "chart" txt))))))

(ert-deftest etaf-md-tests-file-url-media-resolves-as-local ()
  "A `file://' image URL resolves as a local file rather than a remote URL."
  (let* ((img (etaf-md-tests--fixture "wide-400x100.png"))
         (file-url (concat "file://" img))
         (seen nil)
         (session (etaf-md-create
                   :text (format "![Sample](%s)\n" file-url)
                   :on-media (lambda (kind path)
                               (push (cons kind path) seen)
                               t))))
    (etaf-md-tests--with-mount session
      (goto-char (point-min))
      (should (search-forward "▀" nil t))
      (goto-char (match-beginning 0))
      (call-interactively (key-binding (kbd "RET")))
      (should (equal (car seen) (cons 'image (expand-file-name img)))))))

(ert-deftest etaf-md-tests-preview-splits-nondestructively-and-goto-source-returns ()
  "`etaf-md-preview' preserves unrelated windows, enables follow and supports `etaf-md-goto-source'."
  (let* ((file (make-temp-file "etaf-md-split-" nil ".md"))
         (side-buf (generate-new-buffer " *etaf-md-unrelated*"))
         source preview)
    (unwind-protect
        (progn
          (with-temp-file file
            (insert "# Split Demo\n\n")
            (dotimes (i 25)
              (insert (format "第 %d 段：双栏同步与反向跳回测试内容。\n\n" i))))
          (setq source (find-file-noselect file))
          (delete-other-windows)
          (let* ((win-side (selected-window))
                 (win-src (split-window-below)))
            (set-window-buffer win-side side-buf)
            (set-window-buffer win-src source)
            (select-window win-src)
            (with-current-buffer source
              (goto-char (point-min))
              (search-forward "第 12 段")
              (setq preview (etaf-md-preview)))
            (should (buffer-live-p preview))
            ;; All 3 windows exist: unrelated pane was NOT deleted.
            (should (= 3 (length (window-list))))
            (should (window-live-p win-side))
            (should (eq (selected-window) win-src))
            ;; Reverse jump from preview lands on the matching source line.
            (let ((win-prev (get-buffer-window preview)))
              (should (window-live-p win-prev))
              (select-window win-prev)
              (goto-char (point-min))
              (should (search-forward "第 18 段" nil t))
              (goto-char (match-beginning 0))
              (let ((pos (etaf-md-goto-source)))
                (should (integerp pos))
                (should (eq (current-buffer) source))
                (should (string-match-p
                         "第 18 段"
                         (buffer-substring-no-properties
                          (line-beginning-position) (line-end-position)))))
              ;; Closing the preview removes only the preview split, keeping both original windows.
              (select-window win-prev)
              (etaf-md-close)
              (should (= 2 (length (window-list))))
              (should (window-live-p win-side))
              (should (window-live-p win-src)))))
      (when (buffer-live-p preview) (kill-buffer preview))
      (when (buffer-live-p source) (kill-buffer source))
      (when (buffer-live-p side-buf) (kill-buffer side-buf))
      (delete-file file))))

(ert-deftest etaf-md-tests-theme-cycle-includes-auto-and-locate-pushes-mark ()
  "`etaf-md-cycle-theme' includes `auto', `etaf-md-locate' pushes mark and remote images respect toggle."
  (let* ((etaf-md-remote-images nil)
         (session (etaf-md-create
                   :text "# First\n\n![Remote](https://example.invalid/pic.png)\n\n## Second\n\nBody.\n"
                   :theme 'dark)))
    (should (eq (etaf-md-cycle-theme session) 'light))
    (should (eq (plist-get (etaf-md-state session) :background) 'palette))
    (should (eq (etaf-md-cycle-theme session) 'sepia))
    (should (eq (etaf-md-cycle-theme session) 'auto))
    (should (null (plist-get (etaf-md-state session) :background)))
    (should (eq (etaf-md-cycle-theme session) 'dark))
    (should (eq (plist-get (etaf-md-state session) :background) 'palette))
    (etaf-md-tests--with-mount session
      (goto-char (point-min))
      (let ((start (point)))
        (etaf-md-locate session 1)
        (should (looking-at-p "Second"))
        (should (= (mark t) start))))))

(ert-deftest etaf-md-tests-extended-layout-and-data-widgets-render ()
  "Curated editorial layout and visualization widgets paint cleanly."
  (let* ((doc (concat
               ":::breadcrumb {items=\"[Home](README.md) > Guide > Widgets\"}\n:::\n\n"
               "## Metrics\n\n"
               ":::progress {title=\"Build\" accent=success}\n- Parser: 100%\n- Widgets: 3/4\n:::\n\n"
               ":::stats {columns=3}\n"
               ":::stat {title=\"Tests\" value=\"390\" trend=\"+12%\" accent=success spark=\"1,4,2,8\"}\n:::\n"
               ":::stat {title=\"Latency\" value=\"12ms\" trend=\"-8%\" accent=primary note=\"p95\"}\n:::\n"
               ":::\n\n"
               ":::chart {type=bar label=\"Timings\" values=\"Parse:4,Paint:8\" unit=\"ms\"}\n:::\n\n"
               ":::chart {type=stacked label=\"Mix\" values=\"A:60,B:40\"}\n:::\n\n"
               ":::chart {type=heatmap label=\"Activity\" values=\"0,1,2,3,4,5,6,7\"}\n:::\n\n"
               ":::timeline {orientation=horizontal card=true}\n"
               ":::event {title=\"Alpha\" time=\"T1\" status=success}\nFirst step.\n:::\n"
               ":::event {title=\"Beta\" time=\"T2\" status=info}\nSecond step.\n:::\n"
               ":::\n\n"
               ":::keymap {title=\"Keys\" columns=2}\n- C-c t : Toggle TOC\n- n / p : Next or Prev\n:::\n"))
         (session (etaf-md-create :text doc :theme 'dark)))
    (etaf-md-tests--with-mount session
      (let ((txt (buffer-substring-no-properties (point-min) (point-max))))
        (should (string-match-p "Home › Guide › Widgets" txt))
        (should (string-match-p "Parser" txt))
        (should (string-match-p "75%" txt))
        (should (string-match-p "\\+12%" txt))
        (should (string-match-p "▁▄▂█" txt))
        (should (string-match-p "p95" txt))
        (should (string-match-p "Timings" txt))
        (should (string-match-p "60%" txt))
        (should (string-match-p "Activity" txt))
        (should (string-match-p "Alpha" txt))
        (should (string-match-p "Beta" txt))
        (should (string-match-p "Toggle TOC" txt))
        ;; In `keymap', `/' between alternative chords must NOT carry a keycap background.
        (let* ((slash-pos (+ 2 (string-match " / " txt)))
               (cap-pos (1+ (string-match "C-c" txt)))
               (bg-of (lambda (p)
                        (let ((s (format "%S" (get-text-property p 'face))))
                          (when (string-match ":background \"\\(#[0-9a-fA-F]\\{6\\}\\)\"" s)
                            (match-string 1 s)))))
               (slash-bg (funcall bg-of slash-pos))
               (cap-bg (funcall bg-of cap-pos)))
          (should cap-bg)
          (should-not (equal slash-bg cap-bg)))))))

(ert-deftest etaf-md-tests-interactive-cognitive-widgets-state-and-actions ()
  "Sortable table, paired diff, pros-cons, demo source toggle and collapsible file-tree update cleanly."
  (let* ((doc (concat
               ":::table {title=\"Bench\" sortable=true}\n"
               "| Name | Score |\n| --- | --- |\n| Zebra | 10 |\n| Alpha | 30 |\n| Beta | 20 |\n"
               ":::\n\n"
               ":::diff {title=\"Patch\" mode=side}\n"
               "@before Old\n```elisp\n(setq x 1)\n```\n"
               "@after New\n```elisp\n(setq x 2)\n```\n"
               ":::\n\n"
               ":::pros-cons\n@pro Good\nFast.\n@con Bad\nComplex.\n:::\n\n"
               ":::demo {title=\"Live Demo\"}\n**Rendered Bold**\n:::\n\n"
               ":::file-tree {title=\"Tree\" collapsible=true}\n- src/\n  - main.el\n:::\n"))
         (session (etaf-md-create :text doc :theme 'dark))
         (buf (etaf-md-open session)))
    (unwind-protect
        (with-current-buffer buf
          ;; 1. Sortable table: click Name header sorts ascending (Alpha before Zebra).
          (goto-char (point-min))
          (should (search-forward "Name ⇅" nil t))
          (goto-char (match-beginning 0))
          (call-interactively (key-binding (kbd "RET")))
          (let ((txt (buffer-substring-no-properties (point-min) (point-max))))
            (should (< (string-match "Alpha" txt) (string-match "Zebra" txt))))
          ;; 2. Diff paired split puts old & new on the same line, and toggles cleanly to unified.
          (let ((split-txt (buffer-substring-no-properties (point-min) (point-max))))
            (should (string-match-p "(setq x 1).*?(setq x 2)" split-txt)))
          (goto-char (point-min))
          (should (search-forward "统一" nil t))
          (goto-char (match-beginning 0))
          (call-interactively (key-binding (kbd "RET")))
          (should (string-match-p "(setq x 2)"
                                  (buffer-substring-no-properties (point-min) (point-max))))
          ;; 3. Pros-cons paints both columns cleanly.
          (let ((pc-txt (buffer-substring-no-properties (point-min) (point-max))))
            (should (string-match-p "✓ Good" pc-txt))
            (should (string-match-p "× Bad" pc-txt)))
          ;; 4. Demo toggle shows raw markdown source.
          (goto-char (point-min))
          (should (search-forward "查看源码" nil t))
          (goto-char (match-beginning 0))
          (call-interactively (key-binding (kbd "RET")))
          (should (string-match-p "\\*\\*Rendered Bold\\*\\*"
                                  (buffer-substring-no-properties (point-min) (point-max))))
          ;; 5. File-tree collapsible directory hides child on click.
          (should (string-match-p "main\\.el"
                                  (buffer-substring-no-properties (point-min) (point-max))))
          (goto-char (point-min))
          (should (search-forward "▾ src/" nil t))
          (goto-char (match-beginning 0))
          (call-interactively (key-binding (kbd "RET")))
          (should-not (string-match-p "main\\.el"
                                      (buffer-substring-no-properties (point-min) (point-max)))))
      (when (buffer-live-p buf)
        (with-current-buffer buf (etaf-md-close))))))

(ert-deftest etaf-md-tests-inline-extensions-spoilers-annotations-and-tasks ()
  "Spoilers, inline annotations, collapsible alerts, collapsed code and interactive GFM tasks work end-to-end."
  (let* ((doc (concat
               "Reveal !!top secret!! and read [+note].\n\n"
               "[+note]: Detailed inline note body.\n\n"
               "> [!tip]- Hidden Tip\n> Alert secret body.\n\n"
               "```elisp :collapsed-lines=2\n"
               "(setq a 1)\n(setq b 2)\n(setq c 3)\n(setq d 4)\n"
               "```\n\n"
               "- [x] Done task\n"
               "- [ ] Pending task\n"))
         (session (etaf-md-create :text doc :theme 'light))
         (buf (etaf-md-open session)))
    (unwind-protect
        (with-current-buffer buf
          (let ((init (buffer-substring-no-properties (point-min) (point-max))))
            (should-not (string-match-p "top secret" init))
            (should-not (string-match-p "Detailed inline note body" init))
            (should-not (string-match-p "Alert secret body" init))
            (should-not (string-match-p "(setq d 4)" init))
            (should (string-match-p "□" init)))
          ;; Global spoiler toggle reveals spoiler and hides it again.
          (should (eq t (etaf-md-toggle-spoilers)))
          (etaf-runtime-flush (etaf-runtime-for-buffer buf))
          (should (string-match-p "top secret"
                                  (buffer-substring-no-properties (point-min) (point-max))))
          (should-not (etaf-md-toggle-spoilers))
          ;; Expand annotation card.
          (goto-char (point-min))
          (should (search-forward "[+note]" nil t))
          (goto-char (match-beginning 0))
          (call-interactively (key-binding (kbd "RET")))
          (should (string-match-p "Detailed inline note body"
                                  (buffer-substring-no-properties (point-min) (point-max))))
          ;; Expand collapsible alert.
          (goto-char (point-min))
          (should (search-forward "Hidden Tip" nil t))
          (goto-char (match-beginning 0))
          (call-interactively (key-binding (kbd "RET")))
          (should (string-match-p "Alert secret body"
                                  (buffer-substring-no-properties (point-min) (point-max))))
          ;; Expand collapsed code block.
          (goto-char (point-min))
          (should (search-forward "展开剩余 2 行" nil t))
          (goto-char (match-beginning 0))
          (call-interactively (key-binding (kbd "RET")))
          (should (string-match-p "(setq d 4)"
                                  (buffer-substring-no-properties (point-min) (point-max))))
          ;; Toggle pending GFM task item -> unchecked □ disappears.
          (goto-char (point-min))
          (should (search-forward "□" nil t))
          (goto-char (match-beginning 0))
          (call-interactively (key-binding (kbd "RET")))
          (etaf-runtime-flush (etaf-runtime-for-buffer buf))
          (should-not (string-match-p "□"
                                      (buffer-substring-no-properties (point-min) (point-max)))))
      (when (buffer-live-p buf)
        (with-current-buffer buf (etaf-md-close))))))

(ert-deftest etaf-md-tests-workspace-l1-widgets-and-path-sandbox ()
  "L1 workspace widgets read bounded local assets (including full Elisp forms) while rejecting path traversal."
  (let* ((root (make-temp-file "etaf-md-ws-" t))
         (sub (expand-file-name "sub" root))
         (src-el (expand-file-name "sample.el" sub))
         (doc-file (expand-file-name "index.md" root)))
    (unwind-protect
        (progn
          (make-directory sub t)
          (with-temp-file src-el
            (insert ";; #region greet\n(defun sample-greet (x)\n  \"Greet X.\"\n  (let ((msg (format \"hi %s\" x)))\n    msg))\n;; #endregion\n"))
          (with-temp-file doc-file
            (insert (concat
                     ":::include {src=\"sub/sample.el\" region=\"greet\"}\n:::\n\n"
                     ":::code-ref {src=\"sub/sample.el\" symbol=\"sample-greet\"}\n:::\n\n"
                     ":::symbol {name=\"etaf-md-open\"}\n:::\n\n"
                     ":::project-tree {path=\".\" depth=2}\n:::\n\n"
                     ":::include {src=\"../../etc/passwd\"}\n:::\n")))
          (let ((session (etaf-md-create :file doc-file :theme 'dark)))
            (etaf-md-tests--with-mount session
              (let ((txt (buffer-substring-no-properties (point-min) (point-max))))
                (should (string-match-p "sample-greet" txt))
                ;; Full balanced Elisp sexp must include the closing body line.
                (should (string-match-p "msg))" txt))
                (should (string-match-p "L2–L5" txt))
                (should (string-match-p "ƒ etaf-md-open" txt))
                (should (string-match-p "sample\\.el" txt))
                (should (string-match-p "超出工作区范围" txt)))))
          ;; Disabling etaf-md-allow-local-read blocks local reads cleanly.
          (let* ((etaf-md-allow-local-read nil)
                 (session (etaf-md-create :file doc-file :theme 'dark)))
            (etaf-md-tests--with-mount session
              (let ((txt (buffer-substring-no-properties (point-min) (point-max))))
                (should (string-match-p "本地文件读取已禁用" txt))))))
      (delete-directory root t))))

(ert-deftest etaf-md-tests-executable-l2-widgets-respect-trust-gate ()
  "Executable `run' Runbook never auto-runs and honors `etaf-md-allow-actions'."
  (let* ((doc ":::run {title=\"Echo Test\"}\n```sh\necho $((6 * 7))\n```\n:::\n")
         (etaf-md-allow-actions nil)
         (session (etaf-md-create :text doc :theme 'dark))
         (buf (etaf-md-open session)))
    (unwind-protect
        (with-current-buffer buf
          ;; Opening never ran the command.
          (should-not (string-match-p "\\b42\\b"
                                      (buffer-substring-no-properties (point-min) (point-max))))
          ;; With etaf-md-allow-actions nil, pressing Run does not execute.
          (goto-char (point-min))
          (should (search-forward "▶ 运行" nil t))
          (goto-char (match-beginning 0))
          (call-interactively (key-binding (kbd "RET")))
          (sit-for 0.15)
          (should-not (string-match-p "\\b42\\b"
                                      (buffer-substring-no-properties (point-min) (point-max))))
          ;; Explicitly enabling etaf-md-allow-actions t lets Run execute and show output.
          (let ((etaf-md-allow-actions t))
            (goto-char (point-min))
            (should (search-forward "▶ 运行" nil t))
            (goto-char (match-beginning 0))
            (call-interactively (key-binding (kbd "RET")))
            (let ((deadline (+ (float-time) 3.0)))
              (while (and (< (float-time) deadline)
                          (not (string-match-p "\\b42\\b"
                                               (buffer-substring-no-properties (point-min) (point-max)))))
                (accept-process-output nil 0.05)
                (etaf-runtime-flush (etaf-runtime-for-buffer buf))))
            (should (string-match-p "\\b42\\b"
                                    (buffer-substring-no-properties (point-min) (point-max))))))
      (when (buffer-live-p buf)
        (with-current-buffer buf (etaf-md-close))))))

(ert-deftest etaf-md-tests-toc-panel-link-preview-and-media-lightbox ()
  "Independent configurable TOC side window (`etaf-md-toggle-toc'), floating `K' peek dialog and media lightbox work cleanly."
  (let* ((img (etaf-md-tests--fixture "wide-400x100.png"))
         (filler (mapconcat (lambda (i) (format "Paragraph filler line %d with enough text to scroll.\n" i))
                            (number-sequence 1 18) "\n"))
         (doc (format (concat "# Main\n\nInspect :sym[etaf-md-open] and jump to [Target](#target).\n\n"
                              "![Banner](%s)\n\n"
                              "## Alpha\n\n%s\n## Beta\n\n%s\n## Target\n\nReached target.\n")
                      img filler filler))
         (etaf-md-media-lightbox t)
         (etaf-md-toc-side 'left)
         (etaf-md-toc-width 28)
         (session (etaf-md-create :text doc :theme 'dark))
         (buf (etaf-md-open session)))
    (unwind-protect
        (with-current-buffer buf
          (let* ((rt (etaf-runtime-for-buffer buf))
                 (win-count (length (window-list)))
                 (find-outline
                  (lambda ()
                    (cl-find-if (lambda (b)
                                  (string-prefix-p "*ETAF Outline*" (buffer-name b)))
                                (buffer-list)))))
            ;; 1. Toggle independent TOC side window on (default left).
            (should (eq t (etaf-md-toggle-toc)))
            (let* ((obuf (funcall find-outline))
                   (owin (and obuf (get-buffer-window obuf t))))
              (should (buffer-live-p obuf))
              (should (window-live-p owin))
              (should (eq 'left (window-parameter owin 'window-side)))
              (should (= (1+ win-count) (length (window-list))))
              (with-current-buffer obuf
                (let ((txt (buffer-substring-no-properties (point-min) (point-max))))
                  (should (string-match-p "目录" txt))
                  (should (string-match-p "Alpha" txt))
                  (should (string-match-p "Target" txt))))
              ;; Clicking distinct TOC items jumps preview point to distinct positions.
              (let ((click-toc
                     (lambda (label)
                       (with-current-buffer obuf
                         (let ((ort (etaf-runtime-for-buffer obuf)))
                           (goto-char (point-min))
                           (should (search-forward label nil t))
                           (goto-char (match-beginning 0))
                           (let ((on-press (plist-get (etaf-runtime-host-props-for
                                                       ort (etaf-host-ref-at ort (point)))
                                                      :on-press)))
                             (if (functionp on-press)
                                 (funcall on-press)
                               (etaf-activate ort)))))
                       (with-current-buffer buf (point)))))
                (let ((pos-beta (funcall click-toc "Beta"))
                      (pos-target (funcall click-toc "Target"))
                      (pos-alpha (funcall click-toc "Alpha")))
                  (should (> pos-target pos-beta))
                  (should (> pos-beta pos-alpha)))))
            ;; `n'/`p' heading navigation keeps working with side window open.
            (let ((before (point)))
              (etaf-md-next-heading)
              (should (> (point) before))
              (etaf-md-previous-heading)
              (should (= (point) before)))
            ;; Right-side placement honors `etaf-md-toc-side'.
            (let ((etaf-md-toc-side 'right))
              (should-not (etaf-md-toggle-toc))
              (should-not (funcall find-outline))
              (should (eq t (etaf-md-toggle-toc)))
              (let* ((obuf (funcall find-outline))
                     (owin (and obuf (get-buffer-window obuf t))))
                (should (buffer-live-p obuf))
                (should (eq 'right (window-parameter owin 'window-side)))))
            ;; Close TOC cleanly and restore window count.
            (should-not (etaf-md-toggle-toc))
            (should-not (funcall find-outline))
            (should (= win-count (length (window-list))))
            ;; 2. Preview Emacs symbol at point with floating `K' dialog; 2nd `K' dismisses.
            (goto-char (point-min))
            (should (search-forward "etaf-md-open" nil t))
            (goto-char (match-beginning 0))
            (let ((info (etaf-md-preview-link)))
              (should info)
              (should (equal (plist-get info :title) "ƒ etaf-md-open")))
            (etaf-runtime-flush rt)
            (should (string-match-p "交互命令"
                                    (buffer-substring-no-properties (point-min) (point-max))))
            (should-not (etaf-md-preview-link))
            (etaf-runtime-flush rt)
            (should-not (string-match-p "交互命令"
                                        (buffer-substring-no-properties (point-min) (point-max))))
            ;; 3. Activate local image -> opens in-buffer media lightbox, close via `q'.
            (goto-char (point-min))
            (should (search-forward "▀" nil t))
            (goto-char (match-beginning 0))
            (call-interactively (key-binding (kbd "RET")))
            (etaf-runtime-flush rt)
            (should (string-match-p "Banner"
                                    (buffer-substring-no-properties (point-min) (point-max))))
            (execute-kbd-macro (kbd "q"))
            (etaf-runtime-flush rt)
            (should (buffer-live-p buf))))
      (when (buffer-live-p buf)
        (with-current-buffer buf (etaf-md-close))))))

(ert-deftest etaf-md-tests-hover-discipline-across-themes-and-widgets ()
  "Hover faces attach strictly to unselected interactive leaves across dark, light and sepia themes."
  (let ((doc (concat
              "PlainProse with [DocLink](https://example.com), [[WikiTarget|WikiAlias]], "
              ":sym[car], !!HiddenWord!!, [+tipnote], :color[#4493f8], "
              ":badge[StaticBadge]{.tip}.\n\n"
              "[+tipnote]: Note detail.\n\n"
              ":::note {title=\"FoldNote\" collapsible=true open=true}\nCalloutBodyText.\n:::\n\n"
              "```elisp :collapsed-lines=2\n(defun alpha-code () 1)\n(defun beta-code () 2)\n(defun gamma-code () 3)\n```\n\n"
              ":::tabs\n@tab ActiveTabLabel\nTabBodyProse.\n@tab IdleTabLabel\nSecond.\n:::\n\n"
              ":::table {title=\"Grid\" sortable=true copy=true}\n"
              "| ColHead | ValHead |\n| --- | --- |\n| CellDataOne | 42 |\n:::\n\n"
              ":::link-card {href=\"https://example.com\" title=\"CardTitleText\" description=\"CardDescText\"}\n:::\n\n"
              ":::code-tree\n@file a.el\n```elisp\n(setq first 1)\n```\n@file b.el\n```elisp\n(setq second 2)\n```\n:::\n\n"
              ":::diff {title=\"DiffCard\" mode=side}\n@before\n```text\nold-line\n```\n@after\n```text\nnew-line\n```\n:::\n\n"
              "- [ ] CheckItemText\n")))
    (dolist (theme '(dark light sepia))
      (let ((session (etaf-md-create :text doc :theme theme)))
        (etaf-md-tests--with-mount session
          (let ((plain (buffer-substring-no-properties (point-min) (point-max))))
            ;; Tier 3: Unselected interactive leaves MUST carry mouse-face and pointer 'hand.
            (dolist (needle '("DocLink" "WikiAlias" "car" "░" "[+tipnote]"
                              "FoldNote" "复制" "展开剩余 1 行" "IdleTabLabel"
                              "ColHead ⇅" "复制表格" "→ https://example.com"
                              "b.el" "统一" "□"))
              (let ((pos (string-match (regexp-quote needle) plain)))
                (should pos)
                (let* ((bufpos (1+ pos))
                       (mf (get-text-property bufpos 'mouse-face))
                       (ptr (get-text-property bufpos 'pointer)))
                  (should mf)
                  (should (eq ptr 'hand)))))
            ;; Tier 2: Selected/active controls MUST NOT carry mouse-face (no state stacking).
            (dolist (needle '("ActiveTabLabel" "a.el" "并排"))
              (let ((pos (string-match (regexp-quote needle) plain)))
                (should pos)
                (should-not (get-text-property (1+ pos) 'mouse-face))))
            ;; Tier 1 & Tier 4 container bodies: static text, code lines, data cells,
            ;; card titles/descriptions and callout bodies MUST NOT carry mouse-face.
            (dolist (needle '("PlainProse" "#4493f8" "StaticBadge"
                              "CalloutBodyText" "alpha-code" "TabBodyProse"
                              "CellDataOne" "CardTitleText" "CardDescText"
                              "old-line" "CheckItemText"))
              (let ((pos (string-match (regexp-quote needle) plain)))
                (should pos)
                (should-not (get-text-property (1+ pos) 'mouse-face))))))))
    ;; Disabling :link-hover removes mouse-face while keeping pointer 'hand.
    (let ((session (etaf-md-create :text doc :theme 'dark :link-hover nil)))
      (etaf-md-tests--with-mount session
        (let* ((plain (buffer-substring-no-properties (point-min) (point-max)))
               (pos (1+ (string-match "DocLink" plain))))
          (should-not (get-text-property pos 'mouse-face))
          (should (eq 'hand (get-text-property pos 'pointer))))))))

(defun etaf-md-tests--visual-x (pos)
  "Return the horizontal layout offset in cells from line start to POS.
Accounts for Ebox `(space :width (N))' spacer properties used in flex and
centered layouts."
  (save-excursion
    (goto-char pos)
    (let ((p (line-beginning-position))
          (cw (max 1 (frame-char-width)))
          (x 0))
      (while (< p pos)
        (let* ((disp (get-text-property p 'display))
               (w (and (consp disp) (eq (car disp) 'space)
                       (plist-get (cdr disp) :width))))
          (cond
           ((and (consp w) (numberp (car w)))
            (setq x (+ x (/ (float (car w)) cw))))
           ((numberp w)
            (setq x (+ x w)))
           (t
            (setq x (+ x (char-width (char-after p)))))))
        (setq p (1+ p)))
      (round x))))

(ert-deftest etaf-md-tests-card-accents-box-surfaces-and-theme-tokens ()
  "Card semantic accents, card centered body, distinct box surfaces and valid 6-digit theme tokens hold across themes."
  (let ((doc (concat
              ":::box {surface=page}\nSURF_PAGE\n:::\n\n"
              ":::box {surface=raised}\nSURF_RAISED\n:::\n\n"
              ":::box {surface=sunken}\nSURF_SUNKEN\n:::\n\n"
              ":::box {surface=table-header}\nSURF_THDR\n:::\n\n"
              ":::card {title=\"CARD_NEUTRAL\" accent=\"neutral\"}\nBody.\n:::\n\n"
              ":::card {title=\"CARD_PRIMARY\" accent=\"primary\"}\nBody.\n:::\n\n"
              ":::card {title=\"CARD_SUCCESS\" accent=\"success\"}\nBody.\n:::\n\n"
              ":::card {title=\"CARD_WARNING\" accent=\"warning\"}\nBody.\n:::\n\n"
              ":::card {title=\"CARD_DANGER\" accent=\"danger\"}\nBody.\n:::\n\n"
              ":::card {title=\"CARD_IMPORTANT\" accent=\"important\"}\nBody.\n:::\n\n"
              ":::card {title=\"CENTER_TITLE\" width=\"40ch\" text-align=\"center\"}\nCENTER_BODY\n:::\n")))
    (dolist (theme '(dark light sepia))
      ;; Every color in `etaf-md-theme-tokens' must be a valid 6-digit #RRGGBB hex string.
      (let ((tokens (etaf-md-theme-tokens theme)))
        (cl-loop for (_k v) on tokens by #'cddr do
                 (when (stringp v)
                   (should (string-match-p "\\`#[0-9a-fA-F]\\{6\\}\\'" v)))))
      (let ((session (etaf-md-create :text doc :theme theme)))
        (etaf-md-tests--with-mount session
          (let* ((plain (buffer-substring-no-properties (point-min) (point-max)))
                 (fg-at (lambda (needle)
                          (let* ((pos (1+ (string-match (regexp-quote needle) plain)))
                                 (face (format "%S" (get-text-property pos 'face))))
                            (when (string-match ":foreground \"\\(#[0-9a-fA-F]\\{6\\}\\)\"" face)
                              (match-string 1 face)))))
                 (bg-at (lambda (needle)
                          (let* ((pos (1+ (string-match (regexp-quote needle) plain)))
                                 (face (format "%S" (get-text-property pos 'face))))
                            (when (string-match ":background \"\\(#[0-9a-fA-F]\\{6\\}\\)\"" face)
                              (match-string 1 face)))))
                 (card-fgs (mapcar fg-at '("CARD_NEUTRAL" "CARD_PRIMARY" "CARD_SUCCESS"
                                           "CARD_WARNING" "CARD_DANGER" "CARD_IMPORTANT")))
                 (bg-page (funcall bg-at "SURF_PAGE"))
                 (bg-raised (funcall bg-at "SURF_RAISED"))
                 (bg-sunken (funcall bg-at "SURF_SUNKEN"))
                 (bg-thdr (funcall bg-at "SURF_THDR")))
            ;; All 6 card accents must paint distinct title foreground colors.
            (should (= 6 (length (delete-dups (copy-sequence card-fgs)))))
            ;; Surfaces must be distinct (page vs raised vs sunken vs table-header).
            (should-not (equal bg-page bg-raised))
            (should-not (equal bg-page bg-sunken))
            (should-not (equal bg-raised bg-sunken))
            (should-not (equal bg-raised bg-thdr))
            ;; In dark theme, sunken must be strictly darker than page, and raised lighter.
            (when (eq theme 'dark)
              (let ((hex-sum (lambda (h)
                               (+ (string-to-number (substring h 1 3) 16)
                                  (string-to-number (substring h 3 5) 16)
                                  (string-to-number (substring h 5 7) 16)))))
                (should (< (funcall hex-sum bg-sunken) (funcall hex-sum bg-page)))
                (should (> (funcall hex-sum bg-raised) (funcall hex-sum bg-page)))))
            ;; Centered card must visually align its body near its centered title.
            (let ((title-x (etaf-md-tests--visual-x (1+ (string-match "CENTER_TITLE" plain))))
                  (body-x (etaf-md-tests--visual-x (1+ (string-match "CENTER_BODY" plain)))))
              (should (> body-x 10))
              (should (<= (abs (- title-x body-x)) 2)))))))))

(ert-deftest etaf-md-tests-columns-table-filetree-and-npmto-contracts ()
  "Columns grow/justify/wrap, table center alignment, file-tree lines=false & bold focus, and npm-to && spacing work."
  (let* ((doc (concat
               ":::columns {columns=2 justify-content=between divider=false}\n"
               ":::col\nJUST_LEFT\n:::\n"
               ":::col\nJUST_RIGHT\n:::\n:::\n\n"
               ":::table {align=center}\n| K | V |\n| --- | --- |\n| A | 1 |\n:::\n\n"
               ":::file-tree {lines=false}\n- root/\n  - leaf.el\n:::\n\n"
               ":::file-tree\n- **focus.el** # important file\n:::\n\n"
               ":::npm-to {tabs=\"pnpm\"}\n```sh\nnpm install vue && npm run build\n```\n:::\n"))
         (session (etaf-md-create :text doc :theme 'dark)))
    (etaf-md-tests--with-mount session
      (let ((plain (buffer-substring-no-properties (point-min) (point-max))))
        ;; 1. justify-content=between pushes JUST_RIGHT near right edge (> 50 visual cells past JUST_LEFT).
        (let ((col-l (etaf-md-tests--visual-x (1+ (string-match "JUST_LEFT" plain))))
              (col-r (etaf-md-tests--visual-x (1+ (string-match "JUST_RIGHT" plain)))))
          (should (> (- col-r col-l) 50)))
        ;; 2. align=center table shifts visually away from left margin.
        (let ((tcol (etaf-md-tests--visual-x (1+ (string-match "K" plain))))
              (lcol (etaf-md-tests--visual-x (1+ (string-match "JUST_LEFT" plain)))))
          (should (> tcol (+ lcol 15))))
        ;; 3. file-tree lines=false omits box-drawing tree chars inside the box on leaf.el.
        (let* ((rline (save-excursion
                        (goto-char (1+ (string-match "leaf\\.el" plain)))
                        (buffer-substring-no-properties
                         (line-beginning-position) (line-end-position)))))
          (should-not (string-match-p "[├└]" rline))
          (should-not (string-match-p "│.*│.*leaf\\.el" rline)))
        ;; 4. file-tree **focus.el** # important file strips ** and applies bold weight.
        (let* ((fpos (1+ (string-match "focus\\.el" plain)))
               (fface (format "%S" (get-text-property fpos 'face))))
          (should-not (string-match-p "\\*\\*focus\\.el\\*\\*" plain))
          (should (string-match-p "bold" fface)))
        ;; 5. npm-to preserves spaces around &&.
        (should (string-match-p "pnpm add vue && pnpm build" plain))))))

(ert-deftest etaf-md-tests-command-surface-and-toggle-split ()
  "Two-tier M-x surface keeps strictly `etaf-md-open' and `etaf-md-preview' globally visible, scopes preview commands to preview buffers, uses single-key defaults with zero prefix keys in `etaf-md-keys', and toggles split cleanly."
  (let* ((file (make-temp-file "etaf-md-cmd-" nil ".md"))
         (source nil)
         (preview nil)
         (global-cmds nil))
    (unwind-protect
        (progn
          (with-temp-file file (insert "# Single Window\n\nBody paragraph.\n"))
          ;; 1. Outside preview buffers, strictly `etaf-md-open' and `etaf-md-preview'
          ;;    pass `command-completion-default-include-p' (zero global M-x clutter).
          (with-temp-buffer
            (mapatoms (lambda (sym)
                        (when (and (string-prefix-p "etaf-md-" (symbol-name sym))
                                   (not (string-prefix-p "etaf-md-tests-" (symbol-name sym)))
                                   (fboundp sym)
                                   (commandp sym)
                                   (command-completion-default-include-p sym (current-buffer)))
                          (push sym global-cmds)))))
          (should (equal (sort global-cmds
                               (lambda (a b) (string< (symbol-name a) (symbol-name b))))
                         '(etaf-md-open etaf-md-preview)))
          ;; Default `etaf-md-keys' uses single keys only (zero C-c / C-t / C-x prefix keys).
          (dolist (binding etaf-md-keys)
            (should-not (string-match-p "\\`C-" (car binding))))
          ;; 2. Inside a preview buffer, preview actions are interactive M-x commands
          ;;    AND their single-key bindings dispatch cleanly.
          (setq source (find-file-noselect file))
          (delete-other-windows)
          (switch-to-buffer source)
          (setq preview (etaf-md-open file))
          (should (= 1 (length (window-list))))
          (with-current-buffer preview
            (dolist (cmd '(etaf-md-toggle-toc etaf-md-goto-heading etaf-md-preview-link
                           etaf-md-toggle-split etaf-md-cycle-theme etaf-md-close))
              (should (commandp cmd))
              (should (command-completion-default-include-p cmd preview)))
            (let ((before (plist-get (etaf-md-state (etaf-app-state)) :theme)))
              (call-interactively (key-binding (kbd "t")))
              (let ((after (plist-get (etaf-md-state (etaf-app-state)) :theme)))
                (should (memq after '(dark light sepia)))
                (ignore before)))
            ;; Toggle split ON via `v' -> 2 windows (source left, preview right).
            (call-interactively (key-binding (kbd "v")))
            (should (= 2 (length (window-list))))
            ;; Toggle split OFF via `v' -> back to 1 full-width preview window.
            (call-interactively (key-binding (kbd "v")))
            (should (= 1 (length (window-list))))
            (should (eq (window-buffer (selected-window)) preview))
            ;; Closing single-window preview via `q' restores source without deleting the window.
            (call-interactively (key-binding (kbd "q")))
            (should (= 1 (length (window-list))))
            (should (eq (window-buffer (selected-window)) source))))
      (when (buffer-live-p preview)
        (with-current-buffer preview (ignore-errors (etaf-md-close))))
      (when (buffer-live-p source) (kill-buffer source))
      (delete-file file))))

(ert-deftest etaf-md-tests-footnotes-keep-compact-gap-after-body ()
  "Many trailing footnote definitions do not stack blank lines before the footnote divider."
  (let* ((refs (mapconcat (lambda (i) (format "[^%d]" i))
                          (number-sequence 1 12) ""))
         (defs (mapconcat (lambda (i) (format "[^%d]: 脚注条目 %d" i i))
                          (number-sequence 1 12) "\n\n"))
         (text (format "正文结尾段落%s。\n\n%s\n" refs defs))
         (gap (etaf-md-tests--gap text "正文结尾段落" "脚注")))
    (should (= gap 1))))

(defun etaf-md-tests--wait-until (pred timeout)
  "Pump Emacs timers and process output until PRED returns non-nil or TIMEOUT."
  (let ((deadline (+ (float-time) timeout)))
    (while (and (not (funcall pred)) (< (float-time) deadline))
      (accept-process-output nil 0.02)
      (sleep-for 0.02))
    (funcall pred)))

(ert-deftest etaf-md-tests-native-typeset-renders-mermaid-and-math-to-svg ()
  "When the native QuickJS module is built, Mermaid diagrams (including flowchart TB with subgraph/classDef) and `$$' display formulas render to SVGs in both dark and light themes."
  (let* ((native-entry (assoc "typeset-native" (plist-get (etaf-md-doctor) :optional)))
         (native-ok (cadr native-entry)))
    (skip-unless native-ok)
    (should (etaf-md-typeset-available-p))
    (let* ((text (concat
                  "# Diagram & Math\n\n"
                  "```mermaid\n"
                  "flowchart TB\n"
                  "  start([收到请求]) --> cache{缓存命中?}\n"
                  "  cache -->|是| draw[(读取图片)]\n"
                  "  subgraph 缓存层\n"
                  "    cache\n"
                  "    draw\n"
                  "  end\n"
                  "  classDef hit fill:#1f6feb,stroke:#1f6feb,color:#ffffff\n"
                  "  class cache,draw hit\n"
                  "```\n\n"
                  "$$\n"
                  "\\text{行高} = \\sum_{i=1}^{n} i\n"
                  "$$\n"))
           (session (etaf-md-create :text text :theme 'dark))
           (buffer (etaf-md-open session)))
      (unwind-protect
          (progn
            (should (etaf-md-tests--wait-until
                     (lambda ()
                       (with-current-buffer buffer
                         (let ((content (buffer-substring-no-properties (point-min) (point-max))))
                           (and (string-match-p "▲ mermaid" content)
                                (not (string-match-p "classDef hit" content))
                                (not (string-match-p "∑" content))))))
                     5.0))
            (etaf-md-set-theme session 'light)
            (should (etaf-md-tests--wait-until
                     (lambda ()
                       (with-current-buffer buffer
                         (let ((content (buffer-substring-no-properties (point-min) (point-max))))
                           (and (string-match-p "▲ mermaid" content)
                                (not (string-match-p "classDef hit" content))))))
                     5.0)))
        (when (buffer-live-p buffer)
          (with-current-buffer buffer (ignore-errors (etaf-md-close))))))))

(ert-deftest etaf-md-tests-native-typeset-keeps-valid-picture-on-incomplete-live-edit ()
  "While live-editing a rendered Mermaid block into transiently invalid syntax, the preview retains the last valid diagram instead of flashing back to raw code."
  (let* ((native-entry (assoc "typeset-native" (plist-get (etaf-md-doctor) :optional)))
         (native-ok (cadr native-entry)))
    (skip-unless native-ok)
    (let* ((file (make-temp-file "etaf-md-swr-" nil ".md"))
           (source nil)
           (preview nil))
      (unwind-protect
          (progn
            (with-temp-file file
              (insert "# Live Diagram\n\n```mermaid\nflowchart LR\n  A[起点] --> B[终点]\n```\n"))
            (setq source (find-file-noselect file))
            (setq preview (etaf-md-open file))
            (should (etaf-md-tests--wait-until
                     (lambda ()
                       (with-current-buffer preview
                         (let ((content (buffer-substring-no-properties (point-min) (point-max))))
                           (and (string-match-p "▲ mermaid" content)
                                (not (string-match-p "flowchart LR" content))))))
                     5.0))
            ;; Break Mermaid syntax mid-edit in the source buffer.
            (with-current-buffer source
              (goto-char (point-min))
              (re-search-forward "B\\[终点\\]")
              (replace-match "" t t))
            ;; Pump live-edit tick and background render; previous valid diagram stays visible.
            (etaf-md-tests--wait-until (lambda () nil) 0.35)
            (with-current-buffer preview
              (let ((content (buffer-substring-no-properties (point-min) (point-max))))
                (should (string-match-p "▲ mermaid" content))
                (should-not (string-match-p "flowchart LR" content)))))
        (when (buffer-live-p preview)
          (with-current-buffer preview (ignore-errors (etaf-md-close))))
        (when (buffer-live-p source)
          (with-current-buffer source (set-buffer-modified-p nil))
          (kill-buffer source))
        (delete-file file)))))

(ert-deftest etaf-md-tests-table-vertical-borders-and-tall-diagram-sizing ()
  "`:::table' restores vertical grid borders across all columns, and tall portrait Mermaid diagrams keep native scale instead of being crushed to 20 rows and open the lightbox on activation."
  ;; 1. `:::table' renders outer and inner vertical borders (`│').
  (let* ((table-md (concat ":::table {title=\"耗时\"}\n"
                           "| 版本 | 耗时 | 内存 |\n"
                           "| --- | --- | --- |\n"
                           "| 0.1.9 | 5.4 s | 380 MB |\n"
                           ":::\n"))
         (session (etaf-md-create :text table-md :theme 'dark)))
    (etaf-md-tests--with-mount session
      (goto-char (point-min))
      (should (search-forward "0.1.9" nil t))
      (let* ((line (buffer-substring-no-properties
                    (line-beginning-position) (line-end-position)))
             (bars (cl-count ?│ line)))
        (should (>= bars 4)))))
  ;; 2. Portrait Mermaid diagram is width-bounded (exceeds the 20-row photo cap)
  ;;    and pressing RET activates the in-buffer media lightbox when enabled.
  (let* ((native-entry (assoc "typeset-native" (plist-get (etaf-md-doctor) :optional)))
         (native-ok (cadr native-entry)))
    (when native-ok
      (let* ((etaf-md-media-lightbox t)
             (tall-mmd (concat "```mermaid\n"
                               "flowchart TB\n"
                               "  a[步骤一] --> b[步骤二]\n"
                               "  b --> c[步骤三]\n"
                               "  c --> d[步骤四]\n"
                               "  d --> e[步骤五]\n"
                               "  e --> f[步骤六]\n"
                               "  f --> g[步骤七]\n"
                               "  g --> h[步骤八]\n"
                               "```\n"))
             (session (etaf-md-create :text tall-mmd :theme 'dark))
             (buffer (etaf-md-open session)))
        (unwind-protect
            (progn
              (should (etaf-md-tests--wait-until
                       (lambda ()
                         (with-current-buffer buffer
                           (string-match-p
                            "▲ mermaid"
                            (buffer-substring-no-properties (point-min) (point-max)))))
                       5.0))
              (with-current-buffer buffer
                (let ((shape (etaf-md-tests--media-grid-shape)))
                  (should shape)
                  ;; Tall 8-step vertical flowchart stays at 1:1 readable scale (> 20 rows).
                  (should (> (cdr shape) 20)))
                ;; Pressing RET on the diagram caption opens the in-buffer lightbox.
                (goto-char (point-min))
                (should (search-forward "▲ mermaid" nil t))
                (goto-char (match-beginning 0))
                (let ((cmd (key-binding (kbd "RET"))))
                  (should cmd)
                  (call-interactively cmd))
                (let ((txt (buffer-substring-no-properties (point-min) (point-max))))
                  (should (string-match-p "mermaid[ \t]+✕" txt)))))
          (when (buffer-live-p buffer)
            (with-current-buffer buffer (ignore-errors (etaf-md-close)))))))))

(ert-deftest etaf-md-tests-wide-table-adapts-across-viewport-widths ()
  "A wide 8-column table breaks out on wide screens and never clips on resize.
Prose stays within the centered reading measure while the wide table expands up
to the available viewport minus side gutters, compresses into a full-column
grid on medium viewports, and folds into stacked cards on narrow viewports."
  (let* ((md (concat
              "前文段落保持舒适的阅读列宽，不会因为宽表格而拉满整屏。\n\n"
              "| 标准 | 方法论 (BEM/SMACSS) | 预处理器 (Sass) | CSS 模块 | 运行时 CSS-in-JS | 编译时 CSS-in-JS | 实用工具优先 (Tailwind) | 现代原生 CSS |\n"
              "| --- | --- | --- | --- | --- | --- | --- | --- |\n"
              "| 作用域机制 | 手动命名约定 | 无 (全局) | 构建时哈希化类名 | JS闭包/运行时生成 | 构建时提取/哈希化 | 无 (依赖组合) | @scope |\n"
              "| 最佳适用 | 纪律严明的团队 | 组织中大型CSS | 任何组件化应用 | 高度动态化的UI | 性能敏感的组件化应用 | 快速原型/设计系统 | 简化工具链的项目 |\n"))
         (session (etaf-md-create :text md))
         (char (frame-char-width))
         (margin (* etaf-md-tests--documented-gutter char)))
    (etaf-md-tests--with-mount session
      (let ((rt (etaf-runtime-for-buffer (current-buffer))))
        ;; Wide 170-col viewport: table breaks out wider than 80ch measure with all 8 cols intact.
        (etaf-runtime-refit rt (* 170 char) 60)
        (let* ((txt (buffer-substring-no-properties (point-min) (point-max)))
               (rows (cl-remove-if-not (lambda (l) (string-match-p "│" l))
                                       (split-string txt "\n")))
               (prose-line (cl-find-if (lambda (l) (string-match-p "前文段落" l))
                                       (split-string txt "\n"))))
          (should (string-match-p "@scope" txt))
          (should (string-match-p "现代原生 CSS" txt))
          (should (cl-every (lambda (r) (= 9 (cl-count ?│ r))) rows))
          (should (> (string-width (car rows)) 100))
          ;; Prose stays centered at reading measure with wide displayed margins.
          (should prose-line)
          (goto-char (point-min))
          (search-forward "前文段落")
          (let ((blank (etaf-md-tests--page-margin-pixels)))
            (should (> (car blank) (* 20 char)))))
        ;; Medium 84-col viewport: all 8 columns still fit with full right border and side gutters.
        (etaf-runtime-refit rt (* 84 char) 60)
        (let* ((txt (buffer-substring-no-properties (point-min) (point-max)))
               (rows (cl-remove-if-not (lambda (l) (string-match-p "│" l))
                                       (split-string txt "\n"))))
          (should (string-match-p "@scope" txt))
          (should (cl-every (lambda (r) (= 9 (cl-count ?│ r))) rows))
          (goto-char (point-min))
          (search-forward "@scope")
          (let ((blank (etaf-md-tests--page-margin-pixels)))
            (should (>= (car blank) margin))
            (should (>= (cdr blank) margin))))
        ;; Narrow 46-col viewport: stacked cards keep every column value readable inside gutters.
        (etaf-runtime-refit rt (* 46 char) 60)
        (let ((txt (buffer-substring-no-properties (point-min) (point-max))))
          (should (string-match-p "标准 · 作用域机制" txt))
          (should (string-match-p "@scope" txt))
          (goto-char (point-min))
          (search-forward "@scope")
          (let ((blank (etaf-md-tests--page-margin-pixels)))
            (should (>= (car blank) margin))
            (should (>= (cdr blank) margin))))))))

(ert-deftest etaf-md-tests-doctor-recommends-prebuilt-native-install ()
  "When `typeset-native' is inactive, `etaf-md-doctor' points archive users to `M-x etaf-install-native' rather than an unshipped `make native-build'."
  (let* ((etaf-md-typeset nil)
         (optional (plist-get (etaf-md-doctor) :optional))
         (entry (assoc "typeset-native" optional))
         (remedy (nth 2 entry)))
    (should entry)
    (should-not (cadr entry))
    (should (string-match-p "etaf-install-native" remedy))
    (should-not (string-match-p "make native-build" remedy))))

(ert-deftest etaf-md-tests-accordion-and-details-lifecycle-and-hover-borders ()
  "Details and accordion blocks close open=true/expand=true sections, handle edge cases, and keep borders on hover."
  (let ((doc (concat
              ":::details {title=\"SingleDetails\" open=true}\nSingleDetailsBody.\n:::\n\n"
              ":::accordion\n"
              ":::collapse {title=\"AccOne\" open=true}\nAccOneBody.\n:::\n"
              ":::collapse {title=\"AccTwo\" open=true}\nAccTwoBody.\n:::\n"
              ":::\n\n"
              ":::accordion {expand=true}\n"
              ":::collapse {title=\"ExpOne\"}\nExpOneBody.\n:::\n"
              ":::collapse {title=\"ExpTwo\"}\n:::\n"
              ":::\n\n"
              ":::accordion\n:::\n")))
    (dolist (theme '(dark light sepia))
      (let ((session (etaf-md-create :text doc :theme theme)))
        (etaf-md-tests--with-mount session
          (let ((plain (buffer-substring-no-properties (point-min) (point-max))))
            ;; Multiple open=true under accordion=true clamps to first without error.
            (should (string-match-p "AccOneBody" plain))
            (should-not (string-match-p "AccTwoBody" plain))
            ;; Empty accordion degrades cleanly without throwing.
            (should (string-match-p "空折叠组" plain))
            ;; Hovering top header keeps border overline and paints distinct hover bg.
            (let* ((pos (1+ (string-match "SingleDetails" plain)))
                   (mf (get-text-property pos 'mouse-face))
                   (panel (etaf-md-color :panel theme))
                   (border (etaf-md-color :border theme)))
              (should mf)
              (should (equal (plist-get mf :overline) border))
              (should-not (string-equal-ignore-case (or (plist-get mf :background) "") panel)))
            ;; Clicking an open=true accordion item actually closes it (no sticky re-open).
            (goto-char (point-min))
            (search-forward "AccOne")
            (goto-char (match-beginning 0))
            (call-interactively (key-binding (kbd "RET")))
            (should-not (string-match-p "AccOneBody" (buffer-substring-no-properties (point-min) (point-max))))
            ;; Clicking an expand=true accordion item actually closes it too.
            (goto-char (point-min))
            (search-forward "ExpOne")
            (goto-char (match-beginning 0))
            (call-interactively (key-binding (kbd "RET")))
            (should-not (string-match-p "ExpOneBody" (buffer-substring-no-properties (point-min) (point-max))))))))))

(ert-deftest etaf-md-tests-goto-source-cursor-accuracy ()
  "`etaf-md-goto-source' lands on the exact source line and column after cursor motion or `C-s'/`C-r'.
Covers front matter, inline-formatted words, single-line containers (`:::details',
`:::center'), multi-column tables, repeated code lines and footnotes."
  (let* ((file (make-temp-file "etaf-md-goto-" nil ".md"))
         source preview)
    (unwind-protect
        (progn
          (with-temp-file file
            (insert "---\n"
                    "title: Cursor Jump Guide\n"
                    "author: Alice\n"
                    "---\n\n"
                    "# Section Alpha\n\n"
                    "包含 **粗体词**、`inline-code` 与普通文字[^note1]。\n\n"
                    ":::details {title=\"展开看完整报错\"}\n"
                    "报错详情第一行\n"
                    "报错详情第二行\n"
                    ":::\n\n"
                    ":::center\n"
                    "这一行居中展示。\n"
                    ":::\n\n"
                    "| 列A | 列B | 列C |\n"
                    "| --- | --- | --- |\n"
                    "| alpha | beta-cell | @scope |\n"
                    "| gamma | delta-cell | @layer |\n\n"
                    "```js\n"
                    "return 1;\n"
                    "return 2;\n"
                    "return 3;\n"
                    "return 4;\n"
                    "return 5;\n"
                    "```\n\n"
                    "[^note1]: 这是第一条脚注内容。\n"))
          (setq source (find-file-noselect file))
          (setq preview (with-current-buffer source (etaf-md-open file)))
          (cl-labels
              ((check-jump (needle side expect-line-re expect-looking)
                 (with-current-buffer preview
                   (goto-char (point-min))
                   (should (search-forward needle nil t))
                   (when (eq side 'before)
                     (goto-char (match-beginning 0)))
                   (let ((isearch-string needle)
                         (isearch-case-fold-search t))
                     (let ((pos (etaf-md-goto-source)))
                       (should (eq (current-buffer) source))
                       (should (= (point) pos))
                       (let ((ltxt (buffer-substring-no-properties
                                    (line-beginning-position)
                                    (line-end-position))))
                         (should (string-match-p expect-line-re ltxt)))
                       (when expect-looking
                         (if (eq side 'before)
                             (should (looking-at-p (regexp-quote expect-looking)))
                           (should (looking-back (regexp-quote expect-looking)
                                                 (line-beginning-position))))))))))
            ;; Front matter hero lands on YAML title line, not body text.
            (check-jump "Cursor Jump Guide" 'after "title: Cursor Jump Guide" "Cursor Jump Guide")
            ;; Inline formatted word jumps directly onto the bold word.
            (check-jump "粗体词" 'after "\\*\\*粗体词\\*\\*" "粗体词")
            ;; Single-line `:::details' header lands on opening line, never closing `:::'.
            (check-jump "展开看完整报错" 'after ":::details" "展开看完整报错")
            (check-jump "展开看完整报错" 'before ":::details" "展开看完整报错")
            ;; Single-line `:::center' body lands on the text line, never closing `:::'.
            (check-jump "这一行居中展示" 'after "这一行居中展示" "这一行居中展示")
            ;; Table cell jumps to exact row and column.
            (check-jump "@layer" 'after "| gamma | delta-cell | @layer |" "@layer")
            ;; Repeated token in multiline code block lands on exact line.
            (check-jump "return 4;" 'after "return 4;" "return 4;")
            ;; Footnote body jumps directly to `[^note1]:' definition.
            (check-jump "这是第一条脚注内容" 'after "\\[\\^note1\\]:" "这是第一条脚注内容")))
      (when (buffer-live-p preview)
        (with-current-buffer preview (ignore-errors (etaf-md-close))))
      (when (buffer-live-p source) (kill-buffer source))
      (delete-file file))))

(ert-deftest etaf-md-tests-narrower-shrinks-tables-monotonically ()
  "Narrowing via `etaf-md-adjust-width' shrinks all tables monotonically alongside prose.
Wide multi-column tables still break out automatically on initial open in a wide
viewport, shrink smoothly without reverse jumps once narrowed, fold to cards at
narrow widths, widen smoothly back up, and restore breakout when widened past
`etaf-md-width-max'."
  (let* ((md (concat
              "普通段落文字用来对照阅读栏宽度，确认表格在缩窄时与段落同步收缩。\n\n"
              "| 特性 | CommonMark | GFM | ETAF |\n"
              "| --- | --- | --- | --- |\n"
              "| 表格 | 不支持 | 支持 | 支持对齐与宽表适配 |\n"
              "| 容器 | 不支持 | 不支持 | 支持 details/tabs/accordion |\n\n"
              "| 标准 | 方法论 (BEM/SMACSS) | 预处理器 (Sass) | CSS 模块 | 运行时 CSS-in-JS | 编译时 CSS-in-JS | 实用工具优先 (Tailwind) | 现代原生 CSS |\n"
              "| --- | --- | --- | --- | --- | --- | --- | --- |\n"
              "| 作用域机制 | 手动命名约定 | 无 (全局) | 构建时哈希化类名 | JS闭包/运行时生成 | 构建时提取/哈希化 | 无 (依赖组合) | @scope |\n"))
         (session (etaf-md-create :text md))
         (char (frame-char-width))
         (vw 170))
    (etaf-md-tests--with-mount session
      (let ((rt (etaf-runtime-for-buffer (current-buffer))))
        (cl-labels
            ((line-visual-width (needle)
               (save-excursion
                 (goto-char (point-min))
                 (should (search-forward needle nil t))
                 (let ((blank (etaf-md-tests--page-margin-pixels)))
                   (- (* vw char) (car blank) (cdr blank))))))
          (etaf-runtime-refit rt (* vw char) 60)
          ;; Default open: wide 8-col table breaks out wider than 100 cells.
          (let ((wide-initial (line-visual-width "@scope")))
            (should (> wide-initial (* 100 char)))
            ;; Narrow step by step via negative `etaf-md-adjust-width': both the
            ;; 4-col table and 8-col table must shrink monotonically without
            ;; jumping wider or freezing.
            (let ((prev4 (line-visual-width "特性"))
                  (prev8 wide-initial))
              (dolist (expected-w '(88 80 72 64 56 48 44 40))
                (let ((delta (- expected-w (plist-get (etaf-md-state session) :width))))
                  (when (< delta 0)
                    (etaf-md-adjust-width session delta)))
                (etaf-runtime-flush rt)
                (let ((w4 (line-visual-width "特性"))
                      (w8 (line-visual-width "@scope")))
                  (should (<= w4 prev4))
                  (should (<= w8 prev8))
                  (should (<= w4 (* (+ expected-w 2) char)))
                  (should (<= w8 (* (+ expected-w 2) char)))
                  (setq prev4 w4 prev8 w8)))
              ;; At narrowest 40ch, 8-col table folded cleanly into stacked cards.
              (should (string-match-p
                       "标准 · 作用域机制"
                       (buffer-substring-no-properties (point-min) (point-max))))
              ;; Widening back up to 96 keeps tables in lockstep with reading width.
              (etaf-md-adjust-width session 56)
              (etaf-runtime-flush rt)
              (should (<= (line-visual-width "@scope") (* 98 char)))
              ;; Widening once more past `etaf-md-width-max' restores wide-table breakout.
              (etaf-md-adjust-width session 4)
              (etaf-runtime-flush rt)
              (should (> (line-visual-width "@scope") (* 100 char))))))))))

(ert-deftest etaf-md-tests-resize-preserves-scroll-and-source-alignment ()
  "Width changes and split window resizes preserve reading position and source sync.
Narrowing/widening with `etaf-md-narrower'/`etaf-md-wider' keeps the top block
pinned in single-window reading, and resizing the preview window in side-by-side
follow-scroll mode re-aligns preview `window-start' to the source window's line."
  (let* ((file (make-temp-file "etaf-md-resize-sync-" nil ".md"))
         source preview)
    (unwind-protect
        (progn
          (with-temp-file file
            (insert "# Resize Sync Demo\n\n")
            (dotimes (i 24)
              (insert (format "## 第 %d 节\n\n" i))
              (insert (format "第 %d 节正文内容非常长，用来在缩窄或拉宽预览窗口宽度时触发显著的多行折行变化，检验顶部显示位置不会偏移。\n\n" i))))
          (setq source (find-file-noselect file))
          (delete-other-windows)
          ;; 1. Single-window reading: narrow/widen keeps top heading pinned.
          (setq preview (with-current-buffer source (etaf-md-open file)))
          (let ((win (get-buffer-window preview)))
            (should (window-live-p win))
            (select-window win)
            (with-current-buffer preview
              (goto-char (point-min))
              (should (search-forward "第 16 节" nil t))
              (let ((bol (line-beginning-position)))
                (set-window-start win bol nil)
                (set-window-point win bol))
              ;; Narrow significantly (wrapping all blocks above into more lines).
              (dotimes (_ 10) (etaf-md-narrower))
              (let ((top-text (buffer-substring-no-properties
                               (window-start win)
                               (min (point-max) (+ (window-start win) 80)))))
                (should (string-match-p "第 16 节" top-text)))
              ;; Widen back up (unwrapping all blocks above).
              (dotimes (_ 10) (etaf-md-wider))
              (let ((top-text (buffer-substring-no-properties
                               (window-start win)
                               (min (point-max) (+ (window-start win) 80)))))
                (should (string-match-p "第 16 节" top-text)))
              (etaf-md-close)))
          ;; 2. Side-by-side split with follow-scroll: resizing preview width
          ;;    re-aligns preview `window-start' to the source window's top line.
          (delete-other-windows)
          (switch-to-buffer source)
          (let ((src-win (selected-window)))
            (goto-char (point-min))
            (should (search-forward "## 第 14 节" nil t))
            (let ((bol (line-beginning-position)))
              (goto-char bol)
              (set-window-start src-win bol nil))
            (setq preview (etaf-md-preview))
            (let* ((prev-win (get-buffer-window preview))
                   (rt (etaf-runtime-for-buffer preview)))
              (should (window-live-p prev-win))
              (should rt)
              ;; Simulate dragging the split narrower and refitting to the new width.
              (with-current-buffer preview
                (let ((old-w (window-body-width prev-win)))
                  (when (> old-w 36)
                    (window-resize prev-win (- 32 old-w) t)
                    (run-hook-with-args 'window-size-change-functions (selected-frame))
                    (etaf-refit rt prev-win)
                    (let ((top-text (buffer-substring-no-properties
                                     (window-start prev-win)
                                     (min (point-max) (+ (window-start prev-win) 120)))))
                      (should (string-match-p "第 14 节" top-text)))
                    ;; Drag wider again and verify alignment holds.
                    (window-resize prev-win 14 t)
                    (run-hook-with-args 'window-size-change-functions (selected-frame))
                    (etaf-refit rt prev-win)
                    (let ((top-text (buffer-substring-no-properties
                                     (window-start prev-win)
                                     (min (point-max) (+ (window-start prev-win) 120)))))
                      (should (string-match-p "第 14 节" top-text)))))))))
      (when (buffer-live-p preview)
        (with-current-buffer preview (ignore-errors (etaf-md-close))))
      (when (buffer-live-p source) (kill-buffer source))
      (delete-file file))))

(ert-deftest etaf-md-tests-width-change-uses-single-flush-and-keeps-state ()
  "Refitting or adjusting width flushes once per change while preserving layout and widget state."
  (let* ((file (make-temp-file "etaf-md-single-flush-" nil ".md"))
         (preview nil)
         (flushes 0))
    (unwind-protect
        (progn
          (with-temp-file file
            (insert "# Width Fluency Test\n\n"
                    "Paragraph one with plenty of words so narrowing wraps cleanly across multiple lines.\n\n"
                    ":::details {title=\"Toggle Me\"}\n"
                    "Hidden detail body revealed after click.\n"
                    ":::\n\n"
                    ":::card {title=\"Prose Card\"}\n"
                    "Card prose content stays readable across width changes.\n"
                    ":::\n\n"
                    "| ColA | ColB | ColC | ColD |\n"
                    "| --- | --- | --- | --- |\n"
                    "| alpha value | beta value | gamma value | delta value |\n\n"
                    ":::columns {cols=2}\n"
                    ":::column\nLeft column prose.\n:::\n"
                    ":::column\nRight column prose.\n:::\n"
                    ":::\n"))
          (setq preview (etaf-md-open file))
          (let* ((rt (etaf-runtime-for-buffer preview))
                 (flush-hook (lambda (r)
                               (when (eq r rt)
                                 (setq flushes (1+ flushes))))))
            (should rt)
            ;; Open the details block so we verify state survives width changes.
            (with-current-buffer preview
              (goto-char (point-min))
              (should (search-forward "Toggle Me" nil t))
              (goto-char (match-beginning 0))
              (call-interactively (key-binding (kbd "RET")))
              (should (string-match-p "Hidden detail body revealed after click"
                                      (buffer-string))))
            (add-hook 'etaf-runtime-after-flush-functions flush-hook)
            (unwind-protect
                (with-current-buffer preview
                  ;; 1. Viewport refit narrow -> single flush.
                  (setq flushes 0)
                  (etaf-runtime-refit rt 560 40)
                  (should (<= flushes 1))
                  (should (string-match-p "Hidden detail body revealed after click"
                                          (buffer-string)))
                  (should (string-match-p "alpha value" (buffer-string)))
                  ;; 2. Viewport refit wide -> single flush.
                  (setq flushes 0)
                  (etaf-runtime-refit rt 960 40)
                  (should (<= flushes 1))
                  ;; 3. Narrower `[` (`etaf-md-narrower`) batches width+lock into 1 flush.
                  (setq flushes 0)
                  (etaf-md-narrower)
                  (should (= flushes 1))
                  (should (string-match-p "Hidden detail body revealed after click"
                                          (buffer-string)))
                  ;; 4. Wider `]` (`etaf-md-wider`) flushes once.
                  (setq flushes 0)
                  (etaf-md-wider)
                  (should (= flushes 1)))
              (remove-hook 'etaf-runtime-after-flush-functions flush-hook))))
      (when (buffer-live-p preview)
        (with-current-buffer preview (ignore-errors (etaf-md-close))))
      (delete-file file))))

(ert-deftest etaf-md-tests-goto-source-clears-highlight-on-tty ()
  "`etaf-md-goto-source' auto-clears its line highlight on non-pulsing TTY frames.
When `pulse-flag' is nil (or `pulse-available-p' is nil as on terminals with
`unspecified-bg'), the highlight still clears automatically after a short delay
without waiting for another command, while `pulse-flag' = `never' suppresses it."
  (require 'pulse)
  (let* ((file (make-temp-file "etaf-md-tty-pulse-" nil ".md"))
         (source nil)
         (preview nil))
    (unwind-protect
        (progn
          (with-temp-file file
            (insert "# Heading\n\n"
                    "| Key | Description |\n"
                    "| --- | --- |\n"
                    "| `C-c t` | Toggle outline sidebar |\n"))
          (setq source (find-file-noselect file))
          (setq preview (etaf-md-open file))
          (let ((pulse-flag nil)
                (pulse-delay 0.02)
                (pulse-iterations 5))
            (with-current-buffer preview
              (goto-char (point-min))
              (should (search-forward "C-c t" nil t))
              (goto-char (match-beginning 0))
              (etaf-md-goto-source))
            (with-current-buffer source
              ;; Immediately highlighted on jump.
              (should (overlayp pulse-momentary-overlay))
              ;; Clears automatically without any subsequent command.
              (let ((deadline (+ (float-time) 1.0)))
                (while (and pulse-momentary-overlay (< (float-time) deadline))
                  (accept-process-output nil 0.05)))
              (should-not pulse-momentary-overlay)
              (should-not (memq #'pulse-momentary-unhighlight pre-command-hook))))
          ;; Respect `pulse-flag' = `never'.
          (let ((pulse-flag 'never))
            (with-current-buffer preview
              (goto-char (point-min))
              (should (search-forward "C-c t" nil t))
              (goto-char (match-beginning 0))
              (etaf-md-goto-source))
            (should-not pulse-momentary-overlay)))
      (when (fboundp 'pulse-momentary-unhighlight)
        (pulse-momentary-unhighlight))
      (when (buffer-live-p preview)
        (with-current-buffer preview (ignore-errors (etaf-md-close))))
      (when (buffer-live-p source) (kill-buffer source))
      (delete-file file))))
