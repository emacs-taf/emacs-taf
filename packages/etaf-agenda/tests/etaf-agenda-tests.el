;;; etaf-agenda-tests.el --- Acceptance tests for etaf-agenda -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; Public behaviour tests.  Every scenario drives the application through the
;; interfaces declared in `etaf-agenda.el' and the keys the buffer documents,
;; and asserts what a person would see on screen.
;;
;; Batch Emacs has no window metrics, so these tests pin a realistic canvas
;; viewport and compare rendered text; real pixel geometry, light/dark themes
;; and responsive layouts are additionally verified in a GUI session.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'etaf-agenda)

(defconst etaf-agenda-tests--viewport
  (list :viewport-width 1184 :viewport-height 672)
  "Pinned canvas for batch tests: ~148 columns by 42 rows (wide desktop tier).")

(defmacro etaf-agenda-tests--with-app (&rest body)
  "Run BODY with a fresh agenda buffer over a temporary database."
  (declare (indent 0) (debug t))
  `(let ((file (make-temp-file "etaf-agenda-test" nil ".sqlite3")))
     (unwind-protect
         (let ((buffer (etaf-agenda-open file etaf-agenda-tests--viewport)))
           (unwind-protect
               (with-current-buffer buffer
                 ,@body)
             (when (buffer-live-p buffer)
               (with-current-buffer buffer (etaf-agenda-close)))))
       (ignore-errors (delete-file file)))))

(defun etaf-agenda-tests--text (buffer)
  "Return BUFFER's visible text without properties."
  (with-current-buffer buffer
    (buffer-substring-no-properties (point-min) (point-max))))

(defun etaf-agenda-tests--plain (buffer)
  "Return BUFFER's text with spaces, tabs, newlines and box rules removed."
  (replace-regexp-in-string "[ \t\n│─┌┐└┘]+" "" (etaf-agenda-tests--text buffer)))

(defun etaf-agenda-tests--line-of (buffer needle)
  "Return the line of BUFFER that holds NEEDLE, or nil."
  (with-current-buffer buffer
    (save-excursion
      (goto-char (point-min))
      (when (search-forward needle nil t)
        (buffer-substring-no-properties (line-beginning-position)
                                        (line-end-position))))))

(defun etaf-agenda-tests--keys (buffer keys)
  "Send KEYS to BUFFER through the command loop."
  (with-current-buffer buffer
    (execute-kbd-macro keys)))

(defun etaf-agenda-tests--today-label ()
  "Return today's label the way the day header formats it."
  (let ((parts (decode-time (current-time))))
    (format "%d 月 %d 日" (nth 4 parts) (nth 3 parts))))

(defun etaf-agenda-tests--yesterday-iso ()
  "Return yesterday's YYYY-MM-DD date string."
  (format-time-string "%Y-%m-%d" (time-subtract (current-time) (days-to-time 1))))

(defun etaf-agenda-tests--has-p (buffer needle)
  "Return non-nil when NEEDLE appears in BUFFER's whitespace-free text."
  (and (string-match-p (regexp-quote (replace-regexp-in-string "[ \t\n]+" "" needle))
                       (etaf-agenda-tests--plain buffer))
       t))

;;; ---------------------------------------------------------------------------
;;; Core mount, layout chrome & capture grammar
;;; ---------------------------------------------------------------------------

(ert-deftest etaf-agenda-tests-open-shows-today-and-preserves-modeline ()
  "Opening mounts Today with date, tabs, sidebar, quiet hint bar and mode-line."
  (etaf-agenda-tests--with-app
    (let ((live (buffer-live-p buffer))
          (ml mode-line-format)
          (today-ok (etaf-agenda-tests--has-p buffer (etaf-agenda-tests--today-label)))
          (tabs-ok (and (etaf-agenda-tests--has-p buffer "今日")
                        (etaf-agenda-tests--has-p buffer "日历")
                        (etaf-agenda-tests--has-p buffer "清单")
                        (etaf-agenda-tests--has-p buffer "项目")
                        (etaf-agenda-tests--has-p buffer "习惯")
                        (etaf-agenda-tests--has-p buffer "回顾")))
          (sidebar-ok (and (etaf-agenda-tests--has-p buffer "领域")
                           (etaf-agenda-tests--has-p buffer "收件箱")))
          (no-prefix-clutter (not (string-match-p "1 今日" (etaf-agenda-tests--text buffer)))))
      (should live)
      (should ml)
      (should today-ok)
      (should tabs-ok)
      (should sidebar-ok)
      (should no-prefix-clutter))))

(ert-deftest etaf-agenda-tests-capture-natural-language-grammar ()
  "Capture parses dates, time ranges, priority, tags, area, project, estimate and kinds."
  (etaf-agenda-tests--with-app
    (etaf-agenda-capture "设计评审 10:00-11:30 !1 #UI @工作 +网站改版 ~45m")
    (etaf-agenda-capture "整理接口文档 ~45m")
    (etaf-agenda-capture "- 侧栏用 1px 细线比色块更耐看")
    (etaf-agenda-capture "? 周视图是否需要支持快速跳转")
    (etaf-agenda-capture "明天 15:00 同步站会 @工作")
    (let ((today-plain (etaf-agenda-tests--plain buffer)))
      (should (string-match-p "设计评审" today-plain))
      (should (string-match-p "10:00–11:30" today-plain))
      (should (string-match-p "P1" today-plain))
      (should (string-match-p "整理接口文档" today-plain))
      (should (string-match-p "45分" today-plain))
      (should (string-match-p "工作" today-plain))
      (should (string-match-p "网站改版" today-plain))
      (should (string-match-p "侧栏用1px细线比色块更耐看" today-plain))
      (should (string-match-p "周视图是否需要支持快速跳转" today-plain))
      (should-not (etaf-agenda-tests--line-of buffer "15:00")))
    ;; Navigate to tomorrow with `l'
    (etaf-agenda-tests--keys buffer "l")
    (let ((tom-plain (etaf-agenda-tests--plain buffer)))
      (should (string-match-p "同步站会" tom-plain))
      (should (string-match-p "15:00" tom-plain)))
    ;; Back to today with `t'
    (etaf-agenda-tests--keys buffer "t")
    (should (etaf-agenda-tests--has-p buffer "设计评审"))))

;;; ---------------------------------------------------------------------------
;;; Navigation & in-place capture / editing across pages
;;; ---------------------------------------------------------------------------

