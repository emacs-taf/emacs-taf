;;; etaf-video-player-subtitle.el --- Subtitle parsing and timing -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; External subtitle tracks for the player: SubRip (`.srt') and WebVTT
;; (`.vtt') files parse into a list of cues, and the transport clock turns
;; into the cue text shown under the canvas.  Parsing and timing are pure
;; functions over strings and numbers, so the acceptance suite exercises them
;; without a decoder, a network or a window.
;;
;; A cue is `(START END TEXT)': START and END are seconds as floats and TEXT
;; is one display line.  `etaf-video-player-subtitle-text-at' answers the cue
;; covering a playback second through a binary search, so a per-tick lookup
;; stays O(log n) on a feature-length track.

;;; Code:

(require 'cl-lib)
(require 'subr-x)

(define-error 'etaf-video-player-subtitle-error "Video player subtitle error")

(defconst etaf-video-player-subtitle-extensions
  '(".srt" ".vtt" ".zh.srt" ".zh-CN.srt" ".zh-Hans.srt" ".chs.srt" ".sc.srt")
  "File suffixes probed beside a video when it opens.
The bare `.srt' and `.vtt' come first; the language suffixes cover the common
Chinese naming (`movie.zh.srt') before falling back to a plain track.")

(defconst etaf-video-player-subtitle--clock-regexp
  "\\([0-9]+:[0-9]+:[0-9]+[,.]?[0-9]*\\|[0-9]+:[0-9]+[,.][0-9]+\\)"
  "Regexp matching one subtitle clock token.")

(defun etaf-video-player-subtitle--seconds (token)
  "Parse the subtitle clock TOKEN into seconds.
TOKEN is `HH:MM:SS,mmm', `HH:MM:SS.mmm', `MM:SS.mmm' or `SS.mmm'; nil when
it does not carry a clock.  The match data is preserved so callers can read
other groups of their own match."
  (save-match-data
    (let ((parts (and token (split-string token "[:,.]" t))))
      (pcase (length parts)
        (4 (+ (* (string-to-number (nth 0 parts)) 3600.0)
              (* (string-to-number (nth 1 parts)) 60.0)
              (string-to-number (nth 2 parts))
              (/ (string-to-number (nth 3 parts)) 1000.0)))
        (3 (+ (* (string-to-number (nth 0 parts)) 60.0)
              (string-to-number (nth 1 parts))
              (/ (string-to-number (nth 2 parts)) 1000.0)))
        (_ nil)))))

(defun etaf-video-player-subtitle--clean (text)
  "Strip markup and inline control tokens from a subtitle TEXT line."
  (string-trim
   (replace-regexp-in-string
    "{[^}]*}" ""
    (replace-regexp-in-string "<[^>]*>" "" text))))

(defun etaf-video-player-subtitle--line ()
  "Return the current line of the subtitle buffer without properties."
  (buffer-substring-no-properties (line-beginning-position) (line-end-position)))

(defun etaf-video-player-subtitle-parse (file)
  "Parse the subtitle FILE into a sorted list of cues.
FILE must be a readable SubRip or WebVTT file; otherwise
`etaf-video-player-subtitle-error' is signaled.  Each cue is
`(START END TEXT)' in playback seconds with one display line per cue."
  (unless (file-readable-p file)
    (signal 'etaf-video-player-subtitle-error
            (list (format "Subtitle file is not readable: %s" file))))
  (with-temp-buffer
    (insert-file-contents file)
    (goto-char (point-min))
    (let (cues)
      (while (not (eobp))
        (let ((line (etaf-video-player-subtitle--line)))
          (if (not (string-match
                    (concat etaf-video-player-subtitle--clock-regexp
                            "[ \t]*-->[ \t]*"
                            etaf-video-player-subtitle--clock-regexp)
                    line))
              (forward-line 1)
            (let ((start-token (match-string 1 line))
                  (end-token (match-string 2 line)))
              (forward-line 1)
              (let ((texts nil))
                (while (and (not (eobp))
                            (not (string-empty-p
                                  (string-trim (etaf-video-player-subtitle--line)))))
                  (let ((text (etaf-video-player-subtitle--clean
                               (etaf-video-player-subtitle--line))))
                    (unless (string-empty-p text)
                      (push text texts)))
                  (forward-line 1))
                (let ((start (etaf-video-player-subtitle--seconds start-token))
                      (end (etaf-video-player-subtitle--seconds end-token)))
                  (when (and start end texts (< start end))
                    (push (list start end (string-join (nreverse texts) " ")) cues))))))))
      (sort (nreverse cues) (lambda (a b) (< (car a) (car b)))))))

(defun etaf-video-player-subtitle-text-at (cues seconds)
  "Return the text of the cue in CUES covering SECONDS, or nil.
CUES is the sorted list `etaf-video-player-subtitle-parse' returns; SECONDS
is the playback position.  The lookup binary-searches the track, so it stays
cheap on every retention tick."
  (when (and cues (numberp seconds))
    (let ((low 0)
          (high (1- (length cues)))
          (found nil))
      (while (<= low high)
        (let* ((middle (/ (+ low high) 2))
               (cue (nth middle cues))
               (start (nth 0 cue))
               (end (nth 1 cue)))
          (cond ((< seconds start) (setq high (1- middle)))
                ((>= seconds end) (setq low (1+ middle)))
                (t (setq found cue)
                   (setq low (1+ high))))))
      (nth 2 found))))

(defun etaf-video-player-subtitle-beside (video)
  "Return the first readable subtitle file beside VIDEO, or nil.
The probe looks for `VIDEO.srt', `VIDEO.vtt' and the common Chinese language
suffixes in `etaf-video-player-subtitle-extensions' order."
  (let ((base (file-name-sans-extension video)))
    (cl-some (lambda (suffix)
               (let ((candidate (concat base suffix)))
                 (and (file-readable-p candidate) candidate)))
             etaf-video-player-subtitle-extensions)))

(provide 'etaf-video-player-subtitle)
;;; etaf-video-player-subtitle.el ends here
