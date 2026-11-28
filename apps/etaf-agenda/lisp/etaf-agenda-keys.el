;;; etaf-agenda-keys.el --- Key binding table and help notes of etaf-agenda -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; Declares the concise, conflict-free root Host `:keys' and `:help' notes for
;; `etaf-agenda'.  Framework-reserved keys (`Escape', `Tab', `S-Tab', `?',
;; `M-g', `C-g' and physical arrow keys) are never overridden here; spatial and
;; directional navigation integrate through ETAF's native `:region' and
;; `:on-direction' protocol.

;;; Code:

(require 'cl-lib)

(defconst etaf-agenda-help-notes
  (list
   "区域跳转：按 M-g 后输入 f（搜索/顶栏）、s（领域/项目）、m（主工作区）、r（右侧详情），或用 Tab / 方向键跨区。"
   "自然语言捕捉（a / c）：支持 明天、周五、2026-11-25、15:00-16:00、!1-!3、#标签、@领域、+项目、~30m、截止:周五、重复:每周、每天（习惯）、- （记录）、? （问题）。"
   "分层退出：Esc 按顺序退出原位编辑 → 关闭新建行 → 清空搜索 → 关闭右侧检查器 → 取消选中。")
  "Non-binding usage notes displayed in ETAF's native `?' help modal.")

(defun etaf-agenda-keys (handlers)
  "Build the root Host `:keys' list from HANDLERS plist.
Every binding is a (KEY FN LABEL) triple consumed by both ETAF key dispatch
and the native `?' help modal."
  (list
   (list "1" (plist-get handlers :view-today) "今日视图")
   (list "2" (plist-get handlers :view-calendar) "日历视图")
   (list "3" (plist-get handlers :view-list) "清单视图")
   (list "4" (plist-get handlers :view-project) "项目视图")
   (list "5" (plist-get handlers :view-habits) "习惯视图")
   (list "6" (plist-get handlers :view-review) "回顾视图")
   (list "j" (plist-get handlers :next-row) "下一条")
   (list "k" (plist-get handlers :prev-row) "上一条")
   (list "h" (plist-get handlers :prev-day) "前一天 / 习惯前一日")
   (list "l" (plist-get handlers :next-day) "后一天 / 习惯后一日")
   (list "t" (plist-get handlers :today) "回到今天")
   (list "[" (plist-get handlers :prev-month) "上一年 / 上个月 / 上周")
   (list "]" (plist-get handlers :next-month) "下一年 / 下个月 / 下周")
   (list "w" (plist-get handlers :toggle-cal-mode) "切换日历年/月/周视图")
   (list "a" (plist-get handlers :add) "原位新建条目")
   (list "c" (plist-get handlers :capture) "快捷捕捉条目")
   (list "e" (plist-get handlers :edit) "原位编辑标题")
   (list "RET" (plist-get handlers :activate-or-open) "打开详情 / 激活控件")
   (list "x" (plist-get handlers :toggle) "完成 / 习惯打卡")
   (list "m" (plist-get handlers :migrate) "智能迁移 / 迁回")
   (list "M" (plist-get handlers :migrate-overdue) "批量延逾期至今日")
   (list "S" (plist-get handlers :reschedule) "调整计划日期")
   (list "s" (plist-get handlers :cycle-status) "切换状态")
   (list "!" (plist-get handlers :cycle-priority) "切换优先级")
   (list "z" (plist-get handlers :drop) "放弃条目")
   (list "d" (plist-get handlers :delete) "软删除条目")
   (list "u" (plist-get handlers :undo) "撤销上次操作")
   (list "/" (plist-get handlers :focus-search) "搜索任务、标签或项目")
   (list "f" (plist-get handlers :switch-scope) "筛选领域或切换项目")
   (list "g" (plist-get handlers :cycle-grouping) "切换清单分组")
   (list "H" (plist-get handlers :toggle-completed) "显示或隐藏已完成")
   (list "A" (plist-get handlers :add-area-or-stage) "新建领域 / 项目阶段")
   (list "P" (plist-get handlers :add-project) "新建项目")
   (list "q" (plist-get handlers :close) "关闭议程")))

(provide 'etaf-agenda-keys)
;;; etaf-agenda-keys.el ends here