(ert-deftest etaf-agenda-tests-j-k-navigation-and-page-digits ()
  "j/k step through rows and digits 1..6 always switch views without hijacking."
  (etaf-agenda-tests--with-app
    (etaf-agenda-capture "第一条任务")
    (etaf-agenda-capture "第二条任务")
    ;; Select first row, step down to second, complete only second
    (etaf-agenda-tests--keys buffer "j")
    (etaf-agenda-tests--keys buffer "j")
    (etaf-agenda-tests--keys buffer "x")
    (let ((line1 (etaf-agenda-tests--line-of buffer "第一条任务"))
          (line2 (etaf-agenda-tests--line-of buffer "第二条任务")))
      (should line1)
      (should line2)
      (should (string-match-p "已完成" line2))
      (should-not (string-match-p "已完成" line1)))
    ;; Digits 1..6 switch views even while a row is selected
    (etaf-agenda-tests--keys buffer "2")
    (should (etaf-agenda-tests--has-p buffer "月视图"))
    (etaf-agenda-tests--keys buffer "3")
    (should (etaf-agenda-tests--has-p buffer "时间"))
    (etaf-agenda-tests--keys buffer "4")
    (should (etaf-agenda-tests--has-p buffer "项目"))
    (etaf-agenda-tests--keys buffer "5")
    (should (etaf-agenda-tests--has-p buffer "习惯"))
    (etaf-agenda-tests--keys buffer "6")
    (should (etaf-agenda-tests--has-p buffer "月度回顾"))
    (etaf-agenda-tests--keys buffer "1")
    (should (etaf-agenda-tests--has-p buffer "第一条任务"))))

(ert-deftest etaf-agenda-tests-inline-capture-works-across-pages ()
  "Pressing a opens inline capture and commits on Today, Calendar, List, Project and Habits."
  (etaf-agenda-tests--with-app
    ;; Today
    (etaf-agenda-tests--keys buffer "a今日原位任务")
    (etaf-agenda-tests--keys buffer (kbd "RET"))
    (should (etaf-agenda-tests--has-p buffer "今日原位任务"))
    ;; Calendar
    (etaf-agenda-view-calendar)
    (etaf-agenda-tests--keys buffer "a日历原位日程 16:00")
    (etaf-agenda-tests--keys buffer (kbd "RET"))
    (should (etaf-agenda-tests--has-p buffer "日历原位日程"))
    ;; List
    (etaf-agenda-view-list)
    (etaf-agenda-tests--keys buffer "a清单原位待办")
    (etaf-agenda-tests--keys buffer (kbd "RET"))
    (should (etaf-agenda-tests--has-p buffer "清单原位待办"))
    ;; Project
    (etaf-agenda-add-project "示例项目" "交付测试")
    (etaf-agenda-tests--keys buffer "a项目原位里程碑")
    (etaf-agenda-tests--keys buffer (kbd "RET"))
    (should (etaf-agenda-tests--has-p buffer "项目原位里程碑"))
    ;; Habits: creates a real habit even without typing 每天!
    (etaf-agenda-view-habits)
    (etaf-agenda-tests--keys buffer "a冥想 10 分钟")
    (etaf-agenda-tests--keys buffer (kbd "RET"))
    (should (etaf-agenda-tests--has-p buffer "冥想10分钟"))
    (should (etaf-agenda-tests--has-p buffer "0/7"))))

(ert-deftest etaf-agenda-tests-inline-edit-updates-title-and-escape-cancels ()
  "e opens inline title edit, RET commits the rename, and C-c C-k cancels cleanly."
  (etaf-agenda-tests--with-app
    (etaf-agenda-capture "原始标题")
    (etaf-agenda-tests--keys buffer "j")
    ;; Cancel via C-c C-k keeps original title and closes inline editor
    (etaf-agenda-tests--keys buffer "e")
    (etaf-agenda-tests--keys buffer (kbd "C-c C-k"))
    (should (etaf-agenda-tests--has-p buffer "原始标题"))
    ;; Edit again, backspace 4 chars of "原始标题", and submit new title
    (etaf-agenda-tests--keys buffer "e")
    (dotimes (_ 4)
      (etaf-agenda-tests--keys buffer (kbd "DEL")))
    (etaf-agenda-tests--keys buffer "修改后的新标题")
    (etaf-agenda-tests--keys buffer (kbd "RET"))
    (should (etaf-agenda-tests--has-p buffer "修改后的新标题"))
    (should-not (etaf-agenda-tests--has-p buffer "原始标题"))))

;;; ---------------------------------------------------------------------------
;;; Core mutations: x toggle, overdue, recurrence, smart migrate, undo
;;; ---------------------------------------------------------------------------

(ert-deftest etaf-agenda-tests-x-completes-today-and-overdue-and-persists ()
  "x completes both today's tasks and overdue tasks, surviving a reopen."
  (etaf-agenda-tests--with-app
    (etaf-agenda-capture (format "%s 补齐逾期复盘" (etaf-agenda-tests--yesterday-iso)))
    (etaf-agenda-capture "今日常规待办")
    ;; Overdue section appears first; latest capture is today's row, so k steps up to overdue
    (should (etaf-agenda-tests--has-p buffer "逾期"))
    (should (etaf-agenda-tests--has-p buffer "补齐逾期复盘"))
    (etaf-agenda-tests--keys buffer "k")
    (etaf-agenda-tests--keys buffer "x")
    ;; Completing an overdue task clears Overdue and marks it done today
    (should-not (etaf-agenda-tests--has-p buffer "逾期 1"))
    (let ((over-line (etaf-agenda-tests--line-of buffer "补齐逾期复盘")))
      (should over-line)
      (should (string-match-p "已完成" over-line)))
    ;; Select today's open task (now above the completed item) and complete it
    (etaf-agenda-tests--keys buffer "k")
    (etaf-agenda-tests--keys buffer "x")
    (let ((line (etaf-agenda-tests--line-of buffer "今日常规待办")))
      (should line)
      (should (string-match-p "已完成" line)))
    ;; Reopen from disk and confirm persistence
    (etaf-agenda-close)
    (let ((reopened (etaf-agenda-open file etaf-agenda-tests--viewport)))
      (unwind-protect
          (with-current-buffer reopened
            (let ((rline (etaf-agenda-tests--line-of reopened "今日常规待办"))
                  (oline (etaf-agenda-tests--line-of reopened "补齐逾期复盘")))
              (should rline)
              (should (string-match-p "已完成" rline))
              (should oline)
              (should (string-match-p "已完成" oline)))
            (should-not (etaf-agenda-tests--has-p reopened "逾期 1")))
        (when (buffer-live-p reopened)
          (with-current-buffer reopened (etaf-agenda-close)))))))

