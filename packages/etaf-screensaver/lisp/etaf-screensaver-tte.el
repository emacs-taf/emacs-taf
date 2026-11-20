;;; -*- lexical-binding: t; -*-
;;; etaf-screensaver-tte.el --- Terminal Text Effects recordings

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Terminal Text Effects (TTE) stores a rendered effect as TTEREC version 1:
;; a zlib stream of tagged records holding a JSON header (canvas size and
;; frame rate), segment names, ANSI frames and a frame-count trailer.  This
;; provider validates the container and every frame before playback, reports
;; the colors a recording uses and feeds SGR runs through the shared canvas
;; color path.  Playback reads the recording directly; it never runs TTE or
;; any other process.

;;; Code:
(require 'cl-lib)
(require 'json)
(require 'etaf-screensaver-model)
(require 'etaf-screensaver-ansi)
(require 'etaf-screensaver-reel)

(defconst etaf-screensaver-tte--magic "TTEREC"
  "Signature bytes of a TTE recording.")

(defconst etaf-screensaver-tte--version 1
  "Recording format version this provider reads.")

(defconst etaf-screensaver-tte--max-file-bytes (* 64 1024 1024)
  "Largest compressed recording this provider reads.")

(defconst etaf-screensaver-tte--max-decompressed-bytes (* 256 1024 1024)
  "Largest decompressed recording this provider reads.")

(defconst etaf-screensaver-tte--max-metadata-bytes 4096
  "Largest header, segment or trailer record this provider reads.")

(defconst etaf-screensaver-tte--max-frame-bytes (* 64 1024 1024)
  "Largest single frame record this provider reads.")

(defconst etaf-screensaver-tte--max-frames 200000
  "Largest frame count this provider reads.")

(defconst etaf-screensaver-tte--max-dimension 4096
  "Largest frame canvas dimension this provider reads.")

(defun etaf-screensaver-tte-recording-p (file)
  "Return non-nil when FILE begins with the TTE recording signature."
  (ignore-errors
    (with-temp-buffer
      (set-buffer-multibyte nil)
      (insert-file-contents-literally file nil 0 (length etaf-screensaver-tte--magic))
      (equal (buffer-string) etaf-screensaver-tte--magic))))

(defun etaf-screensaver--tte-json (payload file label)
  "Parse JSON record PAYLOAD from FILE, labelled LABEL."
  (condition-case nil
      (json-parse-string (decode-coding-string payload 'utf-8) :object-type 'plist)
    (error (etaf-screensaver--fail "TTE %s record in %s is not valid JSON" label file))))

(defun etaf-screensaver--tte-u32 (data position)
  "Return the little-endian 32-bit number in DATA at POSITION."
  (logior (aref data position)
          (ash (aref data (+ position 1)) 8)
          (ash (aref data (+ position 2)) 16)
          (ash (aref data (+ position 3)) 24)))

(defun etaf-screensaver--tte-header (header file)
  "Validate TTE HEADER read from FILE and return it.
The header holds :tte_version, :width, :height and :frame_rate."
  (let ((version (plist-get header :tte_version))
        (width (plist-get header :width))
        (height (plist-get header :height))
        (frame-rate (plist-get header :frame_rate)))
    (unless (stringp version)
      (etaf-screensaver--fail "TTE recording %s has no version" file))
    (dolist (entry (list (cons :width width) (cons :height height)))
      (unless (and (integerp (cdr entry))
                   (<= 1 (cdr entry) etaf-screensaver-tte--max-dimension))
        (etaf-screensaver--fail "TTE recording %s has an invalid canvas" file)))
    (unless (and (integerp frame-rate) (> frame-rate 0))
      (etaf-screensaver--fail "TTE recording %s has an invalid frame rate" file))
    header))

(defun etaf-screensaver--tte-frame (payload header file &optional features-p)
  "Validate one TTE frame PAYLOAD of HEADER from FILE.
Return (FRAME . PLIST); every row must fill the recorded canvas and contain
only printable text and SGR runs.  With FEATURES-P, also classify the SGR
runs of this frame, which dense recordings scan only for a bounded prefix."
  (let* ((frame (decode-coding-string payload 'utf-8))
         (rows (split-string frame "\n"))
         (height (plist-get header :height))
         (width (plist-get header :width))
         (colors nil) (attributes nil))
    (unless (= (length rows) height)
      (etaf-screensaver--fail "TTE recording %s has a frame with %d rows, expected %d"
                              file (length rows) height))
    (dolist (row rows)
      (let ((stripped (etaf-screensaver--ansi-strip row)))
        (unless (= (string-width stripped) width)
          (etaf-screensaver--fail "TTE recording %s has a frame row that is not %d cells wide"
                                  file width))
        (when (string-match-p "[\x00-\x1f\x7f-\x9f]" stripped)
          (etaf-screensaver--fail "TTE recording %s has a frame with an unsafe control character"
                                  file)))
      (when features-p
        (let ((features (etaf-screensaver--ansi-features row)))
          (setq colors (append colors (plist-get features :colors))
                attributes (append attributes (plist-get features :attributes))))))
    (cons frame (list :colors colors :attributes attributes))))

(defun etaf-screensaver--tte-parse (file data)
  "Parse decompressed TTE DATA from FILE into metadata and frames."
  (let ((position 0) (size (length data))
        (header nil) (segments nil) (frames nil) (index 0)
        (frame-count nil) (colors nil) (attributes nil)
        (feature-budget 128))
    (while (< position size)
      (when (> (+ position 5) size)
        (etaf-screensaver--fail "TTE recording %s is truncated" file))
      (let* ((tag (aref data position))
             (length (etaf-screensaver--tte-u32 data (1+ position)))
             (maximum (if (= tag ?F)
                          etaf-screensaver-tte--max-frame-bytes
                        etaf-screensaver-tte--max-metadata-bytes)))
        (when (> length maximum)
          (etaf-screensaver--fail "TTE recording %s has an oversized record" file))
        (when (> (+ position 5 length) size)
          (etaf-screensaver--fail "TTE recording %s is truncated" file))
        (let ((payload (substring data (+ position 5) (+ position 5 length))))
          (pcase tag
            (?H (when header
                  (etaf-screensaver--fail "TTE recording %s repeats its header" file))
                (setq header (etaf-screensaver--tte-header
                              (etaf-screensaver--tte-json payload file "header") file)))
            (?S (unless header
                  (etaf-screensaver--fail "TTE recording %s starts with a segment" file))
                (setq segments
                      (cons (plist-get (etaf-screensaver--tte-json payload file "segment")
                                       :effect)
                            segments)))
            (?F (unless header
                  (etaf-screensaver--fail "TTE recording %s has a frame before its header" file))
                (when (>= index etaf-screensaver-tte--max-frames)
                  (etaf-screensaver--fail "TTE recording %s has too many frames" file))
                (let ((checked (etaf-screensaver--tte-frame
                                payload header file (> feature-budget 0))))
                  (when (> feature-budget 0)
                    (cl-decf feature-budget))
                  (push (car checked) frames)
                  (setq colors (append colors (plist-get (cdr checked) :colors))
                        attributes (append attributes (plist-get (cdr checked) :attributes)))
                  (cl-incf index)))
            (?E (when frame-count
                  (etaf-screensaver--fail "TTE recording %s repeats its trailer" file))
                (let ((trailer (etaf-screensaver--tte-json payload file "trailer")))
                  (setq frame-count (plist-get trailer :frame_count))))
            (_ (etaf-screensaver--fail "TTE recording %s has an unknown record" file))))
        (setq position (+ position 5 length))))
    (unless header
      (etaf-screensaver--fail "TTE recording %s has no header" file))
    (unless frame-count
      (etaf-screensaver--fail "TTE recording %s has no trailer" file))
    (unless (= frame-count index)
      (etaf-screensaver--fail "TTE recording %s holds %d frames, its trailer says %d"
                              file index frame-count))
    (unless (> index 0)
      (etaf-screensaver--fail "TTE recording %s holds no frames" file))
    (list :width (plist-get header :width)
          :height (plist-get header :height)
          :frame-rate (plist-get header :frame_rate)
          :frames (vconcat (nreverse frames))
          :ansi t
          :colors (delete-dups (copy-sequence colors))
          :attributes (delete-dups (copy-sequence attributes))
          :source (mapconcat #'identity (nreverse segments) ", ")
          :tte-version (plist-get header :tte_version))))

(defun etaf-screensaver--tte-read (file)
  "Read the TTE recording FILE and return its frames and metadata.
Signal `etaf-screensaver-error' when FILE is not a valid version 1
recording, exceeds the provider's size limits or holds an invalid frame."
  (unless (file-regular-p file)
    (etaf-screensaver--fail "TTE recording is not a regular file: %s" file))
  (let ((size (file-attribute-size (file-attributes file))))
    (when (> size etaf-screensaver-tte--max-file-bytes)
      (etaf-screensaver--fail "TTE recording %s exceeds %d bytes"
                              file etaf-screensaver-tte--max-file-bytes)))
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (insert-file-contents-literally file)
    (unless (and (>= (buffer-size) 7)
                 (equal (buffer-substring-no-properties (point-min) (+ (point-min) 6))
                        etaf-screensaver-tte--magic)
                 (= (char-after (+ (point-min) 6)) etaf-screensaver-tte--version))
      (etaf-screensaver--fail "Not a version %d TTE recording: %s"
                              etaf-screensaver-tte--version file))
    (goto-char (+ (point-min) 7))
    (delete-region (point-min) (point))
    (unless (zlib-decompress-region (point-min) (point-max))
      (etaf-screensaver--fail "TTE recording %s has a damaged compressed stream" file))
    (when (> (buffer-size) etaf-screensaver-tte--max-decompressed-bytes)
      (etaf-screensaver--fail "TTE recording %s exceeds the decompressed size limit" file))
    (etaf-screensaver--tte-parse file (buffer-substring-no-properties (point-min) (point-max)))))

(etaf-screensaver-define-reel-provider 'tte
  :title "Terminal Text Effects"
  :license "MIT"
  :extensions '("tterec")
  :match #'etaf-screensaver-tte-recording-p
  :read #'etaf-screensaver--tte-read)

(provide 'etaf-screensaver-tte)
;;; etaf-screensaver-tte.el ends here
