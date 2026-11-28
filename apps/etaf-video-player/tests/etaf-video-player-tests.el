;;; etaf-video-player-tests.el --- Public acceptance scenarios -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Public-entry scenarios for the player.  Decoding, image frames, the audio
;; sidecar and publication belong to the native `etaf-video' Component, so
;; this suite drives it through the application entry only.  The producer,
;; metadata and audio are the repository's fake fixtures, so the suite needs
;; no real decoder, no network, no sound and no graphical frame; one gated
;; scenario runs the real ffmpeg path.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'etaf-video-player)

(defvar etaf-video-player-tests--history-file
  (expand-file-name "etaf-video-player-history-tests.sqlite3"
                    temporary-file-directory)
  "Isolated playback database so acceptance runs never touch user data.")
(setq etaf-video-player-history-file etaf-video-player-tests--history-file)

(defconst etaf-video-player-tests--fixtures
  (expand-file-name "fixtures"
                    (file-name-directory (or load-file-name buffer-file-name)))
  "Fixture directory beside the test source.")

(defconst etaf-video-player-tests--ffmpeg
  (expand-file-name "fake-ffmpeg.py" etaf-video-player-tests--fixtures)
  "Executable fixture standing in for ffmpeg.")

(defconst etaf-video-player-tests--ffprobe
  (expand-file-name "fake-ffprobe.py" etaf-video-player-tests--fixtures)
  "Executable fixture standing in for ffprobe.")

(defconst etaf-video-player-tests--ffplay
  (expand-file-name "fake-ffplay.py" etaf-video-player-tests--fixtures)
  "Executable fixture standing in for ffplay.")

(defconst etaf-video-player-tests--input
  (expand-file-name "fake-ffmpeg.py" etaf-video-player-tests--fixtures)
  "An existing file accepted as the video input; the fixture ignores it.")

(defun etaf-video-player-tests--log ()
  "Return a fresh log path for recorded fixture invocations."
  (make-temp-file "etaf-video-player-log-"))

(defun etaf-video-player-tests--runs (log)
  "Return the recorded fixture invocations in LOG as argument lists."
  (when (file-exists-p log)
    (mapcar (lambda (line) (split-string line "\000" t))
            (split-string
             (with-temp-buffer
               (insert-file-contents log)
               (buffer-string))
             "\n" t))))

(defun etaf-video-player-tests--argument (arguments flag)
  "Return the value following FLAG in ARGUMENTS, or nil."
  (cadr (member flag arguments)))

(defun etaf-video-player-tests--ffplay-pids (log)
  "Return every recorded ffplay process id in LOG."
  (when (file-exists-p log)
    (let (pids)
      (with-temp-buffer
        (insert-file-contents log)
        (goto-char (point-min))
        (while (re-search-forward "^pid=\\([0-9]+\\)$" nil t)
          (push (string-to-number (match-string 1)) pids)))
      (nreverse pids))))

(defun etaf-video-player-tests--ffplay-arguments (log)
  "Return the last recorded ffplay argument list in LOG, or nil."
  (car (last (cl-remove-if-not (lambda (arguments) (member "-nodisp" arguments))
                               (etaf-video-player-tests--runs log)))))

(defun etaf-video-player-tests--ffplay-runs (log)
  "Return the number of recorded ffplay invocations in LOG."
  (length (cl-remove-if-not (lambda (arguments) (member "-nodisp" arguments))
                            (etaf-video-player-tests--runs log))))

(defun etaf-video-player-tests--cleanup ()
  "Close any leftover player without signaling."
  (when-let* ((buffer (get-buffer "*Video Player*")))
    (with-current-buffer buffer
      (condition-case nil
          (etaf-video-player-close)
        (error nil)))))

(defun etaf-video-player-tests--wait (predicate &optional seconds)
  "Wait until PREDICATE is non-nil for at most SECONDS, then retry once.
Return PREDICATE's final value."
  (let ((deadline (+ (float-time) (or seconds 5))))
    (while (and (< (float-time) deadline) (not (funcall predicate)))
      (accept-process-output nil 0.02)
      (sleep-for 0.01))
    (funcall predicate)))

(defun etaf-video-player-tests--state ()
  "Return the live player state."
  (etaf-video-player-state))

(defun etaf-video-player-tests--visible (line)
  "Return LINE's active characters without EBox display padding.
EBox pads rows with `space' display characters for background painting and
for centering; those characters are not video pixels, on either side."
  (let ((position 0) (end (length line)) start cut)
    (while (< position end)
      (let* ((display (get-text-property position 'display line))
             (padding (and (consp display) (eq (car display) 'space))))
        (cond ((and padding (null start)) nil)
              ((null start) (setq start position))
              ((and padding (null cut)) (setq cut position)))
        (setq position (or (next-property-change position line end) end))))
    (substring-no-properties line (or start 0) (or cut end))))

(defun etaf-video-player-tests--canvas-line ()
  "Return the first buffer line carrying video characters, with properties."
  (with-current-buffer "*Video Player*"
    (cl-find-if (lambda (line)
                  (string-match-p "[▀@]" (substring-no-properties line)))
                (split-string (buffer-string) "\n"))))

(defun etaf-video-player-tests--grid (rows)
  "Return the first ROWS visible canvas lines of the player buffer.
The shell puts a header above the canvas, so the canvas is located by the
first line that carries video characters instead of by line number."
  (with-current-buffer "*Video Player*"
    (let* ((lines (split-string (buffer-string) "\n"))
           (start (cl-position-if
                   (lambda (line)
                     (let ((visible (etaf-video-player-tests--visible line)))
                       (string-match-p "[@▀]" visible)))
                   lines)))
      (mapconcat #'etaf-video-player-tests--visible
                 (cl-subseq lines (or start 0) (+ (or start 0) rows))
                 "\n"))))

(defun etaf-video-player-tests--image-rows ()
  "Return the canvas rows that publish an image display cell.
Image mode crops one frame into one character row per display slice, so a
cell counts when its display property is an image or a slice carrying one."
  (with-current-buffer "*Video Player*"
    (let ((text (buffer-string))
          (position 0)
          rows)
      (while (< position (length text))
        (let ((display (get-text-property position 'display text)))
          (when (or (imagep display)
                    (and (consp display)
                         (imagep (car (last display)))))
            (setq rows (1+ (or rows 0)))))
        (setq position (or (next-property-change position text)
                           (length text))))
      (or rows 0))))

(defun etaf-video-player-tests--image-cell ()
  "Return non-nil when the buffer publishes one image display cell."
  (> (etaf-video-player-tests--image-rows) 0))

(defmacro etaf-video-player-tests--with-graphics (&rest body)
  "Run BODY as if the frame could show images at the frame's scale factor.
The batch frame is not a window-system frame, so it cannot render an SVG
image; the fake therefore reports `display-graphic-p' as t (which is what the
video Component asks before publishing raster frames) while SVG stays
unavailable.  A no-X Emacs also lacks the font metrics a graphical frame
serves, so the simulation is skipped there."
  (declare (indent 0))
  `(progn
     (skip-unless (fboundp 'font-info))
     (cl-letf (((symbol-function 'display-graphic-p)
                (lambda (&optional _frame) t))
               ((symbol-function 'image-type-available-p)
                (lambda (type) (not (eq type 'svg)))))
       ,@body)))

(defmacro etaf-video-player-tests--with-retina (&rest body)
  "Run BODY as on a graphical Retina frame with a device pixel ratio of two."
  (declare (indent 0))
  `(etaf-video-player-tests--with-graphics
     (cl-letf (((symbol-function 'frame-scale-factor)
                (lambda (&optional _frame) 2.0)))
       ,@body)))

(defmacro etaf-video-player-tests--with-fixture (log settings &rest body)
  "Run BODY with the fake decoder fixtures and SETTINGS bound.
LOG receives the recorded ffmpeg invocations.  SETTINGS is a list of ENV=VALUE
strings for the fixtures."
  (declare (indent 2))
  `(let ((process-environment
          (append (cons (concat "FAKE_FFMPEG_LOG=" ,log) ,settings)
                  process-environment))
         (etaf-video-engine 'ffmpeg)
         (etaf-video-ffmpeg-program etaf-video-player-tests--ffmpeg)
         (etaf-video-ffprobe-program etaf-video-player-tests--ffprobe)
         (etaf-video-ffplay-program etaf-video-player-tests--ffplay))
     ,@body))

(ert-deftest etaf-video-player-tests-image-frames-publish-image-cells ()
  "Image frames are published as one scaled JPEG display per row.
A graphical frame makes the native Component decode at the canvas pixel
size and crop the frame into one display slice per character row, so the
canvas occupies exactly its declared rows and the transport bar below it
stays inside the window."
  (etaf-video-player-tests--cleanup)
  (let ((log (etaf-video-player-tests--log)))
    (unwind-protect
        (etaf-video-player-tests--with-fixture
         log
         (list "FAKE_FFMPEG_FRAMES=200" "FAKE_FFMPEG_INTERVAL=0.02"
               "FAKE_FFPROBE_DURATION=4.0" "FAKE_FFPROBE_FPS=50/1")
         (etaf-video-player-tests--with-graphics
           (etaf-video-player-open
            (list :file etaf-video-player-tests--input :columns 16 :rows 4))
           (should (etaf-video-player-tests--wait
                    (lambda () (>= (plist-get (etaf-video-player-tests--state) :presented) 1))))
           (should (eq 'image (plist-get (etaf-video-player-tests--state) :render-mode)))
           (should (etaf-video-player-tests--image-cell))
           (should (= 4 (etaf-video-player-tests--image-rows)))
           (let* ((arguments (car (last (etaf-video-player-tests--runs log))))
                  (scale (cl-find-if (lambda (argument)
                                       (string-prefix-p "scale=" argument))
                                     arguments)))
             (should (equal "mjpeg" (etaf-video-player-tests--argument arguments "-c:v")))
             (should (equal "3" (etaf-video-player-tests--argument arguments "-q:v")))
             (should (string-match-p "\\`scale=[0-9]+:[0-9]+:flags=lanczos\\'" scale)))
           (etaf-video-player-close)))
      (ignore-errors (delete-file log))
      (etaf-video-player-tests--cleanup))))

(defun etaf-video-player-tests--scale-size (log)
  "Return the last recorded `scale=W:H' producer size in LOG as (W . H)."
  (let* ((arguments (car (last (etaf-video-player-tests--runs log))))
         (scale (cl-find-if (lambda (argument)
                              (string-prefix-p "scale=" argument))
                            arguments)))
    (when (and scale
               (string-match "\\`scale=\\([0-9]+\\):\\([0-9]+\\)" scale))
      (cons (string-to-number (match-string 1 scale))
            (string-to-number (match-string 2 scale))))))

(ert-deftest etaf-video-player-tests-retina-frames-scale-by-device-pixel-ratio ()
  "Retina frames are produced at twice the logical canvas.
The producer receives device-resolution pixels and the image is drawn back
down at one over the ratio, so the window system never upscales the picture."
  (etaf-video-player-tests--cleanup)
  (let ((log (etaf-video-player-tests--log))
        (columns 16)
        (rows 4)
        logical)
    (unwind-protect
        (etaf-video-player-tests--with-fixture
         log
         (list "FAKE_FFMPEG_FRAMES=200" "FAKE_FFMPEG_INTERVAL=0.02"
               "FAKE_FFPROBE_DURATION=4.0" "FAKE_FFPROBE_FPS=50/1")
         ;; The same environment without the Retina factor is the baseline.
         (etaf-video-player-tests--with-graphics
           (etaf-video-player-open
            (list :file etaf-video-player-tests--input
                  :columns columns :rows rows))
           (should (etaf-video-player-tests--wait
                    (lambda () (etaf-video-player-tests--scale-size log))))
           (setq logical (etaf-video-player-tests--scale-size log))
           (etaf-video-player-close))
         (etaf-video-player-tests--with-retina
           (etaf-video-player-open
            (list :file etaf-video-player-tests--input
                  :columns columns :rows rows))
           (should (etaf-video-player-tests--wait
                    (lambda ()
                      (let ((size (etaf-video-player-tests--scale-size log)))
                        (and size
                             (= (car size) (* 2 (car logical)))
                             (= (cdr size) (* 2 (cdr logical))))))))
           (etaf-video-player-close)))
      (ignore-errors (delete-file log))
      (etaf-video-player-tests--cleanup))))

(ert-deftest etaf-video-player-tests-falls-back-to-ascii-on-terminal ()
  "Without a graphical frame the player falls back to a density ramp.
The requested mode stays `image' while the effective render mode and the
decoded format follow the canvas that is actually available."
  (etaf-video-player-tests--cleanup)
  (let ((log (etaf-video-player-tests--log))
        (columns 16)
        (rows 4))
    (unwind-protect
        (etaf-video-player-tests--with-fixture
         log
         (list "FAKE_FFMPEG_PATTERN=columns" "FAKE_FFMPEG_FRAMES=200"
               "FAKE_FFMPEG_INTERVAL=0.02"
               "FAKE_FFPROBE_DURATION=4.0" "FAKE_FFPROBE_FPS=50/1")
         (etaf-video-player-open
          (list :file etaf-video-player-tests--input
                :columns columns :rows rows))
         (should (etaf-video-player-tests--wait
                  (lambda () (>= (plist-get (etaf-video-player-tests--state) :presented) 1))))
         (should (eq 'image (plist-get (etaf-video-player-tests--state) :mode)))
         (should (eq 'ascii (plist-get (etaf-video-player-tests--state) :render-mode)))
         (let* ((ramp etaf-video-density-ramp)
                (last (1- (length ramp)))
                (expected (mapconcat
                           (lambda (_row)
                             (apply #'string
                                    (cl-loop for x below columns
                                             for value = (floor (* x 255) (1- columns))
                                             for index = (floor (+ (* value last) 127) 255)
                                             collect (aref ramp index))))
                           (number-sequence 1 rows) "\n")))
           (should (equal expected (etaf-video-player-tests--grid rows))))
         (should (equal "gray"
                        (etaf-video-player-tests--argument
                         (car (last (etaf-video-player-tests--runs log))) "-pix_fmt")))
         (etaf-video-player-close))
      (ignore-errors (delete-file log))
      (etaf-video-player-tests--cleanup))))

(ert-deftest etaf-video-player-tests-resolves-relative-file-names ()
  "A relative source plays from the directory it was named in.
`read-file-name' returns the name unexpanded, so the player must resolve it
before probing; otherwise the decoder looks for the file under another
buffer's `default-directory'."
  (etaf-video-player-tests--cleanup)
  (let ((log (etaf-video-player-tests--log))
        (absolute etaf-video-player-tests--input)
        (directory (file-name-directory etaf-video-player-tests--input)))
    (unwind-protect
        (etaf-video-player-tests--with-fixture
         log
         (list "FAKE_FFMPEG_FRAMES=200" "FAKE_FFMPEG_INTERVAL=0.02"
               "FAKE_FFPROBE_DURATION=4.0")
         (let ((default-directory directory))
           (etaf-video-player-open
            (list :file (file-relative-name absolute directory)
                  :columns 16 :rows 4)))
         (should (etaf-video-player-tests--wait
                  (lambda () (>= (plist-get (etaf-video-player-tests--state) :presented) 1))))
         (should (equal absolute (plist-get (etaf-video-player-tests--state) :source)))
         (let ((arguments (car (last (etaf-video-player-tests--runs log)))))
           (should (member absolute arguments)))
         (etaf-video-player-close))
      (ignore-errors (delete-file log))
      (etaf-video-player-tests--cleanup))))

(ert-deftest etaf-video-player-tests-render-mode-switches-without-restarting ()
  "`C' changes the picture and keeps the playback place.
`ascii' draws a density ramp, `color' draws half-block cells and `image'
falls back to the ramp on a terminal; the position, rate and audio state
survive every switch, and an unknown mode is refused."
  (etaf-video-player-tests--cleanup)
  (let ((log (etaf-video-player-tests--log)))
    (unwind-protect
        (etaf-video-player-tests--with-fixture
         log
         (list "FAKE_FFMPEG_FRAMES=800" "FAKE_FFMPEG_INTERVAL=0.02"
               "FAKE_FFPROBE_DURATION=60.0" "FAKE_FFPROBE_FPS=50/1")
         (let ((buffer (etaf-video-player-open
                        (list :file etaf-video-player-tests--input
                              :columns 16 :rows 4 :mode 'ascii))))
           (should (etaf-video-player-tests--wait
                    (lambda ()
                      (>= (plist-get (etaf-video-player-tests--state) :presented) 1))))
           (should (eq 'ascii (plist-get (etaf-video-player-tests--state) :mode)))
           (should (eq 'ascii (plist-get (etaf-video-player-tests--state) :render-mode)))
           (with-current-buffer buffer
             (etaf-video-player-seek 20)
             (execute-kbd-macro (kbd "C")))
           (should (eq 'color (plist-get (etaf-video-player-tests--state) :mode)))
           (should (eq 'color (plist-get (etaf-video-player-tests--state) :render-mode)))
           (should (etaf-video-player-tests--wait
                    (lambda ()
                      (>= (plist-get (etaf-video-player-tests--state) :presented) 1))))
           (should (string-match-p "▀" (etaf-video-player-tests--grid 2)))
           (should (>= (or (plist-get (etaf-video-player-tests--state) :position) 0)
                       19))
           (with-current-buffer buffer
             (execute-kbd-macro (kbd "C")))
           ;; On a terminal `C' cycles directly between the two character modes.
           (should (eq 'ascii (plist-get (etaf-video-player-tests--state) :mode)))
           (should (eq 'ascii (plist-get (etaf-video-player-tests--state) :render-mode)))
           ;; Explicitly requesting `image' on a terminal still falls back cleanly.
           (with-current-buffer buffer
             (etaf-video-player-set-render-mode 'image))
           (should (eq 'image (plist-get (etaf-video-player-tests--state) :mode)))
           (should (eq 'ascii (plist-get (etaf-video-player-tests--state) :render-mode)))
           (should-error (etaf-video-player-set-render-mode 'movie)
                         :type 'user-error)
           (etaf-video-player-close)))
      (ignore-errors (delete-file log))
      (etaf-video-player-tests--cleanup))))

(ert-deftest etaf-video-player-tests-color-mode-caps-the-fitted-canvas ()
  "A color player stops at `etaf-video-player-color-columns' columns.
True-color cells carry one face property each, so the fitted canvas keeps
the property volume bounded while the row count follows the video aspect.
Switching into and out of `color' via `C' applies and lifts the cap."
  (etaf-video-player-tests--cleanup)
  (let ((log (etaf-video-player-tests--log))
        (video nil))
    (unwind-protect
        (etaf-video-player-tests--with-fixture
         log
         (list "FAKE_FFMPEG_FRAMES=800" "FAKE_FFMPEG_INTERVAL=0.02"
               "FAKE_FFPROBE_DURATION=60.0" "FAKE_FFPROBE_FPS=50/1")
         (setq video etaf-video-player-tests--input)
         (save-window-excursion
           (let ((etaf-video-player-color-columns 8))
             (etaf-video-player-open
              (list :file video :mode 'color :audio nil))
             (should (etaf-video-player-tests--wait
                      (lambda ()
                        (>= (plist-get (etaf-video-player-tests--state) :presented)
                            1))))
             (should (= 8 (plist-get (etaf-video-player-tests--state) :columns)))
             (should (>= (plist-get (etaf-video-player-tests--state) :rows) 1))
             ;; Switching out of color expands back to the full stage.
             (with-current-buffer "*Video Player*"
               (execute-kbd-macro (kbd "C")))
             (let ((ascii-cols (plist-get (etaf-video-player-tests--state) :columns)))
               (should (> ascii-cols 8))
               ;; Switching back into color re-applies the column cap.
               (with-current-buffer "*Video Player*"
                 (execute-kbd-macro (kbd "C")))
               (should (= 8 (plist-get (etaf-video-player-tests--state) :columns))))
             (etaf-video-player-close))
           (let ((etaf-video-player-color-columns nil))
             (etaf-video-player-open
              (list :file video :mode 'color :audio nil))
             (should (> (plist-get (etaf-video-player-tests--state) :columns)
                        8))
             (etaf-video-player-close))))
      (ignore-errors (delete-file log))
      (etaf-video-player-tests--cleanup))))

(ert-deftest etaf-video-player-tests-color-half-blocks-publish-true-colors ()
  "Color mode publishes half-block cells with per-cell true colors.
The fixture's RGB24 pattern makes each cell's foreground and background
predictable, and the canvas carries exactly one `▀' per column."
  (etaf-video-player-tests--cleanup)
  (let ((log (etaf-video-player-tests--log)))
    (unwind-protect
        (etaf-video-player-tests--with-fixture
         log
         (list "FAKE_FFMPEG_PATTERN=columns"
               "FAKE_FFMPEG_FRAMES=400" "FAKE_FFMPEG_INTERVAL=0.02"
               "FAKE_FFPROBE_DURATION=4.0" "FAKE_FFPROBE_FPS=50/1")
         (etaf-video-player-open
          (list :file etaf-video-player-tests--input
                :columns 16 :rows 4 :mode 'color :audio nil))
         (should (etaf-video-player-tests--wait
                  (lambda ()
                    (>= (plist-get (etaf-video-player-tests--state) :presented) 1))))
         (let* ((line (etaf-video-player-tests--canvas-line))
                (text (substring-no-properties line))
                (start (string-match "▀" text)))
           (should start)
           (should (= 16 (cl-loop for index from start below (length text)
                                  while (eq (aref text index) ?▀)
                                  count index)))
           (should (member '(:foreground "#000000" :background "#ff0000")
                           (get-text-property start 'face line)))
           (should (member '(:foreground "#111111" :background "#ee0011")
                           (get-text-property (1+ start) 'face line))))
         (etaf-video-player-close))
      (ignore-errors (delete-file log))
      (etaf-video-player-tests--cleanup))))

(ert-deftest etaf-video-player-tests-audio-sidecar-follows-playback ()
  "Audio playback runs one ffplay sidecar while playing and releases it.
A source that reports an audio stream starts the sidecar with the documented
arguments; pausing terminates it, and turning sound off keeps it stopped."
  (etaf-video-player-tests--cleanup)
  (let ((log (etaf-video-player-tests--log))
        (audio-log (etaf-video-player-tests--log)))
    (unwind-protect
        (etaf-video-player-tests--with-fixture
         log (list "FAKE_FFMPEG_FRAMES=400" "FAKE_FFMPEG_INTERVAL=0.02"
                   "FAKE_FFPROBE_AUDIO=1"
                   (concat "FAKE_FFPLAY_LOG=" audio-log))
         (etaf-video-player-open
          (list :file etaf-video-player-tests--input :columns 8 :rows 2))
         (should (etaf-video-player-tests--wait
                  (lambda () (etaf-video-player-tests--ffplay-pids audio-log))))
         (let ((arguments (etaf-video-player-tests--ffplay-arguments audio-log)))
           (should (member "-nodisp" arguments))
           (should (member "-autoexit" arguments))
           (should (equal "100" (etaf-video-player-tests--argument arguments "-volume"))))
         ;; Pausing releases the sidecar.
         (let ((pid (car (last (etaf-video-player-tests--ffplay-pids audio-log)))))
           (etaf-video-player-toggle-playback)
           (should (etaf-video-player-tests--wait
                    (lambda () (null (process-attributes pid))))))
         ;; Sound off stays silent when playback resumes.
         (let ((runs (etaf-video-player-tests--ffplay-runs audio-log)))
           (etaf-video-player-set-audio nil)
           (etaf-video-player-toggle-playback)
           (sleep-for 0.2)
           (should (= runs (etaf-video-player-tests--ffplay-runs audio-log))))
         ;; Sound on starts one sidecar again.
         (etaf-video-player-set-audio t)
         (should (etaf-video-player-tests--wait
                  (lambda ()
                    (let ((pid (car (last (etaf-video-player-tests--ffplay-pids audio-log)))))
                      (and pid (process-attributes pid))))))
         (etaf-video-player-close))
      (ignore-errors (delete-file log))
      (ignore-errors (delete-file audio-log))
      (etaf-video-player-tests--cleanup))))

(ert-deftest etaf-video-player-tests-volume-commands-restart-sidecar ()
  "The volume commands change the level and apply it to the running sound.
The sidecar restarts at the same position with the documented volume."
  (etaf-video-player-tests--cleanup)
  (let ((log (etaf-video-player-tests--log))
        (audio-log (etaf-video-player-tests--log)))
    (unwind-protect
        (etaf-video-player-tests--with-fixture
         log (list "FAKE_FFMPEG_FRAMES=400" "FAKE_FFMPEG_INTERVAL=0.02"
                   "FAKE_FFPROBE_AUDIO=1"
                   (concat "FAKE_FFPLAY_LOG=" audio-log))
         (etaf-video-player-open
          (list :file etaf-video-player-tests--input :columns 8 :rows 2
                :volume 30))
         (should (= 30 (plist-get (etaf-video-player-tests--state) :volume)))
         (should (etaf-video-player-tests--wait
                  (lambda () (etaf-video-player-tests--ffplay-pids audio-log))))
         (let ((window (get-buffer-window "*Video Player*" t)))
           (should window)
           (with-selected-window window
             (execute-kbd-macro (kbd "]"))))
         (should (= 40 (plist-get (etaf-video-player-tests--state) :volume)))
         (should (etaf-video-player-tests--wait
                  (lambda ()
                    (equal "40"
                           (etaf-video-player-tests--argument
                            (etaf-video-player-tests--ffplay-arguments audio-log)
                            "-volume")))))
         (with-selected-window (get-buffer-window "*Video Player*" t)
           (execute-kbd-macro (kbd "[")))
         (should (= 30 (plist-get (etaf-video-player-tests--state) :volume)))
         (should-error (etaf-video-player-set-volume 101) :type 'user-error)
         (etaf-video-player-close))
      (ignore-errors (delete-file log))
      (ignore-errors (delete-file audio-log))
      (etaf-video-player-tests--cleanup))))

(ert-deftest etaf-video-player-tests-controls-pause-step-seek-speed ()
  "Pause, step, seek and speed keep the reported state honest.
A paused position freezes, a step presents exactly one more frame, and the
next producer starts with the documented seek and read-rate arguments."
  (etaf-video-player-tests--cleanup)
  (let ((log (etaf-video-player-tests--log)))
    (unwind-protect
        (etaf-video-player-tests--with-fixture
         log (list "FAKE_FFMPEG_FRAMES=400" "FAKE_FFMPEG_INTERVAL=0.02"
                   "FAKE_FFPROBE_DURATION=8.0" "FAKE_FFPROBE_FPS=50/1")
         (etaf-video-player-open
          (list :file etaf-video-player-tests--input :columns 16 :rows 4))
         (should (etaf-video-player-tests--wait
                  (lambda () (>= (plist-get (etaf-video-player-tests--state) :presented) 1))))
         (etaf-video-player-toggle-playback)
         (should-not (plist-get (etaf-video-player-tests--state) :playing))
         (let ((paused (plist-get (etaf-video-player-tests--state) :position))
               (presented (plist-get (etaf-video-player-tests--state) :presented)))
           (sleep-for 0.15)
           (should (= paused (plist-get (etaf-video-player-tests--state) :position)))
           (etaf-video-player-step)
           (should (etaf-video-player-tests--wait
                    (lambda ()
                      (> (plist-get (etaf-video-player-tests--state) :presented)
                         presented))))
           (should-not (plist-get (etaf-video-player-tests--state) :playing)))
         (etaf-video-player-seek 1.0)
         (should (= 1.0 (plist-get (etaf-video-player-tests--state) :position)))
         (etaf-video-player-toggle-playback)
         (should (plist-get (etaf-video-player-tests--state) :playing))
         (should (etaf-video-player-tests--wait
                  (lambda ()
                    (equal "1.0"
                           (etaf-video-player-tests--argument
                            (car (last (etaf-video-player-tests--runs log))) "-ss")))
                  3))
         (etaf-video-player-set-speed 2)
         (should (= 2 (plist-get (etaf-video-player-tests--state) :speed)))
         (should (etaf-video-player-tests--wait
                  (lambda ()
                    (equal "2"
                           (etaf-video-player-tests--argument
                            (car (last (etaf-video-player-tests--runs log))) "-readrate")))
                  3))
         (etaf-video-player-toggle-playback))
      (ignore-errors (delete-file log))
      (etaf-video-player-tests--cleanup))))

(ert-deftest etaf-video-player-tests-finishes-and-restarts ()
  "A producer that runs out of frames ends the player and keeps its picture.
Toggling playback afterwards restarts from the beginning."
  (etaf-video-player-tests--cleanup)
  (let ((log (etaf-video-player-tests--log)))
    (unwind-protect
        (etaf-video-player-tests--with-fixture
         log (list "FAKE_FFMPEG_FRAMES=2" "FAKE_FFMPEG_INTERVAL=0.01"
                   "FAKE_FFPROBE_DURATION=1.0" "FAKE_FFPROBE_FPS=50/1")
         (etaf-video-player-open
          (list :file etaf-video-player-tests--input :columns 8 :rows 2))
         (should (etaf-video-player-tests--wait
                  (lambda () (plist-get (etaf-video-player-tests--state) :ended))))
         (should-not (plist-get (etaf-video-player-tests--state) :playing))
         (etaf-video-player-toggle-playback)
         (should (plist-get (etaf-video-player-tests--state) :playing))
         (should-not (plist-get (etaf-video-player-tests--state) :ended))
         (etaf-video-player-close))
      (ignore-errors (delete-file log))
      (etaf-video-player-tests--cleanup))))

(ert-deftest etaf-video-player-tests-streams-http-url ()
  "An HTTP(S) source reaches ffmpeg as a reconnecting stream.
A non-HTTP scheme is rejected before any process starts."
  (etaf-video-player-tests--cleanup)
  (let ((log (etaf-video-player-tests--log)))
    (unwind-protect
        (etaf-video-player-tests--with-fixture
         log (list "FAKE_FFMPEG_FRAMES=40" "FAKE_FFMPEG_INTERVAL=0.02"
                   "FAKE_FFPROBE_DURATION=4.0" "FAKE_FFPROBE_FPS=50/1")
         (etaf-video-player-open-url "https://example.invalid/video.mp4")
         (should (etaf-video-player-tests--wait
                  (lambda () (>= (plist-get (etaf-video-player-tests--state) :presented) 1))))
         (should (equal "https://example.invalid/video.mp4"
                        (plist-get (etaf-video-player-tests--state) :source)))
         (let ((arguments (car (last (etaf-video-player-tests--runs log)))))
           (should (member "https://example.invalid/video.mp4" arguments))
           (should (equal "1" (etaf-video-player-tests--argument arguments "-reconnect"))))
         (should-error (etaf-video-player-open-url "ftp://example.invalid/v.mp4")
                       :type 'user-error)
         (etaf-video-player-close))
      (ignore-errors (delete-file log))
      (etaf-video-player-tests--cleanup))))

(ert-deftest etaf-video-player-tests-rejects-invalid-sources ()
  "Invalid sources and a missing ffmpeg fail before anything is left behind.
Every rejection signals `user-error', the state API refuses a foreign buffer,
and no application buffer survives a failed open."
  (etaf-video-player-tests--cleanup)
  (should-error (etaf-video-player-open 42) :type 'user-error)
  (should-error (etaf-video-player-open '(:file "/definitely/missing.mp4"))
                :type 'user-error)
  (should-error (etaf-video-player-open '(:file)) :type 'user-error)
  (let ((etaf-video-ffmpeg-program "etaf-video-player-missing-ffmpeg")
        (etaf-video-ffprobe-program "etaf-video-player-missing-ffprobe"))
    (should-error (etaf-video-player-open '(:demo :columns 8 :rows 3))
                  :type 'user-error))
  (should-not (get-buffer "*Video Player*"))
  (with-temp-buffer
    (should-error (etaf-video-player-state) :type 'user-error))
  (etaf-video-player-tests--cleanup))

(ert-deftest etaf-video-player-tests-documented-keys-reach-player ()
  "The documented keys drive the player instead of the renderer's own map.
Every binding is exercised through the command loop; closing with `q' leaves
no buffer behind."
  (etaf-video-player-tests--cleanup)
  (let ((log (etaf-video-player-tests--log)))
    (unwind-protect
        (etaf-video-player-tests--with-fixture
         log (list "FAKE_FFMPEG_FRAMES=400" "FAKE_FFMPEG_INTERVAL=0.02"
                   "FAKE_FFPROBE_DURATION=8.0" "FAKE_FFPROBE_FPS=50/1")
         (etaf-video-player-open
          (list :file etaf-video-player-tests--input :columns 16 :rows 4))
         (should (etaf-video-player-tests--wait
                  (lambda () (>= (plist-get (etaf-video-player-tests--state) :presented) 1))))
         (with-current-buffer "*Video Player*"
           (execute-kbd-macro (kbd "SPC")))
         (should-not (plist-get (etaf-video-player-tests--state) :playing))
         (with-current-buffer "*Video Player*"
           (execute-kbd-macro (kbd "a")))
         (should-not (plist-get (etaf-video-player-tests--state) :audio))
         (let ((presented (plist-get (etaf-video-player-tests--state) :presented)))
           (with-current-buffer "*Video Player*"
             (execute-kbd-macro (kbd "n")))
           (should (etaf-video-player-tests--wait
                    (lambda ()
                      (> (plist-get (etaf-video-player-tests--state) :presented)
                         presented)))))
         (with-current-buffer "*Video Player*"
           (execute-kbd-macro (kbd "SPC")))
         (should (plist-get (etaf-video-player-tests--state) :playing))
         (with-current-buffer "*Video Player*"
           (execute-kbd-macro (kbd "q")))
         (should-not (get-buffer "*Video Player*")))
      (ignore-errors (delete-file log))
      (etaf-video-player-tests--cleanup))))

(ert-deftest etaf-video-player-tests-canvas-and-close-follow-the-application ()
  "The canvas follows the appearance and killing the buffer closes the player.
Cells the shell leaves unpainted take the chrome color of the current
appearance, T repaints them, and killing the buffer saves the playback
position the way `q' does."
  (etaf-video-player-tests--cleanup)
  (let ((log (etaf-video-player-tests--log))
        (directory (make-temp-file "etaf-video-player-close-" t))
        (etaf-video-player-theme-mode 'dark)
        (canvas (lambda (buffer)
                  (with-current-buffer buffer
                    (plist-get (car (last (alist-get 'default face-remapping-alist)))
                               :background)))))
    (unwind-protect
        (let ((video (expand-file-name "close.mp4" directory)))
          (write-region "" nil video)
          (etaf-video-player-tests--with-fixture
           log (list "FAKE_FFMPEG_FRAMES=800" "FAKE_FFMPEG_INTERVAL=0.02"
                     "FAKE_FFPROBE_DURATION=60.0" "FAKE_FFPROBE_FPS=50/1")
           (save-window-excursion
             (let ((buffer (etaf-video-player-open
                            (list :file video :columns 8 :rows 2 :audio nil))))
               (should (etaf-video-player-tests--wait
                        (lambda ()
                          (>= (plist-get (etaf-video-player-tests--state) :presented)
                              1))))
               (should (equal (funcall canvas buffer) "#111216"))
               (with-current-buffer buffer
                 (execute-kbd-macro (kbd "T")))
               (should (eq etaf-video-player-theme-mode 'light))
               (should (equal (funcall canvas buffer) "#F7F8FA"))
               (with-current-buffer buffer
                 (execute-kbd-macro (kbd "SPC"))
                 (should-not (plist-get (etaf-video-player-tests--state) :playing))
                 (etaf-video-player-seek 20))
               (kill-buffer buffer)
               (should-not (get-buffer "*Video Player*"))
               (let ((saved (car (etaf-video-player-history-position video))))
                 (should (and (numberp saved) (< 19 saved 21))))))))
      (ignore-errors (delete-file log))
      (etaf-video-player-tests--cleanup)
      (ignore-errors (delete-directory directory t)))))

(ert-deftest etaf-video-player-tests-preserves-frame-background-and-mode-line ()
  "Opening the player keeps Emacs's mode line and frame background untouched.
The player paints its own buffer canvas and buffer-local fringe in its
palette so split windows and other buffers in the frame keep their theme."
  (etaf-video-player-tests--cleanup)
  (let* ((log (etaf-video-player-tests--log))
         (etaf-video-player-theme-mode 'dark)
         (frame (selected-frame))
         (original (frame-parameter frame 'background-color)))
    (unwind-protect
        (etaf-video-player-tests--with-fixture
         log (list "FAKE_FFMPEG_FRAMES=400" "FAKE_FFMPEG_INTERVAL=0.02"
                   "FAKE_FFPROBE_DURATION=8.0" "FAKE_FFPROBE_FPS=50/1")
         (save-window-excursion
           (let ((buffer (etaf-video-player-open
                          (list :file etaf-video-player-tests--input
                                :columns 16 :rows 4 :audio nil))))
             (with-current-buffer buffer
               (should mode-line-format)
               (let ((fringe-bg (plist-get (car (last (alist-get 'fringe
                                                                 face-remapping-alist)))
                                           :background)))
                 (should (equal fringe-bg "#1B1D23")))
               (should (equal (frame-parameter frame 'background-color) original))
               (execute-kbd-macro (kbd "T"))
               (should (equal (frame-parameter frame 'background-color) original))
               (let ((fringe-bg (plist-get (car (last (alist-get 'fringe
                                                                 face-remapping-alist)))
                                           :background)))
                 (should (equal fringe-bg "#FFFFFF")))
               (execute-kbd-macro (kbd "q"))))
           (should (equal (frame-parameter frame 'background-color) original))))
      (ignore-errors (delete-file log))
      (etaf-video-player-tests--cleanup))))

(ert-deftest etaf-video-player-tests-open-interactively-shows-welcome ()
  "The generic entry opens the Welcome / Continue Watching home screen.
`M-x etaf-video-player-open' reads nothing from the minibuffer and spawns no
decoder until the user picks a file, URL, history item or demo (`d')."
  (etaf-video-player-tests--cleanup)
  (let ((log (etaf-video-player-tests--log))
        prompted)
    (unwind-protect
        (etaf-video-player-tests--with-fixture
         log (list "FAKE_FFMPEG_FRAMES=100" "FAKE_FFMPEG_INTERVAL=0.02")
         (cl-letf (((symbol-function 'read-file-name)
                    (lambda (&rest _) (setq prompted t) ""))
                   ((symbol-function 'read-string)
                    (lambda (&rest _) (setq prompted t) ""))
                   ((symbol-function 'read-from-minibuffer)
                    (lambda (&rest _) (setq prompted t) "")))
           (call-interactively #'etaf-video-player-open))
         (should-not prompted)
         (let ((st (etaf-video-player-tests--state)))
           (should (plist-get st :welcome))
           (should-not (plist-get st :playing))
           (should-not (etaf-video-player-tests--runs log)))
         (with-current-buffer "*Video Player*"
           (should-error (etaf-video-player-toggle-playback) :type 'user-error)
           ;; Pressing `d' transitions explicitly to the built-in test pattern.
           (execute-kbd-macro (kbd "d")))
         (let ((st (etaf-video-player-tests--state)))
           (should-not (plist-get st :welcome))
           (should (eq 'demo (plist-get st :source)))
           (should (equal "内建演示" (plist-get st :title)))
           (should (plist-get st :playing)))
         (etaf-video-player-close))
      (ignore-errors (delete-file log))
      (etaf-video-player-tests--cleanup))))

(ert-deftest etaf-video-player-tests-plays-demo-with-real-ffmpeg ()
  "The built-in demo plays through a real ffmpeg when one is installed.
This scenario is skipped on machines without ffmpeg; the fixture scenarios
above still cover the full public path there."
  (skip-unless (executable-find "ffmpeg"))
  (etaf-video-player-tests--cleanup)
  (unwind-protect
      (progn
        (etaf-video-player-demo)
        (etaf-video-player-set-grid 48 14)
        (should (etaf-video-player-tests--wait
                 (lambda () (>= (plist-get (etaf-video-player-tests--state) :presented) 2))
                 10))
        (should (= 30 (plist-get (etaf-video-player-tests--state) :source-fps)))
        (should (equal 640 (plist-get (etaf-video-player-tests--state) :source-width))))
    (etaf-video-player-tests--cleanup)))

(ert-deftest etaf-video-player-tests-playlist-navigates-and-edits ()
  "A playlist plays items by index and follows next, previous and edits.
The state reports the queue length, the running index and the title, and
enqueue/remove keep the running item addressable."
  (etaf-video-player-tests--cleanup)
  (let ((log (etaf-video-player-tests--log))
        (second (make-temp-file "etaf-video-second-" nil ".mp4")))
    (unwind-protect
        (etaf-video-player-tests--with-fixture
         log (list "FAKE_FFMPEG_FRAMES=400" "FAKE_FFMPEG_INTERVAL=0.02"
                   "FAKE_FFPROBE_DURATION=8.0" "FAKE_FFPROBE_FPS=50/1")
         (copy-file etaf-video-player-tests--input second t)
         (etaf-video-player-open
          (list :playlist (list (list :file etaf-video-player-tests--input)
                                (list :file second))
                :columns 16 :rows 4))
         (should (etaf-video-player-tests--wait
                  (lambda () (>= (plist-get (etaf-video-player-tests--state) :presented) 1))))
         (should (= 2 (plist-get (etaf-video-player-tests--state) :queue-length)))
         (should (= 0 (plist-get (etaf-video-player-tests--state) :index)))
         (should (equal "fake-ffmpeg.py"
                        (plist-get (etaf-video-player-tests--state) :title)))
         (with-current-buffer "*Video Player*" (etaf-video-player-next))
         (should (= 1 (plist-get (etaf-video-player-tests--state) :index)))
         (should (equal (file-name-nondirectory second)
                        (plist-get (etaf-video-player-tests--state) :title)))
         (should (plist-get (etaf-video-player-tests--state) :playing))
         (with-current-buffer "*Video Player*" (etaf-video-player-previous))
         (should (= 0 (plist-get (etaf-video-player-tests--state) :index)))
         (with-current-buffer "*Video Player*" (etaf-video-player-play-index 1))
         (should (= 1 (plist-get (etaf-video-player-tests--state) :index)))
         (with-current-buffer "*Video Player*"
           (etaf-video-player-enqueue (list :file etaf-video-player-tests--input)))
         (should (= 3 (plist-get (etaf-video-player-tests--state) :queue-length)))
         (with-current-buffer "*Video Player*" (etaf-video-player-remove 0))
         (should (= 2 (plist-get (etaf-video-player-tests--state) :queue-length)))
         (should (= 0 (plist-get (etaf-video-player-tests--state) :index)))
         (should-error (with-current-buffer "*Video Player*"
                         (etaf-video-player-remove 0) (etaf-video-player-remove 0))
                       :type 'user-error)
         (etaf-video-player-close))
      (ignore-errors (delete-file log))
      (ignore-errors (delete-file second))
      (etaf-video-player-tests--cleanup))))

(ert-deftest etaf-video-player-tests-playlist-auto-advances-with-loop ()
  "An item that ends advances according to the loop policy.
`all' plays the next item and wraps to the first, `one' repeats the item
and `none' stops on the last one."
  (etaf-video-player-tests--cleanup)
  (let ((log (etaf-video-player-tests--log)))
    (unwind-protect
        (etaf-video-player-tests--with-fixture
         log (list "FAKE_FFMPEG_FRAMES=2" "FAKE_FFMPEG_INTERVAL=0.01"
                   "FAKE_FFPROBE_DURATION=1.0" "FAKE_FFPROBE_FPS=50/1")
         (etaf-video-player-open
          (list :playlist (list (list :file etaf-video-player-tests--input)
                                (list :file etaf-video-player-tests--input))
                :loop 'all :columns 8 :rows 2))
         (should (etaf-video-player-tests--wait
                  (lambda () (= 1 (plist-get (etaf-video-player-tests--state) :index)))
                  6))
         (should (etaf-video-player-tests--wait
                  (lambda () (= 0 (plist-get (etaf-video-player-tests--state) :index)))
                  6))
         (etaf-video-player-close))
      (ignore-errors (delete-file log))
      (etaf-video-player-tests--cleanup)))
  (etaf-video-player-tests--cleanup)
  (let ((log (etaf-video-player-tests--log)))
    (unwind-protect
        (etaf-video-player-tests--with-fixture
         log (list "FAKE_FFMPEG_FRAMES=2" "FAKE_FFMPEG_INTERVAL=0.01"
                   "FAKE_FFPROBE_DURATION=1.0" "FAKE_FFPROBE_FPS=50/1")
         (etaf-video-player-open
          (list :playlist (list (list :file etaf-video-player-tests--input)
                                (list :file etaf-video-player-tests--input))
                :loop 'none :columns 8 :rows 2))
         (should (etaf-video-player-tests--wait
                  (lambda () (= 1 (plist-get (etaf-video-player-tests--state) :index)))
                  6))
         (should (etaf-video-player-tests--wait
                  (lambda () (plist-get (etaf-video-player-tests--state) :ended))
                  6))
         (should (= 1 (plist-get (etaf-video-player-tests--state) :index)))
         (etaf-video-player-close))
      (ignore-errors (delete-file log))
      (etaf-video-player-tests--cleanup)))
  ;; `one' repeats the same item from zero without advancing the index.
  (etaf-video-player-tests--cleanup)
  (let ((log (etaf-video-player-tests--log)))
    (unwind-protect
        (etaf-video-player-tests--with-fixture
         log (list "FAKE_FFMPEG_FRAMES=2" "FAKE_FFMPEG_INTERVAL=0.01"
                   "FAKE_FFPROBE_DURATION=1.0" "FAKE_FFPROBE_FPS=50/1")
         (etaf-video-player-open
          (list :file etaf-video-player-tests--input
                :loop 'one :columns 8 :rows 2 :audio nil))
         (should (etaf-video-player-tests--wait
                  (lambda () (>= (plist-get (etaf-video-player-tests--state) :presented) 4))
                  6))
         (should (= 0 (plist-get (etaf-video-player-tests--state) :index)))
         (etaf-video-player-close))
      (ignore-errors (delete-file log))
      (etaf-video-player-tests--cleanup)))
  ;; `none' with shuffle still stops cleanly on a single-item queue.
  (etaf-video-player-tests--cleanup)
  (let ((log (etaf-video-player-tests--log)))
    (unwind-protect
        (etaf-video-player-tests--with-fixture
         log (list "FAKE_FFMPEG_FRAMES=2" "FAKE_FFMPEG_INTERVAL=0.01"
                   "FAKE_FFPROBE_DURATION=1.0" "FAKE_FFPROBE_FPS=50/1")
         (etaf-video-player-open
          (list :file etaf-video-player-tests--input
                :loop 'none :shuffle t :columns 8 :rows 2 :audio nil))
         (should (etaf-video-player-tests--wait
                  (lambda () (plist-get (etaf-video-player-tests--state) :ended))
                  6))
         (let ((presented (plist-get (etaf-video-player-tests--state) :presented)))
           (sleep-for 0.35)
           (should (plist-get (etaf-video-player-tests--state) :ended))
           (should (= presented (plist-get (etaf-video-player-tests--state) :presented))))
         (etaf-video-player-close))
      (ignore-errors (delete-file log))
      (etaf-video-player-tests--cleanup))))

(ert-deftest etaf-video-player-tests-playlist-shuffle-stays-in-range ()
  "Shuffle picks another item in the queue, returns on previous and reports its flag."
  (etaf-video-player-tests--cleanup)
  (let ((log (etaf-video-player-tests--log)))
    (unwind-protect
        (etaf-video-player-tests--with-fixture
         log (list "FAKE_FFMPEG_FRAMES=400" "FAKE_FFMPEG_INTERVAL=0.02"
                   "FAKE_FFPROBE_DURATION=8.0" "FAKE_FFPROBE_FPS=50/1")
         (etaf-video-player-open
          (list :playlist (list (list :file etaf-video-player-tests--input)
                                (list :file etaf-video-player-tests--input)
                                (list :file etaf-video-player-tests--input))
                :columns 8 :rows 2))
         (should (etaf-video-player-tests--wait
                  (lambda () (>= (plist-get (etaf-video-player-tests--state) :presented) 1))))
         (with-current-buffer "*Video Player*" (etaf-video-player-toggle-shuffle))
         (should (plist-get (etaf-video-player-tests--state) :shuffle))
         (let ((before (plist-get (etaf-video-player-tests--state) :index)))
           (with-current-buffer "*Video Player*" (etaf-video-player-next))
           (let ((after (plist-get (etaf-video-player-tests--state) :index)))
             (should (and (>= after 0) (< after 3)))
             (should-not (= before after))
             ;; Previous steps back along the same shuffle order.
             (with-current-buffer "*Video Player*" (etaf-video-player-previous))
             (should (= before (plist-get (etaf-video-player-tests--state) :index)))))
         (with-current-buffer "*Video Player*" (etaf-video-player-toggle-shuffle))
         (should-not (plist-get (etaf-video-player-tests--state) :shuffle))
         (etaf-video-player-close))
      (ignore-errors (delete-file log))
      (etaf-video-player-tests--cleanup))))

(ert-deftest etaf-video-player-tests-subtitles-parse-time-and-probe ()
  "SubRip and WebVTT tracks parse into timed cues and answer lookups.
The parser skips malformed blocks and strips inline markup; the binary
search returns the cue covering a playback second; an unreadable file raises
the documented error and the beside probe prefers the language suffix."
  (let ((track (make-temp-file "etaf-video-player-subtitle-" nil ".srt"))
        (webvtt (make-temp-file "etaf-video-player-subtitle-" nil ".vtt"))
        (directory (make-temp-file "etaf-video-player-video-" t)))
    (unwind-protect
        (progn
          (with-temp-file track
            (insert "1\n00:00:01,000 --> 00:00:03,500\n第一行<i>字幕</i>\n第二行\n\n"
                    "2\n00:00:04,000 --> 00:00:06,000\n第二句\n\n"
                    "block without a clock\n\n"
                    "3\n00:00:07,000 --> 00:00:09,000\n第三句\n"))
          (let ((cues (etaf-video-player-subtitle-parse track)))
            (should (= 3 (length cues)))
            (should (equal "第一行字幕 第二行" (nth 2 (nth 0 cues))))
            (should (equal "第二句" (nth 2 (nth 1 cues))))
            (should-not (etaf-video-player-subtitle-text-at cues 0.5))
            (should (equal "第一行字幕 第二行"
                           (etaf-video-player-subtitle-text-at cues 2.0)))
            (should-not (etaf-video-player-subtitle-text-at cues 3.5))
            (should (equal "第二句" (etaf-video-player-subtitle-text-at cues 4.5)))
            (should (equal "第三句" (etaf-video-player-subtitle-text-at cues 8.0)))
            (should-not (etaf-video-player-subtitle-text-at cues 9.5)))
          (with-temp-file webvtt
            (insert "\ufeffWEBVTT\n\n"
                    "NOTE comment 00:00:00,000 --> 00:00:10,000\nignored\n\n"
                    "00:01.000 --> 00:02.000\nVTT 字幕\n\n"
                    "00:00:03 --> 00:00:04.5\n可变小数\n\n"
                    "5.500 --> 6,50\n纯秒数\n\n"
                    "00:00:10,000 --> 00:00:20,000\n长字幕\n\n"
                    "00:00:12,000 --> 00:00:14,000\n叠层短字幕\n"))
          (let ((cues (etaf-video-player-subtitle-parse webvtt)))
            (should (equal "VTT 字幕" (etaf-video-player-subtitle-text-at cues 1.5)))
            (should (equal "可变小数" (etaf-video-player-subtitle-text-at cues 3.2)))
            (should (equal "可变小数" (etaf-video-player-subtitle-text-at cues 4.4)))
            (should-not (etaf-video-player-subtitle-text-at cues 4.6))
            (should (equal "纯秒数" (etaf-video-player-subtitle-text-at cues 6.0)))
            (should (equal "长字幕 叠层短字幕"
                           (etaf-video-player-subtitle-text-at cues 13.0)))
            (should (equal "长字幕"
                           (etaf-video-player-subtitle-text-at cues 16.0))))
          (should-error (etaf-video-player-subtitle-parse
                         (expand-file-name "missing.srt" directory))
                        :type 'etaf-video-player-subtitle-error)
          (let* ((video (expand-file-name "clip.mp4" directory))
                 (beside (expand-file-name "clip.zh.srt" directory)))
            (write-region "1\n00:00:00,000 --> 00:00:02,000\n嗨\n" nil beside)
            (should (equal beside (etaf-video-player-subtitle-beside video)))
            (should-not (etaf-video-player-subtitle-beside
                         (expand-file-name "other.mp4" directory)))))
      (ignore-errors (delete-file track))
      (ignore-errors (delete-file webvtt))
      (ignore-errors (delete-directory directory t)))))

(ert-deftest etaf-video-player-tests-subtitle-loads-beside-video-and-toggles ()
  "A local video adopts the track beside it and the c key toggles it.
The subtitle line reaches the buffer through the retained content update and
leaves with the next retained tick, without a graphical frame."
  (etaf-video-player-tests--cleanup)
  (let ((log (etaf-video-player-tests--log))
        (directory (make-temp-file "etaf-video-player-video-" t)))
    (unwind-protect
        (let ((video (expand-file-name "clip.mp4" directory))
              (track (expand-file-name "clip.srt" directory)))
          (write-region "" nil video)
          (write-region "1\n00:00:00,000 --> 00:00:30,000\n测试字幕行\n" nil track)
          (etaf-video-player-tests--with-fixture
           log (list "FAKE_FFMPEG_FRAMES=400" "FAKE_FFMPEG_INTERVAL=0.02"
                     "FAKE_FFPROBE_DURATION=30.0" "FAKE_FFPROBE_FPS=50/1")
           (etaf-video-player-open (list :file video :columns 8 :rows 2))
           (should (equal track (plist-get (etaf-video-player-tests--state)
                                           :subtitle-file)))
           (should (plist-get (etaf-video-player-tests--state) :subtitle-on))
           (should (etaf-video-player-tests--wait
                    (lambda ()
                      (with-current-buffer "*Video Player*"
                        (string-match-p "测试字幕行" (buffer-string))))))
           (with-current-buffer "*Video Player*"
             (execute-kbd-macro (kbd "c")))
           (should-not (plist-get (etaf-video-player-tests--state) :subtitle-on))
           (should (etaf-video-player-tests--wait
                    (lambda ()
                      (with-current-buffer "*Video Player*"
                        (not (string-match-p "测试字幕行" (buffer-string)))))))
           (with-current-buffer "*Video Player*"
             (execute-kbd-macro (kbd "c")))
           (should (plist-get (etaf-video-player-tests--state) :subtitle-on))
           (etaf-video-player-close)))
      (ignore-errors (delete-file log))
      (etaf-video-player-tests--cleanup)
      (ignore-errors (delete-directory directory t)))))

(ert-deftest etaf-video-player-tests-history-records-and-resumes ()
  "Saved positions persist per file and a useful record resumes playback.
A record near the start or the end restarts from zero; unknown files have
no record."
  (etaf-video-player-tests--cleanup)
  (let ((log (etaf-video-player-tests--log))
        (directory (make-temp-file "etaf-video-player-video-" t)))
    (unwind-protect
        (let ((video (expand-file-name "resume.mp4" directory)))
          (write-region "" nil video)
          (should (equal 12.5 (etaf-video-player-history-record video 12.5 100.0)))
          (should (equal (cons 12.5 100.0)
                         (etaf-video-player-history-position video)))
          (etaf-video-player-history-record video 30.0 120.0)
          (should (equal (cons 30.0 120.0)
                         (etaf-video-player-history-position video)))
          (should-not (etaf-video-player-history-position
                       (expand-file-name "never.mp4" directory)))
          ;; A useful record resumes playback right after open.
          (etaf-video-player-history-record video 40.0 200.0)
          (etaf-video-player-tests--with-fixture
           log (list "FAKE_FFMPEG_FRAMES=800" "FAKE_FFMPEG_INTERVAL=0.02"
                     "FAKE_FFPROBE_DURATION=200.0" "FAKE_FFPROBE_FPS=50/1")
           (etaf-video-player-open (list :file video :columns 8 :rows 2))
           (should (etaf-video-player-tests--wait
                    (lambda ()
                      (> (plist-get (etaf-video-player-tests--state) :position)
                         35))))
           (etaf-video-player-close))
          ;; A record at the very end restarts from the beginning.
          (etaf-video-player-history-record video 195.0 200.0)
          (etaf-video-player-tests--with-fixture
           log (list "FAKE_FFMPEG_FRAMES=800" "FAKE_FFMPEG_INTERVAL=0.02"
                     "FAKE_FFPROBE_DURATION=200.0" "FAKE_FFPROBE_FPS=50/1")
           (etaf-video-player-open (list :file video :columns 8 :rows 2))
           (sleep-for 0.5)
           (should (< (plist-get (etaf-video-player-tests--state) :position) 30))
           (etaf-video-player-close)))
      (ignore-errors (delete-file log))
      (etaf-video-player-tests--cleanup)
      (ignore-errors (delete-directory directory t)))))

(ert-deftest etaf-video-player-tests-screenshot-writes-a-png ()
  "S saves the current frame as a readable PNG beside the video.
Runs only where a real ffmpeg is installed; the fixture scenarios above do
not cover the decode-to-image path."
  (skip-unless (executable-find "ffmpeg"))
  (etaf-video-player-tests--cleanup)
  (let ((directory (make-temp-file "etaf-video-player-shot-" t)))
    (unwind-protect
        (let ((video (expand-file-name "shot.mp4" directory)))
          (should (zerop (call-process "ffmpeg" nil nil nil
                                       "-hide_banner" "-loglevel" "error"
                                       "-f" "lavfi" "-i" "testsrc=size=64x36:rate=10"
                                       "-t" "1" "-pix_fmt" "yuv420p" "-y" video)))
          (etaf-video-player-open (list :file video :columns 8 :rows 2))
          (should (etaf-video-player-tests--wait
                   (lambda ()
                     (>= (plist-get (etaf-video-player-tests--state) :presented) 1))
                   10))
          (let ((output (expand-file-name "frame.png" directory)))
            (should (equal output (etaf-video-player-save-screenshot output)))
            (should (etaf-video-player-tests--wait
                     (lambda ()
                       (and (file-readable-p output)
                            (> (file-attribute-size (file-attributes output)) 0)))
                     10)))
          (etaf-video-player-close))
      (etaf-video-player-tests--cleanup)
      (ignore-errors (delete-directory directory t)))))

(ert-deftest etaf-video-player-tests-help-stays-in-player ()
  "Both help keys preserve the player and guard playback while searching."
  (save-window-excursion
    (let ((log (etaf-video-player-tests--log)))
      (unwind-protect
          (etaf-video-player-tests--with-fixture
              log '("FAKE_FFMPEG_FRAMES=400" "FAKE_FFMPEG_INTERVAL=0.1")
            (let* ((buffer (etaf-video-player-open
                            (list :file etaf-video-player-tests--input :columns 16 :rows 4 :audio nil)))
                   (runtime (etaf-runtime-for-buffer buffer))
                   (windows (window-list)))
              (with-current-buffer buffer
                (etaf-video-player-toggle-playback)
                (dolist (key '("?" "C-c h"))
                  (execute-kbd-macro (kbd key))
                  (let* ((data (etaf-help-data runtime))
                         (entries (apply #'append (mapcar (lambda (group) (plist-get group :entries))
                                                          (plist-get data :groups))))
                         (play (cl-find "SPC" entries :key (lambda (entry) (plist-get entry :key))
                                        :test #'equal))
                         (same-runtime (eq runtime (etaf-runtime-for-buffer buffer))))
                    (should same-runtime)
                    (should (equal windows (window-list)))
                    (should (eq (window-buffer) buffer))
                    (should (equal (plist-get play :label) "播放／暂停")))
                  (execute-kbd-macro (kbd "SPC"))
                  (execute-kbd-macro (kbd "/"))
                  (execute-kbd-macro "?")
                  (execute-kbd-macro (kbd "<escape>"))
                  (let ((editing (etaf-text-input-active-p runtime)))
                    (should-not editing))
                  (should (string-match-p "快捷键 · 只读"
                                          (buffer-substring-no-properties (point-min) (point-max))))
                  (execute-kbd-macro (kbd "<escape>"))
                  (let ((playing (plist-get (etaf-video-player-state) :playing))
                        (text (buffer-substring-no-properties (point-min) (point-max))))
                    (should-not playing)
                    (should (string-match-p "SPC" text))
                    (should-not (string-match-p "快捷键 · 只读" text)))))))
        (etaf-video-player-tests--cleanup)
        (delete-file log)))))

(ert-deftest etaf-video-player-tests-opens-directory-and-lazy-probes ()
  "Opening a directory collects sorted video files and probes non-active items lazily.
An empty directory signals `user-error' before any player opens."
  (etaf-video-player-tests--cleanup)
  (let ((log (etaf-video-player-tests--log))
        (probe-log (etaf-video-player-tests--log))
        (directory (make-temp-file "etaf-video-player-dir-" t))
        (empty-dir (make-temp-file "etaf-video-player-empty-" t)))
    (unwind-protect
        (progn
          (write-region "" nil (expand-file-name "01-alpha.mp4" directory))
          (write-region "" nil (expand-file-name "02-beta.mkv" directory))
          (write-region "" nil (expand-file-name "03-gamma.webm" directory))
          (write-region "" nil (expand-file-name "notes.txt" directory))
          (should-error (etaf-video-player-open empty-dir) :type 'user-error)
          (etaf-video-player-tests--with-fixture
           log (list "FAKE_FFMPEG_FRAMES=400" "FAKE_FFMPEG_INTERVAL=0.02"
                     "FAKE_FFPROBE_DURATION=30.0" "FAKE_FFPROBE_FPS=50/1"
                     (concat "FAKE_FFPROBE_LOG=" probe-log))
           (etaf-video-player-open (list :file directory :columns 12 :rows 3 :audio nil))
           (let* ((state (etaf-video-player-tests--state))
                  (runs-at-open (etaf-video-player-tests--runs probe-log))
                  (beta (expand-file-name "02-beta.mkv" directory))
                  (gamma (expand-file-name "03-gamma.webm" directory)))
             (should (= 3 (plist-get state :queue-length)))
             (should (equal "01-alpha.mp4" (plist-get state :title)))
             ;; Non-active items were NOT probed at open time.
             (should-not (cl-some (lambda (r) (member beta r)) runs-at-open))
             (should-not (cl-some (lambda (r) (member gamma r)) runs-at-open))
             (with-current-buffer "*Video Player*" (etaf-video-player-next))
             (let ((next-state (etaf-video-player-tests--state))
                   (runs-after-next (etaf-video-player-tests--runs probe-log)))
               (should (equal "02-beta.mkv" (plist-get next-state :title)))
               (should (cl-some (lambda (r) (member beta r)) runs-after-next))
               (should-not (cl-some (lambda (r) (member gamma r)) runs-after-next))))
           (etaf-video-player-close)))
      (ignore-errors (delete-file log))
      (ignore-errors (delete-file probe-log))
      (ignore-errors (delete-directory directory t))
      (ignore-errors (delete-directory empty-dir t))
      (etaf-video-player-tests--cleanup))))

(ert-deftest etaf-video-player-tests-quick-keys-subtitle-offset-and-doctor ()
  "Quick seek keys, single-dimension grid hints, subtitle offset and doctor work.
`C-f'/`C-b' seek 30 seconds, `0' restarts from zero, `z'/`x' shift subtitles
by 0.5 seconds, a single `:columns' hint derives `:rows', and doctor honors
configured program variables."
  (etaf-video-player-tests--cleanup)
  (let ((log (etaf-video-player-tests--log))
        (directory (make-temp-file "etaf-video-player-quick-" t)))
    (unwind-protect
        (let ((video (expand-file-name "clip.mp4" directory))
              (track (expand-file-name "clip.srt" directory)))
          (write-region "" nil video)
          (write-region "1\n00:00:00,400 --> 00:00:01,000\n延迟字幕\n" nil track)
          (etaf-video-player-tests--with-fixture
           log (list "FAKE_FFMPEG_FRAMES=800" "FAKE_FFMPEG_INTERVAL=0.02"
                     "FAKE_FFPROBE_DURATION=120.0" "FAKE_FFPROBE_FPS=50/1")
           (let ((doctor (etaf-video-player-doctor)))
             (should (= 1 (length (plist-get doctor :required))))
             (should (nth 1 (car (plist-get doctor :required))))
             (should (>= (length (plist-get doctor :optional)) 3)))
           (etaf-video-player-open (list :file video :columns 64 :audio nil))
           (let ((state (etaf-video-player-tests--state)))
             (should (= 64 (plist-get state :columns)))
             (should (> (plist-get state :rows) 1)))
           (with-current-buffer "*Video Player*"
             (etaf-video-player-toggle-playback)
             (etaf-video-player-seek 0)
             (execute-kbd-macro (kbd "C-f"))
             (should (>= (plist-get (etaf-video-player-tests--state) :position) 29))
             (execute-kbd-macro (kbd "C-b"))
             (should (<= (plist-get (etaf-video-player-tests--state) :position) 1))
             (etaf-video-player-seek 45)
             (execute-kbd-macro (kbd "0"))
             (should (= 0 (plist-get (etaf-video-player-tests--state) :position)))
             ;; At t=0 the cue at 0.4..1.0 is hidden; `z' (+0.5s) brings it in.
             (should-not (string-match-p "延迟字幕"
                                         (buffer-substring-no-properties (point-min) (point-max))))
             (execute-kbd-macro (kbd "z"))
             (should (string-match-p "延迟字幕"
                                     (buffer-substring-no-properties (point-min) (point-max))))
             (execute-kbd-macro (kbd "x"))
             (should-not (string-match-p "延迟字幕"
                                         (buffer-substring-no-properties (point-min) (point-max)))))
           (etaf-video-player-close)))
      (ignore-errors (delete-file log))
      (ignore-errors (delete-directory directory t))
      (etaf-video-player-tests--cleanup))))

(ert-deftest etaf-video-player-tests-canvas-click-and-decoder-error ()
  "Clicking the video canvas toggles playback and decoder errors surface in state."
  (etaf-video-player-tests--cleanup)
  (let ((log (etaf-video-player-tests--log)))
    (unwind-protect
        (progn
          (etaf-video-player-tests--with-fixture
           log (list "FAKE_FFMPEG_FRAMES=400" "FAKE_FFMPEG_INTERVAL=0.02"
                     "FAKE_FFPROBE_DURATION=8.0" "FAKE_FFPROBE_FPS=50/1")
           (let* ((buffer (etaf-video-player-open
                           (list :file etaf-video-player-tests--input
                                 :columns 12 :rows 3 :audio nil)))
                  (runtime (etaf-runtime-for-buffer buffer)))
             (should (plist-get (etaf-video-player-tests--state) :playing))
             (etaf-dispatch-event runtime 'video-canvas 'press)
             (should-not (plist-get (etaf-video-player-tests--state) :playing))
             (etaf-dispatch-event runtime 'video-canvas 'press)
             (should (plist-get (etaf-video-player-tests--state) :playing))
             (etaf-video-player-close)))
          (etaf-video-player-tests--with-fixture
           log (list "FAKE_FFMPEG_FRAMES=0" "FAKE_FFMPEG_STATUS=1"
                     "FAKE_FFMPEG_ERROR=HTTP 404 Not Found"
                     "FAKE_FFPROBE_DURATION=8.0")
           (etaf-video-player-open
            (list :file etaf-video-player-tests--input
                  :columns 12 :rows 3 :audio nil))
           (should (etaf-video-player-tests--wait
                    (lambda () (plist-get (etaf-video-player-tests--state) :error))
                    5))
           (let ((err (plist-get (etaf-video-player-tests--state) :error)))
             (should (string-match-p "404" err)))
           (should (etaf-video-player-tests--wait
                    (lambda ()
                      (with-current-buffer "*Video Player*"
                        (string-match-p "出错"
                                        (buffer-substring-no-properties
                                         (point-min) (point-max)))))
                    5))
           (etaf-video-player-close)))
      (ignore-errors (delete-file log))
      (etaf-video-player-tests--cleanup))))

(ert-deftest etaf-video-player-tests-drawers-theater-ab-and-goto ()
  "Theater/Studio drawers, goto-time, A-B loop and queue reordering work cleanly."
  (etaf-video-player-tests--cleanup)
  (let ((log (etaf-video-player-tests--log))
        (dir (make-temp-file "etaf-video-player-studio-" t)))
    (unwind-protect
        (let ((a (expand-file-name "first.mp4" dir))
              (b (expand-file-name "second.mp4" dir)))
          (write-region "" nil a)
          (write-region "" nil b)
          (etaf-video-player-tests--with-fixture
           log (list "FAKE_FFMPEG_FRAMES=400" "FAKE_FFMPEG_INTERVAL=0.02"
                     "FAKE_FFPROBE_DURATION=120.0" "FAKE_FFPROBE_FPS=50/1")
           ;; Single video opens in Cinema Theater mode by default.
           (etaf-video-player-open (list :file a :columns 12 :rows 3 :audio nil))
           (let ((st (etaf-video-player-tests--state)))
             (should (plist-get st :theater))
             (should-not (plist-get st :media-panel))
             (should-not (plist-get st :inspector)))
           (with-current-buffer "*Video Player*"
             (execute-kbd-macro (kbd "p"))
             (should (plist-get (etaf-video-player-tests--state) :media-panel))
             (execute-kbd-macro (kbd "i"))
             (should (plist-get (etaf-video-player-tests--state) :inspector))
             (execute-kbd-macro (kbd "w"))
             (should (plist-get (etaf-video-player-tests--state) :theater))
             ;; Pressing `w' again restores previously open drawers.
             (execute-kbd-macro (kbd "w"))
             (should (plist-get (etaf-video-player-tests--state) :media-panel))
             (should (plist-get (etaf-video-player-tests--state) :inspector))
             ;; Goto time parses MM:SS and plain seconds.
             (etaf-video-player-toggle-playback)
             (etaf-video-player-goto-time "01:05")
             (should (= 65 (plist-get (etaf-video-player-tests--state) :position)))
             (etaf-video-player-goto-time "10")
             (should (= 10 (plist-get (etaf-video-player-tests--state) :position)))
             ;; A-B loop lifecycle.
             (etaf-video-player-set-ab-start 10)
             (etaf-video-player-set-ab-end 25)
             (should (equal '(10.0 . 25.0)
                            (plist-get (etaf-video-player-tests--state) :ab-loop)))
             (etaf-video-player-clear-ab)
             (should-not (plist-get (etaf-video-player-tests--state) :ab-loop))
             ;; Enqueue and reorder current item with J / K.
             (etaf-video-player-enqueue b)
             (should (= 2 (plist-get (etaf-video-player-tests--state) :queue-length)))
             (execute-kbd-macro (kbd "J"))
             (should (= 1 (plist-get (etaf-video-player-tests--state) :index)))
             (execute-kbd-macro (kbd "K"))
             (should (= 0 (plist-get (etaf-video-player-tests--state) :index))))
           (etaf-video-player-close)))
      (ignore-errors (delete-file log))
      (ignore-errors (delete-directory dir t))
      (etaf-video-player-tests--cleanup))))

(ert-deftest etaf-video-player-tests-bookmarks-history-and-chapters ()
  "SQLite bookmarks, recent watch history and async chapter navigation work."
  (etaf-video-player-tests--cleanup)
  (let* ((log (etaf-video-player-tests--log))
         (dir (make-temp-file "etaf-video-player-bm-" t))
         (etaf-video-player-history-file (expand-file-name "player.sqlite3" dir))
         (chapters-json
          "[{\"start_time\":\"0.0\",\"end_time\":\"20.0\",\"tags\":{\"title\":\"Intro\"}},{\"start_time\":\"20.0\",\"end_time\":\"60.0\",\"tags\":{\"title\":\"Boss Fight\"}}]"))
    (unwind-protect
        (let ((clip (expand-file-name "zhongkui.mp4" dir)))
          (write-region "" nil clip)
          (etaf-video-player-tests--with-fixture
           log (list "FAKE_FFMPEG_FRAMES=400" "FAKE_FFMPEG_INTERVAL=0.02"
                     "FAKE_FFPROBE_DURATION=60.0" "FAKE_FFPROBE_FPS=50/1"
                     (concat "FAKE_FFPROBE_CHAPTERS=" chapters-json))
           (etaf-video-player-open (list :file clip :columns 12 :rows 3 :audio nil))
           (should (etaf-video-player-tests--wait
                    (lambda () (= 2 (plist-get (etaf-video-player-tests--state) :chapters)))
                    5))
           (with-current-buffer "*Video Player*"
             (etaf-video-player-toggle-playback)
             (etaf-video-player-seek 5)
             (etaf-video-player-next-chapter)
             (should (= 20 (plist-get (etaf-video-player-tests--state) :position)))
             (etaf-video-player-previous-chapter)
             (should (= 0 (plist-get (etaf-video-player-tests--state) :position)))
             ;; SQLite bookmarks round-trip.
             (etaf-video-player-seek 12)
             (let ((bm (etaf-video-player-add-bookmark "雨中挥刃")))
               (should bm)
               (should (= 1 (plist-get (etaf-video-player-tests--state) :bookmarks)))
               (should (equal "雨中挥刃"
                              (plist-get (car (etaf-video-player-bookmarks clip)) :note)))
               (etaf-video-player-bookmark-remove (plist-get bm :id))
               (should (null (etaf-video-player-bookmarks clip)))))
           (etaf-video-player-close)
           ;; Recent watch history recorded on close and can be queried/deleted.
           (let ((recent (etaf-video-player-history-recent 10)))
             (should (= 1 (length recent)))
             (should (equal (expand-file-name clip) (plist-get (car recent) :path)))
             (etaf-video-player-history-delete clip)
             (should (null (etaf-video-player-history-recent 10))))))
      (ignore-errors (delete-file log))
      (ignore-errors (delete-directory dir t))
      (etaf-video-player-tests--cleanup))))

(ert-deftest etaf-video-player-tests-m3u-siblings-sort-timestamp-stop-after ()
  "M3U playlists, sibling enqueue, queue sort, goto %/relative, copy time and stop-after work."
  (etaf-video-player-tests--cleanup)
  (let* ((log (etaf-video-player-tests--log))
         (dir (make-temp-file "etaf-video-player-m3u-" t))
         (a (expand-file-name "01-alpha.mp4" dir))
         (b (expand-file-name "02-beta.mp4" dir))
         (c (expand-file-name "03-gamma.mp4" dir))
         (m3u (expand-file-name "list.m3u" dir)))
    (unwind-protect
        (progn
          (write-region "" nil a)
          (write-region "" nil b)
          (write-region "" nil c)
          (with-temp-file m3u
            (insert "#EXTM3U\n"
                    "#EXTINF:100,Beta Clip\n"
                    "02-beta.mp4\n"
                    "#EXTINF:100,Alpha Clip\n"
                    "01-alpha.mp4\n"))
          (etaf-video-player-tests--with-fixture
           log (list "FAKE_FFMPEG_FRAMES=400" "FAKE_FFMPEG_INTERVAL=0.02"
                     "FAKE_FFPROBE_DURATION=100.0" "FAKE_FFPROBE_FPS=50/1")
           (etaf-video-player-open (list :file m3u :columns 12 :rows 3 :audio nil))
           (let ((st (etaf-video-player-tests--state)))
             (should (= 2 (plist-get st :queue-length)))
             (should (equal "Beta Clip" (plist-get st :title))))
           (with-current-buffer "*Video Player*"
             ;; Enqueue siblings adds only missing 03-gamma.mp4.
             (should (= 1 (etaf-video-player-enqueue-siblings)))
             (should (= 3 (plist-get (etaf-video-player-tests--state) :queue-length)))
             ;; Sort alphabetically while preserving active Beta Clip.
             (etaf-video-player-sort-queue)
             (let ((st (etaf-video-player-tests--state)))
               (should (equal "Beta Clip" (plist-get st :title)))
               (should (= 2 (plist-get st :index))))
             ;; Enhanced goto-time supports percentage and +/- relative jumps.
             (etaf-video-player-toggle-playback)
             (etaf-video-player-goto-time "50%")
             (should (= 50.0 (plist-get (etaf-video-player-tests--state) :position)))
             (etaf-video-player-goto-time "+15")
             (should (= 65.0 (plist-get (etaf-video-player-tests--state) :position)))
             (etaf-video-player-goto-time "-5")
             (should (= 60.0 (plist-get (etaf-video-player-tests--state) :position)))
             ;; Copy timestamp returns formatted clock and writes kill-ring.
             (let ((stamp (etaf-video-player-copy-timestamp)))
               (should (equal "01:00" stamp))
               (should (equal "01:00" (car kill-ring)))))
           (etaf-video-player-close))
          ;; Stop-after-current halts instead of advancing even under :loop all.
          (etaf-video-player-tests--with-fixture
           log (list "FAKE_FFMPEG_FRAMES=2" "FAKE_FFMPEG_INTERVAL=0.01"
                     "FAKE_FFPROBE_DURATION=1.0" "FAKE_FFPROBE_FPS=50/1")
           (etaf-video-player-open
            (list :playlist (list (list :file a) (list :file b))
                  :loop 'all :columns 8 :rows 2 :audio nil))
           (with-current-buffer "*Video Player*"
             (should (etaf-video-player-toggle-stop-after-current)))
           (should (etaf-video-player-tests--wait
                    (lambda ()
                      (let ((st (etaf-video-player-tests--state)))
                        (and (plist-get st :ended)
                             (not (plist-get st :stop-after-current)))))
                    6))
           (let ((st (etaf-video-player-tests--state)))
             (should (= 0 (plist-get st :index)))
             (should-not (plist-get st :stop-after-current)))
           (etaf-video-player-close)))
      (ignore-errors (delete-file log))
      (ignore-errors (delete-directory dir t))
      (etaf-video-player-tests--cleanup))))

(ert-deftest etaf-video-player-tests-libmpv-multitrack-subtitles-and-transforms ()
  "On libmpv, multi-audio, embedded/dual subtitles, rotation, step-back and screenshots work."
  (skip-unless (and (etaf-video-mpv-available-p)
                    (executable-find "ffmpeg")
                    (fboundp 'font-info)))
  (etaf-video-player-tests--cleanup)
  (let* ((dir (make-temp-file "etaf-video-player-mpv-" t))
         (sub-zh (expand-file-name "zh.srt" dir))
         (sub-en (expand-file-name "en.srt" dir))
         (mkv (expand-file-name "multi.mkv" dir))
         (shot (expand-file-name "mpv-shot.png" dir)))
    (unwind-protect
        (progn
          (with-temp-file sub-zh
            (insert "1\n00:00:00,000 --> 00:00:03,000\n中文字幕测试\n"))
          (with-temp-file sub-en
            (insert "1\n00:00:00,000 --> 00:00:03,000\nEnglish subtitle test\n"))
          (should
           (zerop
            (call-process
             "ffmpeg" nil nil nil "-hide_banner" "-loglevel" "error" "-y"
             "-f" "lavfi" "-i" "testsrc2=size=160x90:rate=15:duration=2.5"
             "-f" "lavfi" "-i" "sine=frequency=440:duration=2.5"
             "-f" "lavfi" "-i" "sine=frequency=660:duration=2.5"
             "-i" sub-zh "-i" sub-en
             "-map" "0:v" "-map" "1:a" "-map" "2:a" "-map" "3:s" "-map" "4:s"
             "-c:v" "libx264" "-pix_fmt" "yuv420p" "-c:a" "aac" "-c:s" "srt"
             "-metadata:s:a:0" "language=chi" "-metadata:s:a:0" "title=国语"
             "-metadata:s:a:1" "language=eng" "-metadata:s:a:1" "title=English"
             "-metadata:s:s:0" "language=chi" "-metadata:s:s:0" "title=中文"
             "-metadata:s:s:1" "language=eng" "-metadata:s:s:1" "title=English"
             mkv)))
          (etaf-video-player-tests--with-graphics
            (let ((etaf-video-engine 'mpv))
              (etaf-video-player-open
               (list :file mkv :columns 24 :rows 6 :audio nil))
              (should (etaf-video-player-tests--wait
                       (lambda ()
                         (let ((st (etaf-video-player-tests--state)))
                           (and (>= (or (plist-get st :presented) 0) 1)
                                (>= (length (plist-get st :tracks)) 4))))
                       8))
              (let ((st (etaf-video-player-tests--state)))
                (should (eq 'mpv (plist-get st :engine)))
                (should (eq 'image (plist-get st :render-mode)))
                (should (= 4 (length (plist-get st :tracks))))
                (should (cl-every (lambda (tr) (memq (plist-get tr :type) '(audio sub)))
                                  (plist-get st :tracks))))
              (with-current-buffer "*Video Player*"
                (etaf-video-player-cycle-audio-track)
                (etaf-video-player-cycle-subtitle-track)
                (should (= 2 (etaf-video-player-set-secondary-subtitle 2)))
                (should (= 90 (etaf-video-player-rotate)))
                (should (= 90 (plist-get (etaf-video-player-tests--state) :rotate)))
                (should (= 180 (etaf-video-player-rotate)))
                (etaf-video-player-set-ab-start 0.2)
                (etaf-video-player-set-ab-end 1.8)
                (should (equal '(0.2 . 1.8)
                               (plist-get (etaf-video-player-tests--state) :ab-loop)))
                (etaf-video-player-clear-ab)
                (etaf-video-player-step-back)
                (should-not (plist-get (etaf-video-player-tests--state) :playing))
                (should (equal shot (etaf-video-player-save-screenshot shot)))
                (should (etaf-video-player-tests--wait
                         (lambda ()
                           (and (file-readable-p shot)
                                (> (file-attribute-size (file-attributes shot)) 0)))
                         8)))
              (etaf-video-player-close))))
      (etaf-video-player-tests--cleanup)
      (ignore-errors (delete-directory dir t)))))

(ert-deftest etaf-video-player-tests-fullscreen-modes-and-mode-line-restore ()
  "Pure Fullscreen toggles window and frame tiers, hides/restores mode-line and shares the cinema deck."
  (unwind-protect
      (let ((buf (etaf-video-player-open '(:demo :audio nil))))
        (with-current-buffer buf
          (let ((orig-ml mode-line-format)
                (rt (etaf-runtime-for-buffer buf)))
            (etaf-runtime-flush rt)
            (let ((normal-text (buffer-substring-no-properties (point-min) (point-max))))
              (should (string-match-p "全屏" normal-text)))
            ;; Window fullscreen
            (should (eq 'window (etaf-video-player-toggle-fullscreen)))
            (etaf-runtime-flush rt)
            (should (eq 'window (etaf-fullscreen-mode buf)))
            (should (null mode-line-format))
            (let ((fs-text (buffer-substring-no-properties (point-min) (point-max))))
              (should (string-match-p "↩ 退出" fs-text))
              (should (string-match-p "真全屏 Z" fs-text)))
            ;; Frame fullscreen
            (should (eq 'frame (etaf-video-player-toggle-frame-fullscreen)))
            (etaf-runtime-flush rt)
            (should (eq 'frame (etaf-fullscreen-mode buf)))
            ;; Toggle frame fullscreen again exits and restores mode-line
            (should-not (etaf-video-player-toggle-frame-fullscreen))
            (etaf-runtime-flush rt)
            (should-not (etaf-fullscreen-mode buf))
            (should (equal mode-line-format orig-ml)))
          (etaf-video-player-close)))
    (etaf-video-player-tests--cleanup)))

(provide 'etaf-video-player-tests)
;;; etaf-video-player-tests.el ends here