(ert-deftest etaf-agenda-tests-recurring-task-spawns-next-day ()
  "Completing a recurring task spawns the next scheduled occurrence."
  (etaf-agenda-tests--with-app
    (etaf-agenda-capture "检查线上告警 重复:每天")
    (etaf-agenda-tests--keys buffer "j")
    (etaf-agenda-tests--keys buffer "x")
    (let ((today-line (etaf-agenda-tests--line-of buffer "检查线上告警")))
      (should today-line)
      (should (string-match-p "已完成" today-line)))
    ;; Tomorrow has a fresh open copy
    (etaf-agenda-tests--keys buffer "l")
    (let ((tom-line (etaf-agenda-tests--line-of buffer "检查线上告警")))
      (should tom-line)
      (should-not (string-match-p "已完成" tom-line)))))

(ert-deftest etaf-agenda-tests-smart-migrate-pull-back-and-batch-overdue ()
  "m migrates today->tomorrow, pulls migrated rows back cleanly, and M clears overdue."
  (etaf-agenda-tests--with-app
    (etaf-agenda-capture "推到明天的事项")
    (etaf-agenda-tests--keys buffer "j")
    ;; Migrate to tomorrow
    (etaf-agenda-tests--keys buffer "m")
    (should (etaf-agenda-tests--has-p buffer "已迁移"))
    ;; Verify tomorrow has it
    (etaf-agenda-tests--keys buffer "l")
    (should (etaf-agenda-tests--has-p buffer "推到明天的事项"))
    ;; Go back to today and press m again on the migrated row -> pulls back cleanly!
    (etaf-agenda-tests--keys buffer "h")
    (etaf-agenda-tests--keys buffer "j")
    (etaf-agenda-tests--keys buffer "m")
    (should (etaf-agenda-tests--has-p buffer "推到明天的事项"))
    (should-not (etaf-agenda-tests--has-p buffer "已迁移"))
    ;; Batch overdue migration with M
    (etaf-agenda-capture (format "%s 逾期项一" (etaf-agenda-tests--yesterday-iso)))
    (etaf-agenda-capture (format "%s 逾期项二" (etaf-agenda-tests--yesterday-iso)))
    (should (etaf-agenda-tests--has-p buffer "逾期 2"))
    (etaf-agenda-tests--keys buffer "M")
    (should-not (etaf-agenda-tests--has-p buffer "逾期 2"))
    (should (etaf-agenda-tests--has-p buffer "逾期项一"))
    (should (etaf-agenda-tests--has-p buffer "逾期项二"))))

(ert-deftest etaf-agenda-tests-delete-drop-and-undo-restore ()
  "d soft-deletes, z drops, and u / `etaf-agenda-undo-last' restores them cleanly."
  (etaf-agenda-tests--with-app
    (etaf-agenda-capture "可恢复的事项")
    (etaf-agenda-tests--keys buffer "j")
    ;; Soft delete
    (etaf-agenda-tests--keys buffer "d")
    (should-not (etaf-agenda-tests--has-p buffer "可恢复的事项"))
    ;; Undo restores it
    (etaf-agenda-tests--keys buffer "u")
    (should (etaf-agenda-tests--has-p buffer "可恢复的事项"))
    ;; Drop and undo via public function
    (etaf-agenda-tests--keys buffer "j")
    (etaf-agenda-tests--keys buffer "z")
    (should-not (etaf-agenda-tests--has-p buffer "可恢复的事项"))
    (etaf-agenda-undo-last)
    (should (etaf-agenda-tests--has-p buffer "可恢复的事项"))))

;;; ---------------------------------------------------------------------------
;;; Right-rail Inspector, status/priority cycling & layered Escape
;;; ---------------------------------------------------------------------------

(ert-deftest etaf-agenda-tests-inspector-status-priority-and-layered-escape ()
  "RET opens the right-rail Inspector, s/! edit fields, and Escape closes keeping selection."
  (etaf-agenda-tests--with-app
    (etaf-agenda-capture "核心评审任务 @工作 ~30m")
    (etaf-agenda-tests--keys buffer "j")
    ;; Open right-rail inspector
    (etaf-agenda-tests--keys buffer (kbd "RET"))
    (let ((insp (etaf-agenda-tests--plain buffer)))
      (should (string-match-p "详情" insp))
      (should (string-match-p "计划日" insp))
      (should (string-match-p "工作" insp))
      (should (string-match-p "30分" insp))
      (should (string-match-p "备注" insp))
      (should (string-match-p "历史记录" insp)))
    ;; Cycle status (open -> doing) and priority (nil -> P1)
    (etaf-agenda-tests--keys buffer "s")
    (should (etaf-agenda-tests--has-p buffer "在做"))
    (etaf-agenda-tests--keys buffer "!")
    (should (etaf-agenda-tests--has-p buffer "P1"))
    ;; First Escape closes inspector while keeping selection intact
    (etaf-agenda-tests--keys buffer (kbd "<escape>"))
    (should-not (etaf-agenda-tests--has-p buffer "历史记录"))
    ;; Row is still selected so x completes it immediately
    (etaf-agenda-tests--keys buffer "x")
    (let ((line (etaf-agenda-tests--line-of buffer "核心评审任务")))
      (should line)
      (should (string-match-p "已完成" line)))))

;;; ---------------------------------------------------------------------------
;;; Live search & filtering
;;; ---------------------------------------------------------------------------

(ert-deftest etaf-agenda-tests-search-filters-live-and-escape-clears ()
  "`etaf-agenda-search' filters entries across title, tags and area; Escape clears it."
  (etaf-agenda-tests--with-app
    (etaf-agenda-capture "编写架构文档 #doc @工作")
    (etaf-agenda-capture "买咖啡豆与牛奶 @生活")
    (etaf-agenda-search "doc")
    (should (etaf-agenda-tests--has-p buffer "编写架构文档"))
    (should-not (etaf-agenda-tests--has-p buffer "买咖啡豆与牛奶"))
    (etaf-agenda-tests--keys buffer (kbd "<escape>"))
    (should (etaf-agenda-tests--has-p buffer "编写架构文档"))
    (should (etaf-agenda-tests--has-p buffer "买咖啡豆与牛奶"))))

;;; ---------------------------------------------------------------------------
;;; Calendar, List, Project, Habits & Review views
;;; ---------------------------------------------------------------------------

