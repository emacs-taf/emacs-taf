;;; etaf-video-player-media.el --- Async media metadata, chapters and subtitle discovery -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Non-blocking media inspection for the video player.  Once playback starts,
;; `etaf-video-player-media-probe-async' invokes `ffprobe -of json' once in the
;; background via `etaf-process-run' to collect codec, bitrate, pixel format,
;; audio stream layout, file size and embedded chapters, caching results by
;; target so re-selecting a track stays instant.  This module also discovers
;; all matching external subtitle tracks beside a local video file.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'subr-x)
(require 'etaf)
(require 'etaf-video-player-subtitle)

(defvar etaf-video-player--media-cache (make-hash-table :test #'equal)
  "Cache of detailed media metadata plists keyed by expanded file path or URL.")

(defun etaf-video-player-media-format-bytes (bytes)
  "Format integer BYTES as a concise human-readable size string."
  (cond ((not (and (numberp bytes) (> bytes 0))) "—")
        ((>= bytes (* 1024 1024 1024))
         (format "%.2f GB" (/ (float bytes) (* 1024 1024 1024))))
        ((>= bytes (* 1024 1024))
         (format "%.1f MB" (/ (float bytes) (* 1024 1024))))
        ((>= bytes 1024)
         (format "%.0f KB" (/ (float bytes) 1024)))
        (t (format "%d B" (round bytes)))))

(defun etaf-video-player-media-format-bitrate (bps)
  "Format bitrate BPS (bits per second) as Mbps or kbps."
  (cond ((not (and (numberp bps) (> bps 0))) "—")
        ((>= bps 1000000) (format "%.2f Mbps" (/ (float bps) 1000000.0)))
        (t (format "%d kbps" (round (/ (float bps) 1000.0))))))

(defun etaf-video-player-media--number (value)
  "Coerce JSON string or number VALUE to a positive number, or nil."
  (let ((n (cond ((numberp value) value)
                 ((and (stringp value) (string-match-p "\\`[0-9.]+\\'" value))
                  (string-to-number value)))))
    (and (numberp n) (> n 0) n)))

(defun etaf-video-player-media--rate (rate)
  "Parse an ffprobe rational frame rate string like \"60000/1001\"."
  (when (and (stringp rate)
             (string-match "\\`\\([0-9.]+\\)/\\([0-9.]+\\)\\'" rate))
    (let ((num (string-to-number (match-string 1 rate)))
          (den (string-to-number (match-string 2 rate))))
      (when (> den 0) (/ num den)))))

(defun etaf-video-player-media--aspect-label (width height)
  "Return a concise aspect-ratio label for WIDTH × HEIGHT."
  (when (and (numberp width) (numberp height) (> width 0) (> height 0))
    (let ((ratio (/ (float width) height)))
      (cond ((< (abs (- ratio (/ 16.0 9))) 0.04) "16:9")
            ((< (abs (- ratio (/ 4.0 3))) 0.04) "4:3")
            ((< (abs (- ratio (/ 21.0 9))) 0.06) "21:9")
            ((< (abs (- ratio 2.39)) 0.06) "2.39:1")
            ((< (abs (- ratio 1.85)) 0.05) "1.85:1")
            ((< (abs (- ratio (/ 9.0 16))) 0.04) "9:16")
            (t (format "%.2f:1" ratio))))))

(defun etaf-video-player-media--pretty-codec (name)
  "Return a clean display name for ffprobe codec NAME."
  (when (stringp name)
    (pcase (downcase name)
      ("h264" "H.264")
      ((or "hevc" "h265") "H.265")
      ("vp9" "VP9")
      ("av1" "AV1")
      (_ (upcase name)))))

(defun etaf-video-player-media--pretty-format (format-name target)
  "Return a clean container format label from FORMAT-NAME and TARGET."
  (when (stringp format-name)
    (let* ((parts (split-string (downcase format-name) "," t))
           (ext (and (stringp target)
                     (not (string-match-p "\\`https?://" target))
                     (file-name-extension target)))
           (low-ext (and ext (downcase ext))))
      (cond ((and low-ext (member low-ext parts)) (upcase low-ext))
            ((and (equal low-ext "mkv") (member "matroska" parts)) "MKV")
            ((member "mp4" parts) "MP4")
            (t (upcase (car parts)))))))

