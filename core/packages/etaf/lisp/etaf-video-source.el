;;; etaf-video-source.el --- Frame producers for native video -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Source normalization, ffprobe metadata, the ffmpeg argument contract, and
;; the process filter that keeps the newest complete frame.  A producer feeds
;; either fixed-size raw frames (gray or RGB24) or a stream of JPEG images
;; delimited by their SOI and EOI markers.  No buffer or Runtime state lives
;; here; `etaf-video-session' owns the playback state machine.

;;; Code:

(require 'cl-lib)
(require 'subr-x)

(declare-function etaf-video-canvas-open "etaf-video-canvas" (file))
(declare-function etaf-video-canvas-read "etaf-video-canvas"
                  (fd canvas bytes))
(declare-function etaf-video-canvas-close "etaf-video-canvas" (fd))

(defvar etaf-video-ffmpeg-program "ffmpeg"
  "Name or absolute path of the ffmpeg executable.
Point it at a wrapper script to add decoder options; ETAF appends the filter
and output arguments described in the manual.")

(defvar etaf-video-ffprobe-program "ffprobe"
  "Name or absolute path of the ffprobe executable.
Missing metadata degrades to documented defaults instead of failing.")

(defconst etaf-video--queue-high-water 18
  "Buffered frame count above which the decoder pauses via SIGSTOP.")

(defconst etaf-video--queue-low-water 8
  "Buffered frame count at or below which a paused decoder resumes.")

(defconst etaf-video--queue-max-frames 36
  "Hard cap on queued frames when POSIX flow control is unavailable.")

(cl-defstruct (etaf-video--source (:constructor etaf-video--source--make))
  "A running frame producer."
  process pipe stderr width height frame-size carry latest received dropped
  ended exit error-text mjpeg-p fifo err canvas-fd
  start-pts frame-fps queue queue-tail queue-count flow-paused)

(defun etaf-video--probe-values (program &rest arguments)
  "Run PROGRAM with ARGUMENTS and return its key=value output as a table."
  (let ((values (make-hash-table :test #'equal)))
    (dolist (line (ignore-errors (apply #'process-lines program arguments)))
      (when (string-match "\\`\\([^=]+\\)=\\(.+\\)\\'" line)
        (puthash (match-string 1 line) (match-string 2 line) values)))
    values))

(defun etaf-video--probe-number (values key)
  "Return VALUES's KEY as a positive number, or nil."
  (let ((text (gethash key values)))
    (when (and (stringp text) (string-match-p "\\`[0-9.]+\\'" text))
      (let ((number (string-to-number text)))
        (when (> number 0) number)))))

(defun etaf-video--header-pairs (headers)
  "Return HEADERS as a list of (NAME . VALUE) string pairs.
HEADERS is nil, an alist, a hash table, or one string carrying `Name: value'
lines separated by CRLF.  Malformed headers signal `user-error' instead of
reaching a decoder."
  (let ((pairs
         (cond
          ((null headers) nil)
          ((stringp headers)
           (mapcar (lambda (line)
                     (unless (string-match
                              "\\`\\([^:\r\n]+\\):[ \t]*\\([^\r\n]*\\)\\'" line)
                       (user-error "Video header line is malformed: %S" line))
                     (cons (match-string 1 line) (match-string 2 line)))
                   (split-string headers "\r\n" t)))
          ((hash-table-p headers)
           (let (result)
             (maphash (lambda (name value)
                        (push (cons (format "%s" name) (format "%s" value))
                              result))
                      headers)
             (nreverse result)))
          ((listp headers)
           (mapcar (lambda (pair)
                     (unless (and (consp pair)
                                  (stringp (car pair)) (stringp (cdr pair)))
                       (user-error "Video headers must be name and value strings: %S"
                                   pair))
                     (cons (car pair) (cdr pair)))
                   headers))
          (t (user-error "Video headers must be an alist, a hash table or a string: %S"
                         headers)))))
    (dolist (pair pairs)
      (when (or (string-match-p "\\`[ \t]*\\'" (car pair))
                (string-match-p "[[:cntrl:]]" (car pair))
                (string-match-p "[\r\n]" (cdr pair)))
        (user-error "Video header names and values must not contain control characters: %S"
                    pair)))
    pairs))