(ert-deftest etaf-agenda-tests-calendar-month-week-and-rail ()
  "Calendar cycles Month/Week/Year with w, uses 本年/本月/本周 steppers and keeps rail synced."
  (etaf-agenda-tests--with-app
    (etaf-agenda-capture "团队周会 10:00-11:00")
    (etaf-agenda-capture "整理周报草稿")
    (etaf-agenda-view-calendar)
    ;; Month mode: anchored mode tabs left, 本月 stepper right, both events & tasks in rail
    (let ((plain (etaf-agenda-tests--plain buffer)))
      (should (string-match-p "年视图" plain))
      (should (string-match-p "月视图" plain))
      (should (string-match-p "周视图" plain))
      (should (string-match-p "‹上月" plain))
      (should (string-match-p "本月" plain))
      (should (string-match-p "下月›" plain))
      (should (string-match-p "团队周会" plain))
      (should (string-match-p "整理周报草稿" plain))
      (should-not (string-match-p "当天的排期" plain)))
    ;; Toggle to 7-column Week Calendar Grid
    (etaf-agenda-tests--keys buffer "w")
    (let ((week-plain (etaf-agenda-tests--plain buffer)))
      (should (string-match-p "‹上周" week-plain))
      (should (string-match-p "本周" week-plain))
      (should (string-match-p "下周›" week-plain))
      (should (string-match-p "第[0-9]+周" week-plain))
      (should (string-match-p "\\[/\\]切周" week-plain))
      (should (string-match-p "团队周会" week-plain))
      (should (string-match-p "整理周报草稿" week-plain)))
    ;; In Week mode [ / ] shift by week cleanly, and t returns to today
    (etaf-agenda-tests--keys buffer "[")
    (etaf-agenda-tests--keys buffer "t")
    (should (etaf-agenda-tests--has-p buffer "团队周会"))
    ;; Toggle to 12-month Year Grid
    (etaf-agenda-tests--keys buffer "w")
    (let ((year-plain (etaf-agenda-tests--plain buffer)))
      (should (string-match-p "‹上年" year-plain))
      (should (string-match-p "本年" year-plain))
      (should (string-match-p "下年›" year-plain))
      (should (string-match-p "\\[/\\]切年" year-plain))
      (should (string-match-p "1月" year-plain))
      (should (string-match-p "4月" year-plain))
      (should (string-match-p "7月" year-plain))
      (should (string-match-p "12月" year-plain))
      (should (string-match-p "团队周会" year-plain)))
    ;; In Year mode [ / ] shift by year cleanly, and t returns to current year
    (let ((cur-year (format-time-string "%Y 年" (current-time)))
          (prev-year (format "%d 年" (1- (string-to-number (format-time-string "%Y" (current-time)))))))
      (etaf-agenda-tests--keys buffer "[")
      (should (etaf-agenda-tests--has-p buffer prev-year))
      (etaf-agenda-tests--keys buffer "t")
      (should (etaf-agenda-tests--has-p buffer cur-year)))
    ;; Cycle back to Month view and shift month cleanly
    (etaf-agenda-tests--keys buffer "w")
    (etaf-agenda-tests--keys buffer "[")
    (etaf-agenda-tests--keys buffer "t")
    (should (etaf-agenda-tests--has-p buffer "团队周会"))))

(ert-deftest etaf-agenda-tests-list-grouping-and-done-state ()
  "List cycles all 4 groupings with g, toggles completed with H, and reflects true done state."
  (etaf-agenda-tests--with-app
    (etaf-agenda-capture "完成接口设计 @工作 +改版 !1")
    (etaf-agenda-capture "预约体检 @健康")
    ;; Complete first task on Today
    (etaf-agenda-tests--keys buffer "j")
    (etaf-agenda-tests--keys buffer "x")
    ;; Switch to List: completed task must NOT show as open/overdue
    (etaf-agenda-view-list)
    (should (etaf-agenda-tests--has-p buffer "预约体检"))
    ;; Cycle all 4 groupings: time -> area -> project -> status -> time
    (etaf-agenda-tests--keys buffer "g")
    (should (etaf-agenda-tests--has-p buffer "健康"))
    (etaf-agenda-tests--keys buffer "g")
    (should (etaf-agenda-tests--has-p buffer "一次性任务"))
    (etaf-agenda-tests--keys buffer "g")
    (should (etaf-agenda-tests--has-p buffer "预约体检"))
    ;; Show completed with H
    (etaf-agenda-tests--keys buffer "H")
    (should (etaf-agenda-tests--has-p buffer "完成接口设计"))))

(ert-deftest etaf-agenda-tests-project-stages-and-real-progress ()
  "Projects support adding stages, binding +project tasks, and real completion progress."
  (etaf-agenda-tests--with-app
    (etaf-agenda-add-area "工作")
    (etaf-agenda-add-project "网站改版" "完成 0.2 视觉升级")
    (etaf-agenda-add-stage "设计")
    (etaf-agenda-add-stage "研发")
    (etaf-agenda-capture "画线框稿 +网站改版")
    (etaf-agenda-capture "落地首页组件 +网站改版")
    (etaf-agenda-view-project)
    (let ((plain (etaf-agenda-tests--plain buffer)))
      (should (string-match-p "网站改版" plain))
      (should (string-match-p "完成0.2视觉升级" plain))
      (should (string-match-p "设计" plain))
      (should (string-match-p "研发" plain))
      (should (string-match-p "0/2" plain)))
    ;; Complete one task directly from the Project page!
    (etaf-agenda-tests--keys buffer "j")
    (etaf-agenda-tests--keys buffer "x")
    (let ((after (etaf-agenda-tests--plain buffer)))
      (should (string-match-p "1/2" after))
      (should (string-match-p "50%" after)))))

(ert-deftest etaf-agenda-tests-habits-checkin-and-day-navigation ()
  "Habits show 21-day matrix, support x toggle and h/l day cursor navigation."
  (etaf-agenda-tests--with-app
    (etaf-agenda-capture "每天 早起阅读")
    ;; Habit does not inflate today's task count
    (should (etaf-agenda-tests--has-p buffer "待办 0"))
    (etaf-agenda-view-habits)
    (should (etaf-agenda-tests--has-p buffer "早起阅读"))
    (should (etaf-agenda-tests--has-p buffer "0/7"))
    ;; Select habit and toggle today
    (etaf-agenda-tests--keys buffer "j")
    (etaf-agenda-tests--keys buffer "x")
    (should (etaf-agenda-tests--has-p buffer "1/7"))
    ;; Step one day back with h and check off yesterday too!
    (etaf-agenda-tests--keys buffer "h")
    (etaf-agenda-tests--keys buffer "x")
    (should (etaf-agenda-tests--has-p buffer "2/7"))))