(defun etaf-video-player-media--parse-json (raw &optional target)
  "Parse ffprobe JSON output RAW into a normalized media metadata plist."
  (let* ((json-object-type 'alist)
         (json-array-type 'list)
         (json-key-type 'symbol)
         (data (ignore-errors (json-read-from-string raw))))
    (when (listp data)
      (let* ((fmt (alist-get 'format data))
             (streams (alist-get 'streams data))
             (vstream (cl-find-if (lambda (s) (equal (alist-get 'codec_type s) "video")) streams))
             (astream (cl-find-if (lambda (s) (equal (alist-get 'codec_type s) "audio")) streams))
             (vcodec (alist-get 'codec_name vstream))
             (vprofile (alist-get 'profile vstream))
             (width (etaf-video-player-media--number (alist-get 'width vstream)))
             (height (etaf-video-player-media--number (alist-get 'height vstream)))
             (fps (or (etaf-video-player-media--rate (alist-get 'avg_frame_rate vstream))
                      (etaf-video-player-media--rate (alist-get 'r_frame_rate vstream))))
             (pix (alist-get 'pix_fmt vstream))
             (cspace (alist-get 'color_space vstream))
             (bitrate (or (etaf-video-player-media--number (alist-get 'bit_rate fmt))
                          (etaf-video-player-media--number (alist-get 'bit_rate vstream))))
             (size (etaf-video-player-media--number (alist-get 'size fmt)))
             (format-name (alist-get 'format_name fmt))
             (acodec (alist-get 'codec_name astream))
             (achannels (etaf-video-player-media--number (alist-get 'channels astream)))
             (alayout (alist-get 'channel_layout astream))
             (arate (etaf-video-player-media--number (alist-get 'sample_rate astream)))
             (abitrate (etaf-video-player-media--number (alist-get 'bit_rate astream)))
             (raw-chapters (alist-get 'chapters data))
             (chapters
              (cl-loop for idx from 0
                       for ch in raw-chapters
                       for start = (or (etaf-video-player-media--number (alist-get 'start_time ch)) 0.0)
                       for end = (or (etaf-video-player-media--number (alist-get 'end_time ch)) start)
                       for tags = (alist-get 'tags ch)
                       for title = (or (alist-get 'title tags)
                                       (format "第 %d 章" (1+ idx)))
                       collect (list :index idx :title (string-trim title)
                                     :start (float start) :end (float end)))))
        (list :video-codec (etaf-video-player-media--pretty-codec vcodec)
              :video-profile (and (stringp vprofile) vprofile)
              :width width :height height
              :aspect-label (etaf-video-player-media--aspect-label width height)
              :fps fps
              :pix-fmt (and (stringp pix) pix)
              :color-space (and (stringp cspace) (not (equal cspace "unknown")) cspace)
              :bitrate bitrate
              :size size
              :format-name (etaf-video-player-media--pretty-format format-name target)
              :audio-codec (etaf-video-player-media--pretty-codec acodec)
              :audio-channels achannels
              :audio-channel-layout (and (stringp alayout) alayout)
              :audio-sample-rate arate
              :audio-bitrate abitrate
              :chapters (sort chapters (lambda (a b)
                                         (< (plist-get a :start) (plist-get b :start)))))))))

(defun etaf-video-player-media-cached (target)
  "Return cached detailed media info for TARGET, or nil."
  (and (stringp target) (gethash target etaf-video-player--media-cache)))

(defun etaf-video-player-media-probe-async (spec http-args callback)
  "Asynchronously probe detailed metadata and chapters for SPEC.
HTTP-ARGS is an optional list of ffmpeg/ffprobe HTTP arguments for URL sources.
CALLBACK is called with (TARGET INFO) once metadata is available (immediately
when cached).  Demo sources and missing `ffprobe' call CALLBACK with nil."
  (let* ((kind (plist-get spec :kind))
         (target (pcase kind
                   ('file (plist-get spec :file))
                   ('url (plist-get spec :url))))
         (program (and target (executable-find etaf-video-ffprobe-program))))
    (cond
     ((null target) (funcall callback nil nil))
     ((gethash target etaf-video-player--media-cache)
      (funcall callback target (gethash target etaf-video-player--media-cache)))
     ((null program) (funcall callback target nil))
     (t
      (etaf-process-run
       (append (list program "-v" "error" "-of" "json"
                     "-show_format" "-show_streams" "-show_chapters")
               (when (eq kind 'url) http-args)
               (list target))
       :name "etaf-video-player-probe"
       :callback
       (lambda (result)
         (let ((info (when (and (eq (plist-get result :status) 'exit)
                                (eql (plist-get result :exit) 0)
                                (stringp (plist-get result :output)))
                       (etaf-video-player-media--parse-json (plist-get result :output) target))))
           (when info
             (puthash target info etaf-video-player--media-cache))
           (funcall callback target info))))))))

(defun etaf-video-player-media-chapter-at (chapters position)
  "Return the chapter plist covering POSITION seconds in CHAPTERS, or nil."
  (when (and chapters (numberp position))
    (cl-find-if (lambda (ch)
                  (and (>= position (plist-get ch :start))
                       (< position (plist-get ch :end))))
                chapters)))

(defun etaf-video-player-media-subtitles-for (video-file)
  "Return sorted external subtitle files matching VIDEO-FILE in its directory.
Matches exact stem (`clip.srt') and language-tagged variants (`clip.zh.vtt')."
  (when (and (stringp video-file) (file-readable-p video-file))
    (let* ((expanded (expand-file-name video-file))
           (dir (file-name-directory expanded))
           (stem (file-name-base expanded))
           (stem-prefix (concat stem "."))
           (exts (mapcar #'downcase etaf-video-player-subtitle-extensions)))
      (when (and dir (file-directory-p dir))
        (let ((found
               (cl-loop for path in (directory-files dir t "\\`[^.]")
                        for name = (file-name-nondirectory path)
                        for ext = (file-name-extension path)
                        when (and (file-regular-p path)
                                  (file-readable-p path)
                                  ext
                                  (member (downcase ext) exts)
                                  (or (string= (file-name-base path) stem)
                                      (string-prefix-p stem-prefix name)))
                        collect path)))
          (sort found (lambda (a b)
                        (let ((a-exact (string= (file-name-base a) stem))
                              (b-exact (string= (file-name-base b) stem)))
                          (if (eq a-exact b-exact)
                              (string-lessp a b)
                            a-exact)))))))))

(provide 'etaf-video-player-media)
;;; etaf-video-player-media.el ends here