(defun etaf-video--http-arguments (headers proxy)
  "Return decoder input options for HEADERS and PROXY.
A User-Agent header becomes `-user_agent', so a request carries one
User-Agent instead of ffmpeg's default plus a custom one; the remaining
headers become one `-headers' string.  PROXY is applied with `-http_proxy',
which ffmpeg also uses for HTTPS when no HTTPS-specific proxy is set."
  (let ((user-agent nil) (rest nil))
    (dolist (pair (etaf-video--header-pairs headers))
      (if (string= (downcase (car pair)) "user-agent")
          (setq user-agent (cdr pair))
        (push pair rest)))
    (append
     (when user-agent (list "-user_agent" user-agent))
     (when rest
       (list "-headers"
             (mapconcat (lambda (pair)
                          (format "%s: %s\r\n" (car pair) (cdr pair)))
                        (nreverse rest) "")))
     (when (and (stringp proxy) (> (length proxy) 0))
       (list "-http_proxy" proxy)))))

(defun etaf-video--probe (target &optional headers proxy)
  "Return TARGET's metadata plist from ffprobe, or nil.
TARGET is a local file name or an HTTP(S) URL.  HEADERS and PROXY are the
network options `etaf-video--http-arguments' builds; they apply when TARGET
is a URL.  The result holds `:width', `:height', `:fps', `:duration' and
`:audio', each nil when the source does not report it."
  (when-let* ((program (executable-find etaf-video-ffprobe-program)))
    (let* ((input (append (if (etaf-video--url-p target)
                              (etaf-video--http-arguments headers proxy)
                            nil)
                          (list target)))
           (video (apply #'etaf-video--probe-values
                         program "-v" "error" "-select_streams" "v:0"
                         "-show_entries" "stream=width,height,r_frame_rate"
                         "-of" "default=nw=1"
                         input))
           (meta (apply #'etaf-video--probe-values
                        program "-v" "error"
                        "-show_entries" "format=duration"
                        "-of" "default=nw=1"
                        input))
           (audio (apply #'etaf-video--probe-values
                         program "-v" "error" "-select_streams" "a:0"
                         "-show_entries" "stream=index"
                         "-of" "default=nw=1"
                         input))
           (rate (gethash "r_frame_rate" video)))
      (list :width (etaf-video--probe-number video "width")
            :height (etaf-video--probe-number video "height")
            :duration (etaf-video--probe-number meta "duration")
            :fps (when (and (stringp rate)
                            (string-match "\\`\\([0-9.]+\\)/\\([0-9.]+\\)\\'" rate))
                   (let ((frames (string-to-number (match-string 1 rate)))
                         (seconds (string-to-number (match-string 2 rate))))
                     (when (> seconds 0) (/ frames seconds))))
            :audio (and (gethash "index" audio) t)))))

(defun etaf-video--url-p (source)
  "Return non-nil when SOURCE is an HTTP or HTTPS URL string."
  (and (stringp source)
       (string-match-p "\\`https?://[^[:space:]]+\\'" source)))