(ert-deftest etaf-agenda-tests-review-and-doctor ()
  "Review summarizes monthly completions and doctor reports database facts."
  (etaf-agenda-tests--with-app
    (etaf-agenda-capture "回顾测试项一 @工作")
    (etaf-agenda-capture "回顾测试项二 @个人")
    (etaf-agenda-tests--keys buffer "j")
    (etaf-agenda-tests--keys buffer "x")
    (etaf-agenda-view-review)
    (let ((plain (etaf-agenda-tests--plain buffer)))
      (should (string-match-p "月度回顾" plain))
      (should (string-match-p "已完成" plain))
      (should (string-match-p "完成率" plain))
      (should (string-match-p "每日完成热力" plain)))
    ;; Shift to previous month and back without error
    (etaf-agenda-tests--keys buffer "[")
    (etaf-agenda-tests--keys buffer "]")
    (let ((report (etaf-agenda-doctor)))
      (should (equal file (plist-get report :file)))
      (should (plist-get report :writable))
      (should (= 2 (plist-get report :entries))))))

(ert-deftest etaf-agenda-tests-area-filter-scopes-today-and-list ()
  "Selecting an area via f filters both Today and List to that area, and restores on 全部."
  (etaf-agenda-tests--with-app
    (etaf-agenda-add-area "工作")
    (etaf-agenda-add-area "健康")
    (etaf-agenda-capture "撰写季度方案 @工作")
    (etaf-agenda-capture "预约常规体检 @健康")
    ;; Filter to 健康 via `f'
    (cl-letf (((symbol-function 'completing-read)
               (lambda (&rest _) "领域：健康")))
      (etaf-agenda-tests--keys buffer "f"))
    (should (etaf-agenda-tests--has-p buffer "预约常规体检"))
    (should-not (etaf-agenda-tests--has-p buffer "撰写季度方案"))
    ;; Same filter holds on List view
    (etaf-agenda-view-list)
    (should (etaf-agenda-tests--has-p buffer "预约常规体检"))
    (should-not (etaf-agenda-tests--has-p buffer "撰写季度方案"))
    ;; Restore to 全部
    (cl-letf (((symbol-function 'completing-read)
               (lambda (&rest _) "全部")))
      (etaf-agenda-tests--keys buffer "f"))
    (should (etaf-agenda-tests--has-p buffer "撰写季度方案"))
    (should (etaf-agenda-tests--has-p buffer "预约常规体检"))))

(defun etaf-agenda-tests--prop-at (buffer needle prop)
  "Return text property PROP at the first occurrence of NEEDLE in BUFFER."
  (with-current-buffer buffer
    (save-excursion
      (goto-char (point-min))
      (when (search-forward needle nil t)
        (get-text-property (match-beginning 0) prop)))))

(ert-deftest etaf-agenda-tests-hover-discipline-across-views ()
  "Hover highlights stay off calendars, habit matrices, pills, active tabs and reading cards."
  (etaf-agenda-tests--with-app
    (etaf-agenda-capture "核心对齐任务 !1 @工作")
    (etaf-agenda-capture "明天 月历预览芯片")
    (etaf-agenda-capture "每天 睡前阅读")
    (etaf-agenda-capture "每天 晨跑五公里")
    ;; Today: unselected title hovers, P1 pill stays free of parent mouse-face,
    ;; active tab 今日 / current-day 今天 / tinted CTA + 新建 suppress hover.
    (let ((title-mf (etaf-agenda-tests--prop-at buffer "核心对齐任务" 'mouse-face))
          (pill-mf (etaf-agenda-tests--prop-at buffer "P1" 'mouse-face))
          (cur-tab-mf (etaf-agenda-tests--prop-at buffer "今日" 'mouse-face))
          (cur-tab-ptr (etaf-agenda-tests--prop-at buffer "今日" 'pointer))
          (other-tab-mf (etaf-agenda-tests--prop-at buffer "日历" 'mouse-face))
          (cta-mf (etaf-agenda-tests--prop-at buffer "+ 新建" 'mouse-face))
          (today-btn-mf (etaf-agenda-tests--prop-at buffer "今天" 'mouse-face))
          (today-btn-ptr (etaf-agenda-tests--prop-at buffer "今天" 'pointer)))
      (should title-mf)
      (should-not pill-mf)
      (should-not cur-tab-mf)
      (should-not cur-tab-ptr)
      (should other-tab-mf)
      (should-not cta-mf)
      (should-not today-btn-mf)
      (should-not today-btn-ptr))
    ;; Inspector: multi-line notes card, static labels and active kind pill stay calm.
    (etaf-agenda-tests--keys buffer "j")
    (etaf-agenda-tests--keys buffer (kbd "RET"))
    (let ((notes-mf (etaf-agenda-tests--prop-at buffer "点击添加备注说明" 'mouse-face))
          (label-mf (etaf-agenda-tests--prop-at buffer "计划日" 'mouse-face))
          (kind-mf (etaf-agenda-tests--prop-at buffer "待办" 'mouse-face)))
      (should-not notes-mf)
      (should-not label-mf)
      (should-not kind-mf))
    (etaf-agenda-tests--keys buffer (kbd "<escape>"))
    ;; Calendar month grid: unselected day cells and read-only chips take no
    ;; hover highlight and no hand pointer.
    (etaf-agenda-view-calendar)
    (let ((month-seg-mf (etaf-agenda-tests--prop-at buffer "月视图" 'mouse-face))
          (week-seg-mf (etaf-agenda-tests--prop-at buffer "周视图" 'mouse-face))
          (chip-mf (etaf-agenda-tests--prop-at buffer "月历" 'mouse-face))
          (chip-ptr (etaf-agenda-tests--prop-at buffer "月历" 'pointer)))
      (should-not month-seg-mf)
      (should week-seg-mf)
      (should-not chip-mf)
      (should-not chip-ptr))
    ;; Habits matrix: selected habit suppresses hover; unselected habit title
    ;; uses foreground-only hover while sub-label and numeric summary never hover.
    (etaf-agenda-view-habits)
    (let ((sel-hab-mf (etaf-agenda-tests--prop-at buffer "晨跑五公里" 'mouse-face))
          (unsel-hab-mf (etaf-agenda-tests--prop-at buffer "睡前阅读" 'mouse-face))
          (hab-sub-mf (etaf-agenda-tests--prop-at buffer "差 7 次" 'mouse-face))
          (hab-stat-mf (etaf-agenda-tests--prop-at buffer "0/7" 'mouse-face)))
      ;; Exactly one of the two habits is auto-selected (nil hover) and the other
      ;; is unselected (foreground-only hover, no background fill).
      (let ((active-mf (or sel-hab-mf unsel-hab-mf)))
        (should (or (null sel-hab-mf) (null unsel-hab-mf)))
        (should active-mf)
        (should-not (plist-get active-mf :background)))
      (should-not hab-sub-mf)
      (should-not hab-stat-mf))
    ;; Review: current month button suppresses hover & hand pointer.
    (etaf-agenda-view-review)
    (let ((curr-m-mf (etaf-agenda-tests--prop-at buffer "本月" 'mouse-face))
          (curr-m-ptr (etaf-agenda-tests--prop-at buffer "本月" 'pointer)))
      (should-not curr-m-mf)
      (should-not curr-m-ptr))))

(ert-deftest etaf-agenda-tests-lossless-undo-across-mutations ()
  "u cleanly reverts batch overdue migrate, smart migrate, recurring complete and habit check-in."
  (etaf-agenda-tests--with-app
    ;; 1. Batch overdue migrate (M) + Undo (u): zero items stuck in Today
    (etaf-agenda-capture (format "%s 逾期撤销一" (etaf-agenda-tests--yesterday-iso)))
    (etaf-agenda-capture (format "%s 逾期撤销二" (etaf-agenda-tests--yesterday-iso)))
    (should (etaf-agenda-tests--has-p buffer "逾期 2"))
    (etaf-agenda-tests--keys buffer "M")
    (should-not (etaf-agenda-tests--has-p buffer "逾期 2"))
    (should (etaf-agenda-tests--has-p buffer "待办 2"))
    (etaf-agenda-tests--keys buffer "u")
    (should (etaf-agenda-tests--has-p buffer "逾期 2"))
    (should (etaf-agenda-tests--has-p buffer "待办 0"))
    ;; 2. Smart migrate today->tomorrow (m) + Undo (u): removes tomorrow ghost
    (etaf-agenda-capture "智能迁移撤销项")
    (etaf-agenda-tests--keys buffer "m")
    (should (etaf-agenda-tests--has-p buffer "已迁移"))
    (etaf-agenda-tests--keys buffer "l")
    (should (etaf-agenda-tests--has-p buffer "待办 1"))
    (etaf-agenda-tests--keys buffer "h")
    (etaf-agenda-tests--keys buffer "u")
    (should-not (etaf-agenda-tests--has-p buffer "已迁移"))
    (etaf-agenda-tests--keys buffer "l")
    ;; Tomorrow has 0 scheduled tasks (no ghost tomorrow instance left behind)
    (should (etaf-agenda-tests--has-p buffer "待办 0"))
    (etaf-agenda-tests--keys buffer "h")
    ;; 3. Recurring task complete (x) + Undo (u): removes next-cycle ghost
    (etaf-agenda-capture "循环撤销校验 重复:每天")
    (etaf-agenda-tests--keys buffer "x")
    (let ((done-line (etaf-agenda-tests--line-of buffer "循环撤销校验")))
      (should (and done-line (string-match-p "已完成" done-line))))
    (etaf-agenda-tests--keys buffer "l")
    (should (etaf-agenda-tests--has-p buffer "待办 1"))
    (etaf-agenda-tests--keys buffer "h")
    (etaf-agenda-tests--keys buffer "u")
    (let ((reverted-line (etaf-agenda-tests--line-of buffer "循环撤销校验")))
      (should (and reverted-line (not (string-match-p "已完成" reverted-line)))))
    (etaf-agenda-tests--keys buffer "l")
    (should (etaf-agenda-tests--has-p buffer "待办 0"))
    (etaf-agenda-tests--keys buffer "h")
    ;; 4. Habit check-in (x) + Undo (u): reverts newly created habit instance
    (etaf-agenda-capture "每天 冥想撤销测试")
    (etaf-agenda-view-habits)
    (should (etaf-agenda-tests--has-p buffer "0/7"))
    (etaf-agenda-tests--keys buffer "x")
    (should (etaf-agenda-tests--has-p buffer "1/7"))
    (etaf-agenda-tests--keys buffer "u")
    (should (etaf-agenda-tests--has-p buffer "0/7"))))

(ert-deftest etaf-agenda-tests-reschedule-and-clear-date-remove-stale-day ()
  "Rescheduling or clearing scheduled date removes stale instances from old day and undoes cleanly."
  (etaf-agenda-tests--with-app
    (etaf-agenda-capture "改期去重校验")
    ;; Reschedule to tomorrow via S -> gone from today, appears on tomorrow
    (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) "明天")))
      (etaf-agenda-tests--keys buffer "S"))
    (should-not (etaf-agenda-tests--has-p buffer "改期去重校验"))
    (should (etaf-agenda-tests--has-p buffer "待办 0"))
    (etaf-agenda-tests--keys buffer "l")
    (should (etaf-agenda-tests--has-p buffer "改期去重校验"))
    (should (etaf-agenda-tests--has-p buffer "待办 1"))
    ;; Undo removes tomorrow's copy and restores it to today
    (etaf-agenda-tests--keys buffer "u")
    (should (etaf-agenda-tests--has-p buffer "待办 0"))
    (etaf-agenda-tests--keys buffer "h")
    (should (etaf-agenda-tests--has-p buffer "改期去重校验"))
    (should (etaf-agenda-tests--has-p buffer "待办 1"))
    ;; Clear scheduled date via S -> removes completely from today; u restores
    (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) "清除日期")))
      (etaf-agenda-tests--keys buffer "S"))
    (should-not (etaf-agenda-tests--has-p buffer "改期去重校验"))
    (should (etaf-agenda-tests--has-p buffer "待办 0"))
    (etaf-agenda-tests--keys buffer "u")
    (should (etaf-agenda-tests--has-p buffer "改期去重校验"))
    (should (etaf-agenda-tests--has-p buffer "待办 1"))))

(ert-deftest etaf-agenda-tests-inline-capture-on-review-and-empty-project ()
  "a opens visible inline capture on both empty Project page and Review page."
  (etaf-agenda-tests--with-app
    ;; Empty Project page (0 projects)
    (etaf-agenda-view-project)
    (etaf-agenda-tests--keys buffer "a")
    (etaf-agenda-tests--keys buffer "空项目页新建校验\r")
    ;; Review page
    (etaf-agenda-view-review)
    (etaf-agenda-tests--keys buffer "a")
    (etaf-agenda-tests--keys buffer "回顾页新建校验\r")
    ;; Both entries were committed and show up on Today
    (etaf-agenda-view-today)
    (should (etaf-agenda-tests--has-p buffer "空项目页新建校验"))
    (should (etaf-agenda-tests--has-p buffer "回顾页新建校验"))))

(ert-deftest etaf-agenda-tests-inspector-title-edit-recurrence-and-body-actions ()
  "Inspector supports inline title edit on Calendar, recurrence on regular tasks and explicit notes buttons."
  (etaf-agenda-tests--with-app
    (etaf-agenda-capture "详情原位编辑原名")
    ;; Switch to Calendar where no center entry-row exists, open Inspector, edit title via e
    (etaf-agenda-view-calendar)
    (etaf-agenda-tests--keys buffer (kbd "RET"))
    (let ((insp (etaf-agenda-tests--plain buffer)))
      (should (string-match-p "重复" insp))
      (should (string-match-p "不重复" insp)))
    (etaf-agenda-tests--keys buffer "e")
    (etaf-agenda-tests--keys buffer (kbd "C-a C-k"))
    (etaf-agenda-tests--keys buffer "日历详情改名成功\r")
    (should (etaf-agenda-tests--has-p buffer "日历详情改名成功"))
    ;; Click 编辑 on 备注 -> shows 保存 / 取消 and C-c C-c hint
    (let ((pos (with-current-buffer buffer
                 (save-excursion
                   (goto-char (point-min))
                   (when (search-forward "编辑" nil t)
                     (match-beginning 0))))))
      (should pos)
      (with-current-buffer buffer
        (let* ((map (get-text-property pos 'keymap))
               (cmd (and (keymapp map) (lookup-key map [mouse-1])))
               (last-input-event (list 'mouse-1 (list (selected-window) pos '(0 . 0) 0))))
          (should (commandp cmd))
          (command-execute cmd))))
    (let ((editing-plain (etaf-agenda-tests--plain buffer)))
      (should (string-match-p "保存" editing-plain))
      (should (string-match-p "取消" editing-plain))
      (should-not (string-match-p "按RET保存" editing-plain)))))

(defun etaf-agenda-tests--rendered-x-of (buffer needle &optional max-x)
  "Return the rendered pixel X offset of NEEDLE from its line start in BUFFER.
When MAX-X is non-nil, skip matches at or beyond pixel MAX-X."
  (with-current-buffer buffer
    (save-excursion
      (goto-char (point-min))
      (let ((found nil)
            (cw (max 1 (frame-char-width))))
        (while (and (not found) (search-forward needle nil t))
          (let ((mb (match-beginning 0))
                (p (line-beginning-position))
                (px 0))
            (while (< p mb)
              (let ((disp (get-text-property p 'display)))
                (if (and (consp disp) (eq (car disp) 'space))
                    (let ((w (plist-get (cdr disp) :width))
                          (nxt (or (next-single-property-change p 'display nil mb) mb)))
                      (setq px (+ px (cond ((and (consp w) (numberp (car w))) (car w))
                                           ((numberp w) (* w cw))
                                           (t 0)))
                            p nxt))
                  (setq px (+ px (* (char-width (char-after p)) cw))
                        p (1+ p)))))
            (when (or (null max-x) (< px max-x))
              (setq found px))))
        found))))

(ert-deftest etaf-agenda-tests-zero-jitter-selection-and-anchored-headers ()
  "Calendar mode switchers, steppers and day selection keep exact pixels without jitter."
  (etaf-agenda-tests--with-app
    (etaf-agenda-capture "防抖日程 10:00-11:00")
    (etaf-agenda-capture "防抖任务")
    (etaf-agenda-capture "每天 真实今日锚定习惯")
    ;; 1. Today header: stepper ‹ / 今天 / › sits to the right of progress counter
    (let ((cnt-x (etaf-agenda-tests--rendered-x-of buffer "0/1"))
          (step-x (etaf-agenda-tests--rendered-x-of buffer "今天")))
      (should cnt-x)
      (should step-x)
      (should (< cnt-x step-x)))
    ;; 2. List header: 隐藏已完成 sits to the right of total count
    (etaf-agenda-view-list)
    (let ((cnt-x (etaf-agenda-tests--rendered-x-of buffer "2 条"))
          (tog-x (etaf-agenda-tests--rendered-x-of buffer "隐藏已完成")))
      (should cnt-x)
      (should tog-x)
      (should (< cnt-x tog-x)))
    ;; 3. Calendar header: left [年视图|月视图|周视图] & right stepper stay at exact pixel X
    ;;    across Month, Week and Year modes (0-pixel shift!)
    (etaf-agenda-view-calendar)
    (let ((m-year-btn (etaf-agenda-tests--rendered-x-of buffer "年视图"))
          (m-step (etaf-agenda-tests--rendered-x-of buffer "‹ 上月"))
          (m-mid (etaf-agenda-tests--rendered-x-of buffer "本月"))
          (m-ev-before (etaf-agenda-tests--rendered-x-of buffer "10:00" 900)))
      ;; Move selection in Month view: 10:00 chip pixel X must not shift!
      (etaf-agenda-tests--keys buffer "l")
      (let ((m-ev-after (etaf-agenda-tests--rendered-x-of buffer "10:00" 900)))
        (should m-ev-before)
        (should (= m-ev-before m-ev-after)))
      (etaf-agenda-tests--keys buffer "h")
      ;; Switch to Week mode
      (etaf-agenda-tests--keys buffer "w")
      (let ((w-year-btn (etaf-agenda-tests--rendered-x-of buffer "年视图"))
            (w-step (etaf-agenda-tests--rendered-x-of buffer "‹ 上周"))
            (w-mid (etaf-agenda-tests--rendered-x-of buffer "本周"))
            (w-ev-before (etaf-agenda-tests--rendered-x-of buffer "10:00" 900)))
        (should (= m-year-btn w-year-btn))
        (should (= m-step w-step))
        (should (= m-mid w-mid))
        ;; Move selection by 1 day in Week view: 10:00 card pixel X must NOT jitter!
        (etaf-agenda-tests--keys buffer "l")
        (let ((w-ev-after (etaf-agenda-tests--rendered-x-of buffer "10:00" 900)))
          (should w-ev-before)
          (should (= w-ev-before w-ev-after)))
        (etaf-agenda-tests--keys buffer "h"))
      ;; Switch to Year mode
      (etaf-agenda-tests--keys buffer "w")
      (let ((y-year-btn (etaf-agenda-tests--rendered-x-of buffer "年视图"))
            (y-step (etaf-agenda-tests--rendered-x-of buffer "‹ 上年"))
            (y-mid (etaf-agenda-tests--rendered-x-of buffer "本年"))
            (y-m1-before (etaf-agenda-tests--rendered-x-of buffer "1 月" 900))
            (y-m4-before (etaf-agenda-tests--rendered-x-of buffer "4 月" 900)))
        (should (= m-year-btn y-year-btn))
        (should (= m-step y-step))
        (should (= m-mid y-mid))
        ;; Step month selection in Year view: permanent reserved border gives 0-pixel jitter!
        (etaf-agenda-tests--keys buffer "l")
        (should (= y-m1-before (etaf-agenda-tests--rendered-x-of buffer "1 月" 900)))
        (should (= y-m4-before (etaf-agenda-tests--rendered-x-of buffer "4 月" 900)))
        (etaf-agenda-tests--keys buffer "h")))
    ;; 4. Habits view stays anchored to real today even if Today view stepped to yesterday
    (etaf-agenda-view-today)
    (etaf-agenda-tests--keys buffer "h")
    (etaf-agenda-view-habits)
    (let ((today-short (format-time-string "%m-%d" (current-time))))
      (should (etaf-agenda-tests--has-p buffer (format "当前光标日 %s" today-short))))))

(defun etaf-agenda-tests--wcag-luminance (hex)
  "Compute WCAG 2.1 relative luminance for colour HEX."
  (pcase-let ((`(,r ,g ,b) (color-name-to-rgb hex)))
    (cl-flet ((lin (c) (if (<= c 0.03928)
                           (/ c 12.92)
                         (expt (/ (+ c 0.055) 1.055) 2.4))))
      (+ (* 0.2126 (lin r)) (* 0.7152 (lin g)) (* 0.0722 (lin b))))))

