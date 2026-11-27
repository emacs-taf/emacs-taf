;;; etaf-agenda-parse.el --- Natural-language capture grammar of etaf-agenda -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; One pure function turns a captured line into structured fields.  Recognised
;; tokens include dates (`今天', `明天', `周五', `下周一', `2026-11-02'), times
;; (`15:00', `15:00-16:00'), priorities (`!1'..`!3'), tags (`#tag'), area
;; (`@area'), project (`+project'), estimate (`~30m', `~1.5h', `~45分'),
;; deadline (`截止:明天', `截止:2026-11-25'), habits (`每天', `工作日', `每周'),
;; recurrence (`重复:每天|工作日|每周|每月') and leading `- ' (note) or `? '
;; (question).  Unrecognised words always stay in the title, so capture never
;; fails.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'time-date)
(require 'calendar)

(defconst etaf-agenda--date-words
  '(("今天" . 0) ("今日" . 0) ("明天" . 1) ("明日" . 1)
    ("后天" . 2) ("大后天" . 3) ("昨天" . -1) ("前天" . -2))
  "Relative day words and their offset in days.")

(defconst etaf-agenda--weekday-words
  '(("一" . 1) ("二" . 2) ("三" . 3) ("四" . 4) ("五" . 5) ("六" . 6)
    ("日" . 0) ("天" . 0))
  "Weekday names and their `calendar-day-of-week' value.")

(defconst etaf-agenda--habit-words
  '(("每天" . 7) ("每周" . 1) ("工作日" . 5))
  "Habit prefixes and their weekly target days.")

(defconst etaf-agenda--recurrence-words
  '(("每天" . "daily") ("每日" . "daily")
    ("工作日" . "weekdays")
    ("每周" . "weekly") ("每星期" . "weekly")
    ("每月" . "monthly"))
  "Recurrence keywords mapped to stored recurrence tokens.")

(defun etaf-agenda-ymd (time)
  "Return TIME's local date as an integer YYYYMMDD."
  (let ((parts (decode-time time)))
    (+ (* 10000 (nth 5 parts)) (* 100 (nth 4 parts)) (nth 3 parts))))

(defun etaf-agenda--ymd-string (ymd)
  "Return YMD as an ISO date string."
  (format "%04d-%02d-%02d" (/ ymd 10000) (% (/ ymd 100) 100) (% ymd 100)))

(defun etaf-agenda--day-number (ymd)
  "Return the absolute day number of YMD, an integer YYYYMMDD."
  (date-to-day (etaf-agenda--ymd-string ymd)))

(defun etaf-agenda--number->ymd (number)
  "Return the YYYYMMDD integer of absolute day NUMBER."
  (pcase-let ((`(,month ,day ,year) (calendar-gregorian-from-absolute number)))
    (+ (* 10000 year) (* 100 month) day)))

(defun etaf-agenda--weekday-of (ymd)
  "Return the `calendar-day-of-week' value of YMD."
  (calendar-day-of-week (list (% (/ ymd 100) 100) (% ymd 100) (/ ymd 10000))))

(defun etaf-agenda--shift (ymd delta)
  "Return YMD shifted by DELTA days."
  (etaf-agenda--number->ymd (+ (etaf-agenda--day-number ymd) delta)))

(defun etaf-agenda--next-weekday (today target next-week)
  "Return TODAY moved forward to weekday TARGET.
TODAY itself answers when it already is TARGET and NEXT-WEEK is nil."
  (let* ((current (etaf-agenda--weekday-of today))
         (delta (- target current)))
    (when (or (< delta 0) (and next-week (= delta 0)))
      (setq delta (+ delta 7)))
    (etaf-agenda--shift today delta)))

(defun etaf-agenda--take-bounded (regexp text)
  "Remove the first bounded match of REGEXP from TEXT and return (VALUE . REST).
A match must start at the beginning of TEXT or after whitespace."
  (let ((full (concat "\\(?:^\\|[ \t]\\)\\(" regexp "\\)\\(?:[ \t]\\|$\\)")))
    (if (not (string-match full text))
        (cons nil text)
      (let ((value (match-string 1 text))
            (rest (concat (substring text 0 (match-beginning 0))
                          " "
                          (substring text (match-end 0)))))
        (cons value rest)))))

(defun etaf-agenda--parse-date-token (token today)
  "Parse a single date TOKEN relative to TODAY, returning YYYYMMDD or nil."
  (when (and token (not (string-empty-p token)))
    (let ((case-fold-search nil))
      (cond
       ((string-match "\\`\\([0-9]\\{4\\}\\)-\\([0-9]\\{1,2\\}\\)-\\([0-9]\\{1,2\\}\\)\\'" token)
        (let ((y (string-to-number (match-string 1 token)))
              (m (string-to-number (match-string 2 token)))
              (d (string-to-number (match-string 3 token))))
          (when (and (<= 1 m 12) (<= 1 d 31))
            (+ (* 10000 y) (* 100 m) d))))
       ((string-match "\\`下\\(?:个\\)?\\(?:周\\|星期\\|礼拜\\)\\([一二三四五六日天]\\)\\'" token)
        (etaf-agenda--next-weekday
         today (cdr (assoc (match-string 1 token) etaf-agenda--weekday-words)) t))
       ((string-match "\\`\\(?:周\\|星期\\|礼拜\\)\\([一二三四五六日天]\\)\\'" token)
        (etaf-agenda--next-weekday
         today (cdr (assoc (match-string 1 token) etaf-agenda--weekday-words)) nil))
       ((assoc token etaf-agenda--date-words)
        (etaf-agenda--shift today (cdr (assoc token etaf-agenda--date-words))))
       (t nil)))))

(defun etaf-agenda--parse-date (text today)
  "Remove a leading date word or ISO date from TEXT and return (YMD . REST)."
  (let ((case-fold-search nil)
        (found nil))
    (cond
     ((string-match "\\`[ \t]*\\([0-9]\\{4\\}\\)-\\([0-9]\\{2\\}\\)-\\([0-9]\\{2\\}\\)"
                    text)
      (setq found (+ (* 10000 (string-to-number (match-string 1 text)))
                     (* 100 (string-to-number (match-string 2 text)))
                     (string-to-number (match-string 3 text))))
      (cons found (concat " " (substring text (match-end 0)))))
     (t
      (let ((next-week nil)
            (probe text))
        (when (string-match "\\`[ \t]*下\\(?:个\\)?\\(周\\|星期\\|礼拜\\)" probe)
          (setq next-week t
                probe (concat " " (match-string 1 probe)
                              (substring probe (match-end 0)))))
        (if (and (string-match "\\`[ \t]*\\(?:周\\|星期\\|礼拜\\)\\([一二三四五六日天]\\)"
                               probe)
                 (let ((tail (substring probe (match-end 0))))
                   (or (string-empty-p tail)
                       (string-match-p "\\`[ \t0-9]" tail))))
            (let ((target (cdr (assoc (match-string 1 probe)
                                      etaf-agenda--weekday-words)))
                  (rest (concat " " (substring probe (match-end 0)))))
              (cons (etaf-agenda--next-weekday today target next-week)
                    rest))
          (let ((trimmed (string-trim-left text)))
            (cl-loop for (word . offset) in etaf-agenda--date-words
                     when (and (string-prefix-p word trimmed)
                               (let ((tail (substring trimmed (length word))))
                                 (or (string-empty-p tail)
                                     (string-match-p "\\`[ \t0-9]" tail))))
                     do (setq found (etaf-agenda--shift today offset))
                        (setq text (concat " " (substring trimmed (length word))))
                        (cl-return)))
          (cons found text)))))))

(defun etaf-agenda--hhmm (string)
  "Return the HHMM integer of STRING, a H:MM clock time, or nil."
  (when (and string
             (string-match "\\`\\([0-9]\\{1,2\\}\\):\\([0-9]\\{2\\}\\)\\'" string))
    (let ((hour (string-to-number (match-string 1 string)))
          (minute (string-to-number (match-string 2 string))))
      (and (< hour 24) (< minute 60) (+ (* hour 100) minute)))))

(defun etaf-agenda--parse-time (text)
  "Remove a clock time or range from TEXT.
Return (AT END . REST); AT and END are HHMM integers or nil."
  (let ((regexp "\\(?:^\\|[ \t]\\)\\([0-9]\\{1,2\\}:[0-9]\\{2\\}\\)\\(?:[-~–]\\([0-9]\\{1,2\\}:[0-9]\\{2\\}\\)\\)?\\(?:[ \t]\\|$\\)"))
    (if (not (string-match regexp text))
        (list nil nil text)
      (let ((first (match-string 1 text))
            (second (match-string 2 text))
            (beg (match-beginning 0))
            (end (match-end 0)))
        (list (etaf-agenda--hhmm first)
              (etaf-agenda--hhmm second)
              (concat (substring text 0 beg) " " (substring text end)))))))

(defun etaf-agenda--parse-estimate (token)
  "Parse estimate TOKEN such as `~30m', `~1.5h', `~45分', returning minutes."
  (when (and token (string-prefix-p "~" token))
    (let ((body (substring token 1)))
      (cond
       ((string-match "\\`\\([0-9]+\\(?:\\.[0-9]+\\)?\\)[hH小时]+\\'" body)
        (round (* 60 (string-to-number (match-string 1 body)))))
       ((string-match "\\`\\([0-9]+\\)\\(?:[mM]\\|分\\|分钟\\)\\'" body)
        (string-to-number (match-string 1 body)))
       (t nil)))))

(defun etaf-agenda--clean (text)
  "Collapse whitespace in TEXT and trim it."
  (string-trim (replace-regexp-in-string "[ \t\n]+" " " text)))

(defun etaf-agenda-parse (text &optional today)
  "Return the structured capture fields of TEXT relative to TODAY.
Result plist keys: `:title', `:kind', `:date', `:at', `:end', `:deadline',
`:estimate', `:priority', `:tags', `:container' (area name), `:project'
(project name), `:habit' and `:recurrence'."
  (let* ((today (or today (etaf-agenda-ymd (current-time))))
         (rest text)
         (kind nil)
         (tags nil)
         (container nil)
         (project nil)
         (priority nil)
         (estimate nil)
         (deadline nil)
         (habit nil)
         (recurrence nil)
         (case-fold-search nil))
    ;; Leading note/question shorthand
    (let ((trimmed (string-trim-left rest)))
      (cond
       ((string-prefix-p "- " trimmed)
        (setq kind "note" rest (substring trimmed 2)))
       ((or (string-prefix-p "? " trimmed) (string-prefix-p "？ " trimmed))
        (setq kind "question" rest (substring trimmed 2)))))
    ;; #tags (repeatable)
    (while (string-match "\\(?:^\\|[ \t]\\)#\\([^ \t]+\\)\\(?:[ \t]\\|$\\)" rest)
      (push (match-string 1 rest) tags)
      (setq rest (concat (substring rest 0 (match-beginning 0)) " "
                         (substring rest (match-end 0)))))
    ;; @area
    (let ((pair (etaf-agenda--take-bounded "@[^ \t]+" rest)))
      (setq container (and (car pair) (substring (car pair) 1))
            rest (cdr pair)))
    ;; +project
    (let ((pair (etaf-agenda--take-bounded "\\+[^ \t]+" rest)))
      (setq project (and (car pair) (substring (car pair) 1))
            rest (cdr pair)))
    ;; !1..!3 priority
    (let ((pair (etaf-agenda--take-bounded "![123]" rest)))
      (setq priority (and (car pair) (string-to-number (substring (car pair) 1)))
            rest (cdr pair)))
    ;; ~estimate
    (let ((pair (etaf-agenda--take-bounded "~[0-9]+\\(?:\\.[0-9]+\\)?\\(?:[hHmM]\\|小时\\|分钟?\\)" rest)))
      (when (car pair)
        (setq estimate (etaf-agenda--parse-estimate (car pair))
              rest (cdr pair))))
    ;; 截止:DATE
    (let ((pair (etaf-agenda--take-bounded "截止[:：][^ \t]+" rest)))
      (when (car pair)
        (let* ((raw (replace-regexp-in-string "\\`截止[:：]" "" (car pair)))
               (parsed (etaf-agenda--parse-date-token raw today)))
          (when parsed
            (setq deadline parsed
                  rest (cdr pair))))))
    ;; 重复:FREQ
    (let ((pair (etaf-agenda--take-bounded "重复[:：][^ \t]+" rest)))
      (when (car pair)
        (let* ((raw (replace-regexp-in-string "\\`重复[:：]" "" (car pair)))
               (freq (cdr (assoc raw etaf-agenda--recurrence-words))))
          (when freq
            (setq recurrence freq
                  rest (cdr pair))))))
    ;; Leading habit prefix (only when not explicit recurrence; require space after keyword)
    (unless recurrence
      (dolist (pair etaf-agenda--habit-words)
        (let ((word (car pair))
              (trimmed (string-trim-left rest)))
          (when (and (not habit)
                     (string-prefix-p word trimmed)
                     (let ((tail (substring trimmed (length word))))
                       (string-match-p "\\`[ \t]+" tail)))
            (setq habit (cdr pair)
                  rest (concat " " (substring trimmed (length word))))))))
    ;; Time and date
    (let* ((time-pair (etaf-agenda--parse-time rest))
           (at (nth 0 time-pair))
           (end (nth 1 time-pair))
           (date-pair (etaf-agenda--parse-date (nth 2 time-pair) today)))
      (when (and (null kind) at (not habit))
        (setq kind "event"))
      (list :title (let ((title (etaf-agenda--clean (cdr date-pair))))
                     (if (string-empty-p title) (string-trim text) title))
            :kind kind
            :date (and (not habit) (car date-pair))
            :at at
            :end end
            :deadline deadline
            :estimate estimate
            :priority priority
            :tags (nreverse tags)
            :container container
            :project project
            :habit habit
            :recurrence recurrence))))

(provide 'etaf-agenda-parse)
;;; etaf-agenda-parse.el ends here
