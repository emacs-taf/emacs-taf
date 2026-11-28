;;; etaf-agenda-app.el --- Application shell and interactive commands of etaf-agenda -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; Owns the Emacs buffer, mount lifecycle, display-table hygiene, interactive
;; commands, minibuffer property pickers and ETAF directional dispatch.  All
;; state is buffer-local through `etaf-app-state' (no leaked global singleton).

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'etaf)
(require 'etaf-ui)
(require 'etaf-agenda-theme)
(require 'etaf-agenda-layout)
(require 'etaf-agenda-parse)
(require 'etaf-agenda-store)
(require 'etaf-agenda-model)
(require 'etaf-agenda-keys)
(require 'etaf-agenda-views)

(defcustom etaf-agenda-buffer-name "*Agenda*"
  "Buffer name of the mounted agenda application."
  :type 'string
  :group 'etaf-agenda)

(defun etaf-agenda--current (&optional model)
  "Return MODEL, or the buffer-local agenda model, signaling if not in an agenda."
  (or model
      (let ((state (ignore-errors (etaf-app-state))))
        (and (listp state) (plist-get state :store) state))
      (user-error "当前 buffer 不是议程")))

(setq etaf-agenda-model-resolver
      (lambda ()
        (let ((state (ignore-errors (etaf-app-state))))
          (and (listp state) (plist-get state :store) state))))

(defun etaf-agenda--runtime ()
  "Return the ETAF runtime of the current buffer (or `*Agenda*'), or nil."
  (or (etaf-runtime-for-buffer (current-buffer))
      (when-let* ((buf (get-buffer etaf-agenda-buffer-name)))
        (etaf-runtime-for-buffer buf))))

(defun etaf-agenda--reveal-row (id)
  "Scroll the main pane so row ID stays visible."
  (when-let* ((id id)
              (rt (etaf-agenda--runtime)))
    (ignore-errors
      (etaf-scroll-into-view rt (intern (concat "agenda-row-" id))))))