(defun etaf-agenda-tests--wcag-contrast (fg bg)
  "Compute WCAG 2.1 contrast ratio between FG and BG."
  (let* ((l1 (etaf-agenda-tests--wcag-luminance fg))
         (l2 (etaf-agenda-tests--wcag-luminance bg))
         (hi (max l1 l2))
         (lo (min l1 l2)))
    (/ (+ hi 0.05) (+ lo 0.05))))

(defun etaf-agenda-tests--fg-at (buffer needle)
  "Return the rendered foreground colour of NEEDLE in BUFFER."
  (let ((face (etaf-agenda-tests--prop-at buffer needle 'face)))
    (cond
     ((and (listp face) (keywordp (car face))) (plist-get face :foreground))
     ((listp face) (cl-some (lambda (f) (and (listp f) (plist-get f :foreground))) face))
     (t nil))))

(ert-deftest etaf-agenda-tests-light-theme-contrast-and-year-summary ()
  "Light themes enforce WCAG AA contrast across muted/dim/info and Year View shows summary."
  (let* ((frame (selected-frame))
         (orig-bg (face-attribute 'default :background frame))
         (orig-fg (face-attribute 'default :foreground frame))
         (orig-shadow (face-attribute 'shadow :foreground frame))
         (orig-type (face-attribute 'font-lock-type-face :foreground frame))
         (orig-warn (face-attribute 'warning :foreground frame))
         (orig-link (face-attribute 'link :foreground frame)))
    (unwind-protect
        (progn
          ;; Simulate a worst-case light theme: bright off-white bg, faint shadow,
          ;; and pale yellow-ochre font-lock-type-face.
          (set-face-attribute 'default frame :background "#fafafa" :foreground "#1a1a1a")
          (set-face-attribute 'shadow frame :foreground "#b0b0b0")
          (set-face-attribute 'font-lock-type-face frame :foreground "#c4a000")
          (set-face-attribute 'warning frame :foreground "#b58900")
          (set-face-attribute 'link frame :foreground "#1d5dc2")
          (etaf-agenda-tests--with-app
            (etaf-agenda-capture "亮色对比度待办")
            (etaf-agenda-tests--keys buffer "x")
            (etaf-agenda-view-calendar)
            ;; Switch Month -> Week -> Year
            (etaf-agenda-tests--keys buffer "w")
            (etaf-agenda-tests--keys buffer "w")
            (let* ((plain (etaf-agenda-tests--plain buffer))
                   (info-fg (etaf-agenda-tests--fg-at buffer "日程 · 0"))
                   (dim-fg (etaf-agenda-tests--fg-at buffer "无排定日程"))
                   (done-fg (etaf-agenda-tests--fg-at buffer "亮色对比度待办"))
                   (muted-fg (etaf-agenda-tests--fg-at buffer "‹ 上年")))
              ;; Year View v2 renders all 12 months, 今 badge, annual summary & heat legend
              (should (etaf-agenda-tests--has-p buffer "1 月"))
              (should (etaf-agenda-tests--has-p buffer "12 月"))
              (should (string-match-p "今" plain))
              (should (etaf-agenda-tests--has-p buffer "全年"))
              (should (etaf-agenda-tests--has-p buffer "活跃 1 天"))
              (should (string-match-p "3–5" plain))
              (should (string-match-p "6\\+" plain))
              (should (string-match-p "选中" plain))
              ;; Every text tier meets WCAG AA contrast on #fafafa light background
              (should (and info-fg (>= (etaf-agenda-tests--wcag-contrast info-fg "#fafafa") 4.5)))
              (should (and dim-fg (>= (etaf-agenda-tests--wcag-contrast dim-fg "#fafafa") 4.5)))
              (should (and done-fg (>= (etaf-agenda-tests--wcag-contrast done-fg "#fafafa") 4.5)))
              (should (and muted-fg (>= (etaf-agenda-tests--wcag-contrast muted-fg "#fafafa") 5.2)))
              ;; :info must not stay warm yellow/ochre (blue channel must stay cool/distinct)
              (pcase-let ((`(,r ,g ,b) (color-name-to-rgb info-fg)))
                (should-not (and (> r 0.40) (> g 0.30) (> (- (min r g) b) 0.16)))))))
      (set-face-attribute 'default frame :background orig-bg :foreground orig-fg)
      (set-face-attribute 'shadow frame :foreground orig-shadow)
      (set-face-attribute 'font-lock-type-face frame :foreground orig-type)
      (set-face-attribute 'warning frame :foreground orig-warn)
      (set-face-attribute 'link frame :foreground orig-link))))

(provide 'etaf-agenda-tests)
;;; etaf-agenda-tests.el ends here
