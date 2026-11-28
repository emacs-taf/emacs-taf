;;; etaf-agenda.el --- Daily log, task list, calendar and habits in one model -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later
;; Author: ETAF contributors
;; Version: 0.2.0
;; Package-Requires: ((emacs "29.1") (etaf "0.3.0") (etaf-ui "0.2.0") (etaf-db "0.1.0"))
;; Keywords: convenience, calendar
;; URL: https://github.com/emacs-taf/etaf-agenda

;;; Commentary:

;; ETAF Agenda keeps a personal agenda in one single-canvas Emacs buffer:
;; today's overdue/events/tasks/notes/migrated items, a month/week calendar,
;; a grouped task list, staged project progress, a 21-day square-tile habit
;; matrix and a monthly review dashboard.  All records live in one local
;; SQLite database, and every colour is dynamically derived from the active
;; Emacs theme so light and dark themes repaint in place cleanly.
;;
;; Navigation integrates with ETAF's region and keyboard contract: digits 1..6
;; switch views, M-g / Tab / arrow keys move across regions (search/topbar,
;; sidebar, main workspace, right context/inspector), j/k move rows, a/e edit
;; in place, RET opens the interactive right-rail inspector (or activates a
;; focused control), x completes or checks off habits, m migrates smartly,
;; u undoes the last mutation, / searches live and ? opens the native help
;; modal.
;;
;; Load this package with (require 'etaf-agenda) after adding this repository
;; root and the ETAF, ETAF UI and ETAF DB roots to `load-path'.
;;
;; Only the interfaces listed below are supported for use by other packages.
;; All unlisted symbols and implementation features are internal, including
;; names without a double hyphen.  Do not require files below lisp/ from
;; consumers.  This Commentary is the authoritative export list;
;; implementations and precise docstrings stay beside their definitions.
;;
;; Function: etaf-agenda-open (&optional file mount-options)
;;;###autoload (autoload 'etaf-agenda-open "etaf-agenda" nil t)
;; Mount the agenda over the SQLite database at FILE and return its buffer.
;; FILE defaults to `etaf-agenda-database-file'; directories and tables are
;; created on first use and older schemas migrate in order.  MOUNT-OPTIONS is
;; forwarded to `etaf-app-open' for tests and scripts that pin viewport sizes.
;; Closing the buffer releases the model and store.
;;
;; Function: etaf-agenda-close ()
;;;###autoload (autoload 'etaf-agenda-close "etaf-agenda" nil t)
;; Close the agenda buffer.  Signals `user-error' when it is not open.
;;
;; Function: etaf-agenda-capture (text)
;;;###autoload (autoload 'etaf-agenda-capture "etaf-agenda" nil t)
;; Add one entry from natural-language TEXT and return its title.
;; Understands relative dates (`今天', `明天', `周五', `下周一', `2026-11-25'),
;; times (`15:00', `15:00-16:00'), priority (`!1'..`!3'), tags (`#tag'),
;; area (`@area'), project (`+project'), estimate (`~30m', `~1.5h'),
;; deadline (`截止:周五'), recurrence (`重复:每周'), habits (`每天', `工作日')
;; and leading `- ' (note) or `? ' (question).  Unrecognised tokens remain in
;; the title.  Signals `user-error' outside an agenda buffer.
;;
;; Function: etaf-agenda-search (query)
;;;###autoload (autoload 'etaf-agenda-search "etaf-agenda" nil t)
;; Filter visible entries in the current agenda buffer by space-separated
;; keywords in QUERY (empty string clears search).
;;
;; Function: etaf-agenda-undo-last ()
;;;###autoload (autoload 'etaf-agenda-undo-last "etaf-agenda" nil t)
;; Undo the most recent entry or instance mutation (delete, drop, migrate,
;; toggle or property edit) in the current agenda buffer.
;;
;; Function: etaf-agenda-add-area (name)
;;;###autoload (autoload 'etaf-agenda-add-area "etaf-agenda" nil t)
;; Create a new area named NAME in the current agenda buffer and return its id.
;;
;; Function: etaf-agenda-add-project (name &optional goal)
;;;###autoload (autoload 'etaf-agenda-add-project "etaf-agenda" nil t)
;; Create a new project named NAME (with optional GOAL), switch to it and
;; return its id.
;;
;; Function: etaf-agenda-add-stage (name)
;;;###autoload (autoload 'etaf-agenda-add-stage "etaf-agenda" nil t)
;; Create a new stage named NAME in the current project and return its id.
;;
;; Function: etaf-agenda-doctor ()
;;;###autoload (autoload 'etaf-agenda-doctor "etaf-agenda" nil t)
;; Return capability facts about the agenda database as a plist with keys
;; `:file', `:directory', `:writable' and `:entries'.
;;
;; Function: etaf-agenda-view-today ()
;;;###autoload (autoload 'etaf-agenda-view-today "etaf-agenda" nil t)
;; Show the 今日 page.
;;
;; Function: etaf-agenda-view-calendar ()
;;;###autoload (autoload 'etaf-agenda-view-calendar "etaf-agenda" nil t)
;; Show the 日历 page (year, month or 7-day week view plus selected day rail).
;;
;; Function: etaf-agenda-view-list ()
;;;###autoload (autoload 'etaf-agenda-view-list "etaf-agenda" nil t)
;; Show the 清单 page grouped by time, area, project or status.
;;
;; Function: etaf-agenda-view-project ()
;;;###autoload (autoload 'etaf-agenda-view-project "etaf-agenda" nil t)
;; Show the 项目 page with completion progress and stages.
;;
;; Function: etaf-agenda-view-habits ()
;;;###autoload (autoload 'etaf-agenda-view-habits "etaf-agenda" nil t)
;; Show the 习惯 page with its 21-day square-tile check-in matrix.
;;
;; Function: etaf-agenda-view-review ()
;;;###autoload (autoload 'etaf-agenda-view-review "etaf-agenda" nil t)
;; Show the 回顾 page with monthly KPIs, breakdowns, heatmap and insights.

;;; Code:

(eval-and-compile
  (let ((lisp-dir
         (catch 'found
           (dolist (file (list (bound-and-true-p byte-compile-current-file)
                               (and load-file-name
                                    (not (string-suffix-p ".eln" load-file-name))
                                    load-file-name)
                               (locate-library "etaf-agenda")
                               buffer-file-name))
             (when (stringp file)
               (let* ((dir (file-name-directory file))
                      (sub (and dir (expand-file-name "lisp" dir))))
                 (when (and sub
                            (file-directory-p sub)
                            (or (file-exists-p (expand-file-name "etaf-agenda.el" dir))
                                (file-exists-p (expand-file-name "etaf-agenda.elc" dir))))
                   (throw 'found sub))))))))
    (when lisp-dir
      (add-to-list 'load-path lisp-dir))))

(require 'etaf-agenda-theme)
(require 'etaf-agenda-layout)
(require 'etaf-agenda-parse)
(require 'etaf-agenda-store)
(require 'etaf-agenda-model)
(require 'etaf-agenda-keys)
(require 'etaf-agenda-views-pages)
(require 'etaf-agenda-views)
(require 'etaf-agenda-app)

;;;###autoload
(with-eval-after-load 'etaf
  (etaf-app-register 'etaf-agenda
    :title "日程与任务"
    :icon "A"
    :category 'productivity
    :feature 'etaf-agenda
    :open 'etaf-agenda-open
    :doctor 'etaf-agenda-doctor
    :hosts '(buffer)))

(provide 'etaf-agenda)
;;; etaf-agenda.el ends here