(defun etaf-agenda--prepare-buffer (buffer)
  "Clear BUFFER's truncation glyph, hide cursor, and configure 1px right fringe."
  (with-current-buffer buffer
    (setq-local cursor-type nil)
    (let ((table (if buffer-display-table
                     (copy-sequence buffer-display-table)
                   (if standard-display-table
                       (copy-sequence standard-display-table)
                     (make-display-table)))))
      (set-display-table-slot table 'truncation ?\s)
      (setq-local buffer-display-table table))
    (when-let* ((win (get-buffer-window buffer t)))
      (set-window-fringes win 0 1 nil t))))

;;; ---------------------------------------------------------------------------
;;; Interactive property pickers (used by Inspector clicks & commands)
;;; ---------------------------------------------------------------------------

(defun etaf-agenda--prompt-date (model prompt &optional allow-clear)
  "Read a date string with PROMPT relative to MODEL's day; return YYYYMMDD or nil."
  (let* ((day (etaf-value (plist-get model :day)))
         (choices (append (list "今天" "明天" "后天" "下周一")
                          (when allow-clear (list "清除日期"))))
         (input (string-trim (completing-read prompt choices nil nil))))
    (cond
     ((or (string-empty-p input) (equal input "清除日期")) nil)
     ((etaf-agenda--parse-date-token input day))
     (t (user-error "无法识别日期「%s」（支持 今天/明天/周五/YYYY-MM-DD）" input)))))

(defun etaf-agenda--pick-scheduled (model id)
  "Prompt for a new scheduled date for entry ID."
  (let ((ymd (etaf-agenda--prompt-date model "计划日（如 明天 / 周五 / 2026-11-25）：" t)))
    (etaf-agenda-set-scheduled model id ymd)))

(defun etaf-agenda--pick-deadline (model id)
  "Prompt for a new deadline date for entry ID."
  (let ((ymd (etaf-agenda--prompt-date model "截止日（留空或选清除日期）：" t)))
    (etaf-agenda-set-deadline model id ymd)))

(defun etaf-agenda--pick-time (model id)
  "Prompt for a clock time or range for entry ID."
  (let* ((raw (string-trim (read-string "时间段（如 14:30 或 14:30-15:30，留空清除）："))))
    (if (string-empty-p raw)
        (etaf-agenda-set-time model id nil nil)
      (let* ((parsed (etaf-agenda--parse-time raw))
             (at (nth 0 parsed))
             (end (nth 1 parsed)))
        (unless at (user-error "时间格式无效，请用 HH:MM 或 HH:MM-HH:MM"))
        (etaf-agenda-set-time model id at end)))))

(defun etaf-agenda--pick-estimate (model id)
  "Prompt for estimated duration for entry ID."
  (let* ((choice (string-trim
                  (completing-read "预估时长（分钟或如 30m / 1.5h，留空清除）："
                                   '("15m" "30m" "45m" "1h" "1.5h" "2h" "清除") nil nil))))
    (cond
     ((or (string-empty-p choice) (equal choice "清除"))
      (etaf-agenda-set-estimate model id nil))
     ((string-match-p "\\`[0-9]+\\'" choice)
      (etaf-agenda-set-estimate model id (string-to-number choice)))
     ((etaf-agenda--parse-estimate (concat "~" choice))
      (etaf-agenda-set-estimate model id (etaf-agenda--parse-estimate (concat "~" choice))))
     (t (user-error "无法识别时长「%s」" choice)))))

(defun etaf-agenda--pick-recurrence (model id)
  "Prompt for a recurrence rule for entry ID."
  (let* ((choices '("不重复" "每天" "工作日" "每周" "每月"))
         (pick (completing-read "重复规则：" choices nil t))
         (val (cdr (assoc pick etaf-agenda--recurrence-words))))
    (etaf-agenda-set-recurrence model id val)))

(defun etaf-agenda--pick-area (model id)
  "Prompt for an area for entry ID (supports creating a new area)."
  (let* ((sb (etaf-agenda-sidebar-rows (etaf-agenda--read model)))
         (areas (plist-get sb :areas))
         (add-opt "+ 新建领域…")
         (choices (append (list "收件箱")
                          (mapcar (lambda (a) (plist-get a :title)) areas)
                          (list add-opt)))
         (pick (completing-read "所属领域：" choices nil t)))
    (cond
     ((equal pick "收件箱") (etaf-agenda-set-area model id nil))
     ((equal pick add-opt)
      (let* ((name (read-string "新领域名称："))
             (aid (etaf-agenda-create-area model name)))
        (etaf-agenda-set-area model id aid)))
     (t
      (when-let* ((row (seq-find (lambda (a) (equal (plist-get a :title) pick)) areas)))
        (etaf-agenda-set-area model id (plist-get row :id)))))))

(defun etaf-agenda--pick-project (model id)
  "Prompt for a project (and optional stage) for entry ID."
  (let* ((snapshot (etaf-agenda--read model))
         (sb (etaf-agenda-sidebar-rows snapshot))
         (projects (plist-get sb :projects))
         (add-opt "+ 新建项目…")
         (choices (append (list "无项目")
                          (mapcar (lambda (p) (plist-get p :title)) projects)
                          (list add-opt)))
         (pick (completing-read "所属项目：" choices nil t)))
    (cond
     ((equal pick "无项目") (etaf-agenda-set-project-of-entry model id nil nil))
     ((equal pick add-opt)
      (let* ((name (read-string "新项目名称："))
             (pid (etaf-agenda-create-project model name)))
        (etaf-agenda-set-project-of-entry model id pid nil)))
     (t
      (when-let* ((pr (seq-find (lambda (p) (equal (plist-get p :title) pick)) projects))
                  (pid (plist-get pr :id)))
        (let* ((stages (seq-filter (lambda (c)
                                     (and (equal (plist-get c :kind) "stage")
                                          (equal (plist-get c :parent) pid)))
                                   (plist-get snapshot :containers)))
               (stage-id
                (when stages
                  (let ((sp (completing-read
                             "阶段："
                             (cons "未分阶段" (mapcar (lambda (s) (plist-get s :name)) stages))
                             nil t)))
                    (plist-get (seq-find (lambda (s) (equal (plist-get s :name) sp)) stages) :id)))))
          (etaf-agenda-set-project-of-entry model id pid stage-id)))))))

(defun etaf-agenda--pick-tags (model id)
  "Prompt for tags for entry ID."
  (let* ((entry (gethash id (plist-get (etaf-agenda--read model) :entries)))
         (initial (or (plist-get entry :tags) ""))
         (input (read-string "标签（空格分隔，留空清除）：" initial)))
    (etaf-agenda-set-tags model id input)))

(defun etaf-agenda--pick-scope (model)
  "Prompt to switch area/project perspective (used in medium/narrow topbar)."
  (let* ((sb (etaf-agenda-sidebar-rows (etaf-agenda--read model)))
         (areas (plist-get sb :areas))
         (projects (plist-get sb :projects))
         (choices (append (list "全部" "收件箱")
                          (mapcar (lambda (a) (concat "领域：" (plist-get a :title))) areas)
                          (mapcar (lambda (p) (concat "项目：" (plist-get p :title))) projects)))
         (pick (completing-read "切换视角：" choices nil t)))
    (cond
     ((equal pick "全部") (etaf-agenda-select-area model 'all))
     ((equal pick "收件箱") (etaf-agenda-select-area model 'inbox))
     ((string-prefix-p "领域：" pick)
      (let ((name (substring pick 3)))
        (when-let* ((a (seq-find (lambda (r) (equal (plist-get r :title) name)) areas)))
          (etaf-agenda-select-area model (plist-get a :id)))))
     ((string-prefix-p "项目：" pick)
      (let ((name (substring pick 3)))
        (when-let* ((p (seq-find (lambda (r) (equal (plist-get r :title) name)) projects)))
          (etaf-agenda-set-project model (plist-get p :id))))))))

(defun etaf-agenda--prompt-new-area (model)
  "Prompt for a new area name and create it."
  (let ((name (string-trim (read-string "新建领域名称："))))
    (unless (string-empty-p name)
      (etaf-agenda-create-area model name))))

(defun etaf-agenda--prompt-new-project (model)
  "Prompt for a new project name and optional goal, then create it."
  (let ((name (string-trim (read-string "新建项目名称："))))
    (unless (string-empty-p name)
      (let* ((goal (string-trim (read-string "项目目标（可选）：")))
             (cur-area (etaf-value (plist-get model :area)))
             (area-id (and (stringp cur-area) cur-area)))
        (etaf-agenda-create-project model name area-id
                                    (unless (string-empty-p goal) goal))))))

(defun etaf-agenda--prompt-new-stage (model)
  "Prompt for a new stage name in MODEL's active project."
  (let* ((plan (etaf-agenda-plan model))
         (pid (plist-get plan :project)))
    (unless pid (user-error "请先选择或创建一个项目"))
    (let ((name (string-trim (read-string "新建阶段名称："))))
      (unless (string-empty-p name)
        (etaf-agenda-create-stage model pid name)))))

;;; ---------------------------------------------------------------------------
;;; Direction protocol & activation dispatch
;;; ---------------------------------------------------------------------------

(defun etaf-agenda--handle-direction (model direction)
  "Handle directional navigation inside MODEL's main workspace region.
Returns `handled' when consumed locally, or `release' at a region boundary so
ETAF's spatial region navigation can move to adjacent regions."
  (let ((view (etaf-value (plist-get model :view))))
    (pcase view
      ('calendar
       (if (eq (etaf-value (plist-get model :calendar-mode)) 'year)
           (let* ((plan (etaf-agenda-plan model))
                  (cal-w (plist-get (plist-get plan :layout) :cal-inner-cols))
                  (cols (etaf-agenda-layout-year-columns
                         cal-w (etaf-agenda-plan-char-px plan (etaf-agenda--runtime)))))
             (pcase direction
               ('left (etaf-agenda-shift-month model -1) 'handled)
               ('right (etaf-agenda-shift-month model 1) 'handled)
               ('up (etaf-agenda-shift-month model (- cols)) 'handled)
               ('down (etaf-agenda-shift-month model cols) 'handled)
               (_ 'release)))
         (pcase direction
           ('left (etaf-agenda-shift-day model -1) 'handled)
           ('right (etaf-agenda-shift-day model 1) 'handled)
           ('up (etaf-agenda-shift-day model -7) 'handled)
           ('down (etaf-agenda-shift-day model 7) 'handled)
           (_ 'release))))
      ('habits
       (pcase direction
         ('left (etaf-agenda-shift-habit-day model -1) 'handled)
         ('right (etaf-agenda-shift-habit-day model 1) 'handled)
         ('up
          (let ((before (etaf-value (plist-get model :selected)))
                (after (etaf-agenda-move-row model -1)))
            (if (equal before after) 'release 'handled)))
         ('down
          (let ((before (etaf-value (plist-get model :selected)))
                (after (etaf-agenda-move-row model 1)))
            (if (equal before after) 'release 'handled)))
         (_ 'release)))
      (_
       (pcase direction
         ('up
          (let ((before (etaf-value (plist-get model :selected)))
                (after (etaf-agenda-move-row model -1)))
            (when after (etaf-agenda--reveal-row after))
            (if (and before (equal before after)) 'release 'handled)))
         ('down
          (let ((before (etaf-value (plist-get model :selected)))
                (after (etaf-agenda-move-row model 1)))
            (when after (etaf-agenda--reveal-row after))
            (if (and before (equal before after)) 'release 'handled)))
         (_ 'release))))))

(defun etaf-agenda--activate-or-open (model)
  "Activate focused non-row control, or open the selected entry's Inspector."
  (let* ((rt (etaf-agenda--runtime))
         (focused (and rt (etaf-focused-host-ref rt))))
    (if (and focused
             (not (string-prefix-p "agenda-row-" (symbol-name focused))))
        (etaf-activate rt)
      (etaf-agenda-open-inspector model))))

(defun etaf-agenda--focus-search ()
  "Activate the topbar search text input."
  (when-let* ((rt (etaf-agenda--runtime)))
    (ignore-errors (etaf-text-input-begin rt 'etaf-agenda-search))))

(defun etaf-agenda--open-help ()
  "Open ETAF's native read-only keyboard help modal."
  (when-let* ((rt (etaf-agenda--runtime)))
    (etaf-help rt)))

;;; ---------------------------------------------------------------------------
;;; Build shell bindings & callbacks
;;; ---------------------------------------------------------------------------

(defun etaf-agenda--shift-calendar-period (model delta)
  "Shift MODEL by DELTA years/weeks/months according to active Calendar mode."
  (if (eq (etaf-value (plist-get model :view)) 'calendar)
      (pcase (etaf-value (plist-get model :calendar-mode))
        ('year (etaf-agenda-shift-year model delta))
        ('week (etaf-agenda-shift-day model (* 7 delta)))
        (_ (etaf-agenda-shift-month model delta)))
    (etaf-agenda-shift-month model delta)))

(defun etaf-agenda--build-handlers (model)
  "Return the command handler plist for MODEL's root Host `:keys'."
  (list
   :view-today (lambda () (etaf-agenda-set-view model 'today))
   :view-calendar (lambda () (etaf-agenda-set-view model 'calendar))
   :view-list (lambda () (etaf-agenda-set-view model 'list))
   :view-project (lambda () (etaf-agenda-set-view model 'project))
   :view-habits (lambda () (etaf-agenda-set-view model 'habits))
   :view-review (lambda () (etaf-agenda-set-view model 'review))
   :next-row (lambda ()
               (when-let* ((id (etaf-agenda-move-row model 1)))
                 (etaf-agenda--reveal-row id)))
   :prev-row (lambda ()
               (when-let* ((id (etaf-agenda-move-row model -1)))
                 (etaf-agenda--reveal-row id)))
   :prev-day (lambda ()
               (if (eq (etaf-value (plist-get model :view)) 'habits)
                   (etaf-agenda-shift-habit-day model -1)
                 (etaf-agenda-shift-day model -1)))
   :next-day (lambda ()
               (if (eq (etaf-value (plist-get model :view)) 'habits)
                   (etaf-agenda-shift-habit-day model 1)
                 (etaf-agenda-shift-day model 1)))
   :today (lambda () (etaf-agenda-show-today model))
   :prev-month (lambda () (etaf-agenda--shift-calendar-period model -1))
   :next-month (lambda () (etaf-agenda--shift-calendar-period model 1))
   :toggle-cal-mode (lambda () (etaf-agenda-toggle-calendar-mode model))
   :add (lambda ()
          (etaf-agenda-begin-draft model)
          (when-let* ((rt (etaf-agenda--runtime)))
            (unless (etaf-text-input-active-p rt)
              (ignore-errors (etaf-text-input-begin rt 'etaf-agenda-draft)))))
   :capture (lambda () (call-interactively #'etaf-agenda-capture))
   :edit (lambda ()
           (etaf-agenda-begin-edit model)
           (when-let* ((rt (etaf-agenda--runtime)))
             (unless (etaf-text-input-active-p rt)
               (ignore-errors (etaf-text-input-begin rt 'etaf-agenda-edit)))))
   :activate-or-open (lambda () (etaf-agenda--activate-or-open model))
   :toggle (lambda () (etaf-agenda-toggle-entry model))
   :migrate (lambda () (etaf-agenda-migrate-entry model))
   :migrate-overdue (lambda () (etaf-agenda-migrate-all-overdue model))
   :reschedule (lambda ()
                 (etaf-agenda--pick-scheduled model (etaf-agenda--require-selected model)))
   :cycle-status (lambda () (etaf-agenda-cycle-status model))
   :cycle-priority (lambda () (etaf-agenda-cycle-priority model))
   :drop (lambda () (etaf-agenda-drop-entry model))
   :delete (lambda () (etaf-agenda-delete-entry model))
   :undo (lambda () (etaf-agenda-undo model))
   :focus-search #'etaf-agenda--focus-search
   :switch-scope (lambda () (etaf-agenda--pick-scope model))
   :cycle-grouping (lambda () (etaf-agenda-cycle-grouping model))
   :toggle-completed (lambda () (etaf-agenda-toggle-show-completed model))
   :add-area-or-stage (lambda ()
                        (if (eq (etaf-value (plist-get model :view)) 'project)
                            (etaf-agenda--prompt-new-stage model)
                          (etaf-agenda--prompt-new-area model)))
   :add-project (lambda () (etaf-agenda--prompt-new-project model))
   :close #'etaf-agenda-close))

(defun etaf-agenda--build-actions (model)
  "Return the UI callback plist passed into `etaf-agenda-shell'."
  (list
   :on-dismiss (lambda () (etaf-agenda-dismiss model))
   :on-direction (lambda (dir) (etaf-agenda--handle-direction model dir))
   :on-switch-view (lambda (v) (etaf-agenda-set-view model v))
   :on-switch-scope (lambda () (etaf-agenda--pick-scope model))
   :on-search-change (lambda (text) (etaf-agenda-set-query model text))
   :on-search-submit (lambda (text) (etaf-agenda-set-query model text))
   :on-search-clear (lambda () (etaf-agenda-set-query model ""))
   :on-new (lambda ()
             (etaf-agenda-begin-draft model)
             (when-let* ((rt (etaf-agenda--runtime)))
               (unless (etaf-text-input-active-p rt)
                 (ignore-errors (etaf-text-input-begin rt 'etaf-agenda-draft)))))
   :on-help #'etaf-agenda--open-help
   :on-select-area (lambda (a) (etaf-agenda-select-area model a))
   :on-select-project (lambda (p) (etaf-agenda-set-project model p))
   :on-add-area (lambda () (etaf-agenda--prompt-new-area model))
   :on-add-project (lambda () (etaf-agenda--prompt-new-project model))
   :on-add-stage (lambda () (etaf-agenda--prompt-new-stage model))
   :on-add-task-in-stage (lambda (sid)
                           (etaf-agenda-begin-draft model 'project sid)
                           (when-let* ((rt (etaf-agenda--runtime)))
                             (unless (etaf-text-input-active-p rt)
                               (ignore-errors (etaf-text-input-begin rt 'etaf-agenda-draft)))))
   :on-select (lambda (id)
                (etaf-agenda-select model id)
                (when (etaf-value (plist-get model :inspector))
                  (etaf-agenda-open-inspector model id)))
   :on-toggle (lambda (id) (etaf-agenda-toggle-entry model id))
   :on-toggle-habit (lambda (id d) (etaf-agenda-habit-toggle model id d))
   :on-open (lambda (id) (etaf-agenda-open-inspector model id))
   :on-close-inspector (lambda () (etaf-agenda-close-inspector model))
   :on-prev-day (lambda () (etaf-agenda-shift-day model -1))
   :on-next-day (lambda () (etaf-agenda-shift-day model 1))
   :on-today (lambda () (etaf-agenda-show-today model))
   :on-prev-month (lambda () (etaf-agenda--shift-calendar-period model -1))
   :on-next-month (lambda () (etaf-agenda--shift-calendar-period model 1))
   :on-pick-day (lambda (d) (etaf-agenda-set-day model d))
   :on-zoom-month (lambda (d)
                    (etaf-agenda-set-day model d)
                    (etaf-agenda-set-calendar-mode model 'month))
   :on-calendar-mode (lambda (m) (etaf-agenda-set-calendar-mode model m))
   :on-grouping (lambda (g) (etaf-agenda-set-grouping model g))
   :on-toggle-completed (lambda () (etaf-agenda-toggle-show-completed model))
   :on-migrate-overdue (lambda () (etaf-agenda-migrate-all-overdue model))
   :on-clear-area (lambda () (etaf-agenda-select-area model 'all))
   :on-draft-submit (lambda (&optional text) (etaf-agenda-submit-draft model text))
   :on-draft-cancel (lambda (&optional _text) (etaf-agenda-cancel-draft model))
   :on-edit-submit (lambda (text) (etaf-agenda-submit-edit model text))
   :on-edit-cancel (lambda (&optional _text) (etaf-agenda-cancel-edit model))
   :on-set-kind (lambda (id k) (etaf-agenda-set-kind model id k))
   :on-cycle-status (lambda (id) (etaf-agenda-cycle-status model id))
   :on-cycle-priority (lambda (id) (etaf-agenda-cycle-priority model id))
   :on-edit-title (lambda (id)
                    (etaf-agenda-begin-edit model id)
                    (when-let* ((rt (etaf-agenda--runtime)))
                      (unless (etaf-text-input-active-p rt)
                        (ignore-errors (etaf-text-input-begin rt 'etaf-agenda-edit)))))
   :on-pick-scheduled (lambda (id) (etaf-agenda--pick-scheduled model id))
   :on-pick-deadline (lambda (id) (etaf-agenda--pick-deadline model id))
   :on-pick-time (lambda (id) (etaf-agenda--pick-time model id))
   :on-pick-estimate (lambda (id) (etaf-agenda--pick-estimate model id))
   :on-pick-area (lambda (id) (etaf-agenda--pick-area model id))
   :on-pick-project (lambda (id) (etaf-agenda--pick-project model id))
   :on-pick-tags (lambda (id) (etaf-agenda--pick-tags model id))
   :on-pick-recurrence (lambda (id) (etaf-agenda--pick-recurrence model id))
   :on-edit-body (lambda ()
                   (etaf-agenda-begin-body-edit model)
                   (when-let* ((rt (etaf-agenda--runtime)))
                     (unless (etaf-text-input-active-p rt)
                       (ignore-errors (etaf-text-input-begin rt 'etaf-agenda-body-edit)))))
   :on-submit-body (lambda (text)
                     (when-let* ((rt (etaf-agenda--runtime)))
                       (when (etaf-text-input-active-p rt)
                         (ignore-errors (etaf-text-input-end 'blur))))
                     (etaf-agenda-submit-body-edit model text))
   :on-cancel-body (lambda (&optional _text)
                     (when-let* ((rt (etaf-agenda--runtime)))
                       (when (etaf-text-input-active-p rt)
                         (ignore-errors (etaf-text-input-end 'cancel))))
                     (etaf-set-value (plist-get model :inspector-body-editing) nil))
   :on-delete (lambda (id) (etaf-agenda-delete-entry model id))))

;;; ---------------------------------------------------------------------------
;;; Public entry commands
;;; ---------------------------------------------------------------------------

(defun etaf-agenda--sync-window (model window)
  "Sync MODEL's viewport dimensions from WINDOW using `etaf-display-metrics'."
  (when (window-live-p window)
    (let* ((rt (etaf-agenda--runtime))
           (metrics (or (and rt (ignore-errors (etaf-display-metrics rt)))
                        (ignore-errors (etaf-display-metrics))))
           (cw (max 1 (or (plist-get metrics :char-width)
                          (/ (window-body-width window t)
                             (max 1 (window-body-width window))))))
           (lh (max 1 (or (plist-get metrics :line-height)
                          (/ (window-body-height window t)
                             (max 1 (window-body-height window))))))
           (vp (and rt (ignore-errors (etaf-runtime-window-viewport rt))))
           (w-px (or (car-safe vp)
                     (let ((body (window-body-width window t)))
                       (if (zerop (or (nth 1 (window-fringes window)) 0))
                           (max cw (- body cw))
                         body))))
           (h-px (window-body-height window t))
           (cols (max 40 (/ w-px cw)))
           (rows (max 12 (floor h-px lh))))
      (etaf-batch
       (etaf-set-value (plist-get model :width) cols)
       (etaf-set-value (plist-get model :width-px) w-px)
       (etaf-set-value (plist-get model :height) rows)))))

;;;###autoload
(defun etaf-agenda-open (&optional file mount-options)
  "Open the agenda over SQLite FILE and return its buffer.
MOUNT-OPTIONS overrides automatic window fitting when provided (for tests)."
  (interactive)
  (let* ((model (etaf-agenda--make-model file))
         (keys (etaf-agenda-keys (etaf-agenda--build-handlers model)))
         (actions (etaf-agenda--build-actions model)))
    ;; Sync pinned mount-options dimensions into model before first render
    (when (consp mount-options)
      (when-let* ((vw (plist-get mount-options :viewport-width)))
        (etaf-set-value (plist-get model :width-px) vw)
        (etaf-set-value (plist-get model :width) (max 40 (if (>= vw 320) (/ vw 8) vw))))
      (when-let* ((vh (plist-get mount-options :viewport-height)))
        (etaf-set-value (plist-get model :height) (max 12 (if (> vh 120) (/ vh 16) vh)))))
    (let ((buffer
           (etaf-app-open
            etaf-agenda-buffer-name
            (etaf-agenda-view model keys etaf-agenda-help-notes actions)
            :state model
            :mode-line t
            :cursor nil
            :mount-options mount-options
            :on-fit (lambda (window)
                      (when (and window (not (consp mount-options)))
                        (etaf-agenda--sync-window model window)))
            :on-close (lambda () (etaf-agenda--release model)))))
      (etaf-agenda--prepare-buffer buffer)
      (when (and (not (consp mount-options)) (buffer-live-p buffer))
        (when-let* ((win (or (get-buffer-window buffer t) (selected-window))))
          (with-current-buffer buffer
            (etaf-agenda--sync-window model win))))
      buffer)))

;;;###autoload
(defun etaf-agenda-close ()
  "Close the agenda buffer."
  (interactive)
  (if (etaf-app-buffer etaf-agenda-buffer-name)
      (etaf-app-close etaf-agenda-buffer-name)
    (if-let* ((buf (get-buffer etaf-agenda-buffer-name)))
        (kill-buffer buf)
      (user-error "议程没有打开"))))

;;;###autoload
(defun etaf-agenda-doctor ()
  "Return capability facts about the agenda SQLite database as a plist."
  (interactive)
  (let* ((file (or (ignore-errors
                     (plist-get (plist-get (etaf-agenda--current) :store) :file))
                   etaf-agenda-database-file))
         (dir (file-name-directory file)))
    (list :file file
          :directory (and dir (file-exists-p dir))
          :writable (file-writable-p (or (and (file-exists-p file) file) dir))
          :entries (and (file-exists-p file)
                        (condition-case nil
                            (let ((store (etaf-agenda--store-open file)))
                              (unwind-protect
                                  (length (seq-remove
                                           #'etaf-agenda--deleted-p
                                           (plist-get (etaf-agenda--store-page store 'entries)
                                                      :items)))
                                (etaf-agenda--store-close store)))
                          (error nil))))))

;;;###autoload
(defun etaf-agenda-capture (text)
  "Add one entry from natural-language TEXT and return its title."
  (interactive "s记一条：")
  (let ((model (etaf-agenda--current)))
    (unless (string-empty-p (string-trim (or text "")))
      (etaf-agenda--capture model text "task"))))

;;;###autoload
(defun etaf-agenda-search (query)
  "Filter the current agenda buffer by QUERY (empty string clears search)."
  (interactive "s搜索议程：")
  (let ((model (etaf-agenda--current)))
    (etaf-agenda-set-query model (or query ""))))

;;;###autoload
(defun etaf-agenda-undo-last ()
  "Undo the most recent mutation in the current agenda buffer."
  (interactive)
  (etaf-agenda-undo (etaf-agenda--current)))

;;;###autoload
(defun etaf-agenda-add-area (name)
  "Create a new area named NAME in the current agenda buffer."
  (interactive "s新建领域名称：")
  (etaf-agenda-create-area (etaf-agenda--current) name))

;;;###autoload
(defun etaf-agenda-add-project (name &optional goal)
  "Create a new project named NAME (with optional GOAL) in the current agenda."
  (interactive "s新建项目名称：\ns项目目标（可选）：")
  (etaf-agenda-create-project (etaf-agenda--current) name nil
                              (unless (string-empty-p (string-trim (or goal ""))) goal)))

;;;###autoload
(defun etaf-agenda-add-stage (name)
  "Create a new stage named NAME in the current project."
  (interactive "s新建阶段名称：")
  (let* ((model (etaf-agenda--current))
         (pid (plist-get (etaf-agenda-plan model) :project)))
    (etaf-agenda-create-stage model pid name)))

;;;###autoload
(defun etaf-agenda-view-today ()
  "Show the 今日 page."
  (interactive)
  (etaf-agenda-set-view (etaf-agenda--current) 'today))

;;;###autoload
(defun etaf-agenda-view-calendar ()
  "Show the 日历 page."
  (interactive)
  (etaf-agenda-set-view (etaf-agenda--current) 'calendar))

;;;###autoload
(defun etaf-agenda-view-list ()
  "Show the 清单 page."
  (interactive)
  (etaf-agenda-set-view (etaf-agenda--current) 'list))

;;;###autoload
(defun etaf-agenda-view-project ()
  "Show the 项目 page."
  (interactive)
  (etaf-agenda-set-view (etaf-agenda--current) 'project))

;;;###autoload
(defun etaf-agenda-view-habits ()
  "Show the 习惯 page."
  (interactive)
  (etaf-agenda-set-view (etaf-agenda--current) 'habits))

;;;###autoload
(defun etaf-agenda-view-review ()
  "Show the 回顾 page."
  (interactive)
  (etaf-agenda-set-view (etaf-agenda--current) 'review))

(provide 'etaf-agenda-app)
;;; etaf-agenda-app.el ends here
