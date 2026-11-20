;;; etaf-video-tests.el --- Native video acceptance -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Public scenarios for the `etaf-video' Component and its handle control
;; API.  The producer is the repository's fake ffmpeg fixture, so the suite
;; needs no real decoder, no network and no graphical frame; `image' mode
;; falls back to `ascii' in batch Emacs, and the graphical image path is
;; covered by the GUI workflow.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'json)
(require 'etaf)

(defconst etaf-video-tests--fixtures
  (expand-file-name "fixtures"
                    (file-name-directory (or load-file-name buffer-file-name)))
  "Fixture directory beside the test source.")

(defconst etaf-video-tests--ffmpeg
  (expand-file-name "fake-ffmpeg.py" etaf-video-tests--fixtures)
  "Executable fixture standing in for ffmpeg.")

(defconst etaf-video-tests--ffprobe
  (expand-file-name "fake-ffprobe.py" etaf-video-tests--fixtures)
  "Executable fixture standing in for ffprobe.")

(defconst etaf-video-tests--ffplay
  (expand-file-name "fake-ffplay.py" etaf-video-tests--fixtures)
  "Executable fixture standing in for ffplay.")

(defconst etaf-video-tests--input
  (expand-file-name "fake-ffmpeg.py" etaf-video-tests--fixtures)
  "An existing file accepted as the video input; the fixture ignores it.")

(defun etaf-video-tests--log ()
  "Return a fresh log path for recorded fixture invocations."
  (make-temp-file "etaf-video-log-"))

(defun etaf-video-tests--runs (log)
  "Return the recorded fixture invocations in LOG as argument lists.
Each fixture writes one JSON array per invocation; ffplay also writes a
`pid=...' line that is skipped here."
  (when (file-exists-p log)
    (let (runs)
      (with-temp-buffer
        (insert-file-contents log)
        (goto-char (point-min))
        (while (not (eobp))
          (let ((line (buffer-substring-no-properties
                       (line-beginning-position) (line-end-position))))
            (unless (or (string-empty-p line) (string-prefix-p "pid=" line))
              (push (append (json-parse-string line) nil) runs)))
          (forward-line 1)))
      (nreverse runs))))

(defun etaf-video-tests--argument (arguments flag)
  "Return the value following FLAG in ARGUMENTS, or nil."
  (cadr (member flag arguments)))

(defun etaf-video-tests--wait (predicate &optional seconds)
  "Wait until PREDICATE is non-nil for at most SECONDS.
Return PREDICATE's final value."
  (let ((deadline (+ (float-time) (or seconds 5))))
    (while (and (< (float-time) deadline) (not (funcall predicate)))
      (accept-process-output nil 0.02)
      (sleep-for 0.005))
    (funcall predicate)))

