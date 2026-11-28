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

(require 'etaf-media)
(require 'cl-lib)
(require 'subr-x)

(define-error 'etaf-video-player-subtitle-error "Video player subtitle error")

(defcustom etaf-video-player-subtitle-extensions
  '(".srt" ".vtt" ".zh.srt" ".zh-CN.srt" ".zh-Hans.srt" ".chs.srt" ".sc.srt")
  "File suffixes probed beside a video when it opens.
The bare `.srt' and `.vtt' come first; the language suffixes cover the common
Chinese naming (`movie.zh.srt') before falling back to a plain track."
  :type '(repeat string)
  :group 'etaf-video-player)

(defconst etaf-video-player-subtitle--clock-regexp
  (concat "\\([0-9]+:[0-9]+:[0-9]+\\(?:[,.][0-9]+\\)?"
          "\\|[0-9]+:[0-9]+\\(?:[,.][0-9]+\\)?"
          "\\|[0-9]+[,.][0-9]+\\)")
  "Regexp matching one subtitle clock token.")

(defun etaf-video-player-subtitle--seconds (token)
  "Parse the subtitle clock TOKEN into seconds.
TOKEN is `HH:MM:SS[.,frac]', `MM:SS[.,frac]' or `SS[.,frac]'; nil when
it does not carry a clock.  The match data is preserved so callers can read
other groups of their own match."
  (save-match-data
    (when (and (stringp token)
               (string-match
                "\\`\\([0-9]+\\(?::[0-9]+\\)*\\)\\(?:[,.]\\([0-9]+\\)\\)?\\'"
                token))
      ;; Capture both match groups before `split-string' overwrites match data.
      (let* ((whole (match-string 1 token))
             (frac (match-string 2 token))
             (fields (mapcar #'string-to-number (split-string whole ":" t)))
             (fraction (if frac (string-to-number (concat "0." frac)) 0.0)))
        (pcase (length fields)
          (3 (+ (* (nth 0 fields) 3600.0)
                (* (nth 1 fields) 60.0)
                (nth 2 fields)
                fraction))
          (2 (+ (* (nth 0 fields) 60.0)
                (nth 1 fields)
                fraction))
          (1 (when frac (+ (nth 0 fields) fraction)))
          (_ nil))))))

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
    (when (eq (char-after) ?\ufeff)
      (delete-char 1))
    (let ((arrow-regexp
           (concat etaf-video-player-subtitle--clock-regexp
                   "[ \t]*-->[ \t]*"
                   etaf-video-player-subtitle--clock-regexp))
          cues)
      (while (not (eobp))
        (let ((line (etaf-video-player-subtitle--line)))
          (cond
           ;; Skip WebVTT NOTE comment blocks up to the next blank line.
           ((string-match-p "\\`NOTE\\(?:[ \t]\\|\\'\\)" line)
            (forward-line 1)
            (while (and (not (eobp))
                        (not (string-empty-p
                              (string-trim (etaf-video-player-subtitle--line)))))
              (forward-line 1)))
           ((not (string-match arrow-regexp line))
            (forward-line 1))
           (t
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
                    (push (list start end (string-join (nreverse texts) " "))
                          cues)))))))))
      (sort (nreverse cues) (lambda (a b) (< (car a) (car b)))))))

(defun etaf-video-player-subtitle-text-at (cues seconds)
  "Return the text of the cue in CUES covering SECONDS, or nil.
CUES is a sorted list (from `etaf-video-player-subtitle-parse') or vector of
cues; SECONDS is the playback position.  Uses an upper-bound binary search so
lookups stay O(log n) on vectors while still honoring overlapping cues."
  (when (and cues (numberp seconds))
    (let* ((vec (if (vectorp cues) cues (vconcat cues)))
           (len (length vec)))
      (when (> len 0)
        ;; Find the rightmost cue whose start <= seconds.
        (let ((low 0)
              (high (1- len))
              (pos -1))
          (while (<= low high)
            (let* ((mid (/ (+ low high) 2))
                   (start (nth 0 (aref vec mid))))
              (if (<= start seconds)
                  (setq pos mid low (1+ mid))
                (setq high (1- mid)))))
          (when (>= pos 0)
            ;; Scan a bounded neighborhood backward to catch overlapping cues
            ;; (for example a longer caption spanning a shorter nested cue).
            (let ((floor-idx (max 0 (- pos 8)))
                  (idx pos)
                  matches)
              (while (>= idx floor-idx)
                (let ((cue (aref vec idx)))
                  (when (< seconds (nth 1 cue))
                    (push (nth 2 cue) matches)))
                (setq idx (1- idx)))
              (when matches
                (if (cdr matches)
                    (string-join matches " ")
                  (car matches))))))))))

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