(cl-defun etaf-video--normalize-source (source)
  "Return SOURCE as a normalized plist, or signal `user-error'.
SOURCE is nil for the built-in demo, a file name or HTTP(S) URL string, or a
plist:

  (:file PATH)   a local video file; ffprobe supplies its metadata
  (:url URL)     an HTTP(S) video stream decoded directly by ffmpeg
  (:demo)        a generated 30 second test pattern, no file needed

A plist that already carries `:kind' is treated as authoritative metadata, as
returned by `etaf-video-source-info', so callers that probed once can mount
without another probe.

A local file name is expanded with `expand-file-name', so a name that starts
with `~' or is relative to `default-directory' reaches the decoders as an
absolute name; `:file' and `:target' hold that expanded name.

A source may split its video and audio into separate HTTP(S) streams with
`:audio-url'; the audio sidecar then opens that URL while ffmpeg decodes the
video URL.  `:headers' (an alist, a hash table or one `Name: value' string)
and `:proxy' (an HTTP(S) proxy URL) are applied to every request both
decoders make.

The result holds `:kind', `:file', `:url', `:target', `:audio-url',
`:audio-target' (the stream the audio sidecar opens), `:headers', `:proxy',
`:width', `:height', `:duration', `:fps' (source rate) and `:audio' (whether
the source reports an audio stream; a present `:audio-url' implies one)."
  (let (kind file url audio-url headers proxy)
    (cond ((and (consp source) (plist-member source :kind))
           (setq kind (plist-get source :kind)
                 file (plist-get source :file)
                 url (plist-get source :url)
                 audio-url (plist-get source :audio-url)
                 headers (plist-get source :headers)
                 proxy (plist-get source :proxy))
           (unless (memq kind '(file url demo))
             (user-error "Unsupported etaf-video source kind: %S" kind)))
          ((null source) (setq kind 'demo))
          ((etaf-video--url-p source) (setq kind 'url url source))
          ((stringp source) (setq kind 'file file source))
          ((and (consp source) (eq (car source) :demo)) (setq kind 'demo))
          ((and (consp source) (plist-get source :demo)) (setq kind 'demo))
          ((and (consp source) (plist-get source :url))
           (setq kind 'url url (plist-get source :url)
                 audio-url (plist-get source :audio-url)
                 headers (plist-get source :headers)
                 proxy (plist-get source :proxy)))
          ((and (consp source) (plist-get source :file))
           (setq kind 'file file (plist-get source :file)
                 audio-url (plist-get source :audio-url)
                 headers (plist-get source :headers)
                 proxy (plist-get source :proxy)))
          (t (user-error "Unsupported etaf-video source: %S" source)))
    (when (and (eq kind 'file) (stringp file))
      ;; `read-file-name' hands back names unexpanded, and the decoders are
      ;; external programs that never expand `~' or resolve relative names.
      ;; Resolve once here so every decoder gets the same absolute name.
      (setq file (expand-file-name file)))
    (when (eq kind 'file)
      (unless (and (stringp file) (file-readable-p file))
        (user-error "Video file is not readable: %S" file)))
    (when (eq kind 'url)
      (unless (etaf-video--url-p url)
        (user-error "Video URL must be http or https: %S" url)))
    (when (and audio-url (not (etaf-video--url-p audio-url)))
      (user-error "Video audio URL must be http or https: %S" audio-url))
    (when (and proxy (not (etaf-video--url-p proxy)))
      (user-error "Video proxy must be an http or https URL: %S" proxy))
    (when headers
      (etaf-video--header-pairs headers))
    (if (and (consp source) (plist-member source :kind))
        (append
         (list :kind kind
               :file file
               :url url
               :target (or file url)
               :audio-url audio-url
               :audio-target (or audio-url file url)
               :headers headers
               :proxy proxy
               :width (plist-get source :width)
               :height (plist-get source :height)
               :duration (plist-get source :duration)
               :fps (plist-get source :fps)
               :audio (and (or (plist-get source :audio) audio-url) t))
         (when (and (numberp (plist-get source :start))
                    (>= (plist-get source :start) 0))
           (list :start (plist-get source :start))))
      (let* ((probe (and (memq kind '(file url))
                         (etaf-video--probe (or file url)
                                            (and (eq kind 'url) headers)
                                            (and (eq kind 'url) proxy))))
             (width (or (and (memq kind '(file url)) (plist-get probe :width))
                        (plist-get source :width) 640))
             (height (or (and (memq kind '(file url)) (plist-get probe :height))
                         (plist-get source :height) 360))
             (duration (or (and (memq kind '(file url)) (plist-get probe :duration))
                           (plist-get source :duration)
                           (and (eq kind 'demo) 30)))
             (fps (or (and (memq kind '(file url)) (plist-get probe :fps))
                      (plist-get source :fps)
                      (and (eq kind 'demo) 30)
                      25))
             (audio (if (eq kind 'demo)
                        nil
                      (or audio-url
                          (and probe (plist-get probe :audio))
                          (plist-get source :audio)))))
        (append
         (list :kind kind
               :file file
               :url url
               :target (or file url)
               :audio-url audio-url
               :audio-target (or audio-url file url)
               :headers headers
               :proxy proxy
               :width width
               :height height
               :duration duration
               :fps fps
               :audio (and audio t))
         (when (and (consp source)
                    (numberp (plist-get source :start))
                    (>= (plist-get source :start) 0))
           (list :start (plist-get source :start))))))))

;;;###autoload
(defun etaf-video-source-info (source)
  "Return SOURCE's normalized playback metadata as a plist.

SOURCE is nil for the built-in demo, a local file name, an HTTP(S) URL, or a
plist accepted by the `etaf-video' Component (`:file', `:url' or `:demo',
optionally `:audio-url', `:headers' and `:proxy').  A local file name may
start with `~' or be relative to `default-directory'; it is expanded with
`expand-file-name', and `:file' and `:target' hold the absolute name.
The result holds `:kind', `:file', `:url', `:target', `:audio-url',
`:audio-target', `:headers', `:proxy', `:width', `:height', `:duration',
`:fps' (source rate) and `:audio' (whether the source reports an audio
stream; a present `:audio-url' implies one).  Values come from ffprobe when
it runs; a missing ffprobe keeps documented defaults.  Unsupported sources,
unreadable files and malformed network options signal `user-error'.  Each
call probes the source; the result is authoritative metadata that can be
passed back as the Component's `:src' without another probe, so an
application that resizes or restarts a video keeps them."
  (etaf-video--normalize-source source))