(defmacro etaf-video-tests--with-fixture (log settings &rest body)
  "Run BODY with the fake decoder fixtures and SETTINGS bound.
LOG receives the recorded ffmpeg invocations.  SETTINGS is a list of
ENV=VALUE strings for the fixtures."
  (declare (indent 2))
  `(let ((process-environment
          (append (cons (concat "FAKE_FFMPEG_LOG=" ,log) ,settings)
                  process-environment))
         (etaf-video-ffmpeg-program etaf-video-tests--ffmpeg)
         (etaf-video-ffprobe-program etaf-video-tests--ffprobe)
         (etaf-video-ffplay-program etaf-video-tests--ffplay))
     ,@body))

(defun etaf-video-tests--mount (name props)
  "Mount an `etaf-video' with PROPS in buffer NAME and return its handle."
  (let ((handle (make-symbol "etaf-video-test")))
    (etaf-mount
     name
     (lambda ()
       (etaf-node 'etaf-video (append (list :handle handle) props) nil)))
    handle))

(defun etaf-video-tests--cleanup (name)
  "Release any Runtime in buffer NAME and kill the buffer."
  (when-let* ((buffer (get-buffer name)))
    (when-let* ((runtime (etaf-runtime-for-buffer buffer)))
      (ignore-errors (etaf-unmount runtime)))
    (kill-buffer buffer)))

(defun etaf-video-tests--visible (line)
  "Return LINE's active characters without EBox display padding.
EBox pads each row to its owner width with a `space' display character for
background painting; those characters are not video pixels."
  (let ((position 0) (end (length line)) cut)
    (while (< position end)
      (let ((display (get-text-property position 'display line)))
        (when (and (null cut) (consp display) (eq (car display) 'space))
          (setq cut position))
        (setq position (or (next-property-change position line end) end))))
    (substring-no-properties line 0 (or cut end))))

(defun etaf-video-tests--grid (name rows)
  "Return the first ROWS visible canvas lines of buffer NAME."
  (with-current-buffer name
    (let ((lines (split-string (buffer-string) "\n")))
      (mapconcat #'identity
                 (cl-subseq lines 0 (min rows (length lines)))
                 "\n"))))

(defun etaf-video-tests--columns-grid (columns rows)
  "Return the expected fixture grid for the `columns' pattern."
  (let* ((ramp etaf-video-density-ramp)
         (last (1- (length ramp)))
         (span (max 1 (1- columns))))
    (mapconcat
     (lambda (_row)
       (apply #'string
              (cl-loop for x below columns
                       for value = (floor (* x 255) span)
                       for index = (floor (+ (* value last) 127) 255)
                       collect (aref ramp index))))
     (number-sequence 1 rows) "\n")))

(defun etaf-video-tests--state (handle)
  "Return HANDLE's detached video state."
  (etaf-video-state handle))

(defun etaf-video-tests--presented (handle)
  "Return HANDLE's presented frame count."
  (plist-get (etaf-video-tests--state handle) :presented))

(defun etaf-video-tests--ffplay-pid (log)
  "Return the last recorded ffplay process id in LOG, or nil."
  (when (file-exists-p log)
    (with-temp-buffer
      (insert-file-contents log)
      (goto-char (point-max))
      (when (re-search-backward "^pid=\\([0-9]+\\)$" nil t)
        (string-to-number (match-string 1))))))

(defun etaf-video-tests--ffplay-arguments (log)
  "Return the last recorded ffplay argument list in LOG, or nil."
  (car (last (cl-remove-if-not (lambda (arguments) (member "-nodisp" arguments))
                               (etaf-video-tests--runs log)))))

(ert-deftest etaf-video-tests-renders-ascii-ramp-frames ()
  "Every canvas pixel is the ramp character of its grayscale byte.
The producer receives the documented gray scale and read rate, and the
displayed canvas matches the fixture's column pattern."
  (let ((name " *etaf-video-ascii*")
        (log (etaf-video-tests--log))
        (columns 16)
        (rows 4))
    (unwind-protect
        (etaf-video-tests--with-fixture
            log '("FAKE_FFMPEG_FRAMES=40" "FAKE_FFMPEG_INTERVAL=0.01")
          (let ((handle (etaf-video-tests--mount
                         name (list :src etaf-video-tests--input :mode 'ascii
                                    :columns columns :rows rows :autoplay t))))
            (should (etaf-video-tests--wait
                     (lambda () (>= (etaf-video-tests--presented handle) 1))))
            (should (equal (etaf-video-tests--columns-grid columns rows)
                           (etaf-video-tests--grid name rows)))
            (let ((arguments (car (last (etaf-video-tests--runs log)))))
              (should (equal "gray" (etaf-video-tests--argument arguments "-pix_fmt")))
              (should (member (format "scale=%d:%d:flags=area" columns rows)
                              arguments))
              (should (equal "1" (etaf-video-tests--argument arguments "-readrate"))))
            (etaf-video-pause handle)
            (should-not (plist-get (etaf-video-tests--state handle) :playing))))
      (etaf-video-tests--cleanup name)
      (ignore-errors (delete-file log)))))

(ert-deftest etaf-video-tests-renders-color-half-blocks ()
  "Color mode publishes one half-block cell per two full-color pixels.
The fixture's even scanline becomes the cell foreground and its odd scanline
the background, and the producer receives RGB24 pixels at double height."
  (let ((name " *etaf-video-color*")
        (log (etaf-video-tests--log))
        (columns 8)
        (rows 3))
    (unwind-protect
        (etaf-video-tests--with-fixture
            log '("FAKE_FFMPEG_FRAMES=40" "FAKE_FFMPEG_INTERVAL=0.01")
          (let ((handle (etaf-video-tests--mount
                         name (list :src etaf-video-tests--input :mode 'color
                                    :columns columns :rows rows :autoplay t))))
            (should (etaf-video-tests--wait
                     (lambda () (>= (etaf-video-tests--presented handle) 1))))
            (with-current-buffer name
              (let ((text (buffer-string)))
                (should (= (* columns rows) (cl-count ?▀ text)))
                (should (member '(:foreground "#000000" :background "#ff0000")
                                (get-text-property 0 'face text)))))
            (let ((arguments (car (last (etaf-video-tests--runs log)))))
              (should (equal "rgb24" (etaf-video-tests--argument arguments "-pix_fmt")))
              (should (member (format "scale=%d:%d:flags=area" columns (* 2 rows))
                              arguments)))))
      (etaf-video-tests--cleanup name)
      (ignore-errors (delete-file log)))))

(ert-deftest etaf-video-tests-image-canvas-uses-one-line-per-row ()
  "An image canvas publishes one display cell per character row.
A frame image is many character rows tall while a buffer line holds one row,
so publishing it whole would push every line below the canvas past the
window edge.  The canvas must occupy exactly the rows it declares, which is
what lets a caller place chrome under it."
  (let ((name " *etaf-video-image-rows*")
        (log (etaf-video-tests--log))
        (columns 16)
        (rows 4))
    (unwind-protect
        (etaf-video-tests--with-fixture
            log '("FAKE_FFMPEG_FRAMES=40" "FAKE_FFMPEG_INTERVAL=0.01")
          (cl-letf (((symbol-function 'display-graphic-p)
                     (lambda (&optional _frame) t))
                    ((symbol-function 'image-type-available-p)
                     (lambda (_type) nil)))
            (let ((handle (etaf-video-tests--mount
                           name (list :src etaf-video-tests--input :mode 'image
                                      :columns columns :rows rows :autoplay t))))
              (should (etaf-video-tests--wait
                       (lambda () (>= (etaf-video-tests--presented handle) 1))))
              (should (eq 'image (plist-get (etaf-video-tests--state handle) :mode)))
              (with-current-buffer name
                (let ((text (buffer-string))
                      (position 0)
                      sliced)
                  (while (< position (length text))
                    (let ((display (get-text-property position 'display text)))
                      (when (and (consp display)
                                 (eq (car-safe (car display)) 'slice))
                        (setq sliced (1+ (or sliced 0)))))
                    (setq position (or (next-property-change position text)
                                       (length text))))
                  (should (= rows sliced)))
                (should (= rows (line-number-at-pos (point-max))))))))
      (etaf-video-tests--cleanup name)
      (ignore-errors (delete-file log)))))

(ert-deftest etaf-video-tests-live-control-sources-survive-resize ()
  "Reactive sound, volume and speed control playback without losing state."
  (let ((name " *etaf-video-controlled*") (log (etaf-video-tests--log))
        (volume (etaf-ref 70)) (audio (etaf-ref nil)) (speed (etaf-ref 1))
        (columns (etaf-ref 16)) (handle (make-symbol "controlled-video")))
    (unwind-protect
        (etaf-video-tests--with-fixture
            log '("FAKE_FFMPEG_FRAMES=200" "FAKE_FFMPEG_INTERVAL=0.01")
          (etaf-mount name
            (etaf-view
             (etaf-video :src etaf-video-tests--input :handle handle :mode 'ascii
                         :columns (etaf-value columns) :rows 4 :display-fps 24
                         :volume volume :audio audio :speed speed)))
          (should (etaf-video-tests--wait
                   (lambda () (> (plist-get (etaf-video-state handle) :presented) 0))))
          (etaf-batch
            (etaf-set-value volume 35)
            (etaf-set-value audio t)
            (etaf-set-value speed 1.5))
          (should (= 1.5 (plist-get (etaf-video-state handle) :speed)))
          (should (= 24 (plist-get (etaf-video-state handle) :display-fps)))
          (should (plist-get (etaf-video-state handle) :playing))
          (etaf-set-value columns 18)
          (should (= 18 (plist-get (etaf-video-state handle) :width)))
          (should (= 1.5 (plist-get (etaf-video-state handle) :speed)))
          (etaf-video-pause handle)
          (should-not (plist-get (etaf-video-state handle) :playing))
          (etaf-set-value volume 60)
          (etaf-set-value audio nil)
          (etaf-video-play handle)
          (should (plist-get (etaf-video-state handle) :playing)))
      (etaf-video-tests--cleanup name)
      (delete-file log))))

(ert-deftest etaf-video-tests-image-mode-falls-back-on-terminal ()
  "`image' mode renders ASCII when the buffer is not in a graphical frame.
The session reports the effective mode and decodes grayscale instead of
JPEG, so a layout built for a graphical frame still works in a terminal."
  (let ((name " *etaf-video-fallback*")
        (log (etaf-video-tests--log))
        (columns 8)
        (rows 2))
    (unwind-protect
        (etaf-video-tests--with-fixture
            log '("FAKE_FFMPEG_FRAMES=40" "FAKE_FFMPEG_INTERVAL=0.01")
          (let ((handle (etaf-video-tests--mount
                         name (list :src etaf-video-tests--input :mode 'image
                                    :columns columns :rows rows :autoplay t))))
            (should (etaf-video-tests--wait
                     (lambda () (>= (etaf-video-tests--presented handle) 1))))
            (should (eq 'ascii (plist-get (etaf-video-tests--state handle) :mode)))
            (should (eq 'gray (plist-get (etaf-video-tests--state handle) :format)))
            (should (equal (etaf-video-tests--columns-grid columns rows)
                           (etaf-video-tests--grid name rows)))
            (should (equal "gray"
                           (etaf-video-tests--argument
                            (car (last (etaf-video-tests--runs log))) "-pix_fmt")))))
      (etaf-video-tests--cleanup name)
      (ignore-errors (delete-file log)))))

(ert-deftest etaf-video-tests-controls-pause-step-seek-speed ()
  "Pause, step, seek and speed keep the reported state honest.
A paused position freezes, a step presents exactly one more frame, a paused
seek presents the frame at its target, and the next producer starts with the
documented seek, rate and read-rate arguments."
  (let ((name " *etaf-video-controls*")
        (log (etaf-video-tests--log)))
    (unwind-protect
        (etaf-video-tests--with-fixture
            log '("FAKE_FFMPEG_FRAMES=200" "FAKE_FFMPEG_INTERVAL=0.01")
          (let ((handle (etaf-video-tests--mount
                         name (list :src etaf-video-tests--input :mode 'ascii
                                    :columns 16 :rows 4 :autoplay t))))
            (should (etaf-video-tests--wait
                     (lambda () (>= (etaf-video-tests--presented handle) 1))))
            (etaf-video-pause handle)
            (let ((paused (plist-get (etaf-video-tests--state handle) :position))
                  (presented (etaf-video-tests--presented handle)))
              (etaf-video-tests--wait (lambda () nil) 0.15)
              (should (= paused (plist-get (etaf-video-tests--state handle) :position)))
              (etaf-video-step handle)
              (should (etaf-video-tests--wait
                       (lambda () (> (etaf-video-tests--presented handle) presented))))
              (should-not (plist-get (etaf-video-tests--state handle) :playing))
              ;; A step closes its producer deliberately; that is not the end.
              (should-not (plist-get (etaf-video-tests--state handle) :ended)))
            (let ((presented (etaf-video-tests--presented handle)))
              (etaf-video-seek handle 1.0)
              (should (= 1.0 (plist-get (etaf-video-tests--state handle) :position)))
              ;; A paused seek shows the frame at its new position.
              (should (etaf-video-tests--wait
                       (lambda () (> (etaf-video-tests--presented handle) presented))))
              (should (equal "1.0" (etaf-video-tests--argument
                                    (car (last (etaf-video-tests--runs log))) "-ss")))
              (should-not (plist-get (etaf-video-tests--state handle) :playing)))
            (etaf-video-seek handle 1.0)
            (etaf-video-toggle-playback handle)
            (should (plist-get (etaf-video-tests--state handle) :playing))
            (should (etaf-video-tests--wait
                     (lambda ()
                       (equal "1.0"
                              (etaf-video-tests--argument
                               (car (last (etaf-video-tests--runs log))) "-ss")))
                     3))
            (etaf-video-set-speed handle 2)
            (should (= 2 (plist-get (etaf-video-tests--state handle) :speed)))
            (should (etaf-video-tests--wait
                     (lambda ()
                       (equal "2"
                              (etaf-video-tests--argument
                               (car (last (etaf-video-tests--runs log))) "-readrate")))
                     3))))
      (etaf-video-tests--cleanup name)
      (ignore-errors (delete-file log)))))

(ert-deftest etaf-video-tests-finishes-and-restarts ()
  "A producer that runs out of frames ends the video and keeps its picture.
Toggling playback afterwards restarts from the beginning."
  (let ((name " *etaf-video-ended*")
        (log (etaf-video-tests--log)))
    (unwind-protect
        (etaf-video-tests--with-fixture
            log '("FAKE_FFMPEG_FRAMES=2" "FAKE_FFMPEG_INTERVAL=0.01")
          (let ((handle (etaf-video-tests--mount
                         name (list :src etaf-video-tests--input :mode 'ascii
                                    :columns 8 :rows 2 :autoplay t))))
            (should (etaf-video-tests--wait
                     (lambda () (plist-get (etaf-video-tests--state handle) :ended))))
            (should-not (plist-get (etaf-video-tests--state handle) :playing))
            (should (equal (etaf-video-tests--columns-grid 8 2)
                           (etaf-video-tests--grid name 2)))
            (etaf-video-toggle-playback handle)
            (should (plist-get (etaf-video-tests--state handle) :playing))
            (should-not (plist-get (etaf-video-tests--state handle) :ended))))
      (etaf-video-tests--cleanup name)
      (ignore-errors (delete-file log)))))

(ert-deftest etaf-video-tests-audio-sidecar-follows-playback ()
  "Audio playback runs one ffplay sidecar while playing and releases it.
A source that reports an audio stream starts the sidecar with the documented
arguments; pausing terminates it."
  (let ((name " *etaf-video-audio*")
        (log (etaf-video-tests--log))
        (audio-log (etaf-video-tests--log)))
    (unwind-protect
        (etaf-video-tests--with-fixture
            log (list "FAKE_FFMPEG_FRAMES=200" "FAKE_FFMPEG_INTERVAL=0.01"
                      "FAKE_FFPROBE_AUDIO=1"
                      (concat "FAKE_FFPLAY_LOG=" audio-log))
          (let ((handle (etaf-video-tests--mount
                         name (list :src etaf-video-tests--input :mode 'ascii
                                    :columns 8 :rows 2 :autoplay t :audio t))))
            (should (etaf-video-tests--wait
                     (lambda () (etaf-video-tests--ffplay-pid audio-log))
                     5))
            (let ((arguments (etaf-video-tests--ffplay-arguments audio-log)))
              (should (member "-nodisp" arguments))
              (should (member "-autoexit" arguments))
              (should (equal "100" (etaf-video-tests--argument arguments "-volume"))))
            (let ((pid (etaf-video-tests--ffplay-pid audio-log)))
              (etaf-video-pause handle)
              (should (etaf-video-tests--wait
                       (lambda () (null (process-attributes pid))) 5)))))
      (etaf-video-tests--cleanup name)
      (ignore-errors (delete-file log))
      (ignore-errors (delete-file audio-log)))))

(ert-deftest etaf-video-tests-streams-http-url ()
  "An HTTP(S) source reaches ffmpeg as a reconnecting stream.
A paused video still presents its first frame, and a non-HTTP scheme is
rejected before any process starts."
  (let ((name " *etaf-video-url*")
        (log (etaf-video-tests--log)))
    (unwind-protect
        (etaf-video-tests--with-fixture
            log '("FAKE_FFMPEG_FRAMES=40" "FAKE_FFMPEG_INTERVAL=0.01")
          (let ((handle (etaf-video-tests--mount
                         name (list :src "http://example.test/stream.mp4"
                                    :mode 'ascii :columns 8 :rows 2
                                    :autoplay nil))))
            (should (etaf-video-tests--wait
                     (lambda () (>= (etaf-video-tests--presented handle) 1))))
            (should-not (plist-get (etaf-video-tests--state handle) :playing))
            (let ((arguments (car (last (etaf-video-tests--runs log)))))
              (should (equal "1" (etaf-video-tests--argument arguments "-reconnect")))
              (should (equal "1"
                             (etaf-video-tests--argument arguments "-reconnect_streamed")))
              (should (equal "5"
                             (etaf-video-tests--argument arguments "-reconnect_delay_max")))
              (should (member "http://example.test/stream.mp4" arguments)))
            (should-error (etaf-video-tests--mount
                           " *etaf-video-bad-url*"
                           (list :src "ftp://example.test/stream.mp4"
                                 :mode 'ascii :autoplay nil))
                          :type 'user-error)))
      (etaf-video-tests--cleanup name)
      (etaf-video-tests--cleanup " *etaf-video-bad-url*")
      (ignore-errors (delete-file log)))))

(ert-deftest etaf-video-tests-normalizes-separate-audio-stream ()
  "A split audio stream and network options survive source normalization.
The video URL is probed with the headers and proxy, the audio URL becomes
`:audio-target', and a present audio URL implies audio even though ffprobe
reports no audio stream."
  (let ((probe-log (etaf-video-tests--log))
        (log (etaf-video-tests--log)))
    (unwind-protect
        (etaf-video-tests--with-fixture
            log (list (concat "FAKE_FFPROBE_LOG=" probe-log)
                      "FAKE_FFPROBE_DURATION=12.5")
          (let ((info (etaf-video-source-info
                       (list :url "https://media.test/video.m4s"
                             :audio-url "https://media.test/audio.m4s"
                             :headers "User-Agent: EtAfTest/1.0\r\nAccept-Language: zh-CN"
                             :proxy "http://127.0.0.1:7890"))))
            (should (equal "https://media.test/video.m4s" (plist-get info :url)))
            (should (equal "https://media.test/audio.m4s"
                           (plist-get info :audio-url)))
            (should (equal "https://media.test/audio.m4s"
                           (plist-get info :audio-target)))
            (should (equal "https://media.test/video.m4s" (plist-get info :target)))
            (should (equal "http://127.0.0.1:7890" (plist-get info :proxy)))
            (should (plist-get info :audio))
            (should (= 12.5 (plist-get info :duration)))
            (should-not (etaf-video-tests--runs log))
            (let ((runs (etaf-video-tests--runs probe-log)))
              (should (= 3 (length runs)))
              (dolist (arguments runs)
                (should (member "https://media.test/video.m4s" arguments))
                (should-not (member "https://media.test/audio.m4s" arguments))
                (should (equal "EtAfTest/1.0"
                               (etaf-video-tests--argument arguments "-user_agent")))
                (should (equal "Accept-Language: zh-CN\r\n"
                               (etaf-video-tests--argument arguments "-headers")))
                (should (equal "http://127.0.0.1:7890"
                               (etaf-video-tests--argument arguments "-http_proxy")))))
            ;; A hash table is accepted the way JSON objects usually arrive.
            (let ((headers (make-hash-table :test #'equal)))
              (puthash "User-Agent" "Hash/1.0" headers)
              (let ((normalized (etaf-video-source-info
                                 (list :kind 'url
                                       :url "https://media.test/video.m4s"
                                       :audio-url "https://media.test/audio.m4s"
                                       :headers headers :audio t))))
                (should (plist-get normalized :audio))
                (should (equal "https://media.test/audio.m4s"
                               (plist-get normalized :audio-target)))))))
      (ignore-errors (delete-file probe-log))
      (ignore-errors (delete-file log)))))

(ert-deftest etaf-video-tests-streams-separate-audio-with-network-options ()
  "A split HTTP(S) source feeds video to ffmpeg and audio to ffplay.
Both decoders receive the same User-Agent, extra headers and proxy, the
producer never opens the audio URL, and the sidecar follows playback."
  (let ((name " *etaf-video-split-stream*")
        (log (etaf-video-tests--log))
        (audio-log (etaf-video-tests--log)))
    (unwind-protect
        (etaf-video-tests--with-fixture
            log (list "FAKE_FFMPEG_FRAMES=200" "FAKE_FFMPEG_INTERVAL=0.01"
                      (concat "FAKE_FFPLAY_LOG=" audio-log))
          (let ((handle (etaf-video-tests--mount
                         name (list :src (list :kind 'url
                                               :url "https://stream.test/video.m4s"
                                               :audio-url "https://stream.test/audio.m4s"
                                               :headers '(("User-Agent" . "EtAfTest/1.0")
                                                          ("Referer" . "https://example.test/"))
                                               :proxy "http://127.0.0.1:7890"
                                               :audio t :width 640 :height 360
                                               :fps 30 :duration 60)
                                    :audio t
                                    :mode 'ascii :columns 8 :rows 2 :autoplay t))))
            (should (etaf-video-tests--wait
                     (lambda () (etaf-video-tests--ffplay-pid audio-log)) 5))
            (should (etaf-video-tests--wait
                     (lambda () (>= (etaf-video-tests--presented handle) 1))))
            (let ((arguments (car (last (etaf-video-tests--runs log)))))
              (should (member "https://stream.test/video.m4s" arguments))
              (should-not (member "https://stream.test/audio.m4s" arguments))
              (should (equal "EtAfTest/1.0"
                             (etaf-video-tests--argument arguments "-user_agent")))
              (should (equal "Referer: https://example.test/\r\n"
                             (etaf-video-tests--argument arguments "-headers")))
              (should (equal "http://127.0.0.1:7890"
                             (etaf-video-tests--argument arguments "-http_proxy"))))
            (let ((arguments (etaf-video-tests--ffplay-arguments audio-log)))
              (should (equal "https://stream.test/audio.m4s"
                             (car (last arguments))))
              (should (equal "EtAfTest/1.0"
                             (etaf-video-tests--argument arguments "-user_agent")))
              (should (equal "Referer: https://example.test/\r\n"
                             (etaf-video-tests--argument arguments "-headers")))
              (should (equal "http://127.0.0.1:7890"
                             (etaf-video-tests--argument arguments "-http_proxy")))
              (should (equal "1"
                             (etaf-video-tests--argument arguments "-reconnect"))))
            (etaf-video-pause handle)))
      (etaf-video-tests--cleanup name)
      (ignore-errors (delete-file log))
      (ignore-errors (delete-file audio-log)))))

(ert-deftest etaf-video-tests-restarts-on-input-change ()
  "Changing the canvas size restarts the producer at the same position.
The Component republishes the new canvas first and then rebuilds its session
with the documented scale, keeping paused playback paused."
  (let ((name " *etaf-video-resize*")
        (log (etaf-video-tests--log))
        (columns (etaf-ref 16))
        (rows (etaf-ref 4))
        (handle (make-symbol "etaf-video-resize-test")))
    (unwind-protect
        (etaf-video-tests--with-fixture
            log '("FAKE_FFMPEG_FRAMES=200" "FAKE_FFMPEG_INTERVAL=0.01")
          (etaf-mount
           name
           (lambda ()
             (etaf-node 'etaf-video
                        (list :handle handle :src etaf-video-tests--input
                              :mode 'ascii
                              :columns (etaf-value columns)
                              :rows (etaf-value rows)
                              :autoplay t)
                        nil)))
          (should (etaf-video-tests--wait
                   (lambda () (>= (etaf-video-tests--presented handle) 1))))
          (etaf-video-pause handle)
          (let ((position (plist-get (etaf-video-tests--state handle) :position)))
            (etaf-set-value columns 32)
            (etaf-set-value rows 8)
            (should (etaf-video-tests--wait
                     (lambda ()
                       (cl-some (lambda (arguments)
                                  (member "scale=32:8:flags=area" arguments))
                                (etaf-video-tests--runs log)))
                     5))
            (let ((arguments (car (last (etaf-video-tests--runs log)))))
              (should (equal (number-to-string position)
                             (etaf-video-tests--argument arguments "-ss"))))
            (should (= 32 (plist-get (etaf-video-tests--state handle) :width)))
            (should (= 8 (plist-get (etaf-video-tests--state handle) :height)))
            (should-not (plist-get (etaf-video-tests--state handle) :playing))))
      (etaf-video-tests--cleanup name)
      (ignore-errors (delete-file log)))))

(ert-deftest etaf-video-tests-ended-video-redraws-at-new-size ()
  "Resizing an ended video presents its last frame at the new canvas size.
The rebuilt producer starts one source frame before the end, so the canvas
never keeps a picture of the old size."
  (let ((name " *etaf-video-ended-resize*")
        (log (etaf-video-tests--log))
        (columns (etaf-ref 8))
        (handle (make-symbol "etaf-video-ended-resize-test")))
    (unwind-protect
        (etaf-video-tests--with-fixture
            log '("FAKE_FFMPEG_FRAMES=2" "FAKE_FFMPEG_INTERVAL=0.01")
          (etaf-mount
           name
           (lambda ()
             (etaf-node 'etaf-video
                        (list :handle handle :src etaf-video-tests--input
                              :mode 'ascii :columns (etaf-value columns) :rows 2
                              :autoplay t)
                        nil)))
          (should (etaf-video-tests--wait
                   (lambda () (plist-get (etaf-video-tests--state handle) :ended))))
          (etaf-set-value columns 12)
          (should (etaf-video-tests--wait
                   (lambda () (equal (etaf-video-tests--columns-grid 12 2)
                                     (etaf-video-tests--grid name 2)))))
          (should (equal "1.96" (etaf-video-tests--argument
                                 (car (last (etaf-video-tests--runs log))) "-ss")))
          (should-not (plist-get (etaf-video-tests--state handle) :playing)))
      (etaf-video-tests--cleanup name)
      (ignore-errors (delete-file log)))))

(ert-deftest etaf-video-tests-unmount-releases-runtime-and-handle ()
  "Unmounting stops the producer, audio and the handle registration.
State queries for the released handle signal an error instead of addressing
a stale session."
  (let ((name " *etaf-video-unmount*")
        (log (etaf-video-tests--log))
        (handle nil))
    (unwind-protect
        (etaf-video-tests--with-fixture
            log '("FAKE_FFMPEG_FRAMES=200" "FAKE_FFMPEG_INTERVAL=0.01")
          (setq handle (etaf-video-tests--mount
                        name (list :src etaf-video-tests--input :mode 'ascii
                                   :columns 8 :rows 2 :autoplay t)))
          (should (etaf-video-tests--wait
                   (lambda () (>= (etaf-video-tests--presented handle) 1))))
          (with-current-buffer name
            (etaf-unmount (etaf-runtime-for-buffer (current-buffer))))
          (should-error (etaf-video-state handle) :type 'user-error)
          (should (etaf-video-tests--wait
                   (lambda ()
                     (null (cl-remove-if-not
                            (lambda (process)
                              (string-prefix-p "etaf-video"
                                               (process-name process)))
                            (process-list))))
                   5)))
      (etaf-video-tests--cleanup name)
      (ignore-errors (delete-file log)))))

(ert-deftest etaf-video-tests-expands-local-file-names ()
  "A local source reaches ffprobe as an absolute file name.
`read-file-name' returns names unexpanded, so a `~' name or one relative to
`default-directory' is resolved before the decoder sees it."
  (let ((probe-log (etaf-video-tests--log))
        (log (etaf-video-tests--log))
        (absolute etaf-video-tests--input)
        (directory (file-name-directory etaf-video-tests--input)))
    (unwind-protect
        (etaf-video-tests--with-fixture
            log (list "FAKE_FFPROBE_DURATION=3.0"
                      (concat "FAKE_FFPROBE_LOG=" probe-log))
          (let ((default-directory directory))
            (let ((info (etaf-video-source-info
                         (file-relative-name absolute directory))))
              (should (equal absolute (plist-get info :file)))
              (should (equal absolute (plist-get info :target)))
              (should (= 3.0 (plist-get info :duration)))))
          (let ((info (etaf-video-source-info (abbreviate-file-name absolute))))
            (should (equal absolute (plist-get info :file)))
            (should (equal absolute (plist-get info :target))))
          (let ((runs (etaf-video-tests--runs probe-log)))
            (should (>= (length runs) 6))
            (dolist (arguments runs)
              (should (member absolute arguments)))))
      (ignore-errors (delete-file log))
      (ignore-errors (delete-file probe-log)))))

(ert-deftest etaf-video-tests-normalized-source-skips-second-probe ()
  "A metadata plist from `etaf-video-source-info' mounts without probing.
The normalized result stays authoritative, so an application that probes
once can resize or restart its video without repeating the metadata call."
  (let ((name " *etaf-video-normalized*")
        (probe-log (etaf-video-tests--log))
        (log (etaf-video-tests--log)))
    (unwind-protect
        (etaf-video-tests--with-fixture
            log (list "FAKE_FFMPEG_FRAMES=40" "FAKE_FFMPEG_INTERVAL=0.01"
                      "FAKE_FFPROBE_DURATION=7.5"
                      (concat "FAKE_FFPROBE_LOG=" probe-log))
          (let* ((info (etaf-video-source-info etaf-video-tests--input))
                 (probes (length (etaf-video-tests--runs probe-log)))
                 (handle (etaf-video-tests--mount
                          name (list :src info :mode 'ascii
                                     :columns 8 :rows 2 :autoplay t))))
            (should (= 7.5 (plist-get info :duration)))
            (should (equal 640 (plist-get info :width)))
            (should (= probes (length (etaf-video-tests--runs probe-log))))
            (should (etaf-video-tests--wait
                     (lambda () (>= (etaf-video-tests--presented handle) 1))))
            (should (= 7.5 (plist-get (etaf-video-tests--state handle) :duration)))
            (should (= probes (length (etaf-video-tests--runs probe-log))))))
      (etaf-video-tests--cleanup name)
      (ignore-errors (delete-file log))
      (ignore-errors (delete-file probe-log)))))

(ert-deftest etaf-video-tests-embeds-in-a-layout-and-drives-by-interaction ()
  "A video sits in a layout as one box and drives from its own gestures.
The canvas keeps its fixed cell size next to ordinary siblings, and the
consumer's `:on-press' turns a click into a handle control."
  (let ((name " *etaf-video-embed*")
        (log (etaf-video-tests--log)))
    (unwind-protect
        (etaf-video-tests--with-fixture
            log '("FAKE_FFMPEG_FRAMES=200" "FAKE_FFMPEG_INTERVAL=0.02"
                  "FAKE_FFPROBE_DURATION=4.0" "FAKE_FFPROBE_FPS=50/1")
          (etaf-mount
           name
           (etaf-view
            (column
             (text "desk")
             (etaf-video :src etaf-video-tests--input :mode 'ascii
                         :columns 12 :rows 3 :autoplay nil
                         :handle 'embedded :ref 'embedded-video
                         :on-press (lambda () (etaf-video-toggle-playback 'embedded)))
             (text "footer"))))
          (should (etaf-video-tests--wait
                   (lambda () (>= (plist-get (etaf-video-state 'embedded) :presented) 1))))
          (should-not (plist-get (etaf-video-state 'embedded) :playing))
          (with-current-buffer name
            (should (string-match-p "desk" (buffer-string)))
            (should (string-match-p "footer" (buffer-string))))
          (etaf-dispatch-event (etaf-runtime-for-buffer name) 'embedded-video 'press)
          (should (plist-get (etaf-video-state 'embedded) :playing))
          (etaf-video-pause 'embedded))
      (etaf-video-tests--cleanup name)
      (ignore-errors (delete-file log)))))

(ert-deftest etaf-video-tests-rejects-invalid-inputs ()
  "Invalid props and unknown handles are reported before publication.
A Component call error names the offending property and no video is left
behind."
  (let ((name " *etaf-video-invalid*"))
    (unwind-protect
        (progn
          (should-error
           (etaf-mount name (lambda ()
                              (etaf-node 'etaf-video (list :mode 'bogus) nil)))
           :type 'etaf-component-call-error)
          (should-error
           (etaf-mount name (lambda ()
                              (etaf-node 'etaf-video (list :columns 0) nil)))
           :type 'etaf-component-call-error)
          (should-error (etaf-video-state (make-symbol "etaf-video-missing"))
                        :type 'user-error)
          (should-error
           (etaf-video-source-info
            (list :url "https://media.test/video.m4s"
                  :audio-url "ftp://media.test/audio.m4s"))
           :type 'user-error)
          (should-error
           (etaf-video-source-info
            (list :url "https://media.test/video.m4s"
                  :proxy "socks5://127.0.0.1:1080"))
           :type 'user-error)
          (should-error
           (etaf-video-source-info
            (list :url "https://media.test/video.m4s"
                  :headers '(("X-Test" . "line\nbreak"))))
           :type 'user-error))
      (etaf-video-tests--cleanup name))))

(provide 'etaf-video-tests)
;;; etaf-video-tests.el ends here
