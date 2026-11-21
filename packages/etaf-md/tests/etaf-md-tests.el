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
  (let* ((video (expand-file-name "../examples/demo.mp4"
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
  (let* ((video (expand-file-name "../examples/demo.mp4"
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
  "The entry command opens the preview in a window beside the source.
The source buffer keeps the selected window, so an edit and its save need no
window switching, and closing the preview gives the window back."
  (let* ((file (make-temp-file "etaf-md-" nil ".md"))
         (source nil))
    (unwind-protect
        (progn
          (with-temp-file file (insert "# Beside\n\nbody text\n"))
          (setq source (find-file-noselect file))
          (switch-to-buffer source)
          (delete-other-windows)
          (etaf-md-preview file)
          (let ((preview-window
                 (cl-find-if (lambda (window)
                               (string-prefix-p "*ETAF Markdown:"
                                                (buffer-name (window-buffer window))))
                             (window-list))))
            (should (= 2 (length (window-list))))
            (should (eq (window-buffer (selected-window)) source))
            (should preview-window)
            ;; source left of the preview, whatever the layout was
            (should (< (car (window-edges (selected-window)))
                       (car (window-edges preview-window))))
            (select-window preview-window)
            (etaf-md-close)
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
  "The file prompt defaults to the current buffer's file, as a relative name.
`read-file-name' resolves a relative default against its own directory; an
absolute one made the prompt show that directory twice."
  (let ((dir (make-temp-file "etaf-md-prompt" t))
        (default nil))
    (unwind-protect
        (progn
          (with-temp-file (expand-file-name "note.md" dir) (insert "# Note\n"))
          (with-temp-buffer
            (setq buffer-file-name (expand-file-name "note.md" dir)
                  default-directory (file-name-as-directory dir))
            (cl-letf (((symbol-function 'read-file-name)
                       (lambda (_prompt &optional _directory _predicate _mustmatch
                                preset &rest _)
                         (setq default preset)
                         buffer-file-name)))
              (call-interactively #'etaf-md-open)))
          (should default)
          (should-not (file-name-absolute-p default))
          (should (equal "note.md" default)))
      (dolist (buffer (buffer-list))
        (when (string-prefix-p "*ETAF Markdown" (buffer-name buffer))
          (with-current-buffer buffer (ignore-errors (etaf-md-close)))))
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
              (dolist (key '("?" "C-c h"))
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
    (should (equal (mapcar #'car optional) '("ffmpeg" "mmdc" "qrencode")))
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

(ert-deftest etaf-md-tests-headings-render-on-line-grid-without-font-size ()
  "Front-matter title and body headings keep standard line height with no scaling.
The document header uses bold weight, heading color and a bottom hairline, and
total line counts stay on the uniform line grid."
  (let* ((front-h3 (concat "---\ntitle: 文档标题\nauthor: 作者\n---\n\n"
                           "### 小节\n\n正文。\n"))
         (all-levels (concat "---\ntitle: 页面标题\n---\n\n"
                             "# 一级标题\n\n"
                             "## 二级标题\n\n"
                             "### 三级标题\n\n"
                             "正文[^n]。\n\n"
                             "[^n]: 脚注内容\n"))
         (s1 (etaf-md-create :text front-h3 :theme 'dark))
         (s2 (etaf-md-create :text all-levels :theme 'dark)))
    (etaf-md-tests--with-mount s1
      (let ((scaled (etaf-md-tests--scaled-chars))
            (lines (count-lines (point-min) (point-max)))
            (weight (etaf-md-tests--face-attribute "文档标题" :weight))
            (underline (etaf-md-tests--face-attribute "文档标题" :underline)))
        (should (equal scaled ""))
        ;; Same 10 lines as before removing heading scaling: no extra rows added.
        (should (= lines 10))
        (should (eq weight 'bold))
        (should underline)))
    (etaf-md-tests--with-mount s2
      (let ((scaled (etaf-md-tests--scaled-chars))
            (h1-weight (etaf-md-tests--face-attribute "一级标题" :weight))
            (h2-weight (etaf-md-tests--face-attribute "二级标题" :weight))
            (h3-weight (etaf-md-tests--face-attribute "三级标题" :weight)))
        (should (equal scaled ""))
        (should (eq h1-weight 'bold))
        (should (eq h2-weight 'bold))
        (should (eq h3-weight 'bold))))))

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