(defun etaf-video--ffmpeg-arguments (spec format width height speed start &optional fps)
  "Return ffmpeg arguments for SPEC producing FORMAT frames.
WIDTH and HEIGHT are the frame dimensions (pixels for raw and JPEG output).
SPEED is the `-readrate' factor, START the seek position in seconds and
optional FPS enforces constant-frame-rate output so frame N carries exact
presentation timestamp START + N / FPS."
  (append (list "-hide_banner" "-loglevel" "error")
          (when (and (numberp start) (> start 0))
            (list "-ss" (number-to-string start)))
          (list "-readrate" (number-to-string speed))
          (pcase (plist-get spec :kind)
            ('file (list "-i" (plist-get spec :file)))
            ('url (append (etaf-video--http-arguments (plist-get spec :headers)
                                                      (plist-get spec :proxy))
                          (list "-reconnect" "1" "-reconnect_streamed" "1"
                                "-reconnect_delay_max" "5"
                                "-i" (plist-get spec :url))))
            ('demo (list "-f" "lavfi" "-i" "testsrc2=size=640x360:rate=30" "-t" "30"))
            (_ (user-error "Cannot build ffmpeg arguments for %S" spec)))
          (when (and (numberp fps) (> fps 0))
            (list "-r" (format "%.6g" (float fps))))
          (pcase format
            ('mjpeg
             (list "-vf" (format "scale=%d:%d:flags=lanczos" width height)
                   "-q:v" "3"
                   "-f" "image2pipe" "-c:v" "mjpeg" "-"))
            ('rgb24
             (list "-vf" (format "scale=%d:%d:flags=area" width height)
                   "-f" "rawvideo" "-pix_fmt" "rgb24" "-"))
            ('bgra
             (list "-vf" (format "scale=%d:%d:flags=area" width height)
                   "-f" "rawvideo" "-pix_fmt" "bgra" "-"))
            (_
             (list "-vf" (format "scale=%d:%d:flags=area" width height)
                   "-f" "rawvideo" "-pix_fmt" "gray" "-")))))

(defun etaf-video--source-pause-flow (source)
  "Temporarily stop SOURCE's decoder process when the frame queue is full."
  (when (and (not (etaf-video--source-flow-paused source))
             (not (memq system-type '(windows-nt ms-dos))))
    (let ((proc (etaf-video--source-process source)))
      (when (process-live-p proc)
        (ignore-errors (signal-process proc 'SIGSTOP))
        (setf (etaf-video--source-flow-paused source) t)))))

(defun etaf-video--source-resume-flow (source)
  "Resume SOURCE's decoder process after queue backpressure drains."
  (when (etaf-video--source-flow-paused source)
    (setf (etaf-video--source-flow-paused source) nil)
    (let ((proc (etaf-video--source-process source)))
      (when (process-live-p proc)
        (ignore-errors (signal-process proc 'SIGCONT))))))

(defun etaf-video--source-enqueue (source frame)
  "Append FRAME with its exact media PTS to SOURCE's bounded presentation queue."
  (let* ((idx (etaf-video--source-received source))
         (fps (max 1.0 (float (or (etaf-video--source-frame-fps source) 30))))
         (pts (+ (float (or (etaf-video--source-start-pts source) 0.0))
                 (/ (float idx) fps)))
         (cell (list (cons pts frame))))
    (cl-incf (etaf-video--source-received source))
    (setf (etaf-video--source-latest source) frame)
    (if (etaf-video--source-queue-tail source)
        (setcdr (etaf-video--source-queue-tail source) cell)
      (setf (etaf-video--source-queue source) cell))
    (setf (etaf-video--source-queue-tail source) cell)
    (cl-incf (etaf-video--source-queue-count source))
    (while (> (etaf-video--source-queue-count source) etaf-video--queue-max-frames)
      (setf (etaf-video--source-queue source) (cdr (etaf-video--source-queue source)))
      (cl-decf (etaf-video--source-queue-count source))
      (cl-incf (etaf-video--source-dropped source))
      (unless (etaf-video--source-queue source)
        (setf (etaf-video--source-queue-tail source) nil)))))

(defun etaf-video--source-filter (process chunk)
  "Accumulate CHUNK into complete timestamped frames in SOURCE's queue.
Raw frames are cut at their fixed byte length; JPEG frames are complete images
delimited by SOI and EOI markers.  Flow control pauses the decoder once the
lookahead queue reaches `etaf-video--queue-high-water' so fast decoding never
drifts ahead of the audio master clock."
  (let ((source (process-get process 'etaf-video-source)))
    (when source
      (let ((data (concat (etaf-video--source-carry source) chunk)))
        (if (etaf-video--source-mjpeg-p source)
            (let ((soi (string-search "\xff\xd8" data))
                  (eoi nil))
              (when soi
                (setq eoi (string-search "\xff\xd9" data (1+ soi))))
              (while (and soi eoi)
                (etaf-video--source-enqueue source (substring data soi (+ eoi 2)))
                (setq data (substring data (+ eoi 2))
                      soi (string-search "\xff\xd8" data)
                      eoi (and soi (string-search "\xff\xd9" data (1+ soi))))))
          (let ((size (etaf-video--source-frame-size source)))
            (while (>= (length data) size)
              (etaf-video--source-enqueue source (substring data 0 size))
              (setq data (substring data size)))))
        (setf (etaf-video--source-carry source) data)
        (when (>= (etaf-video--source-queue-count source) etaf-video--queue-high-water)
          (etaf-video--source-pause-flow source))))))

(defun etaf-video--source-stderr-text (source)
  "Return trimmed stderr output recorded for SOURCE, or nil."
  (let* ((buf (etaf-video--source-stderr source))
         (err-file (etaf-video--source-err source))
         (text (cond
                ((and buf (buffer-live-p buf))
                 (with-current-buffer buf
                   (string-trim (buffer-substring-no-properties
                                 (point-min) (point-max)))))
                ((and err-file (file-readable-p err-file))
                 (with-temp-buffer
                   (insert-file-contents err-file)
                   (string-trim (buffer-substring-no-properties
                                 (point-min) (point-max)))))
                (t ""))))
    (unless (string-empty-p text) text)))

(defun etaf-video--source-sentinel (process _event)
  "Mark PROCESS's source ended when the producer really terminated.
Stop and continue events leave the producer running and are ignored."
  (let ((source (process-get process 'etaf-video-source)))
    (when (and source (not (process-live-p process)))
      (setf (etaf-video--source-ended source) t)
      (let ((code (condition-case nil (process-exit-status process) (error nil))))
        (setf (etaf-video--source-exit source) code)
        (when (and (numberp code) (not (zerop code)))
          (setf (etaf-video--source-error-text source)
                (or (etaf-video--source-stderr-text source)
                    (format "Decoder exited with status %d" code))))))))

(defun etaf-video--source-start-fifo (spec program width height speed start &optional fps)
  "Start a BGRA producer that writes raw frames into a fifo.
The canvas reader drains the fifo directly into the canvas pixel buffer, so
no Emacs filter allocates one frame-sized string per produced frame."
  (let* ((fifo (make-temp-name
                (expand-file-name "etaf-video-" temporary-file-directory)))
         (err (make-temp-file "etaf-video-err-" nil ".log"))
         (pipe (generate-new-buffer " *etaf-video pipe*"))
         (args (etaf-video--ffmpeg-arguments spec 'bgra width height speed start fps)))
    (unless (eq 0 (call-process "mkfifo" nil nil nil fifo))
      (delete-file fifo)
      (user-error "mkfifo failed for %s" fifo))
    (let ((process
           (start-process-shell-command
            "etaf-video" pipe
            (format "%s %s > %s 2> %s"
                    (shell-quote-argument program)
                    (mapconcat #'shell-quote-argument args " ")
                    (shell-quote-argument fifo)
                    (shell-quote-argument err)))))
      (set-process-sentinel process #'etaf-video--source-sentinel)
      (set-process-query-on-exit-flag process nil)
      (let ((source (etaf-video--source--make
                     :process process :pipe pipe :fifo fifo :err err
                     :width width :height height
                     :frame-size (* width height 4)
                     :start-pts (float (or start 0))
                     :frame-fps (float (or fps 30))
                     :queue nil :queue-tail nil :queue-count 0 :flow-paused nil
                     :carry "" :latest nil :received 0 :dropped 0
                     :mjpeg-p nil)))
        (process-put process 'etaf-video-source source)
        source))))

(cl-defun etaf-video--source-start (spec format width height &key speed start fps)
  "Start a producer for normalized SPEC, FORMAT, WIDTH and HEIGHT.
SPEED defaults to 1, START to 0 and FPS to the source's rate.  Return the new
source; a missing ffmpeg signals `user-error' before any process exists.  A
`bgra' producer writes into a fifo consumed by the canvas reader instead of
an Emacs filter."
  (let* ((program (or (executable-find etaf-video-ffmpeg-program)
                      (user-error "ffmpeg is not available: %s"
                                  etaf-video-ffmpeg-program)))
         (out-fps (or fps (plist-get spec :fps) 30)))
    (if (eq format 'bgra)
        (etaf-video--source-start-fifo
         spec program width height (or speed 1) (or start 0) out-fps)
      (etaf-video--source-start-pipe
       spec program format width height speed start out-fps))))

(cl-defun etaf-video--source-start-pipe (spec program format width height speed start &optional fps)
  "Start a producer whose stdout is read by the Emacs frame filter."
  (let* ((mjpeg (eq format 'mjpeg))
         (frame-size (pcase format
                       ('rgb24 (* width height 3))
                       ('bgra (* width height 4))
                       ('mjpeg 0)
                       (_ (* width height))))
         (pipe (generate-new-buffer " *etaf-video pipe*"))
         (stderr (generate-new-buffer " *etaf-video stderr*"))
         (process (make-process
                   :name "etaf-video"
                   :command (cons program
                                  (etaf-video--ffmpeg-arguments
                                   spec format width height (or speed 1)
                                   (or start 0) fps))
                   :buffer pipe
                   :stderr stderr
                   :coding '(no-conversion . no-conversion)
                   :connection-type 'pipe
                   :noquery t
                   :filter #'etaf-video--source-filter
                   :sentinel #'etaf-video--source-sentinel)))
    (when-let* ((err-proc (get-buffer-process stderr)))
      (set-process-sentinel err-proc #'ignore)
      (set-process-query-on-exit-flag err-proc nil))
    (let ((source (etaf-video--source--make
                   :process process :pipe pipe :stderr stderr
                   :width width :height height :frame-size frame-size
                   :start-pts (float (or start 0))
                   :frame-fps (float (or fps 30))
                   :queue nil :queue-tail nil :queue-count 0 :flow-paused nil
                   :carry "" :latest nil :received 0 :dropped 0
                   :mjpeg-p mjpeg)))
      (process-put process 'etaf-video-source source)
      source)))

(defun etaf-video--source-read-canvas (source spec)
  "Read one BGRA frame from SOURCE into canvas SPEC.
Return the number of bytes read, zero at the end of the stream.  The fifo is
opened once and kept; every later call reads the next frame straight into the
canvas pixel buffer through the native module."
  (let ((bytes (* (etaf-video--source-width source)
                  (etaf-video--source-height source)
                  4)))
    (unless (etaf-video--source-canvas-fd source)
      (let ((fd (etaf-video-canvas-open (etaf-video--source-fifo source))))
        (unless (and (integerp fd) (> fd 0))
          (error "Cannot open video fifo %s" (etaf-video--source-fifo source)))
        (setf (etaf-video--source-canvas-fd source) fd)))
    (etaf-video-canvas-read (etaf-video--source-canvas-fd source) spec bytes)))

(defun etaf-video--source-peek-pts (source)
  "Return the presentation timestamp of SOURCE's oldest queued frame, or nil."
  (when-let* ((head (car (etaf-video--source-queue source))))
    (car head)))

(defun etaf-video--source-has-frames-p (source)
  "Return non-nil when SOURCE holds at least one unpresented frame."
  (and source (consp (etaf-video--source-queue source))))

(defun etaf-video--source-pop (source)
  "Pop and return `(PTS . FRAME)' from SOURCE's queue, resuming flow if low."
  (when-let* ((cell (etaf-video--source-queue source)))
    (setf (etaf-video--source-queue source) (cdr cell))
    (cl-decf (etaf-video--source-queue-count source))
    (unless (etaf-video--source-queue source)
      (setf (etaf-video--source-queue-tail source) nil
            (etaf-video--source-latest source) nil))
    (when (<= (etaf-video--source-queue-count source) etaf-video--queue-low-water)
      (etaf-video--source-resume-flow source))
    (car cell)))

(defun etaf-video--source-claim-for-clock (source clock)
  "Pop and return `(PTS . FRAME)' for the newest queued frame at or before CLOCK.
Earlier overdue frames are dropped so presentation catches up cleanly after
jitter; future frames stay queued until CLOCK reaches them."
  (let ((chosen nil))
    (while (and (etaf-video--source-queue source)
                (<= (caar (etaf-video--source-queue source)) clock))
      (when chosen
        (cl-incf (etaf-video--source-dropped source)))
      (setq chosen (etaf-video--source-pop source)))
    chosen))

(defun etaf-video--source-claim (source)
  "Return SOURCE's newest complete frame, clearing the queue, or nil.
The frame is a unibyte string of raw pixels or one complete JPEG image."
  (let ((chosen nil))
    (while (etaf-video--source-queue source)
      (when chosen
        (cl-incf (etaf-video--source-dropped source)))
      (setq chosen (etaf-video--source-pop source)))
    (cdr chosen)))

(defun etaf-video--source-close (source)
  "Terminate SOURCE's producer and release its buffer, fifo and reader."
  (etaf-video--source-resume-flow source)
  (let ((process (etaf-video--source-process source)))
    (when (process-live-p process) (delete-process process)))
  (setf (etaf-video--source-queue source) nil
        (etaf-video--source-queue-tail source) nil
        (etaf-video--source-queue-count source) 0
        (etaf-video--source-latest source) nil)
  (when-let* ((fd (etaf-video--source-canvas-fd source)))
    (ignore-errors (etaf-video-canvas-close fd))
    (setf (etaf-video--source-canvas-fd source) nil))
  (when-let* ((fifo (etaf-video--source-fifo source)))
    (ignore-errors (delete-file fifo)))
  (when-let* ((err (etaf-video--source-err source)))
    (ignore-errors (delete-file err)))
  (when (buffer-live-p (etaf-video--source-pipe source))
    (kill-buffer (etaf-video--source-pipe source)))
  (when-let* ((stderr (etaf-video--source-stderr source)))
    (when-let* ((err-proc (get-buffer-process stderr)))
      (when (process-live-p err-proc) (delete-process err-proc)))
    (when (buffer-live-p stderr)
      (kill-buffer stderr))))

(provide 'etaf-video-source)
;;; etaf-video-source.el ends here
