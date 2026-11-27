;;; etaf-agenda-model.el --- Reactive state and domain logic of etaf-agenda -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; Owns the complete application state, queries, projections, mutations,
;; undo history and container management.  All writes go to SQLite first and
;; then reload the working window (previous, current and next month buckets)
;; so the screen never diverges from the store.  No buffer or view dependency
;; lives here; every command operates on an explicit MODEL.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'calendar)
(require 'etaf)
(require 'etaf-agenda-parse)
(require 'etaf-agenda-store)
(require 'etaf-agenda-layout)

(declare-function etaf-agenda-open "etaf-agenda" (&optional file mount-options))

(defconst etaf-agenda-weekday-labels
  ["周日" "周一" "周二" "周三" "周四" "周五" "周六"]
  "Chinese weekday labels indexed by `calendar-day-of-week'.")

(defconst etaf-agenda-status-labels
  '(("open" . "待办") ("doing" . "在做") ("waiting" . "等待")
    ("deferred" . "以后") ("done" . "完成") ("dropped" . "放弃"))
  "Display label of each entry status.")

(defconst etaf-agenda-status-cycle
  '("open" "doing" "waiting" "deferred" "done")
  "Ordered statuses cycled by `etaf-agenda-cycle-status'.")

(defconst etaf-agenda-kind-labels
  '(("task" . "待办") ("event" . "日程") ("note" . "记录") ("question" . "问题"))
  "Display label of each entry kind.")

(defconst etaf-agenda-recurrence-labels
  '(("daily" . "每天") ("weekdays" . "工作日")
    ("weekly" . "每周") ("monthly" . "每月"))
  "Display label of each recurrence rule.")

(defconst etaf-agenda-views
  '((today "今日") (calendar "日历") (list "清单")
    (project "项目") (habits "习惯") (review "回顾"))
  "Pages of the application, in tab order.")

(defconst etaf-agenda-habit-days 21
  "Days shown in the habit matrix strip, ending at the displayed day.")

;;; ---------------------------------------------------------------------------
;;; Date helpers
;;; ---------------------------------------------------------------------------

(defun etaf-agenda--today ()
  "Return today's date as an integer YYYYMMDD."
  (etaf-agenda-ymd (current-time)))

(defun etaf-agenda--date-label (ymd)
  "Return a human label such as `11 月 22 日' for YMD."
  (if (not (integerp ymd))
      "未排期"
    (format "%d 月 %d 日" (% (/ ymd 100) 100) (% ymd 100))))

(defun etaf-agenda--short-date-label (ymd)
  "Return a compact MM-DD label for YMD."
  (if (not (integerp ymd))
      "—"
    (format "%02d-%02d" (% (/ ymd 100) 100) (% ymd 100))))

(defun etaf-agenda--weekday-label (ymd)
  "Return the weekday label of YMD."
  (aref etaf-agenda-weekday-labels (etaf-agenda--weekday-of ymd)))

(defun etaf-agenda--iso-week (ymd)
  "Return the ISO week number of YMD."
  (let* ((day (etaf-agenda--day-number ymd))
         (dow (let ((value (etaf-agenda--weekday-of ymd)))
                (if (= value 0) 7 value)))
         (thursday (+ day (- 4 dow)))
         (year (nth 2 (calendar-gregorian-from-absolute thursday)))
         (jan1 (etaf-agenda--day-number (+ (* year 10000) 101))))
    (1+ (/ (- thursday jan1) 7))))

(defun etaf-agenda--week-start (ymd)
  "Return the Monday of YMD's week."
  (let ((dow (etaf-agenda--weekday-of ymd)))
    (etaf-agenda--shift ymd (- (if (= dow 0) 6 (1- dow))))))

(defun etaf-agenda--last-day-of-month (ymd)
  "Return the last day of YMD's month."
  (let* ((year (/ ymd 10000))
         (month (% (/ ymd 100) 100))
         (next (if (= month 12)
                   (+ (* (1+ year) 10000) 101)
                 (+ (* year 10000) (* (1+ month) 100) 1))))
    (etaf-agenda--shift next -1)))

(defun etaf-agenda--shift-month (ymd delta)
  "Return YMD moved DELTA months, clamping to the target month's last day."
  (let* ((total (+ (* (/ ymd 10000) 12) (1- (% (/ ymd 100) 100)) delta))
         (first (+ (* (/ total 12) 10000) (* (1+ (mod total 12)) 100) 1))
         (last (etaf-agenda--last-day-of-month first)))
    (min last (+ first (1- (% ymd 100))))))

(defun etaf-agenda--next-recurrence-day (ymd recurrence)
  "Return the next scheduled YYYYMMDD after YMD for RECURRENCE, or nil."
  (pcase recurrence
    ("daily" (etaf-agenda--shift ymd 1))
    ("weekdays"
     (let ((next (etaf-agenda--shift ymd 1)))
       (while (memq (etaf-agenda--weekday-of next) '(0 6))
         (setq next (etaf-agenda--shift next 1)))
       next))
    ("weekly" (etaf-agenda--shift ymd 7))
    ("monthly" (etaf-agenda--shift-month ymd 1))
    (_ nil)))

(defun etaf-agenda--clock-label (hhmm)
  "Return HHMM integer as `HH:MM', or empty string."
  (if (not (integerp hhmm))
      ""
    (format "%02d:%02d" (/ hhmm 100) (% hhmm 100))))

(defun etaf-agenda--time-range-label (at end)
  "Return `HH:MM–HH:MM' or `HH:MM' for AT and END."
  (cond ((and (integerp at) (integerp end))
         (format "%s–%s" (etaf-agenda--clock-label at)
                 (etaf-agenda--clock-label end)))
        ((integerp at) (etaf-agenda--clock-label at))
        (t nil)))

(defun etaf-agenda--duration-label (minutes)
  "Return MINUTES as a Chinese duration string for detail views."
  (cond ((null minutes) nil)
        ((<= minutes 0) nil)
        ((< minutes 60) (format "%d 分" minutes))
        ((zerop (% minutes 60)) (format "%d 小时" (/ minutes 60)))
        (t (format "%d 小时 %d 分" (/ minutes 60) (% minutes 60)))))

(defun etaf-agenda--short-duration-label (minutes)
  "Return MINUTES as a compact inline duration string (e.g. `30 分', `1.5h')."
  (cond ((null minutes) nil)
        ((<= minutes 0) nil)
        ((< minutes 60) (format "%d 分" minutes))
        ((zerop (% minutes 60)) (format "%dh" (/ minutes 60)))
        ((= (% minutes 60) 30) (format "%d.5h" (/ minutes 60)))
        (t (format "%dh%dm" (/ minutes 60) (% minutes 60)))))

(defun etaf-agenda--unique-id (&optional prefix)
  "Return a fresh unique identifier string, optionally prefixed with PREFIX."
  (format "%s%s-%06d"
          (or prefix "")
          (format-time-string "%Y%m%dT%H%M%S")
          (random 1000000)))

(defun etaf-agenda--index (rows key)
  "Return a hash table indexing ROWS by (plist-get ROW KEY)."
  (let ((table (make-hash-table :test #'equal)))
    (dolist (row rows table)
      (puthash (plist-get row key) row table))))

;;; ---------------------------------------------------------------------------
;;; Model lifecycle and snapshot
;;; ---------------------------------------------------------------------------

(defvar etaf-agenda-model-resolver nil
  "Function returning the model of the current agenda buffer.")

(defun etaf-agenda-current-model ()
  "Return the model of the current agenda buffer, or signal `user-error'."
  (or (and etaf-agenda-model-resolver
           (ignore-errors (funcall etaf-agenda-model-resolver)))
      (user-error "当前 buffer 不是议程")))

(defun etaf-agenda--read (model)
  "Return MODEL's published snapshot."
  (etaf-value (plist-get model :snapshot)))

(defun etaf-agenda--deleted-p (row)
  "Return non-nil when ROW carries the soft-delete flag."
  (let ((deleted (plist-get row :deleted)))
    (and deleted (not (equal deleted 0)))))

(defun etaf-agenda--load (store day &optional full-year)
  "Read STORE's window around DAY and index live records.
When FULL-YEAR is non-nil, load all 12 month buckets of DAY's year."
  (let ((raw (etaf-agenda--store-load store day full-year (etaf-agenda--today))))
    (list :day day
          :year-loaded (and full-year (/ day 10000))
          :entries (etaf-agenda--index
                    (seq-remove #'etaf-agenda--deleted-p
                                (plist-get raw :entries))
                    :id)
          :instances (etaf-agenda--index (plist-get raw :instances) :id)
          :containers (seq-remove #'etaf-agenda--deleted-p
                                  (plist-get raw :containers)))))

(defun etaf-agenda--year-mode-p (model)
  "Return non-nil when MODEL is displaying Calendar Year View."
  (and (eq (etaf-value (plist-get model :view)) 'calendar)
       (eq (etaf-value (plist-get model :calendar-mode)) 'year)))

(defun etaf-agenda--refresh-inspector-logs (model)
  "Reload `:inspector-logs' from store if an inspector entry is open."
  (let ((id (etaf-value (plist-get model :inspector))))
    (etaf-set-value (plist-get model :inspector-logs)
                    (if id
                        (seq-take (etaf-agenda--store-logs-for-entry
                                   (plist-get model :store) id)
                                  8)
                      nil))))

(defun etaf-agenda--sync-activity (snapshot)
  "Publish today's schedule summary from SNAPSHOT to ETAF Live Activity."
  (when snapshot
    (let* ((today (etaf-agenda--today))
           (day-rows (etaf-agenda--collect-day snapshot today 'all))
           (overdue (length (plist-get day-rows :overdue)))
           (open-tasks (or (plist-get day-rows :open) 0))
           (events (seq-remove (lambda (r) (plist-get r :done))
                               (plist-get day-rows :events)))
           (now-hhmm (let ((d (decode-time)))
                       (+ (* (nth 2 d) 100) (nth 1 d))))
           (next-ev (or (seq-find (lambda (r)
                                    (let ((at (plist-get r :at)))
                                      (and (integerp at) (< at 99999) (>= at now-hhmm))))
                                  events)
                        (car events)))
           (total (+ overdue open-tasks (length events))))
      (if (<= total 0)
          (when (etaf-activity-get 'etaf-agenda)
            (etaf-activity-remove 'etaf-agenda))
        (let* ((ev-at (and next-ev (plist-get next-ev :at)))
               (ev-time (and (integerp ev-at) (< ev-at 99999)
                             (etaf-agenda--clock-label ev-at)))
               (ev-title (and next-ev (plist-get next-ev :title)))
               (compact (cond
                         ((and ev-time ev-title)
                          (format "%s %s" ev-time ev-title))
                         (ev-title ev-title)
                         ((> overdue 0)
                          (format "今日 %d 项 · %d 逾期" (+ open-tasks (length events)) overdue))
                         (t (format "今日 %d 待办" total))))
               (sub-parts
                (delq nil
                      (list (format "今日 %d 待办" (+ open-tasks (length events)))
                            (when (> overdue 0) (format "%d 逾期" overdue))
                            (when (and ev-time ev-title)
                              (format "下场 %s %s" ev-time ev-title))))))
          (etaf-activity-publish
           'etaf-agenda
           (list
            :app 'etaf-agenda
            :kind 'schedule
            :priority (if ev-time 60 50)
            :state (if ev-time 'active 'idle)
            :tone (if (> overdue 0) 'warning 'info)
            :icon "◷"
            :title (or ev-title "今日议程")
            :subtitle (mapconcat #'identity sub-parts " · ")
            :compact compact
            :open (lambda ()
                    (when (fboundp 'etaf-agenda-open)
                      (etaf-agenda-open))))))))))

(defun etaf-agenda--publish (model snapshot &optional day)
  "Replace MODEL's snapshot with SNAPSHOT, updating DAY when given."
  (etaf-batch
   (when day
     (etaf-set-value (plist-get model :day) day))
   (etaf-set-value (plist-get model :snapshot) snapshot)
   (etaf-agenda--refresh-inspector-logs model))
  (etaf-agenda--sync-activity snapshot))

(defun etaf-agenda--reload (model &optional day)
  "Re-read MODEL's window around DAY (defaulting to its current day)."
  (let* ((day (or day (etaf-value (plist-get model :day))))
         (snapshot (etaf-agenda--load (plist-get model :store) day
                                      (etaf-agenda--year-mode-p model))))
    (etaf-agenda--publish model snapshot day)))

(defun etaf-agenda--make-model (&optional file)
  "Create a fresh agenda model over SQLite store FILE."
  (let* ((store (etaf-agenda--store-open file))
         (day (etaf-agenda--today))
         (saved-sb (ignore-errors (etaf-agenda--store-meta-get store "sidebar-width")))
         (saved-rl (ignore-errors (etaf-agenda--store-meta-get store "rail-width")))
         (sb-cols (if (and saved-sb (> (string-to-number saved-sb) 10))
                      (string-to-number saved-sb)
                    etaf-agenda-default-sidebar-cols))
         (rl-cols (if (and saved-rl (> (string-to-number saved-rl) 14))
                      (string-to-number saved-rl)
                    etaf-agenda-default-rail-cols))
         (initial-snapshot (etaf-agenda--load store day)))
    (etaf-agenda--sync-activity initial-snapshot)
    (list :store store
          :day (etaf-ref day :name 'etaf-agenda-day)
          :snapshot (etaf-ref initial-snapshot :name 'etaf-agenda-snapshot)
          :view (etaf-ref 'today :name 'etaf-agenda-view)
          :calendar-mode (etaf-ref 'month :name 'etaf-agenda-calendar-mode)
          :area (etaf-ref 'all :name 'etaf-agenda-area)
          :project (etaf-ref nil :name 'etaf-agenda-project)
          :grouping (etaf-ref 'time :name 'etaf-agenda-grouping)
          :show-completed (etaf-ref t :name 'etaf-agenda-show-completed)
          :query (etaf-ref "" :name 'etaf-agenda-query)
          :search-input (etaf-ref "" :name 'etaf-agenda-search-input)
          :selected (etaf-ref nil :name 'etaf-agenda-selected)
          :selected-habit-day (etaf-ref day :name 'etaf-agenda-habit-day)
          :inspector (etaf-ref nil :name 'etaf-agenda-inspector)
          :inspector-logs (etaf-ref nil :name 'etaf-agenda-inspector-logs)
          :inspector-body-editing (etaf-ref nil :name 'etaf-agenda-body-editing)
          :inspector-body-draft (etaf-ref "" :name 'etaf-agenda-body-draft)
          :editing (etaf-ref nil :name 'etaf-agenda-editing)
          :edit-draft (etaf-ref "" :name 'etaf-agenda-edit-draft)
          :drafting (etaf-ref nil :name 'etaf-agenda-drafting)
          :draft (etaf-ref "" :name 'etaf-agenda-draft)
          :width (etaf-ref 148 :name 'etaf-agenda-width)
          :width-px (etaf-ref 1036 :name 'etaf-agenda-width-px)
          :height (etaf-ref 42 :name 'etaf-agenda-height)
          :sidebar-width (etaf-ref sb-cols :name 'etaf-agenda-sidebar-width)
          :rail-width (etaf-ref rl-cols :name 'etaf-agenda-rail-width)
          :message (etaf-ref nil :name 'etaf-agenda-message)
          :undo-stack (list nil))))

(defun etaf-agenda--release (model)
  "Release MODEL's store."
  (etaf-agenda--store-close (plist-get model :store)))

(defun etaf-agenda--notice (model text)
  "Set MODEL's status notice to TEXT."
  (etaf-set-value (plist-get model :message) text))

;;; ---------------------------------------------------------------------------
;;; Containers, lookup & predicates
;;; ---------------------------------------------------------------------------

(defun etaf-agenda--instance-of (snapshot entry-id day)
  "Return SNAPSHOT's instance of ENTRY-ID on DAY, or nil."
  (gethash (format "%s@%d" entry-id day) (plist-get snapshot :instances)))

(defun etaf-agenda--habit-p (entry)
  "Return non-nil when ENTRY is a habit."
  (and entry (plist-get entry :habit_target) t))

(defun etaf-agenda--entry-done-p (entry &optional instance)
  "Return non-nil when ENTRY (or INSTANCE) is completed."
  (or (equal (and instance (plist-get instance :state)) "done")
      (equal (and entry (plist-get entry :status)) "done")))

(defun etaf-agenda--entry-open-p (entry)
  "Return non-nil when ENTRY still needs work."
  (and entry
       (member (plist-get entry :status) '("open" "doing" "waiting" "deferred"))
       t))

(defun etaf-agenda--container-of (snapshot id)
  "Return SNAPSHOT's container row matching ID, or nil."
  (when id
    (seq-find (lambda (row) (equal (plist-get row :id) id))
              (plist-get snapshot :containers))))

(defun etaf-agenda--container-name (snapshot id)
  "Return the display name of container ID in SNAPSHOT, or nil."
  (when id
    (or (plist-get (etaf-agenda--container-of snapshot id) :name)
        (and (stringp id) id))))

(defun etaf-agenda--find-container-by-name (snapshot kind name &optional parent)
  "Find a container of KIND with NAME (case-insensitive) in SNAPSHOT."
  (let ((needle (downcase (string-trim name))))
    (seq-find (lambda (row)
                (and (equal (plist-get row :kind) kind)
                     (or (null parent) (equal (plist-get row :parent) parent))
                     (equal (downcase (string-trim (or (plist-get row :name) "")))
                            needle)))
              (plist-get snapshot :containers))))

(defun etaf-agenda--entry-in-area-p (entry area)
  "Return non-nil when ENTRY belongs to AREA (`all', `inbox' or area id)."
  (pcase area
    ('all t)
    ('nil t)
    ('inbox (null (plist-get entry :area)))
    (_ (equal (plist-get entry :area) area))))

(defun etaf-agenda--entry-matches-query-p (snapshot entry query)
  "Return non-nil when ENTRY matches space-separated search terms in QUERY."
  (let ((q (string-trim (or query ""))))
    (if (string-empty-p q)
        t
      (let* ((terms (split-string (downcase q) "[ \t]+" t))
             (haystack
              (downcase
               (string-join
                (delq nil
                      (list (plist-get entry :title)
                            (plist-get entry :body)
                            (plist-get entry :tags)
                            (etaf-agenda--container-name snapshot (plist-get entry :area))
                            (etaf-agenda--container-name snapshot (plist-get entry :project))
                            (etaf-agenda--container-name snapshot (plist-get entry :stage))))
                " "))))
        (cl-every (lambda (term) (string-match-p (regexp-quote term) haystack))
                  terms)))))

(defun etaf-agenda--push-count (snapshot entry-id)
  "Return how many times ENTRY-ID was migrated in SNAPSHOT's window."
  (let ((count 0))
    (maphash (lambda (_id instance)
               (when (and (equal (plist-get instance :entry) entry-id)
                          (equal (plist-get instance :state) "moved"))
                 (cl-incf count)))
             (plist-get snapshot :instances))
    count))

;;; ---------------------------------------------------------------------------
;;; Row projection
;;; ---------------------------------------------------------------------------

(defun etaf-agenda--row-mark (entry instance)
  "Return (KIND . VALUE) for ENTRY's mark column."
  (let ((kind (plist-get entry :kind))
        (state (and instance (plist-get instance :state)))
        (status (plist-get entry :status)))
    (cond ((equal state "moved") (cons 'glyph "→"))
          ((or (equal state "done") (equal status "done")) (cons 'box "done"))
          ((equal state "skipped") (cons 'box "skipped"))
          ((equal status "dropped") (cons 'box "dropped"))
          ((equal kind "event") (cons 'glyph "│"))
          ((equal kind "note") (cons 'glyph "–"))
          ((equal kind "question") (cons 'glyph "?"))
          (t (cons 'box "empty")))))

(defun etaf-agenda--entry-meta (entry instance day &optional overdue-days)
  "Return concise single-slot display metadata (<= 11ch) for ENTRY on DAY.
Keeps tabular list time/meta columns strictly aligned; full details (such as
both deadline and estimate together) remain visible in the Inspector."
  (let* ((deadline (plist-get entry :deadline))
         (estimate (plist-get entry :estimate))
         (done (etaf-agenda--entry-done-p entry instance))
         (overdue-p (and overdue-days (> overdue-days 0))))
    (cond
     (overdue-p (format "逾期 %d 天" overdue-days))
     (done "已完成")
     (deadline
      (cond ((equal deadline day) "今天截止")
            ((< deadline day)
             (format "%s 过期" (etaf-agenda--short-date-label deadline)))
            (t (format "%s 截止" (etaf-agenda--short-date-label deadline)))))
     (estimate (etaf-agenda--short-duration-label estimate))
     (t ""))))

(defun etaf-agenda--row (snapshot entry instance day &optional section meta-override)
  "Build display row plist for ENTRY and INSTANCE on DAY."
  (let* ((id (plist-get entry :id))
         (scheduled (plist-get entry :scheduled))
         (overdue-days (and (eq section 'overdue) scheduled
                            (max 1 (- (etaf-agenda--day-number day)
                                      (etaf-agenda--day-number scheduled)))))
         (done (etaf-agenda--entry-done-p entry instance))
         (area-name (etaf-agenda--container-name snapshot (plist-get entry :area)))
         (proj-name (etaf-agenda--container-name snapshot (plist-get entry :project)))
         (status (plist-get entry :status))
         (status-badge (and (not done)
                            (member status '("doing" "waiting" "deferred"))
                            (cdr (assoc status etaf-agenda-status-labels)))))
    (list :id id
          :section section
          :title (or (plist-get entry :title) "")
          :kind (or (plist-get entry :kind) "task")
          :status (or status "open")
          :status-badge status-badge
          :done done
          :priority (plist-get entry :priority)
          :time-label (etaf-agenda--time-range-label (plist-get entry :at)
                                                     (plist-get entry :end_at))
          :scheduled scheduled
          :deadline (plist-get entry :deadline)
          :area-name area-name
          :project-name proj-name
          :context-label (or proj-name area-name "收件箱")
          :tags (plist-get entry :tags)
          :recurrence (plist-get entry :recurrence)
          :mark (etaf-agenda--row-mark entry instance)
          :overdue-days overdue-days
          :meta (or meta-override
                    (etaf-agenda--entry-meta entry instance day overdue-days))
          :at (or (plist-get entry :at) 99999))))

(defun etaf-agenda--sort-rows (rows)
  "Sort ROWS: open before done, then time, priority, and title."
  (sort (copy-sequence rows)
        (lambda (a b)
          (let ((da (if (plist-get a :done) 1 0))
                (db (if (plist-get b :done) 1 0))
                (ta (plist-get a :at))
                (tb (plist-get b :at))
                (pa (or (plist-get a :priority) 9))
                (pb (or (plist-get b :priority) 9)))
            (cond ((/= da db) (< da db))
                  ((/= ta tb) (< ta tb))
                  ((/= pa pb) (< pa pb))
                  (t (string< (plist-get a :title) (plist-get b :title))))))))

;;; ---------------------------------------------------------------------------
;;; Data collectors for all 6 views
;;; ---------------------------------------------------------------------------

(defun etaf-agenda--collect-day (snapshot day area &optional query)
  "Collect DAY's rows from SNAPSHOT filtered by AREA and QUERY."
  (let ((done-count 0) (open-count 0) overdue events tasks notes migrated)
    (maphash
     (lambda (id entry)
       (when (and (etaf-agenda--entry-in-area-p entry area)
                  (etaf-agenda--entry-matches-query-p snapshot entry query)
                  (not (equal (plist-get entry :status) "dropped"))
                  (not (etaf-agenda--habit-p entry)))
         (let* ((instance (etaf-agenda--instance-of snapshot id day))
                (kind (plist-get entry :kind))
                (scheduled (plist-get entry :scheduled))
                (state (and instance (plist-get instance :state))))
           (cond
            ((equal state "moved")
             (push (etaf-agenda--row
                    snapshot entry instance day 'migrated
                    (format "至 %s" (etaf-agenda--date-label
                                     (or (plist-get entry :scheduled) day))))
                   migrated))
            ((member kind '("note" "question"))
             (when (or instance (equal scheduled day))
               (push (etaf-agenda--row snapshot entry instance day 'notes) notes)))
            ((equal kind "event")
             (when (or instance (equal scheduled day))
               (push (etaf-agenda--row snapshot entry instance day 'events) events)))
            ((or instance (equal scheduled day))
             (if (etaf-agenda--entry-done-p entry instance)
                 (cl-incf done-count)
               (cl-incf open-count))
             (push (etaf-agenda--row snapshot entry instance day 'tasks) tasks))
            ((and (etaf-agenda--entry-open-p entry) scheduled (< scheduled day))
             (push (etaf-agenda--row snapshot entry nil day 'overdue) overdue))))))
     (plist-get snapshot :entries))
    (list :overdue (etaf-agenda--sort-rows overdue)
          :events (etaf-agenda--sort-rows events)
          :tasks (etaf-agenda--sort-rows tasks)
          :notes (etaf-agenda--sort-rows notes)
          :migrated (etaf-agenda--sort-rows migrated)
          :open open-count
          :done done-count)))

(defun etaf-agenda--day-sections (day-rows)
  "Build display section plists for the Today page from DAY-ROWS."
  (list (list :id 'overdue :title "逾期" :accent :danger
              :rows (plist-get day-rows :overdue)
              :count (length (plist-get day-rows :overdue))
              :hide-when-empty t
              :hint "按 M 批量延至今日")
        (list :id 'events :title "日程" :accent :info
              :rows (plist-get day-rows :events)
              :count (length (plist-get day-rows :events))
              :hide-when-empty nil
              :empty "今天没有排定日程")
        (list :id 'tasks :title "待办" :accent :accent
              :rows (plist-get day-rows :tasks)
              :count (length (plist-get day-rows :tasks))
              :hide-when-empty nil
              :empty "今天没有待办，按 a 原位记一条")
        (list :id 'notes :title "记录与问题" :accent :muted
              :rows (plist-get day-rows :notes)
              :count (length (plist-get day-rows :notes))
              :hide-when-empty t)
        (list :id 'migrated :title "已迁移" :accent :warning
              :rows (plist-get day-rows :migrated)
              :count (length (plist-get day-rows :migrated))
              :hide-when-empty t)))

(defun etaf-agenda--day-cell-summary (snapshot day area &optional query)
  "Return (:count N :chips ((KIND . TITLE)...)) for calendar cell DAY."
  (let ((count 0) (chips nil))
    (maphash
     (lambda (id entry)
       (when (and (etaf-agenda--entry-in-area-p entry area)
                  (etaf-agenda--entry-matches-query-p snapshot entry query)
                  (not (equal (plist-get entry :status) "dropped"))
                  (not (etaf-agenda--habit-p entry)))
         (let* ((instance (etaf-agenda--instance-of snapshot id day))
                (scheduled (plist-get entry :scheduled))
                (state (and instance (plist-get instance :state))))
           (when (and (not (equal state "moved"))
                      (or instance (equal scheduled day)))
             (cl-incf count)
             (push (list :kind (or (plist-get entry :kind) "task")
                         :done (etaf-agenda--entry-done-p entry instance)
                         :priority (plist-get entry :priority)
                         :at (or (plist-get entry :at) 99999)
                         :time-short (when (plist-get entry :at)
                                       (etaf-agenda--clock-label (plist-get entry :at)))
                         :title (or (plist-get entry :title) ""))
                   chips)))))
     (plist-get snapshot :entries))
    (list :count count
          :chips (sort chips (lambda (a b)
                               (let ((ta (plist-get a :at))
                                     (tb (plist-get b :at)))
                                 (if (= ta tb)
                                     (string< (plist-get a :title) (plist-get b :title))
                                   (< ta tb))))))))

(defun etaf-agenda--month-weeks (snapshot day area &optional query)
  "Return DAY's month as weeks of 7 day plists."
  (let* ((month (/ day 100))
         (first (+ (* month 100) 1))
         (last (etaf-agenda--last-day-of-month first))
         (start (etaf-agenda--week-start first))
         (today (etaf-agenda--today))
         (weeks nil))
    (while (<= start last)
      (let ((week nil))
        (dotimes (i 7)
          (let* ((cell-day (etaf-agenda--shift start i))
                 (info (etaf-agenda--day-cell-summary snapshot cell-day area query)))
            (push (list :day cell-day
                        :in-month (= (/ cell-day 100) month)
                        :today (= cell-day today)
                        :count (plist-get info :count)
                        :chips (plist-get info :chips))
                  week)))
        (push (nreverse week) weeks)
        (setq start (etaf-agenda--shift start 7))))
    (nreverse weeks)))

(defun etaf-agenda--week-days (snapshot day area &optional query)
  "Return the 7 day plists of DAY's week (Monday..Sunday) for Week View."
  (let* ((start (etaf-agenda--week-start day))
         (today (etaf-agenda--today))
         (days nil))
    (dotimes (i 7)
      (let* ((d (etaf-agenda--shift start i))
             (collected (etaf-agenda--collect-day snapshot d area query)))
        (push (list :day d
                    :today (= d today)
                    :label (etaf-agenda--date-label d)
                    :weekday (etaf-agenda--weekday-label d)
                    :events (plist-get collected :events)
                    :tasks (plist-get collected :tasks))
              days)))
    (nreverse days)))

(defun etaf-agenda--year-months (snapshot day area &optional query)
  "Return 12 compact month plists for DAY's year in a single linear pass.
Each month plist holds `:month' (1..12), `:ym' (YYYYMM), `:count',
`:max-count' (for density bars) and `:weeks' (6 Monday-first rows of 7 cells;
nil outside the month, or (:day YYYYMMDD :dom D :today BOOL :count N))."
  (let* ((year (/ day 10000))
         (today (etaf-agenda--today))
         (entries (plist-get snapshot :entries))
         (instances (plist-get snapshot :instances))
         (day-counts (make-hash-table :test #'eql))
         (seen (make-hash-table :test #'equal))
         (moved-days (make-hash-table :test #'equal)))
    ;; Pass 1: count non-moved instances inside YEAR
    (maphash
     (lambda (_iid inst)
       (let* ((d (plist-get inst :day))
              (eid (plist-get inst :entry))
              (entry (and eid (gethash eid entries)))
              (state (plist-get inst :state)))
         (when (and d (= (/ d 10000) year)
                    entry
                    (etaf-agenda--entry-in-area-p entry area)
                    (etaf-agenda--entry-matches-query-p snapshot entry query)
                    (not (equal (plist-get entry :status) "dropped"))
                    (not (etaf-agenda--habit-p entry)))
           (let ((key (cons eid d)))
             (if (equal state "moved")
                 (puthash key t moved-days)
               (unless (gethash key seen)
                 (puthash key t seen)
                 (puthash d (1+ (gethash d day-counts 0)) day-counts)))))))
     instances)
    ;; Pass 2: count scheduled entries inside YEAR not already covered by an instance
    (maphash
     (lambda (eid entry)
       (let ((sched (plist-get entry :scheduled)))
         (when (and sched (= (/ sched 10000) year)
                    (etaf-agenda--entry-in-area-p entry area)
                    (etaf-agenda--entry-matches-query-p snapshot entry query)
                    (not (equal (plist-get entry :status) "dropped"))
                    (not (etaf-agenda--habit-p entry)))
           (let ((key (cons eid sched)))
             (unless (or (gethash key seen) (gethash key moved-days))
               (puthash key t seen)
               (puthash sched (1+ (gethash sched day-counts 0)) day-counts))))))
     entries)
    ;; Pass 3: build 12 month grids
    (let* ((months nil)
           (max-m 1))
      (dotimes (mi 12)
        (let* ((m (1+ mi))
               (ym (+ (* year 100) m))
               (first (+ (* ym 100) 1))
               (last (etaf-agenda--last-day-of-month first))
               (last-dom (% last 100))
               ;; Monday-first offset: weekday-of returns 0=Sun, 1=Mon..6=Sat
               (w0 (etaf-agenda--weekday-of first))
               (lead (if (= w0 0) 6 (1- w0)))
               (m-count 0)
               (weeks nil))
          (dotimes (wk 6)
            (let ((row nil))
              (dotimes (di 7)
                (let ((dom (- (+ (* wk 7) di) lead -1)))
                  (if (or (< dom 1) (> dom last-dom))
                      (push nil row)
                    (let* ((d (+ (* ym 100) dom))
                           (cnt (gethash d day-counts 0)))
                      (cl-incf m-count cnt)
                      (push (list :day d :dom dom :today (= d today) :count cnt) row)))))
              (push (nreverse row) weeks)))
          (when (> m-count max-m) (setq max-m m-count))
          (push (list :month m :ym ym :count m-count :weeks (nreverse weeks)) months)))
      (mapcar (lambda (mp) (plist-put mp :max-count max-m))
              (nreverse months)))))

(defun etaf-agenda--year-summary (year-months year)
  "Compute annual totals, active days and busiest month from YEAR-MONTHS."
  (let ((total 0)
        (active-days 0)
        (busiest-month nil)
        (busiest-count 0))
    (dolist (mp year-months)
      (let ((m (plist-get mp :month))
            (cnt (or (plist-get mp :count) 0)))
        (cl-incf total cnt)
        (when (> cnt busiest-count)
          (setq busiest-count cnt
                busiest-month m))
        (dolist (wk (plist-get mp :weeks))
          (dolist (cell wk)
            (when (and cell (> (or (plist-get cell :count) 0) 0))
              (cl-incf active-days))))))
    (list :year year
          :total total
          :active-days active-days
          :busiest-month busiest-month
          :busiest-count busiest-count)))

(defconst etaf-agenda--time-group-order
  '("逾期" "今天" "本周" "以后" "无日期" "已完成")
  "Display order of time groups on the List page.")

(defun etaf-agenda--list-group-key (snapshot grouping entry today week-end)
  "Return ENTRY's group label under GROUPING."
  (let ((scheduled (plist-get entry :scheduled))
        (status (plist-get entry :status)))
    (pcase grouping
      ('area (or (etaf-agenda--container-name snapshot (plist-get entry :area))
                 "收件箱"))
      ('project (or (etaf-agenda--container-name snapshot (plist-get entry :project))
                    "一次性任务"))
      ('status (or (cdr (assoc status etaf-agenda-status-labels)) "待办"))
      (_ (cond ((equal status "done") "已完成")
               ((null scheduled) "无日期")
               ((< scheduled today) "逾期")
               ((= scheduled today) "今天")
               ((<= scheduled week-end) "本周")
               (t "以后"))))))

(defun etaf-agenda--list-groups (snapshot grouping area show-completed &optional query)
  "Return grouped sections for the List page."
  (let* ((today (etaf-agenda--today))
         (week-end (etaf-agenda--shift (etaf-agenda--week-start today) 6))
         (table (make-hash-table :test #'equal)))
    (maphash
     (lambda (id entry)
       (let ((status (plist-get entry :status)))
         (when (and (etaf-agenda--entry-in-area-p entry area)
                    (etaf-agenda--entry-matches-query-p snapshot entry query)
                    (not (etaf-agenda--habit-p entry))
                    (not (equal status "dropped"))
                    (or show-completed (not (equal status "done"))))
           (let* ((day-ref (or (plist-get entry :scheduled) today))
                  (instance (etaf-agenda--instance-of snapshot id day-ref))
                  (is-over (and (not (equal status "done"))
                                (plist-get entry :scheduled)
                                (< (plist-get entry :scheduled) today)))
                  (row (etaf-agenda--row snapshot entry instance today
                                         (if is-over 'overdue 'list)))
                  (key (etaf-agenda--list-group-key snapshot grouping entry today week-end)))
             (puthash key (cons row (gethash key table)) table)))))
     (plist-get snapshot :entries))
    (let (groups)
      (maphash (lambda (title rows)
                 (let ((sorted (etaf-agenda--sort-rows rows)))
                   (push (list :id (intern (concat "grp-" title))
                               :title title
                               :accent (cond ((equal title "逾期") :danger)
                                             ((equal title "今天") :accent)
                                             ((equal title "已完成") :ok)
                                             (t :muted))
                               :rows sorted
                               :count (length sorted))
                         groups)))
               table)
      (sort groups
            (if (eq grouping 'time)
                (lambda (a b)
                  (let ((la (or (cl-position (plist-get a :title) etaf-agenda--time-group-order :test #'equal) 99))
                        (lb (or (cl-position (plist-get b :title) etaf-agenda--time-group-order :test #'equal) 99)))
                    (if (= la lb)
                        (string< (plist-get a :title) (plist-get b :title))
                      (< la lb))))
              (lambda (a b)
                (let ((ca (plist-get a :count))
                      (cb (plist-get b :count)))
                  (if (= ca cb)
                      (string< (plist-get a :title) (plist-get b :title))
                    (> ca cb)))))))))

(defun etaf-agenda--project-plan (snapshot project-id &optional query)
  "Return structured stage breakdown and real progress for PROJECT-ID."
  (let* ((today (etaf-agenda--today))
         (project (etaf-agenda--container-of snapshot project-id))
         (stages (sort (seq-filter (lambda (row)
                                     (and (equal (plist-get row :kind) "stage")
                                          (equal (plist-get row :parent) project-id)))
                                   (plist-get snapshot :containers))
                       (lambda (a b)
                         (< (or (plist-get a :sort) 0)
                            (or (plist-get b :sort) 0)))))
         (by-stage (make-hash-table :test #'equal))
         (loose nil)
         (all-rows nil)
         (overdue-count 0))
    (when project-id
      (maphash
       (lambda (id entry)
         (when (and (equal (plist-get entry :project) project-id)
                    (not (equal (plist-get entry :status) "dropped"))
                    (etaf-agenda--entry-matches-query-p snapshot entry query))
           (let* ((day-ref (or (plist-get entry :scheduled) today))
                  (instance (etaf-agenda--instance-of snapshot id day-ref))
                  (row (etaf-agenda--row snapshot entry instance today 'project))
                  (stage (plist-get entry :stage)))
             (when (and (not (plist-get row :done))
                        (plist-get entry :scheduled)
                        (< (plist-get entry :scheduled) today))
               (cl-incf overdue-count))
             (push row all-rows)
             (if (and stage (etaf-agenda--container-of snapshot stage))
                 (puthash stage (cons row (gethash stage by-stage)) by-stage)
               (push row loose)))))
       (plist-get snapshot :entries)))
    (let* ((total (length all-rows))
           (done (seq-count (lambda (r) (plist-get r :done)) all-rows))
           (stage-plans
            (mapcar (lambda (stage)
                      (let* ((sid (plist-get stage :id))
                             (srows (etaf-agenda--sort-rows (gethash sid by-stage)))
                             (sdone (seq-count (lambda (r) (plist-get r :done)) srows))
                             (stotal (length srows)))
                        (list :id sid
                              :title (plist-get stage :name)
                              :rows srows
                              :done sdone
                              :count stotal
                              :progress (if (zerop stotal) 0
                                          (round (* 100 (/ (float sdone) stotal)))))))
                    stages)))
      (list :project project
            :id project-id
            :name (or (plist-get project :name) "项目")
            :goal (or (plist-get project :goal) "")
            :done done
            :total total
            :open (- total done)
            :overdue overdue-count
            :progress (if (zerop total) 0 (round (* 100 (/ (float done) total))))
            :stages stage-plans
            :loose (etaf-agenda--sort-rows loose)))))

(defun etaf-agenda--habit-plan (snapshot day &optional query)
  "Return the 21-day habit matrix ending at DAY (including cross-month days)."
  (let* ((span etaf-agenda-habit-days)
         (start (etaf-agenda--shift day (- (1- span))))
         (week-start (etaf-agenda--shift day -6))
         (habits nil))
    (maphash
     (lambda (id entry)
       (when (and (etaf-agenda--habit-p entry)
                  (not (equal (plist-get entry :status) "dropped"))
                  (etaf-agenda--entry-matches-query-p snapshot entry query))
         (let ((cells nil) (cursor start) (measured 0) (streak 0))
           (while (<= cursor day)
             (let* ((instance (etaf-agenda--instance-of snapshot id cursor))
                    (state (and instance (plist-get instance :state)))
                    (done (equal state "done")))
               (when (and done (>= cursor week-start)) (cl-incf measured))
               (setq streak (if done (1+ streak) 0))
               (push (list :day cursor :state state :done done) cells))
             (setq cursor (etaf-agenda--shift cursor 1)))
           (let* ((ordered (nreverse cells))
                  (today-done (plist-get (car (last ordered)) :done)))
             (push (list :id id
                         :title (or (plist-get entry :title) "")
                         :target (or (plist-get entry :habit_target) 7)
                         :measured measured
                         :streak streak
                         :today-done today-done
                         :cells ordered)
                   habits)))))
     (plist-get snapshot :entries))
    (sort habits (lambda (a b) (string< (plist-get a :title) (plist-get b :title))))))

(defun etaf-agenda--habit-stats (habits day)
  "Compute weekly habit totals and top streaks."
  (let ((done 0) (due 0) (met 0) (today-done 0))
    (dolist (h habits)
      (cl-incf due (or (plist-get h :target) 0))
      (cl-incf done (or (plist-get h :measured) 0))
      (when (plist-get h :today-done) (cl-incf today-done))
      (when (>= (or (plist-get h :measured) 0) (or (plist-get h :target) 1))
        (cl-incf met)))
    (list :done done :due due :met met :today-done today-done
          :total (length habits)
          :rate (if (zerop due) 0 (min 100 (round (* 100 (/ (float done) due)))))
          :best (sort (mapcar (lambda (h)
                                (cons (plist-get h :title) (or (plist-get h :streak) 0)))
                              habits)
                      (lambda (a b)
                        (if (= (cdr a) (cdr b))
                            (string< (car a) (car b))
                          (> (cdr a) (cdr b)))))
          :week (etaf-agenda--iso-week day))))

(defun etaf-agenda--week-counts (snapshot day)
  "Return (DONE MOVED DROPPED) counts for DAY's week (across month boundaries)."
  (let* ((start (etaf-agenda--week-start day))
         (end (etaf-agenda--shift start 6))
         (done 0) (moved 0) (dropped 0))
    (maphash
     (lambda (_id instance)
       (let ((d (plist-get instance :day))
             (entry (gethash (plist-get instance :entry) (plist-get snapshot :entries))))
         (when (and d (<= start d end) entry (not (etaf-agenda--habit-p entry)))
           (pcase (plist-get instance :state)
             ("done" (cl-incf done))
             ("moved" (cl-incf moved))
             ("skipped" (cl-incf dropped))))))
     (plist-get snapshot :instances))
    (list done moved dropped)))

(defun etaf-agenda--review (snapshot day habits)
  "Compute complete monthly review metrics for DAY's month."
  (let* ((month (/ day 100))
         (first (+ (* month 100) 1))
         (last (etaf-agenda--last-day-of-month first))
         (today (etaf-agenda--today))
         (stop (min last today))
         (done 0) (created 0) (migrated 0) (dropped 0)
         (per-area (make-hash-table :test #'equal))
         (per-project (make-hash-table :test #'equal))
         (moved (make-hash-table :test #'equal))
         (per-day (make-hash-table :test #'equal))
         (active-days-tbl (make-hash-table :test #'equal)))
    (maphash
     (lambda (_id instance)
       (let ((d (plist-get instance :day))
             (entry (gethash (plist-get instance :entry) (plist-get snapshot :entries))))
         (when (and d (= (/ d 100) month) entry (not (etaf-agenda--habit-p entry)))
           (puthash d t active-days-tbl)
           (pcase (plist-get instance :state)
             ("done"
              (cl-incf done)
              (puthash d (1+ (gethash d per-day 0)) per-day)
              (let ((area (or (etaf-agenda--container-name snapshot (plist-get entry :area))
                              "收件箱"))
                    (proj (or (etaf-agenda--container-name snapshot (plist-get entry :project))
                              "一次性任务")))
                (puthash area (1+ (gethash area per-area 0)) per-area)
                (puthash proj (1+ (gethash proj per-project 0)) per-project)))
             ("moved"
              (cl-incf migrated)
              (let ((title (or (plist-get entry :title) "")))
                (puthash title (1+ (gethash title moved 0)) moved)))
             ("skipped" (cl-incf dropped))))))
     (plist-get snapshot :instances))
    (maphash
     (lambda (_id entry)
       (let ((sched (plist-get entry :scheduled)))
         (when (and sched (= (/ sched 100) month) (not (etaf-agenda--habit-p entry)))
           (cl-incf created))))
     (plist-get snapshot :entries))
    (let ((daily nil)
          (blank nil)
          (longest-streak 0)
          (cur-streak 0)
          (active-done-days 0))
      (when (<= first stop)
        (let ((cursor first))
          (while (<= cursor stop)
            (let ((cnt (gethash cursor per-day 0)))
              (push (cons cursor cnt) daily)
              (if (> cnt 0)
                  (progn
                    (cl-incf active-done-days)
                    (setq cur-streak (1+ cur-streak)
                          longest-streak (max longest-streak cur-streak)))
                (setq cur-streak 0))
              (unless (gethash cursor active-days-tbl)
                (push (etaf-agenda--short-date-label cursor) blank)))
            (setq cursor (etaf-agenda--shift cursor 1)))))
      (let* ((hstats (etaf-agenda--habit-stats habits day))
             (denom (max 1 (+ done created)))
             (comp-rate (if (zerop created) (if (> done 0) 100 0)
                          (min 100 (round (* 100 (/ (float done) (max created done)))))))
             (mig-rate (if (zerop denom) 0
                         (min 100 (round (* 100 (/ (float migrated) (max 1 created))))))))
        (list :month month
              :done done :created created :migrated migrated :dropped dropped
              :completion-rate comp-rate
              :migrate-rate mig-rate
              :habit-rate (plist-get hstats :rate)
              :longest-streak longest-streak
              :active-days active-done-days
              :areas (let (pairs)
                       (maphash (lambda (k v) (push (cons k v) pairs)) per-area)
                       (sort pairs (lambda (a b) (> (cdr a) (cdr b)))))
              :projects (let (pairs)
                          (maphash (lambda (k v) (push (cons k v) pairs)) per-project)
                          (sort pairs (lambda (a b) (> (cdr a) (cdr b)))))
              :moved (let (pairs)
                       (maphash (lambda (k v) (push (cons k v) pairs)) moved)
                       (sort pairs (lambda (a b) (> (cdr a) (cdr b)))))
              :daily (nreverse daily)
              :first-weekday (let ((dow (etaf-agenda--weekday-of first)))
                               (if (= dow 0) 6 (1- dow)))
              :blank (nreverse blank))))))

(defun etaf-agenda-sidebar-rows (snapshot)
  "Return (:areas LIST :projects LIST :total N :inbox N) for the left sidebar."
  (let ((areas nil) (projects nil) (total 0) (inbox 0))
    (maphash (lambda (_id entry)
               (unless (or (equal (plist-get entry :status) "dropped")
                           (etaf-agenda--habit-p entry))
                 (cl-incf total)
                 (unless (plist-get entry :area) (cl-incf inbox))))
             (plist-get snapshot :entries))
    (dolist (c (plist-get snapshot :containers))
      (let* ((cid (plist-get c :id))
             (kind (plist-get c :kind))
             (cname (plist-get c :name))
             (sort-key (or (plist-get c :sort) 0)))
        (cond
         ((equal kind "area")
          (let ((cnt 0))
            (maphash (lambda (_id e)
                       (when (and (not (equal (plist-get e :status) "dropped"))
                                  (not (etaf-agenda--habit-p e))
                                  (equal (plist-get e :area) cid))
                         (cl-incf cnt)))
                     (plist-get snapshot :entries))
            (push (list :id cid :title cname :count cnt :sort sort-key) areas)))
         ((equal kind "project")
          (let ((ptot 0) (pdone 0))
            (maphash (lambda (_id e)
                       (when (and (not (equal (plist-get e :status) "dropped"))
                                  (equal (plist-get e :project) cid))
                         (cl-incf ptot)
                         (when (equal (plist-get e :status) "done")
                           (cl-incf pdone))))
                     (plist-get snapshot :entries))
            (push (list :id cid :title cname :done pdone :total ptot :sort sort-key)
                  projects))))))
    (list :total total
          :inbox inbox
          :areas (sort areas (lambda (a b) (< (plist-get a :sort) (plist-get b :sort))))
          :projects (sort projects (lambda (a b) (< (plist-get a :sort) (plist-get b :sort)))))))

(defun etaf-agenda--inspector-entry (snapshot id)
  "Return rich display & edit fields for entry ID in SNAPSHOT, or nil."
  (when-let* ((entry (and id (gethash id (plist-get snapshot :entries)))))
    (list :id id
          :title (or (plist-get entry :title) "")
          :body (or (plist-get entry :body) "")
          :kind (or (plist-get entry :kind) "task")
          :status (or (plist-get entry :status) "open")
          :priority (plist-get entry :priority)
          :scheduled (plist-get entry :scheduled)
          :at (plist-get entry :at)
          :end-at (plist-get entry :end_at)
          :deadline (plist-get entry :deadline)
          :estimate (plist-get entry :estimate)
          :recurrence (plist-get entry :recurrence)
          :habit-target (plist-get entry :habit_target)
          :area (plist-get entry :area)
          :area-name (or (etaf-agenda--container-name snapshot (plist-get entry :area)) "收件箱")
          :project (plist-get entry :project)
          :project-name (etaf-agenda--container-name snapshot (plist-get entry :project))
          :stage (plist-get entry :stage)
          :stage-name (etaf-agenda--container-name snapshot (plist-get entry :stage))
          :tags (or (plist-get entry :tags) "")
          :pushes (etaf-agenda--push-count snapshot id)
          :created (let ((cr (plist-get entry :created)))
                     (if (integerp cr)
                         (format-time-string "%m-%d" (seconds-to-time cr))
                       "—")))))

(defun etaf-agenda--visible-row-ids (view day-sections list-groups project-plan habits day-rows)
  "Return ordered list of selectable entry IDs for VIEW."
  (pcase view
    ('today (apply #'append
                   (mapcar (lambda (s)
                             (mapcar (lambda (r) (plist-get r :id))
                                     (plist-get s :rows)))
                           day-sections)))
    ('calendar (append (mapcar (lambda (r) (plist-get r :id)) (plist-get day-rows :events))
                       (mapcar (lambda (r) (plist-get r :id)) (plist-get day-rows :tasks))))
    ('list (apply #'append
                  (mapcar (lambda (g)
                            (mapcar (lambda (r) (plist-get r :id))
                                    (plist-get g :rows)))
                          list-groups)))
    ('project (append (apply #'append
                             (mapcar (lambda (s)
                                       (mapcar (lambda (r) (plist-get r :id))
                                               (plist-get s :rows)))
                                     (plist-get project-plan :stages)))
                      (mapcar (lambda (r) (plist-get r :id))
                              (plist-get project-plan :loose))))
    ('habits (mapcar (lambda (h) (plist-get h :id)) habits))
    (_ nil)))

(defun etaf-agenda--list-stats (snapshot)
  "Return global stats for the List page right rail."
  (let* ((today (etaf-agenda--today))
         (ws (etaf-agenda--week-start today))
         (we (etaf-agenda--shift ws 6))
         (all 0) (open 0) (done 0) (overdue 0) (week 0) (undated 0)
         (by-area (make-hash-table :test #'equal)))
    (maphash
     (lambda (_id e)
       (unless (or (equal (plist-get e :status) "dropped")
                   (etaf-agenda--habit-p e))
         (cl-incf all)
         (let ((st (plist-get e :status))
               (sc (plist-get e :scheduled)))
           (if (equal st "done")
               (cl-incf done)
             (cl-incf open)
             (cond ((null sc) (cl-incf undated))
                   ((< sc today) (cl-incf overdue))
                   ((<= ws sc we) (cl-incf week)))))
         (let ((aname (or (etaf-agenda--container-name snapshot (plist-get e :area))
                          "收件箱")))
           (puthash aname (1+ (gethash aname by-area 0)) by-area))))
     (plist-get snapshot :entries))
    (list :all all :open open :done done :overdue overdue :week week :undated undated
          :areas (let (pairs)
                   (maphash (lambda (k v) (push (cons k v) pairs)) by-area)
                   (sort pairs (lambda (a b) (> (cdr a) (cdr b))))))))

;;; ---------------------------------------------------------------------------
;;; Unified View Plan
;;; ---------------------------------------------------------------------------

(defun etaf-agenda-plan (model)
  "Project MODEL's reactive refs into a complete immutable view plan plist."
  (let* ((snapshot (etaf-agenda--read model))
         (view (etaf-value (plist-get model :view)))
         (cal-mode (etaf-value (plist-get model :calendar-mode)))
         (grouping (etaf-value (plist-get model :grouping)))
         (show-completed (etaf-value (plist-get model :show-completed)))
         (day (etaf-value (plist-get model :day)))
         (area (etaf-value (plist-get model :area)))
         (query (etaf-value (plist-get model :query)))
         (search-input (etaf-value (plist-get model :search-input)))
         (selected (etaf-value (plist-get model :selected)))
         (today (etaf-agenda--today))
         (habit-anchor (if (eq view 'habits) today day))
         (habit-day (or (etaf-value (plist-get model :selected-habit-day)) habit-anchor))
         (inspector-id (etaf-value (plist-get model :inspector)))
         (inspector-entry (etaf-agenda--inspector-entry snapshot inspector-id))
         (width (etaf-value (plist-get model :width)))
         (width-px (etaf-value (plist-get model :width-px)))
         (height (etaf-value (plist-get model :height)))
         (sb-cols (etaf-value (plist-get model :sidebar-width)))
         (rl-cols (etaf-value (plist-get model :rail-width)))
         (layout (etaf-agenda-layout-metrics width height sb-cols rl-cols
                                             (not (null inspector-entry))))
         (sidebar (etaf-agenda-sidebar-rows snapshot))
         (project-id (or (etaf-value (plist-get model :project))
                         (plist-get (car (plist-get sidebar :projects)) :id)))
         (day-rows (etaf-agenda--collect-day snapshot day area query))
         (day-sections (etaf-agenda--day-sections day-rows))
         (list-groups (etaf-agenda--list-groups snapshot grouping area show-completed query))
         (project-plan (etaf-agenda--project-plan snapshot project-id query))
         (habits (etaf-agenda--habit-plan snapshot habit-anchor query))
         (habit-stats (etaf-agenda--habit-stats habits habit-anchor))
         (review (etaf-agenda--review snapshot day habits))
         (weeks (when (and (eq view 'calendar) (eq cal-mode 'month))
                  (etaf-agenda--month-weeks snapshot day area query)))
         (week-days (when (and (eq view 'calendar) (eq cal-mode 'week))
                      (etaf-agenda--week-days snapshot day area query)))
         (year-months (when (and (eq view 'calendar) (eq cal-mode 'year))
                        (etaf-agenda--year-months snapshot day area query)))
         (year-summary (when year-months
                         (etaf-agenda--year-summary year-months (/ day 10000))))
         (week-counts (etaf-agenda--week-counts snapshot day))
         (visible-ids (etaf-agenda--visible-row-ids
                       view day-sections list-groups project-plan habits day-rows))
         (area-label (pcase area
                       ('all "全部领域")
                       ('inbox "收件箱")
                       (_ (or (etaf-agenda--container-name snapshot area) "全部领域")))))
    (list :view view
          :calendar-mode cal-mode
          :grouping grouping
          :show-completed show-completed
          :layout layout
          :width width
          :width-px width-px
          :height height
          :day day
          :today today
          :year (/ day 10000)
          :year-label (format "%d 年" (/ day 10000))
          :month (/ day 100)
          :month-label (format "%d 年 %d 月" (/ day 10000) (% (/ day 100) 100))
          :day-label (etaf-agenda--date-label day)
          :weekday-label (etaf-agenda--weekday-label day)
          :week (etaf-agenda--iso-week day)
          :area area
          :area-label area-label
          :project project-id
          :query query
          :search-input search-input
          :sidebar sidebar
          :day-rows day-rows
          :day-sections day-sections
          :weeks weeks
          :week-days week-days
          :year-months year-months
          :year-summary year-summary
          :list-groups list-groups
          :list-stats (etaf-agenda--list-stats snapshot)
          :project-plan project-plan
          :habits habits
          :habit-stats habit-stats
          :habit-anchor habit-anchor
          :habit-day habit-day
          :review review
          :week-counts week-counts
          :counts (list :open (plist-get day-rows :open)
                        :done (plist-get day-rows :done)
                        :overdue (length (plist-get day-rows :overdue))
                        :events (length (plist-get day-rows :events)))
          :visible-ids visible-ids
          :selected selected
          :inspector-id inspector-id
          :inspector-entry inspector-entry
          :inspector-logs (etaf-value (plist-get model :inspector-logs))
          :inspector-body-editing (etaf-value (plist-get model :inspector-body-editing))
          :inspector-body-draft (etaf-value (plist-get model :inspector-body-draft))
          :editing (etaf-value (plist-get model :editing))
          :edit-draft (etaf-value (plist-get model :edit-draft))
          :drafting (etaf-value (plist-get model :drafting))
          :draft (etaf-value (plist-get model :draft))
          :message (etaf-value (plist-get model :message)))))

;;; ---------------------------------------------------------------------------
;;; Undo support
;;; ---------------------------------------------------------------------------

(defun etaf-agenda--push-undo (model description entries instances &optional delete-instances)
  "Push an undo snapshot onto MODEL's undo stack.
ENTRIES and INSTANCES are prior rows to restore via upsert; DELETE-INSTANCES
is a list of newly created instance IDs to remove when undoing."
  (let ((cell (plist-get model :undo-stack))
        (item (list :description description
                    :entries entries
                    :instances instances
                    :delete-instances delete-instances)))
    (setcar cell (cons item (seq-take (car cell) 24)))))

(defun etaf-agenda-undo (model)
  "Undo the last entry/instance mutation in MODEL."
  (let* ((cell (plist-get model :undo-stack))
         (top (car (car cell))))
    (if (null top)
        (progn (etaf-agenda--notice model "没有可撤销的操作") nil)
      (setcar cell (cdr (car cell)))
      (let ((store (plist-get model :store)))
        (when-let* ((del-insts (plist-get top :delete-instances)))
          (etaf-agenda--store-apply
           store 'instances
           (mapcar (lambda (id) (list 'delete id)) del-insts)))
        (when-let* ((entries (plist-get top :entries)))
          (etaf-agenda--store-apply
           store 'entries
           (mapcar (lambda (row) (list 'upsert row)) entries)))
        (when-let* ((instances (plist-get top :instances)))
          (etaf-agenda--store-apply
           store 'instances
           (mapcar (lambda (row) (list 'upsert row)) instances))))
      (etaf-agenda--reload model)
      (etaf-agenda--notice model (format "已撤销：%s" (plist-get top :description)))
      t)))

;;; ---------------------------------------------------------------------------
;;; Container CRUD
;;; ---------------------------------------------------------------------------

(defun etaf-agenda-ensure-container (model kind name &optional parent goal)
  "Return container id for KIND and NAME in MODEL, creating it if missing."
  (let* ((trimmed (string-trim (or name "")))
         (snapshot (etaf-agenda--read model)))
    (unless (string-empty-p trimmed)
      (if-let* ((existing (etaf-agenda--find-container-by-name snapshot kind trimmed parent)))
          (plist-get existing :id)
        (let* ((same-kind (seq-filter (lambda (r) (equal (plist-get r :kind) kind))
                                      (plist-get snapshot :containers)))
               (max-sort (cl-reduce #'max same-kind
                                    :key (lambda (r) (or (plist-get r :sort) 0))
                                    :initial-value 0))
               (id (etaf-agenda--unique-id (concat kind "-")))
               (row (list :id id
                          :name trimmed
                          :kind kind
                          :parent parent
                          :goal goal
                          :status "active"
                          :deleted 0
                          :sort (1+ max-sort))))
          (etaf-agenda--store-apply (plist-get model :store) 'containers
                                    (list (list 'upsert row)))
          (etaf-agenda--reload model)
          id)))))

(defun etaf-agenda-create-area (model name)
  "Create a new area named NAME in MODEL and return its id."
  (let ((trimmed (string-trim (or name ""))))
    (when (string-empty-p trimmed)
      (user-error "领域名称不能为空"))
    (let ((id (etaf-agenda-ensure-container model "area" trimmed)))
      (etaf-agenda--notice model (format "已添加领域「%s」" trimmed))
      id)))

(defun etaf-agenda-create-project (model name &optional area-id goal)
  "Create a new project NAME in MODEL under optional AREA-ID and GOAL."
  (let ((trimmed (string-trim (or name ""))))
    (when (string-empty-p trimmed)
      (user-error "项目名称不能为空"))
    (let ((id (etaf-agenda-ensure-container model "project" trimmed area-id goal)))
      (etaf-agenda-set-project model id)
      (etaf-agenda--notice model (format "已创建项目「%s」" trimmed))
      id)))

(defun etaf-agenda-create-stage (model project-id name)
  "Create a new stage NAME inside PROJECT-ID in MODEL."
  (let ((trimmed (string-trim (or name ""))))
    (unless project-id (user-error "请先选择一个项目"))
    (when (string-empty-p trimmed)
      (user-error "阶段名称不能为空"))
    (let ((id (etaf-agenda-ensure-container model "stage" trimmed project-id)))
      (etaf-agenda--notice model (format "已添加阶段「%s」" trimmed))
      id)))

;;; ---------------------------------------------------------------------------
;;; Navigation & selection
;;; ---------------------------------------------------------------------------

(defun etaf-agenda-set-view (model view)
  "Switch MODEL to VIEW, clearing transient edit states."
  (etaf-batch
   (etaf-set-value (plist-get model :view) view)
   (etaf-set-value (plist-get model :editing) nil)
   (etaf-set-value (plist-get model :drafting) nil)
   (etaf-set-value (plist-get model :inspector-body-editing) nil)
   (etaf-set-value (plist-get model :message) nil)
   (when (eq view 'habits)
     ;; Keep Habits cursor day anchored inside the real 21-day window ending today.
     (let* ((today (etaf-agenda--today))
            (start (etaf-agenda--shift today (- (1- etaf-agenda-habit-days))))
            (cur (or (etaf-value (plist-get model :selected-habit-day)) today)))
       (when (or (< cur start) (> cur today))
         (etaf-set-value (plist-get model :selected-habit-day) today)))))
  (when (and (eq view 'calendar)
             (eq (etaf-value (plist-get model :calendar-mode)) 'year)
             (not (eql (plist-get (etaf-agenda--read model) :year-loaded)
                       (/ (etaf-value (plist-get model :day)) 10000))))
    (etaf-agenda--reload model))
  (let* ((plan (etaf-agenda-plan model))
         (ids (plist-get plan :visible-ids))
         (cur (etaf-value (plist-get model :selected))))
    (unless (and cur (member cur ids))
      (etaf-set-value (plist-get model :selected) (car ids)))))

(defun etaf-agenda-set-calendar-mode (model mode)
  "Set MODEL's calendar sub-view MODE (`year', `month' or `week')."
  (etaf-set-value (plist-get model :calendar-mode) mode)
  (when (and (eq mode 'year)
             (not (eql (plist-get (etaf-agenda--read model) :year-loaded)
                       (/ (etaf-value (plist-get model :day)) 10000))))
    (etaf-agenda--reload model)))

(defun etaf-agenda-toggle-calendar-mode (model)
  "Cycle MODEL across Year -> Month -> Week calendar views."
  (let ((next (pcase (etaf-value (plist-get model :calendar-mode))
                ('year 'month)
                ('month 'week)
                (_ 'year))))
    (etaf-agenda-set-calendar-mode model next)
    (etaf-agenda--notice model
                         (pcase next
                           ('year "已切换到年视图")
                           ('month "已切换到月视图")
                           (_ "已切换到周视图")))))

(defun etaf-agenda-set-grouping (model grouping)
  "Set MODEL's List page GROUPING (`time', `area', `project', `status')."
  (etaf-batch
   (etaf-set-value (plist-get model :grouping) grouping)
   (etaf-set-value (plist-get model :message) nil)))

(defun etaf-agenda-cycle-grouping (model)
  "Cycle MODEL's List page grouping."
  (let ((next (pcase (etaf-value (plist-get model :grouping))
                ('time 'area)
                ('area 'project)
                ('project 'status)
                (_ 'time))))
    (etaf-agenda-set-grouping model next)
    (etaf-agenda--notice model
                         (pcase next
                           ('time "清单：按时间分组")
                           ('area "清单：按领域分组")
                           ('project "清单：按项目分组")
                           (_ "清单：按状态分组")))))

(defun etaf-agenda-toggle-show-completed (model)
  "Toggle visibility of completed tasks on the List page."
  (let ((next (not (etaf-value (plist-get model :show-completed)))))
    (etaf-set-value (plist-get model :show-completed) next)
    (etaf-agenda--notice model (if next "显示已完成条目" "已隐藏已完成条目"))))

(defun etaf-agenda-select-area (model area)
  "Filter MODEL by AREA (`all', `inbox' or an area id)."
  (etaf-batch
   (etaf-set-value (plist-get model :area) area)
   (when (eq (etaf-value (plist-get model :view)) 'project)
     (etaf-set-value (plist-get model :view) 'today))
   (etaf-set-value (plist-get model :selected) nil)
   (etaf-set-value (plist-get model :message) nil)))

(defun etaf-agenda-set-project (model project-id)
  "Switch MODEL to Project view showing PROJECT-ID."
  (etaf-batch
   (etaf-set-value (plist-get model :project) project-id)
   (etaf-set-value (plist-get model :view) 'project)
   (etaf-set-value (plist-get model :editing) nil)
   (etaf-set-value (plist-get model :drafting) nil)
   (etaf-set-value (plist-get model :selected) nil)
   (etaf-set-value (plist-get model :message) nil)))

(defun etaf-agenda-set-query (model text)
  "Update MODEL's live search query to TEXT."
  (let ((clean (or text "")))
    (etaf-batch
     (etaf-set-value (plist-get model :search-input) clean)
     (etaf-set-value (plist-get model :query) (string-trim clean))
     (etaf-set-value (plist-get model :message) nil))))

(defun etaf-agenda-select (model id)
  "Select row ID in MODEL."
  (etaf-set-value (plist-get model :selected) id))

(defun etaf-agenda-move-row (model delta)
  "Move MODEL's selection by DELTA across visible rows on the current page.
On the Calendar page, moves by weeks when no day row is selected or shifts
through the selected day's items."
  (let* ((plan (etaf-agenda-plan model))
         (ids (plist-get plan :visible-ids))
         (cur (etaf-value (plist-get model :selected))))
    (cond
     ((null ids)
      (if (eq (plist-get plan :view) 'calendar)
          (etaf-agenda-shift-day model (* delta 7))
        (etaf-agenda--notice model "当前页没有可选项")))
     (t
      (let* ((pos (cl-position cur ids :test #'equal))
             (next-idx (cond
                        ((null pos) (if (< delta 0) (1- (length ids)) 0))
                        (t (max 0 (min (1- (length ids)) (+ pos delta))))))
             (next-id (nth next-idx ids)))
        (etaf-agenda-select model next-id)
        (when (etaf-value (plist-get model :inspector))
          (etaf-set-value (plist-get model :inspector) next-id)
          (etaf-agenda--refresh-inspector-logs model))
        next-id)))))

(defun etaf-agenda-shift-habit-day (model delta)
  "Move MODEL's habit day cursor by DELTA within the real 21-day window."
  (let* ((end-day (etaf-agenda--today))
         (start-day (etaf-agenda--shift end-day (- (1- etaf-agenda-habit-days))))
         (cur (or (etaf-value (plist-get model :selected-habit-day)) end-day))
         (next (etaf-agenda--shift cur delta))
         (clamped (max start-day (min end-day next))))
    (etaf-set-value (plist-get model :selected-habit-day) clamped)
    (etaf-agenda--notice model (format "习惯打卡日：%s" (etaf-agenda--date-label clamped)))
    clamped))

(defun etaf-agenda-set-day (model ymd)
  "Display YMD in MODEL and reload its working window."
  (let ((full-year (etaf-agenda--year-mode-p model)))
    (etaf-batch
     (etaf-agenda--publish model
                           (etaf-agenda--load (plist-get model :store) ymd full-year)
                           ymd)
     (etaf-set-value (plist-get model :selected) nil)
     (etaf-set-value (plist-get model :editing) nil)
     (etaf-set-value (plist-get model :drafting) nil)
     (etaf-set-value (plist-get model :inspector-body-editing) nil)
     (etaf-set-value (plist-get model :message) nil))))

(defun etaf-agenda-shift-day (model delta)
  "Move MODEL's displayed day by DELTA days."
  (etaf-agenda-set-day model (etaf-agenda--shift (etaf-value (plist-get model :day)) delta)))

(defun etaf-agenda-shift-month (model delta)
  "Move MODEL's displayed day by DELTA months."
  (etaf-agenda-set-day model (etaf-agenda--shift-month (etaf-value (plist-get model :day)) delta)))

(defun etaf-agenda-shift-year (model delta)
  "Move MODEL's displayed day by DELTA years."
  (etaf-agenda-set-day model (etaf-agenda--shift-month (etaf-value (plist-get model :day)) (* 12 delta))))

(defun etaf-agenda-show-today (model)
  "Jump MODEL to today's date (and reset Habits cursor to today)."
  (let ((today (etaf-agenda--today)))
    (etaf-agenda-set-day model today)
    (etaf-set-value (plist-get model :selected-habit-day) today)))

;;; ---------------------------------------------------------------------------
;;; Mutations & Entry Actions
;;; ---------------------------------------------------------------------------

(defun etaf-agenda--touch (entry)
  "Return a copy of ENTRY with `:updated' set to current epoch seconds."
  (plist-put (copy-sequence entry) :updated (time-convert nil 'integer)))

(defun etaf-agenda--write-log (model entry-id day event note)
  "Append one audit log row for ENTRY-ID."
  (etaf-agenda--store-apply
   (plist-get model :store) 'logs
   (list (list 'insert (list :id (etaf-agenda--unique-id "log-")
                             :entry entry-id
                             :day day
                             :at (time-convert nil 'integer)
                             :event event
                             :note note)))))

(defun etaf-agenda--require-selected (model)
  "Return MODEL's selected entry id (or auto-select first visible row), else error."
  (or (etaf-value (plist-get model :selected))
      (let ((first (car (plist-get (etaf-agenda-plan model) :visible-ids))))
        (when first
          (etaf-set-value (plist-get model :selected) first)
          first))
      (user-error "请先选择一条记录（j/k 或点击行）")))

(defun etaf-agenda--update-entry-field (model id field value notice)
  "Update FIELD of entry ID in MODEL to VALUE, reload and show NOTICE."
  (let* ((snapshot (etaf-agenda--read model))
         (entry (gethash id (plist-get snapshot :entries))))
    (unless entry (user-error "该条目不存在"))
    (etaf-agenda--push-undo model notice (list entry) nil)
    (let ((updated (etaf-agenda--touch (plist-put (copy-sequence entry) field value))))
      (etaf-agenda--store-apply (plist-get model :store) 'entries
                                (list (list 'replace updated)))
      (etaf-agenda--write-log model id (etaf-value (plist-get model :day))
                              (substring (symbol-name field) 1)
                              (format "%s" (or value "")))
      (etaf-agenda--reload model)
      (etaf-agenda-select model id)
      (when notice (etaf-agenda--notice model notice))
      updated)))

(defun etaf-agenda-set-title (model id title)
  "Set entry ID's title to trimmed TITLE."
  (let ((trimmed (string-trim (or title ""))))
    (if (string-empty-p trimmed)
        (etaf-agenda--notice model "标题不能为空")
      (etaf-agenda--update-entry-field model id :title trimmed "已保存标题"))))

(defun etaf-agenda-set-body (model id body)
  "Set entry ID's notes body to BODY."
  (etaf-agenda--update-entry-field model id :body (string-trim-right (or body "")) "已保存备注"))

(defun etaf-agenda-set-kind (model id kind)
  "Set entry ID's kind (`task', `event', `note', `question')."
  (etaf-agenda--update-entry-field
   model id :kind kind
   (format "类型已改为 %s" (or (cdr (assoc kind etaf-agenda-kind-labels)) kind))))

(defun etaf-agenda-set-status (model id status)
  "Set entry ID's status, keeping today's instance in sync."
  (let* ((snapshot (etaf-agenda--read model))
         (entry (gethash id (plist-get snapshot :entries)))
         (day (or (plist-get entry :scheduled) (etaf-value (plist-get model :day))))
         (inst (etaf-agenda--instance-of snapshot id day)))
    (unless entry (user-error "该条目不存在"))
    (etaf-agenda--push-undo model "修改状态" (list entry) (and inst (list inst))
                            (unless inst (list (format "%s@%d" id day))))
    (let ((inst-state (cond ((equal status "done") "done")
                            ((equal status "dropped") "skipped")
                            (t "open"))))
      (etaf-agenda--store-apply
       (plist-get model :store) 'entries
       (list (list 'replace (etaf-agenda--touch (plist-put (copy-sequence entry) :status status)))))
      (etaf-agenda--store-apply
       (plist-get model :store) 'instances
       (list (list 'upsert (list :id (format "%s@%d" id day)
                                 :entry id :day day
                                 :bucket (etaf-agenda--ymd-bucket day)
                                 :state inst-state
                                 :at (when (equal status "done")
                                       (time-convert nil 'integer))))))
      (etaf-agenda--write-log model id day "status" status)
      (etaf-agenda--reload model)
      (etaf-agenda-select model id)
      (etaf-agenda--notice
       model (format "状态已改为 %s" (or (cdr (assoc status etaf-agenda-status-labels)) status))))))

(defun etaf-agenda-cycle-status (model &optional id)
  "Cycle status of ID (or selected entry) in MODEL."
  (let* ((id (or id (etaf-agenda--require-selected model)))
         (entry (gethash id (plist-get (etaf-agenda--read model) :entries)))
         (cur (or (plist-get entry :status) "open"))
         (pos (or (cl-position cur etaf-agenda-status-cycle :test #'equal) 0))
         (next (nth (mod (1+ pos) (length etaf-agenda-status-cycle))
                    etaf-agenda-status-cycle)))
    (etaf-agenda-set-status model id next)))

(defun etaf-agenda-set-priority (model id priority)
  "Set entry ID's priority (1, 2, 3 or nil)."
  (etaf-agenda--update-entry-field
   model id :priority priority
   (if priority (format "优先级已设为 P%d" priority) "已清除优先级")))

(defun etaf-agenda-cycle-priority (model &optional id)
  "Cycle priority of ID (or selected entry) through 1 -> 2 -> 3 -> nil."
  (let* ((id (or id (etaf-agenda--require-selected model)))
         (entry (gethash id (plist-get (etaf-agenda--read model) :entries)))
         (cur (plist-get entry :priority))
         (next (pcase cur (1 2) (2 3) (3 nil) (_ 1))))
    (etaf-agenda-set-priority model id next)))

(defun etaf-agenda-set-scheduled (model id ymd)
  "Reschedule entry ID to YMD (or nil for undated), keeping instances aligned."
  (let* ((snapshot (etaf-agenda--read model))
         (entry (gethash id (plist-get snapshot :entries)))
         (old-day (plist-get entry :scheduled))
         (old-inst (and old-day (etaf-agenda--instance-of snapshot id old-day)))
         (new-inst (and ymd (etaf-agenda--instance-of snapshot id ymd)))
         (remove-old (and old-inst (not (equal old-day ymd))
                          (equal (plist-get old-inst :state) "open")))
         (del-on-undo (when (and ymd (not (equal old-day ymd)) (null new-inst))
                        (list (format "%s@%d" id ymd)))))
    (unless entry (user-error "该条目不存在"))
    (etaf-agenda--push-undo model "调整计划日"
                            (list entry)
                            (delq nil (list old-inst new-inst))
                            del-on-undo)
    (etaf-agenda--store-apply
     (plist-get model :store) 'entries
     (list (list 'replace (etaf-agenda--touch (plist-put (copy-sequence entry) :scheduled ymd)))))
    (let ((inst-ops nil))
      (when remove-old
        (push (list 'delete (plist-get old-inst :id)) inst-ops))
      (when ymd
        (push (list 'upsert (list :id (format "%s@%d" id ymd)
                                  :entry id :day ymd
                                  :bucket (etaf-agenda--ymd-bucket ymd)
                                  :state (if (equal (plist-get entry :status) "done")
                                             "done" "open")))
              inst-ops))
      (when inst-ops
        (etaf-agenda--store-apply (plist-get model :store) 'instances (nreverse inst-ops))))
    (etaf-agenda--write-log model id (or ymd (etaf-value (plist-get model :day)))
                            "rescheduled" (if ymd (number-to-string ymd) "none"))
    (etaf-agenda--reload model)
    (etaf-agenda--notice model (if ymd
                                   (format "计划日已调整为 %s" (etaf-agenda--date-label ymd))
                                 "已取消排期"))))

(defun etaf-agenda-set-deadline (model id ymd)
  "Set entry ID's deadline to YMD (or nil)."
  (etaf-agenda--update-entry-field
   model id :deadline ymd
   (if ymd (format "截止日已设为 %s" (etaf-agenda--date-label ymd)) "已清除截止日")))

(defun etaf-agenda-set-time (model id at end-at)
  "Set entry ID's clock time AT and optional END-AT."
  (let* ((snapshot (etaf-agenda--read model))
         (entry (gethash id (plist-get snapshot :entries))))
    (unless entry (user-error "该条目不存在"))
    (etaf-agenda--push-undo model "修改时间" (list entry) nil)
    (let* ((copy (copy-sequence entry))
           (copy (plist-put copy :at at))
           (copy (plist-put copy :end_at end-at)))
      (etaf-agenda--store-apply (plist-get model :store) 'entries
                                (list (list 'replace (etaf-agenda--touch copy))))
      (etaf-agenda--reload model)
      (etaf-agenda--notice model (if at
                                     (format "时间已设为 %s"
                                             (etaf-agenda--time-range-label at end-at))
                                   "已清除时间")))))

(defun etaf-agenda-set-estimate (model id minutes)
  "Set entry ID's estimate in MINUTES (or nil)."
  (etaf-agenda--update-entry-field
   model id :estimate minutes
   (if minutes (format "预估时长已设为 %s" (etaf-agenda--duration-label minutes)) "已清除预估时长")))

(defun etaf-agenda-set-area (model id area-id)
  "Assign entry ID to AREA-ID (or nil for inbox)."
  (etaf-agenda--update-entry-field
   model id :area area-id
   (format "领域已改为 %s"
           (or (and area-id (etaf-agenda--container-name (etaf-agenda--read model) area-id))
               "收件箱"))))

(defun etaf-agenda-set-project-of-entry (model id project-id &optional stage-id)
  "Assign entry ID to PROJECT-ID and optional STAGE-ID."
  (let* ((snapshot (etaf-agenda--read model))
         (entry (gethash id (plist-get snapshot :entries)))
         (proj (etaf-agenda--container-of snapshot project-id)))
    (unless entry (user-error "该条目不存在"))
    (etaf-agenda--push-undo model "修改项目" (list entry) nil)
    (let* ((copy (copy-sequence entry))
           (copy (plist-put copy :project project-id))
           (copy (plist-put copy :stage stage-id))
           (copy (if (and proj (plist-get proj :parent))
                     (plist-put copy :area (plist-get proj :parent))
                   copy)))
      (etaf-agenda--store-apply (plist-get model :store) 'entries
                                (list (list 'replace (etaf-agenda--touch copy))))
      (etaf-agenda--reload model)
      (etaf-agenda--notice model (if project-id
                                     (format "已归入项目「%s」" (plist-get proj :name))
                                   "已移出项目")))))

(defun etaf-agenda-set-tags (model id tags-str)
  "Set entry ID's tags string."
  (let ((clean (string-trim (replace-regexp-in-string "[#，, \t]+" " " (or tags-str "")))))
    (etaf-agenda--update-entry-field
     model id :tags (unless (string-empty-p clean) clean)
     (if (string-empty-p clean) "已清除标签" (format "标签已更新：%s" clean)))))

(defun etaf-agenda-set-recurrence (model id recurrence)
  "Set entry ID's RECURRENCE (`daily', `weekdays', `weekly', `monthly' or nil)."
  (etaf-agenda--update-entry-field
   model id :recurrence recurrence
   (if recurrence
       (format "重复已设为 %s" (or (cdr (assoc recurrence etaf-agenda-recurrence-labels)) recurrence))
     "已取消重复")))

(defun etaf-agenda-habit-toggle (model entry-id day)
  "Toggle habit ENTRY-ID completion on DAY in MODEL."
  (let* ((snapshot (etaf-agenda--read model))
         (entry (gethash entry-id (plist-get snapshot :entries)))
         (instance (etaf-agenda--instance-of snapshot entry-id day))
         (done (equal (and instance (plist-get instance :state)) "done"))
         (inst-id (format "%s@%d" entry-id day))
         (row (list :id inst-id
                    :entry entry-id :day day
                    :bucket (etaf-agenda--ymd-bucket day)
                    :state (if done "open" "done")
                    :at (unless done (time-convert nil 'integer)))))
    (etaf-agenda--push-undo model "习惯打卡" nil
                            (and instance (list instance))
                            (unless instance (list inst-id)))
    (etaf-agenda--store-apply (plist-get model :store) 'instances
                              (list (list 'upsert row)))
    (etaf-agenda--write-log model entry-id day (if done "reopened" "done") nil)
    (etaf-agenda--reload model)
    (etaf-agenda--notice
     model (format "%s · %s %s"
                   (or (plist-get entry :title) "习惯")
                   (etaf-agenda--short-date-label day)
                   (if done "已取消打卡" "已打卡")))))

(defun etaf-agenda-toggle-entry (model &optional id)
  "Toggle completion of ID (or selected row) on any page.
Works for overdue, list, project, habit, and recurring entries."
  (let* ((id (or id (etaf-agenda--require-selected model)))
         (snapshot (etaf-agenda--read model))
         (view (etaf-value (plist-get model :view)))
         (day (etaf-value (plist-get model :day)))
         (entry (gethash id (plist-get snapshot :entries))))
    (unless entry (user-error "该条目已不存在"))
    (if (etaf-agenda--habit-p entry)
        (let ((target-day (if (eq view 'habits)
                              (or (etaf-value (plist-get model :selected-habit-day)) day)
                            day)))
          (etaf-agenda-habit-toggle model id target-day))
      (let* ((inst-day (cond
                        ((etaf-agenda--instance-of snapshot id day) day)
                        ((and (plist-get entry :scheduled)
                              (>= (plist-get entry :scheduled) day))
                         (plist-get entry :scheduled))
                        (t day)))
             (instance (etaf-agenda--instance-of snapshot id inst-day))
             (done (etaf-agenda--entry-done-p entry instance))
             (next-status (if done "open" "done"))
             (rec (plist-get entry :recurrence))
             (next-rec-day (and (not done) rec
                                (etaf-agenda--next-recurrence-day inst-day rec)))
             (next-inst (and next-rec-day
                             (etaf-agenda--instance-of snapshot id next-rec-day)))
             (del-on-undo (delq nil
                                (list (unless instance (format "%s@%d" id inst-day))
                                      (when (and next-rec-day (null next-inst))
                                        (format "%s@%d" id next-rec-day))))))
        (etaf-agenda--push-undo model (if done "取消完成" "标记完成")
                                (list entry)
                                (delq nil (list instance next-inst))
                                del-on-undo)
        (etaf-agenda--store-apply
         (plist-get model :store) 'instances
         (list (list 'upsert (list :id (format "%s@%d" id inst-day)
                                   :entry id :day inst-day
                                   :bucket (etaf-agenda--ymd-bucket inst-day)
                                   :state next-status
                                   :at (unless done (time-convert nil 'integer))))))
        (let* ((updated (plist-put (copy-sequence entry) :status
                                   (if next-rec-day "open" next-status)))
               (updated (if next-rec-day
                            (plist-put updated :scheduled next-rec-day)
                          updated)))
          (etaf-agenda--store-apply (plist-get model :store) 'entries
                                    (list (list 'replace (etaf-agenda--touch updated))))
          (when next-rec-day
            (etaf-agenda--store-apply
             (plist-get model :store) 'instances
             (list (list 'upsert (list :id (format "%s@%d" id next-rec-day)
                                       :entry id :day next-rec-day
                                       :bucket (etaf-agenda--ymd-bucket next-rec-day)
                                       :state "open"))))))
        (etaf-agenda--write-log model id inst-day (if done "reopened" "done") nil)
        (etaf-agenda--reload model)
        (etaf-agenda-select model id)
        (etaf-agenda--notice
         model (cond
                (next-rec-day
                 (format "已完成，已生成下次循环：%s" (etaf-agenda--date-label next-rec-day)))
                (done "已撤销完成")
                (t "已完成")))))))

(defun etaf-agenda-migrate-entry (model &optional id)
  "Context-aware migration of ID (or selected entry):
- Overdue item -> move to displayed DAY (today)
- Migrated item on DAY -> pull BACK to DAY
- Normal item -> move to DAY + 1 (tomorrow)
Always uses idempotent upsert so repeated migrations never fail."
  (let* ((id (or id (etaf-agenda--require-selected model)))
         (snapshot (etaf-agenda--read model))
         (day (etaf-value (plist-get model :day)))
         (entry (gethash id (plist-get snapshot :entries)))
         (instance (etaf-agenda--instance-of snapshot id day))
         (scheduled (plist-get entry :scheduled)))
    (unless entry (user-error "该条目已不存在"))
    (cond
     ;; Case 1: Already migrated away on DAY -> pull back to DAY!
     ((equal (and instance (plist-get instance :state)) "moved")
      (let* ((other-inst (and scheduled (not (equal scheduled day))
                              (etaf-agenda--instance-of snapshot id scheduled))))
        (etaf-agenda--push-undo model "迁回本日" (list entry)
                                (delq nil (list instance other-inst)))
        (etaf-agenda--store-apply
         (plist-get model :store) 'entries
         (list (list 'replace (etaf-agenda--touch (plist-put (copy-sequence entry) :scheduled day)))))
        (let ((ops (list (list 'upsert (list :id (format "%s@%d" id day)
                                             :entry id :day day
                                             :bucket (etaf-agenda--ymd-bucket day)
                                             :state "open")))))
          (when (and other-inst (equal (plist-get other-inst :state) "open"))
            (push (list 'delete (plist-get other-inst :id)) ops))
          (etaf-agenda--store-apply (plist-get model :store) 'instances ops)))
      (etaf-agenda--write-log model id day "pulled-back" (number-to-string day))
      (etaf-agenda--reload model)
      (etaf-agenda-select model id)
      (etaf-agenda--notice model (format "已迁回 %s" (etaf-agenda--date-label day))))
     ;; Case 2: Overdue item -> pull forward to DAY!
     ((and scheduled (< scheduled day) (not instance))
      (let ((old-inst (etaf-agenda--instance-of snapshot id scheduled)))
        (etaf-agenda--push-undo model "逾期延至本日" (list entry)
                                (and old-inst (list old-inst))
                                (list (format "%s@%d" id day)))
        (etaf-agenda--store-apply
         (plist-get model :store) 'entries
         (list (list 'replace (etaf-agenda--touch (plist-put (copy-sequence entry) :scheduled day)))))
        (let ((ops (list (list 'upsert (list :id (format "%s@%d" id day)
                                             :entry id :day day
                                             :bucket (etaf-agenda--ymd-bucket day)
                                             :state "open")))))
          (when (and old-inst (equal (plist-get old-inst :state) "open"))
            (push (list 'delete (plist-get old-inst :id)) ops))
          (etaf-agenda--store-apply (plist-get model :store) 'instances ops)))
      (etaf-agenda--write-log model id day "migrated" (number-to-string day))
      (etaf-agenda--reload model)
      (etaf-agenda-select model id)
      (etaf-agenda--notice model (format "已延至 %s" (etaf-agenda--date-label day))))
     ;; Case 3: Normal item -> migrate to tomorrow (DAY + 1)
     (t
      (let* ((target (etaf-agenda--shift day 1))
             (target-inst (etaf-agenda--instance-of snapshot id target))
             (del-on-undo (delq nil
                                (list (unless instance (format "%s@%d" id day))
                                      (unless target-inst (format "%s@%d" id target))))))
        (etaf-agenda--push-undo model "迁移至明天"
                                (list entry)
                                (delq nil (list instance target-inst))
                                del-on-undo)
        (etaf-agenda--store-apply
         (plist-get model :store) 'instances
         (list (list 'upsert (list :id (format "%s@%d" id day)
                                   :entry id :day day
                                   :bucket (etaf-agenda--ymd-bucket day)
                                   :state "moved"))
               (list 'upsert (list :id (format "%s@%d" id target)
                                   :entry id :day target
                                   :bucket (etaf-agenda--ymd-bucket target)
                                   :state "open"))))
        (etaf-agenda--store-apply
         (plist-get model :store) 'entries
         (list (list 'replace (etaf-agenda--touch (plist-put (copy-sequence entry) :scheduled target)))))
        (etaf-agenda--write-log model id day "migrated" (number-to-string target))
        (etaf-agenda--reload model)
        (etaf-agenda--notice model (format "已迁至 %s" (etaf-agenda--date-label target))))))))

(defun etaf-agenda-migrate-all-overdue (model)
  "Batch migrate all visible overdue tasks to MODEL's displayed day."
  (let* ((plan (etaf-agenda-plan model))
         (overdue (plist-get (plist-get plan :day-rows) :overdue))
         (day (plist-get plan :day))
         (snapshot (etaf-agenda--read model)))
    (if (null overdue)
        (etaf-agenda--notice model "没有需要顺延的逾期条目")
      (let ((old-entries nil) (old-insts nil) (del-inst-ids nil)
            (entry-ops nil) (inst-ops nil))
        (dolist (row overdue)
          (when-let* ((id (plist-get row :id))
                      (entry (gethash id (plist-get snapshot :entries))))
            (let* ((old-day (plist-get entry :scheduled))
                   (old-inst (and old-day (etaf-agenda--instance-of snapshot id old-day)))
                   (day-inst (etaf-agenda--instance-of snapshot id day))
                   (day-inst-id (format "%s@%d" id day)))
              (push entry old-entries)
              (when old-inst (push old-inst old-insts))
              (if day-inst
                  (push day-inst old-insts)
                (push day-inst-id del-inst-ids))
              (push (list 'replace (etaf-agenda--touch
                                    (plist-put (copy-sequence entry) :scheduled day)))
                    entry-ops)
              (when (and old-inst (not (equal old-day day))
                         (equal (plist-get old-inst :state) "open"))
                (push (list 'delete (plist-get old-inst :id)) inst-ops))
              (push (list 'upsert (list :id day-inst-id
                                        :entry id :day day
                                        :bucket (etaf-agenda--ymd-bucket day)
                                        :state "open"))
                    inst-ops))))
        (etaf-agenda--push-undo model "批量顺延逾期" old-entries old-insts del-inst-ids)
        (etaf-agenda--store-apply (plist-get model :store) 'entries (nreverse entry-ops))
        (etaf-agenda--store-apply (plist-get model :store) 'instances (nreverse inst-ops))
        (etaf-agenda--reload model)
        (etaf-agenda--notice model (format "已将 %d 条逾期延至 %s（按 u 撤销）"
                                           (length old-entries)
                                           (etaf-agenda--date-label day)))))))

(defun etaf-agenda-drop-entry (model &optional id)
  "Drop ID (or selected entry) with undo support."
  (let* ((id (or id (etaf-agenda--require-selected model)))
         (snapshot (etaf-agenda--read model))
         (day (etaf-value (plist-get model :day)))
         (entry (gethash id (plist-get snapshot :entries)))
         (inst (etaf-agenda--instance-of snapshot id day)))
    (unless entry (user-error "该条目已不存在"))
    (etaf-agenda--push-undo model "放弃条目" (list entry) (and inst (list inst)))
    (when inst
      (etaf-agenda--store-apply
       (plist-get model :store) 'instances
       (list (list 'upsert (plist-put (copy-sequence inst) :state "skipped")))))
    (etaf-agenda--store-apply
     (plist-get model :store) 'entries
     (list (list 'replace (etaf-agenda--touch (plist-put (copy-sequence entry) :status "dropped")))))
    (etaf-agenda--write-log model id day "dropped" nil)
    (when (equal (etaf-value (plist-get model :inspector)) id)
      (etaf-set-value (plist-get model :inspector) nil))
    (etaf-agenda--reload model)
    (etaf-agenda--notice model "已放弃（按 u 撤销）")))

(defun etaf-agenda-delete-entry (model &optional id)
  "Soft-delete ID (or selected entry) using `:deleted 1' with undo support."
  (let* ((id (or id (etaf-agenda--require-selected model)))
         (snapshot (etaf-agenda--read model))
         (day (etaf-value (plist-get model :day)))
         (entry (gethash id (plist-get snapshot :entries))))
    (unless entry (user-error "该条目已不存在"))
    (etaf-agenda--push-undo model "删除条目" (list entry) nil)
    (etaf-agenda--store-apply
     (plist-get model :store) 'entries
     (list (list 'replace (etaf-agenda--touch (plist-put (copy-sequence entry) :deleted 1)))))
    (etaf-agenda--write-log model id day "deleted" nil)
    (when (equal (etaf-value (plist-get model :inspector)) id)
      (etaf-set-value (plist-get model :inspector) nil))
    (when (equal (etaf-value (plist-get model :selected)) id)
      (etaf-set-value (plist-get model :selected) nil))
    (etaf-agenda--reload model)
    (etaf-agenda--notice model "已删除（按 u 撤销）")))

;;; ---------------------------------------------------------------------------
;;; Capture, In-place Drafting, Editing & Inspector
;;; ---------------------------------------------------------------------------

(defun etaf-agenda--capture (model text &optional default-kind context)
  "Create a new entry from natural-language TEXT in MODEL.
CONTEXT is an optional plist with `:area', `:project', `:stage', `:day'."
  (let* ((default-day (or (plist-get context :day) (etaf-value (plist-get model :day))))
         (fields (etaf-agenda-parse text default-day))
         (day (or (plist-get fields :date) default-day))
         (id (etaf-agenda--unique-id "ent-"))
         (now (time-convert nil 'integer))
         (habit (plist-get fields :habit))
         (area-name (plist-get fields :container))
         (proj-name (plist-get fields :project))
         (area-id (cond
                   (area-name (etaf-agenda-ensure-container model "area" area-name))
                   ((plist-get context :area))
                   ((let ((cur (etaf-value (plist-get model :area))))
                      (and (stringp cur) cur)))))
         (proj-id (cond
                   (proj-name (etaf-agenda-ensure-container model "project" proj-name area-id))
                   ((plist-get context :project))))
         (stage-id (plist-get context :stage))
         (kind (or (plist-get fields :kind) default-kind "task"))
         (entry (list :id id
                      :kind kind
                      :status "open"
                      :title (plist-get fields :title)
                      :body ""
                      :priority (plist-get fields :priority)
                      :scheduled (and (not habit) day)
                      :at (plist-get fields :at)
                      :end_at (plist-get fields :end)
                      :deadline (plist-get fields :deadline)
                      :estimate (plist-get fields :estimate)
                      :recurrence (plist-get fields :recurrence)
                      :area area-id
                      :project proj-id
                      :stage stage-id
                      :deleted 0
                      :habit_target habit
                      :tags (and (plist-get fields :tags)
                                 (string-join (plist-get fields :tags) " "))
                      :created now
                      :updated now)))
    (etaf-agenda--store-apply (plist-get model :store) 'entries
                              (list (list 'insert entry)))
    (unless habit
      (etaf-agenda--store-apply
       (plist-get model :store) 'instances
       (list (list 'upsert (list :id (format "%s@%d" id day)
                                 :entry id :day day
                                 :bucket (etaf-agenda--ymd-bucket day)
                                 :state "open")))))
    (etaf-agenda--write-log model id day "created" nil)
    (etaf-agenda--reload model)
    (when (or habit (= day default-day)
              (memq (etaf-value (plist-get model :view)) '(list project habits)))
      (etaf-agenda-select model id))
    (etaf-agenda--notice
     model (if habit "已添加习惯，按 x 即可打卡"
             (format "已记下「%s」" (plist-get fields :title))))
    (plist-get fields :title)))

(defun etaf-agenda-begin-draft (model &optional target stage-id)
  "Open an in-place capture row appropriate for MODEL's current page."
  (let* ((view (etaf-value (plist-get model :view)))
         (ctx (pcase view
                ('habits (list :target 'habits))
                ('project (list :target 'project
                                :project (or (etaf-value (plist-get model :project))
                                             (plist-get (car (plist-get (etaf-agenda-sidebar-rows
                                                                         (etaf-agenda--read model))
                                                                        :projects))
                                                        :id))
                                :stage stage-id))
                ('calendar (list :target 'calendar :day (etaf-value (plist-get model :day))))
                ('list (list :target 'list))
                ('review (list :target 'review))
                (_ (list :target (or target 'tasks))))))
    (etaf-batch
     (etaf-set-value (plist-get model :editing) nil)
     (etaf-set-value (plist-get model :draft)
                     (if (eq (plist-get ctx :target) 'habits) "每天 " ""))
     (etaf-set-value (plist-get model :drafting) ctx)
     (etaf-set-value (plist-get model :message) nil))))

(defun etaf-agenda-submit-draft (model &optional text-override)
  "Submit MODEL's in-place capture draft and close the capture row."
  (let* ((text (or text-override (etaf-value (plist-get model :draft)) ""))
         (ctx (etaf-value (plist-get model :drafting)))
         (target (plist-get ctx :target))
         (kind (pcase target ('events "event") ('notes "note") (_ "task"))))
    (etaf-set-value (plist-get model :drafting) nil)
    (etaf-set-value (plist-get model :draft) "")
    (unless (string-empty-p (string-trim text))
      (etaf-agenda--capture model text kind ctx))))

(defun etaf-agenda-cancel-draft (model)
  "Close MODEL's in-place capture row cleanly."
  (etaf-batch
   (etaf-set-value (plist-get model :drafting) nil)
   (etaf-set-value (plist-get model :draft) "")))

(defun etaf-agenda-begin-edit (model &optional id)
  "Start in-place title editing for ID (or selected entry)."
  (let* ((id (or id (etaf-agenda--require-selected model)))
         (entry (gethash id (plist-get (etaf-agenda--read model) :entries))))
    (unless entry (user-error "该条目已不存在"))
    (etaf-batch
     (etaf-set-value (plist-get model :drafting) nil)
     (etaf-set-value (plist-get model :edit-draft) (or (plist-get entry :title) ""))
     (etaf-set-value (plist-get model :editing) id)
     (etaf-set-value (plist-get model :message) nil))))

(defun etaf-agenda-submit-edit (model text)
  "Save TEXT as the title of MODEL's edited entry and close the inline editor."
  (let ((id (etaf-value (plist-get model :editing))))
    (etaf-set-value (plist-get model :editing) nil)
    (when id
      (etaf-agenda-set-title model id text))))

(defun etaf-agenda-cancel-edit (model)
  "Cancel MODEL's in-place title edit."
  (etaf-set-value (plist-get model :editing) nil))

(defun etaf-agenda-open-inspector (model &optional id)
  "Open the interactive Inspector in the right rail for ID (or selected entry)."
  (let ((id (or id (etaf-agenda--require-selected model))))
    (etaf-batch
     (etaf-set-value (plist-get model :selected) id)
     (etaf-set-value (plist-get model :inspector) id)
     (etaf-set-value (plist-get model :inspector-body-editing) nil)
     (etaf-set-value (plist-get model :message) nil))
    (etaf-agenda--refresh-inspector-logs model)))

(defun etaf-agenda-close-inspector (model)
  "Close MODEL's right-rail Inspector while keeping the row selected."
  (etaf-batch
   (etaf-set-value (plist-get model :inspector) nil)
   (etaf-set-value (plist-get model :inspector-logs) nil)
   (etaf-set-value (plist-get model :inspector-body-editing) nil)))

(defun etaf-agenda-begin-body-edit (model)
  "Start editing the notes body of the entry open in MODEL's Inspector."
  (when-let* ((id (etaf-value (plist-get model :inspector)))
              (entry (gethash id (plist-get (etaf-agenda--read model) :entries))))
    (etaf-batch
     (etaf-set-value (plist-get model :inspector-body-draft)
                     (or (plist-get entry :body) ""))
     (etaf-set-value (plist-get model :inspector-body-editing) t))))

(defun etaf-agenda-submit-body-edit (model text)
  "Save TEXT as the open Inspector entry's notes body."
  (let ((id (etaf-value (plist-get model :inspector))))
    (etaf-set-value (plist-get model :inspector-body-editing) nil)
    (when id
      (etaf-agenda-set-body model id text))))

(defun etaf-agenda-dismiss (model)
  "Dismiss one transient layer on Escape.
Order: body-edit -> inline-edit -> draft -> search -> inspector -> selection."
  (cond
   ((etaf-value (plist-get model :inspector-body-editing))
    (etaf-set-value (plist-get model :inspector-body-editing) nil))
   ((etaf-value (plist-get model :editing))
    (etaf-agenda-cancel-edit model))
   ((etaf-value (plist-get model :drafting))
    (etaf-agenda-cancel-draft model))
   ((not (string-empty-p (or (etaf-value (plist-get model :query)) "")))
    (etaf-agenda-set-query model "")
    (etaf-agenda--notice model "已清空搜索"))
   ((etaf-value (plist-get model :inspector))
    (etaf-agenda-close-inspector model))
   ((etaf-value (plist-get model :selected))
    (etaf-set-value (plist-get model :selected) nil))
   (t nil)))

(provide 'etaf-agenda-model)
;;; etaf-agenda-model.el ends here
