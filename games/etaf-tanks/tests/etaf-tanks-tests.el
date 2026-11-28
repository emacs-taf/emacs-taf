;;; -*- lexical-binding: t; -*-
;;; etaf-tanks-tests.el --- Battle rules, maps and application workflows
;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Commentary:
;; Adapter scenarios drive `etaf-tanks-game' through GameKit operations;
;; application scenarios press the documented keys in the rendered buffer.
;;; Code:
(require 'ert)
(require 'etaf-tanks)

(defconst etaf-tanks-test--stages
  (expand-file-name "../native/godot/stages/" (file-name-directory (or load-file-name buffer-file-name)))
  "Bundled campaign maps.")

(defun etaf-tanks-test--map (name counts &rest rows)
  "Return map text called NAME with enemy COUNTS and ROWS."
  (concat "name: " name "\nenemies: " counts "\nmap:\n" (mapconcat #'identity rows "\n") "\n"))

(defconst etaf-tanks-test--duel
  (etaf-tanks-test--map "装甲对决" "0 0 0 1"
                        "@@@@EE@@@@@@" "@@@@EE@@@@@@" "@@@@..@@@@@@" "@@@@..@@@@@@"
                        "@@@@..@@@@@@" "@@@@..@@@@@@" "@@@@..@@@@@@" "@@@@..@@@@@@"
                        "@@@@PP@@@@@@" "@@@@PP@@@@@@" "@@@@@@@@@@@@" "@@@@@@@@@@@@"
                        "@@@@@@@@HH@@" "@@@@@@@@HH@@")
  "One armored enemy facing the player down a closed corridor.")

(defconst etaf-tanks-test--sentry
  (etaf-tanks-test--map "守卫" "1 0 0 0"
                        "EE@@@@@@@@@@" "EE@@@@@@@@@@" "@@@@@@@@@@@@" "@@@@@@@@@@@@"
                        "@@@@@@@@@@@@" "@@@@@@@@@@@@" "@@@@@@@@@@@@" "@@@@@@@@@@@@"
                        "@@@@PP@@@@@@" "@@@@PP@@@@@@" "@@@@HH@@@@@@" "@@@@HH@@@@@@")
  "A player parked directly above the base, with the enemy walled in.")

(defun etaf-tanks-test--stage (number)
  "Return the bundled campaign map NUMBER."
  (with-temp-buffer
    (insert-file-contents (expand-file-name (format "%02d.txt" number) etaf-tanks-test--stages))
    (buffer-string)))

(defun etaf-tanks-test--settled-p (session predicate)
  "Whether SESSION is ready and PREDICATE holds."
  (and (eq (etaf-gamekit-status session) 'ready) (or (null predicate) (funcall predicate))))

(defun etaf-tanks-test--wait (session &optional predicate seconds each)
  "Await ready SESSION and PREDICATE for at most SECONDS, calling EACH meanwhile."
  (let ((end (+ (float-time) (or seconds 8))))
    (while (and (< (float-time) end)
                (not (memq (etaf-gamekit-status session) '(failed closed)))
                (not (etaf-tanks-test--settled-p session predicate)))
      (when each (funcall each))
      (accept-process-output nil 0.02)))
  (let ((status (etaf-gamekit-status session))
        (settled (etaf-tanks-test--settled-p session predicate)))
    (should (eq status 'ready)) (should settled)))

(defun etaf-tanks-test--view (session key)
  "Return KEY from SESSION's latest acknowledged observation.
The display view is published on a timer after the acknowledgement, so
reading it right after an action could still show the previous state."
  (plist-get (etaf-gamekit-observation session) key))

(defun etaf-tanks-test--phase-p (session &rest phases)
  "Return a predicate that holds after SESSION publishes one of PHASES.
An acknowledged backend phase precedes the coalesced display; sending the
next key before that publication would operate the previous screen."
  (lambda ()
    (let ((observed (etaf-tanks-test--view session :phase))
          (published (etaf-gamekit-view session :phase)))
      (and (member observed phases) (equal observed published)))))

(defun etaf-tanks-test--start ()
  "Start an instance at the stage select, cleaning up if startup fails."
  (let* ((session (etaf-gamekit-start etaf-tanks-game))
         (runtime (etaf-runtime-for-buffer (etaf-gamekit-buffer session))) good)
    (unwind-protect
        (progn
          (switch-to-buffer (etaf-gamekit-buffer session))
          (etaf-runtime-refit runtime 1300 50)
          ;; The connected application previews the selected stage.
          (etaf-tanks-test--wait session (lambda () (and (etaf-tanks-test--view session :size)
                                                         (etaf-host-ref-size runtime 'tanks-board))))
          (let ((error (etaf-gamekit-last-error session))) (should-not error))
          (setq good t)
          session)
      (unless good (etaf-tanks-close session)))))

(defun etaf-tanks-test--timer-errors (start)
  "Return timer failures logged to *Messages* after position START."
  (with-current-buffer (messages-buffer)
    (let (found)
      (save-excursion
        (goto-char (min start (point-max)))
        (while (re-search-forward "^Error running timer.*$" nil t)
          (push (match-string-no-properties 0) found)))
      (nreverse found))))

(defmacro etaf-tanks-test--with-sessions (names &rest body)
  "Run BODY with fresh instances bound to NAMES and private user files.
Rendering failures inside GameKit's publishing timer only reach *Messages*,
so the scenario also fails when one was logged."
  (declare (indent 1))
  `(let* ((root (make-temp-file "etaf-tanks-test-" t))
          (etaf-tanks-map-directory (file-name-as-directory (expand-file-name "maps" root)))
          (etaf-tanks-progress-file (expand-file-name "progress.eld" root))
          (messages (with-current-buffer (messages-buffer) (point-max)))
          ,@(mapcar (lambda (name) (list name nil)) names))
     (unwind-protect
         (progn ,@(mapcar (lambda (name) `(setq ,name (etaf-tanks-test--start))) names)
                ,@body
                (let ((failures (etaf-tanks-test--timer-errors messages))) (should-not failures)))
       ,@(mapcar (lambda (name) `(when ,name (etaf-tanks-close ,name))) names)
       (delete-directory root t))))

(defun etaf-tanks-test--act (session operation &optional arguments rejection)
  "Send OPERATION with ARGUMENTS; verify acknowledgement or the expected REJECTION."
  (etaf-gamekit-action session operation arguments)
  (etaf-tanks-test--wait session)
  (let ((failure (etaf-gamekit-last-error session)))
    (if rejection (should failure) (should-not failure))))

(defun etaf-tanks-test--begin (session map &rest arguments)
  "Begin a battle on MAP with ARGUMENTS and await its live phase.
Every battle opens with its intro, so waiting for it first keeps a previous
battle's published play phase from passing for the new one."
  (etaf-tanks-test--act session "begin" (append (list :map map) arguments))
  (etaf-tanks-test--wait session (etaf-tanks-test--phase-p session "intro"))
  (etaf-tanks-test--wait session (etaf-tanks-test--phase-p session "play")))

(defun etaf-tanks-test--units (session type)
  "Return SESSION's world units of TYPE."
  (seq-filter (lambda (unit) (equal (plist-get unit :type) type))
              (plist-get (etaf-tanks-test--view session :world) :units)))

(defun etaf-tanks-test--keys (session keys)
  "Press KEYS in SESSION's buffer, which the selected window shows."
  (switch-to-buffer (etaf-gamekit-buffer session))
  (execute-kbd-macro (kbd keys)))

(defun etaf-tanks-test--text (session)
  "Return SESSION's rendered text."
  (with-current-buffer (etaf-gamekit-buffer session)
    (buffer-substring-no-properties (point-min) (point-max))))

(defun etaf-tanks-test--actor (session)
  "Return the player's position, facing and shot count."
  (let ((actor (etaf-tanks-test--view session :actor)))
    (list (plist-get actor :x) (plist-get actor :y) (plist-get actor :facing) (plist-get actor :shots))))

(defun etaf-tanks-test--stable (session)
  "Return SESSION's battle state without its event log."
  (let ((observation (etaf-gamekit-observation session)))
    (list (plist-get observation :phase) (plist-get observation :paused) (plist-get observation :hud)
          (plist-get observation :actor) (plist-get observation :world))))

(ert-deftest etaf-tanks-maps-are-validated-before-play ()
  "Previews report map defects, and an invalid map cannot start a battle."
  (etaf-tanks-test--with-sessions (session)
    (etaf-tanks-test--act session "menu" (list :map etaf-tanks-test--duel))
    (let ((problem (etaf-tanks-test--view session :map_error))
          (size (etaf-tanks-test--view session :size)))
      (should (equal problem "")) (should (equal size '(12 14))))
    (let ((baseless (string-replace "HH" "@@" etaf-tanks-test--duel)))
      (etaf-tanks-test--act session "menu" (list :map baseless))
      (let ((problem (etaf-tanks-test--view session :map_error)))
        (should (string-match-p "基地" problem)))
      (etaf-tanks-test--act session "begin" (list :map baseless) t)
      (let ((phase (etaf-tanks-test--view session :phase))) (should (equal phase "menu"))))
    ;; Undersized maps are reported without a preview the session cannot show.
    (etaf-tanks-test--act session "menu"
                          (list :map (etaf-tanks-test--map "小" "1 0 0 0" "EE.." "EE.." "PPHH" "PPHH")))
    (let ((problem (etaf-tanks-test--view session :map_error))
          (size (etaf-tanks-test--view session :size)))
      (should (string-match-p "尺寸" problem)) (should-not size))
    (let ((status (etaf-gamekit-status session))) (should (eq status 'ready)))))

(ert-deftest etaf-tanks-settings-and-difficulty-are-validated ()
  "Out-of-range settings are rejected; difficulty sets the starting lives."
  (etaf-tanks-test--with-sessions (session)
    (etaf-tanks-test--act session "settings" '(:speed 2.5) t)
    (etaf-tanks-test--act session "settings" '(:frame_rate 90) t)
    (etaf-tanks-test--act session "settings" '(:speed 2.0 :player_speed 0.5 :frame_rate 60))
    (let ((settings (etaf-tanks-test--view session :settings)))
      (should (= (plist-get settings :speed) 2.0))
      (should (= (plist-get settings :player_speed) 0.5))
      (should (= (plist-get settings :frame_rate) 60)))
    (etaf-tanks-test--begin session (etaf-tanks-test--stage 1) :difficulty "easy" :seed 3)
    (let ((lives (plist-get (etaf-tanks-test--view session :hud) :lives))) (should (= lives 5)))
    (etaf-tanks-test--begin session (etaf-tanks-test--stage 1) :difficulty "hard" :seed 3)
    (let ((lives (plist-get (etaf-tanks-test--view session :hud) :lives))) (should (= lives 3)))
    (etaf-tanks-test--act session "begin" (list :map (etaf-tanks-test--stage 1) :difficulty "insane") t)))

(ert-deftest etaf-tanks-losing-the-base-ends-the-battle ()
  "A shell that reaches the eagle base loses the battle, whoever fired it."
  (etaf-tanks-test--with-sessions (session)
    (etaf-tanks-test--begin session etaf-tanks-test--sentry :difficulty "easy" :seed 1)
    (etaf-tanks-test--act session "aim" '(:direction "s"))
    (etaf-tanks-test--act session "fire")
    (etaf-tanks-test--wait session (lambda () (eq :false (plist-get (etaf-tanks-test--view session :hud) :base))) 3)
    (etaf-tanks-test--wait session (etaf-tanks-test--phase-p session "over") 6)
    (let ((cleared (plist-get (etaf-tanks-test--view session :tally) :cleared))) (should (eq cleared :false)))))

(ert-deftest etaf-tanks-armored-enemies-take-four-hits ()
  "An armored tank loses one armor per hit and scores only when destroyed."
  (etaf-tanks-test--with-sessions (session)
    (etaf-tanks-test--begin session etaf-tanks-test--duel :difficulty "easy" :seed 5)
    (let ((seen nil) (next 0.0))
      (etaf-tanks-test--wait
       session (lambda () (equal (etaf-tanks-test--view session :phase) "cleared")) 30
       (lambda ()
         (dolist (unit (etaf-tanks-test--units session "armor"))
           (cl-pushnew (plist-get unit :armour) seen))
         (when (> (float-time) next)
           (setq next (+ (float-time) 0.1))
           (when (eq (etaf-gamekit-status session) 'ready)
             (etaf-gamekit-action session "fire")))))
      ;; Shells already in flight can hit the tank in its first published frame.
      (should (member (sort seen #'<) '((1 2 3) (1 2 3 4)))))
    (let ((tally (etaf-tanks-test--view session :tally)))
      (should (equal (plist-get tally :kills) '(0 0 0 1)))
      (should (eq (plist-get tally :cleared) t)))))

(ert-deftest etaf-tanks-world-runs-without-input-and-pauses-atomically ()
  "Enemies advance on Godot's clock without commands and freeze while paused."
  (etaf-tanks-test--with-sessions (session)
    (etaf-tanks-test--begin session (etaf-tanks-test--stage 1) :difficulty "normal" :seed 11)
    (etaf-tanks-test--wait session (lambda () (cdr (plist-get (etaf-tanks-test--view session :world) :units))) 8)
    (let ((before (etaf-tanks-test--stable session)))
      (etaf-tanks-test--wait session (lambda () (not (equal before (etaf-tanks-test--stable session))))))
    (etaf-tanks-test--act session "pause")
    (let ((frozen (etaf-tanks-test--stable session)) (until (+ (float-time) 0.4)))
      (while (< (float-time) until) (accept-process-output nil 0.02))
      (should (equal frozen (etaf-tanks-test--stable session)))
      ;; Paused input is acknowledged without moving the world.
      (etaf-tanks-test--act session "drive" '(:direction "e"))
      (etaf-tanks-test--act session "fire")
      (should (equal frozen (etaf-tanks-test--stable session)))
      ;; An explicit pause state is idempotent; a malformed one is rejected.
      (etaf-tanks-test--act session "pause" '(:paused t))
      (etaf-tanks-test--act session "pause" '(:paused 1) t)
      (should (equal frozen (etaf-tanks-test--stable session)))
      (etaf-tanks-test--act session "pause" '(:paused :false))
      (should (eq (etaf-tanks-test--view session :paused) :false)))))

(ert-deftest etaf-tanks-snapshots-restore-paused-with-atomic-rejection ()
  "A snapshot restores the battle paused; malformed files preserve it."
  (etaf-tanks-test--with-sessions (session)
    (let ((file (make-temp-file "etaf-tanks-save-" nil ".json"))
          (broken (make-temp-file "etaf-tanks-broken-" nil ".json" "{\"format\":")))
      (unwind-protect
          (progn
            (etaf-tanks-test--begin session (etaf-tanks-test--stage 2) :difficulty "easy" :seed 9)
            (etaf-tanks-test--act session "pause")
            (let ((saved (etaf-tanks-test--stable session)))
              (etaf-tanks-test--act session "save" (list :path file))
              (etaf-tanks-test--act session "pause")
              (etaf-tanks-test--wait session (lambda () (not (equal saved (etaf-tanks-test--stable session)))))
              (etaf-tanks-test--act session "load" (list :path file))
              (let ((restored (etaf-tanks-test--stable session)))
                (should (equal (nth 1 restored) t))
                (should (equal (nth 3 restored) (nth 3 saved)))
                (should (equal (plist-get (nth 2 restored) :lives) (plist-get (nth 2 saved) :lives)))
                (should (equal (plist-get (nth 4 restored) :terrain) (plist-get (nth 4 saved) :terrain)))
                (etaf-tanks-test--act session "load" (list :path broken) t)
                (etaf-tanks-test--act session "load" (list :path (concat file ".missing")) t)
                (should (equal restored (etaf-tanks-test--stable session))))))
        (delete-file file) (delete-file broken)))))

(ert-deftest etaf-tanks-battles-are-independent ()
  "One live battle cannot advance a second paused battlefield."
  (etaf-tanks-test--with-sessions (first second)
    (etaf-tanks-test--begin first (etaf-tanks-test--stage 1) :seed 1)
    (etaf-tanks-test--begin second (etaf-tanks-test--stage 1) :seed 1)
    (etaf-tanks-test--act second "pause")
    (let ((before (etaf-tanks-test--stable second)) (moving (etaf-tanks-test--stable first)))
      (etaf-tanks-test--wait first (lambda () (not (equal moving (etaf-tanks-test--stable first)))))
      (should (equal before (etaf-tanks-test--stable second))))))

(ert-deftest etaf-tanks-keys-drive-aim-fire-and-pause-a-campaign ()
  "The named stage select starts a campaign that the documented keys control."
  (etaf-tanks-test--with-sessions (session)
    (let ((title (plist-get (etaf-gamekit-game-info session) :title))
          (heading-present (string-match-p "坦克大战" (etaf-tanks-test--text session))))
      (should (equal title "坦克大战"))
      (should heading-present))
    (should (string-match-p "第 1 关" (etaf-tanks-test--text session)))
    (etaf-tanks-test--keys session "g")
    (etaf-tanks-test--wait session (etaf-tanks-test--phase-p session "play"))
    (let ((start (etaf-tanks-test--actor session)))
      (dotimes (_ 6) (etaf-tanks-test--keys session "<right>") (accept-process-output nil 0.1))
      (etaf-tanks-test--wait session (lambda () (> (car (etaf-tanks-test--actor session)) (car start))))
      (let ((facing (nth 2 (etaf-tanks-test--actor session)))) (should (equal facing "e")))
      (etaf-tanks-test--keys session "S-<up>")
      (etaf-tanks-test--wait session (lambda () (equal (nth 2 (etaf-tanks-test--actor session)) "n")))
      (etaf-tanks-test--keys session "f")
      (etaf-tanks-test--wait session (lambda () (> (nth 3 (etaf-tanks-test--actor session)) (nth 3 start)))))
    (etaf-tanks-test--keys session "p")
    (etaf-tanks-test--wait session (lambda () (eq t (etaf-tanks-test--view session :paused))))
    (etaf-tanks-test--wait session (lambda () (string-match-p "继续 · p" (etaf-tanks-test--text session))))
    ;; A paused battle is left without confirmation.
    (etaf-tanks-test--keys session "m")
    (etaf-tanks-test--wait session (etaf-tanks-test--phase-p session "menu"))))

(ert-deftest etaf-tanks-help-entries-pause-and-preserve-the-battle ()
  "Question mark, F1 and the help button share read-only help and pause policy."
  (etaf-tanks-test--with-sessions (session)
    (etaf-tanks-test--begin session etaf-tanks-test--sentry)
    (let* ((buffer (etaf-gamekit-buffer session))
           (runtime (etaf-runtime-for-buffer buffer)))
      (dolist (entry '("?" "<f1>" button))
        (etaf-tanks-test--act session "pause" '(:paused :false))
        (etaf-focus runtime (if (eq entry 'button) 'tanks-help 'tanks-board))
        (let ((focus (etaf-focused-host-ref runtime))
              (windows (window-list)) (buffers (buffer-list)))
          (if (eq entry 'button) (etaf-activate runtime)
            (etaf-tanks-test--keys session entry))
          (etaf-tanks-test--wait
           session (lambda () (eq t (etaf-tanks-test--view session :paused))))
          (let* ((data (etaf-help-data runtime))
                 (labels (mapcan (lambda (group)
                                   (mapcar (lambda (binding) (plist-get binding :label))
                                           (plist-get group :entries)))
                                 (plist-get data :groups)))
                 (title (plist-get data :title)))
            (should (equal title "坦克大战"))
            (should (member "开火" labels)))
          (should (equal windows (window-list)))
          (should (equal buffers (buffer-list)))
          (should (eq (window-buffer) buffer))
          (let ((before (etaf-tanks-test--stable session)))
            (etaf-tanks-test--keys session "f p <right> C-v")
            (accept-process-output nil 0.15)
            (let ((after (etaf-tanks-test--stable session)))
              (should (equal before after)))
            (etaf-tanks-test--keys session "/ f <escape>")
            (let ((visible (string-match-p "快捷键" (etaf-tanks-test--text session))))
              (should visible))
            (etaf-tanks-test--keys session "<escape>")
            (let ((after (etaf-tanks-test--stable session))
                  (restored (etaf-focused-host-ref runtime))
                  (closed-again (etaf-help-close runtime)))
              (should (equal before after))
              (should (equal focus restored))
              (should-not closed-again))))))))

(ert-deftest etaf-tanks-embedded-focus-exit-pauses-and-preserves-battle ()
  "Leaving an embedded battle pauses it; reentry and popup exits keep its state."
  (etaf-tanks-test--with-sessions (session)
    (let ((buffer (generate-new-buffer " *tanks-embedded-focus*"))
          (exits 0))
      (unwind-protect
          (progn
            (etaf-mount
             buffer
             (etaf-view
              (column
                (box :ref 'tanks-test-shell :tab-index 0 "Host")
                (box :key-scope 'local :region '(:id tanks-test-content :label "Battle")
                     :on-dismiss (lambda () (cl-incf exits)
                                   (etaf-focus (etaf-runtime-for-buffer buffer) 'tanks-test-shell))
                  (expr (etaf-tanks-view session)))))
             '(:viewport-width 1300 :viewport-height 50))
            (switch-to-buffer buffer)
            (let ((runtime (etaf-runtime-for-buffer buffer)))
              (etaf-focus runtime 'tanks-board)
              (execute-kbd-macro (kbd "g"))
              (etaf-tanks-test--wait session (etaf-tanks-test--phase-p session "play"))
              (execute-kbd-macro (kbd "<escape>"))
              (should (= exits 1))
              (etaf-tanks-test--wait
               session (lambda () (eq (etaf-tanks-test--view session :paused) t)))
              (should (eq (etaf-focused-host-ref runtime) 'tanks-test-shell))
              (let ((before (etaf-tanks-test--stable session)))
                (accept-process-output nil 0.12)
                (etaf-region-focus 'tanks-test-content runtime)
                (should (eq (etaf-focused-host-ref runtime) 'tanks-board))
                (execute-kbd-macro (kbd "s"))
                (let ((settings-focus (etaf-focused-host-ref runtime)))
                  (execute-kbd-macro (kbd "? <escape>"))
                  (should (= exits 1))
                  (should (eq (etaf-focused-host-ref runtime) settings-focus)))
                (execute-kbd-macro (kbd "<escape>"))
                (should (= exits 1))
                (should (eq (etaf-focused-host-ref runtime) 'tanks-board))
                (execute-kbd-macro (kbd "<escape>"))
                (should (= exits 2))
                (etaf-tanks-test--wait session)
                (let ((after (etaf-tanks-test--stable session)))
                  (should (equal before after))))))
        (when-let* ((runtime (etaf-runtime-for-buffer buffer))) (etaf-unmount runtime))
        (kill-buffer buffer)))))

(ert-deftest etaf-tanks-embedded-publication-keeps-host-focus ()
  "A delayed battle screen cannot reclaim focus after the user left the game."
  (etaf-tanks-test--with-sessions (session)
    (let ((buffer (generate-new-buffer " *tanks-background-screen*")))
      (unwind-protect
          (progn
            (etaf-mount
             buffer
             (etaf-view
              (column
                (box :ref 'tanks-test-shell :tab-index 0 "Host")
                (box :key-scope 'local (expr (etaf-tanks-view session)))))
             '(:viewport-width 1300 :viewport-height 50))
            (let ((runtime (etaf-runtime-for-buffer buffer)))
              (etaf-focus runtime 'tanks-test-shell)
              (etaf-gamekit-action session "edit"
                                   (list :map (etaf-tanks-test--stage 1) :x 0 :y 0 :size 1))
              (etaf-tanks-test--wait session (etaf-tanks-test--phase-p session "edit"))
              (should (eq (etaf-focused-host-ref runtime) 'tanks-test-shell))))
        (when-let* ((runtime (etaf-runtime-for-buffer buffer))) (etaf-unmount runtime))
        (kill-buffer buffer)))))

(ert-deftest etaf-tanks-help-keeps-focus-during-screen-publication ()
  "An asynchronous screen change cannot steal the help's focus or snapshot."
  (etaf-tanks-test--with-sessions (session)
    (let ((runtime (etaf-runtime-for-buffer (etaf-gamekit-buffer session))))
      (etaf-tanks-test--keys session "?")
      (let ((focus (etaf-focused-host-ref runtime))
            (data (etaf-help-data runtime)))
        (etaf-gamekit-action session "edit"
                             (list :map (etaf-tanks-test--stage 1) :x 0 :y 0 :size 1))
        (etaf-tanks-test--wait
         session (lambda () (equal (etaf-gamekit-view session :phase) "edit")))
        (let ((after (etaf-focused-host-ref runtime))
              (snapshot (etaf-help-data runtime)))
          (should (equal focus after))
          (should (equal data snapshot)))
        (etaf-help-close runtime)))))

(ert-deftest etaf-tanks-editor-arrows-draw-and-shift-only-moves ()
  "Arrows paint every step, while Shift with an arrow only moves."
  (etaf-tanks-test--with-sessions (session)
    (etaf-tanks-test--keys session "e")
    (etaf-tanks-test--wait session (etaf-tanks-test--phase-p session "edit"))
    (etaf-tanks-test--keys session "3 S-<right> S-<right> S-<right> S-<right>")
    (etaf-tanks-test--wait
     session (lambda ()
               (let ((cursor (etaf-tanks-test--view session :editor)))
                 (and (eql (plist-get cursor :x) 4) (eql (plist-get cursor :y) 0)))))
    ;; Shift moved four cells without painting a single one.
    (should-not (string-match-p "地图编辑 · 未保存" (etaf-tanks-test--text session)))
    (etaf-tanks-test--keys session "<right> <right> <down>")
    (etaf-tanks-test--wait
     session (lambda ()
               (let ((cursor (etaf-tanks-test--view session :editor)))
                 (and (eql (plist-get cursor :x) 6) (eql (plist-get cursor :y) 1)))))
    (should (string-match-p "地图编辑 · 未保存" (etaf-tanks-test--text session)))
    ;; Moving away with Shift leaves the new column alone.
    (etaf-tanks-test--keys session "S-<right>")
    (etaf-tanks-test--wait
     session (lambda () (eql 7 (plist-get (etaf-tanks-test--view session :editor) :x))))
    (etaf-tanks-test--keys session "C-s RET")
    (let* ((file (expand-file-name "前哨-改.txt" etaf-tanks-map-directory))
           (text (and (file-exists-p file)
                      (with-temp-buffer (insert-file-contents file) (buffer-string)))))
      (should (string-match-p "^map:\nEE\\.\\.\\.@@" text))
      (should (string-match-p "^map:\n[^\n]*\nEE\\.\\.\\.\\.@\\." text)))))

(ert-deftest etaf-tanks-editor-paints-saves-and-test-plays ()
  "Editing a stage saves a custom map that test play and the catalog use."
  (etaf-tanks-test--with-sessions (session)
    (etaf-tanks-test--keys session "e")
    (etaf-tanks-test--wait session (etaf-tanks-test--phase-p session "edit"))
    (let* ((runtime (etaf-runtime-for-buffer (etaf-gamekit-buffer session)))
           (text (etaf-tanks-test--text session))
           (has-movement-hint (string-match-p "方向键移动并绘制" text))
           (has-paint-hint (string-match-p "1–9 换画笔，F 画一格" text))
           (has-move-hint (string-match-p "Shift\\+方向键 只移动" text)))
      (should has-movement-hint)
      (should has-paint-hint)
      (should has-move-hint)
      ;; Turning drawing off keeps the arrows moving without painting.
      (etaf-tanks-test--keys session "d")
      (etaf-tanks-test--wait session (lambda () (string-match-p "绘制：关" (etaf-tanks-test--text session))))
      (etaf-tanks-test--keys session "<right> <right> <down> 3")
      (etaf-dispatch-event runtime 'tanks-map-paint 'press)
      (etaf-dispatch-event runtime 'tanks-map-undo 'press)
      (etaf-tanks-test--keys session "<right> f")
      (etaf-dispatch-event runtime 'tanks-pen 'press)
      (etaf-tanks-test--wait session (lambda () (string-match-p "绘制：开" (etaf-tanks-test--text session))))
      (etaf-dispatch-event runtime 'tanks-pen 'press)
      (etaf-tanks-test--wait session (lambda () (string-match-p "绘制：关" (etaf-tanks-test--text session)))))
    (etaf-tanks-test--keys session "C-s RET")
    (let* ((file (expand-file-name "前哨-改.txt" etaf-tanks-map-directory))
           (text (and (file-exists-p file) (with-temp-buffer (insert-file-contents file) (buffer-string)))))
      (should (string-match-p "^name: 前哨 改$" text))
      ;; Button painting was undone at column 2; keyboard painting remains
      ;; at column 3 in the saved, public map format.
      (should (string-match-p "^map:\n.*\n..\\.@" text)))
    (etaf-tanks-test--keys session "p")
    (etaf-tanks-test--wait session (etaf-tanks-test--phase-p session "intro" "play"))
    (etaf-tanks-test--keys session "m yes RET")
    (etaf-tanks-test--wait session (etaf-tanks-test--phase-p session "edit"))
    (etaf-tanks-test--keys session "m")
    (etaf-tanks-test--wait session (lambda () (and (equal (etaf-tanks-test--view session :phase) "menu")
                                                   (string-match-p "前哨 改" (etaf-tanks-test--text session)))))))

(ert-deftest etaf-tanks-themes-and-resize-preserve-paused-battle ()
  "Appearance and resizing preserve the battlefield, state and keyboard focus."
  (etaf-tanks-test--with-sessions (session)
    (let ((runtime (etaf-runtime-for-buffer (etaf-gamekit-buffer session))))
      (etaf-tanks-test--keys session "g")
      (etaf-tanks-test--wait session (etaf-tanks-test--phase-p session "play"))
      (etaf-tanks-test--keys session "p")
      (etaf-tanks-test--wait session (lambda () (eq t (etaf-tanks-test--view session :paused))))
      (let ((before (etaf-tanks-test--stable session)))
        (dolist (viewport '((700 . 40) (1300 . 40) (1300 . 70) (1300 . 20)))
          (etaf-tanks-test--keys session "t")
          (etaf-runtime-refit runtime (car viewport) (cdr viewport))
          (etaf-tanks-test--wait session (lambda () (etaf-host-ref-size runtime 'tanks-board)))
          (let* ((size (etaf-host-ref-size runtime 'tanks-root))
                 (bounds (etaf-host-ref-bounds runtime 'tanks-root))
                 (surplus (max 0 (- (cdr viewport) (cdr size))))
                 (top (with-current-buffer (etaf-gamekit-buffer session)
                        (1- (line-number-at-pos (car bounds))))))
            ;; Surplus space frames the complete table, never shrinks the board.
            (should (<= (abs (- top (* 0.4 surplus))) 1)))
          (let ((after (etaf-tanks-test--stable session)) (focus (etaf-focused-host-ref runtime)))
            (should (equal before after)) (should (eq focus 'tanks-board))))))))

(ert-deftest etaf-tanks-text-scale-preserves-paused-battle-and-image-rows ()
  "Zoom repartitions graphic strips while keeping the paused game and focus."
  (etaf-tanks-test--with-sessions (session)
    (let* ((buffer (etaf-gamekit-buffer session))
           (runtime (etaf-runtime-for-buffer buffer)))
      (etaf-tanks-test--keys session "g")
      (etaf-tanks-test--wait session (etaf-tanks-test--phase-p session "play"))
      (etaf-tanks-test--keys session "p")
      (etaf-tanks-test--wait session (lambda () (eq t (etaf-tanks-test--view session :paused))))
      (let ((before (etaf-tanks-test--stable session)))
        (dolist (scale '(2 -2 0))
          (with-current-buffer buffer (text-scale-set scale))
          (sleep-for 0.3)
          (etaf-tanks-test--wait
           session
           (lambda ()
             (or (not (display-graphic-p))
                 (let ((frame (etaf-gamekit-view session :frame))
                       (line (plist-get (etaf-display-metrics runtime) :line-height)))
                   (eql (plist-get frame :line)
                        (* line (if (fboundp 'frame-scale-factor)
                                    (max 1 (round (frame-scale-factor))) 1)))))))
          (let ((after (etaf-tanks-test--stable session))
                (focus (etaf-focused-host-ref runtime)))
            (should (equal before after))
            (should (eq focus 'tanks-board)))
          (when (display-graphic-p)
            (with-current-buffer buffer
              (let ((p (point-min)) (images 0))
                (while (< p (point-max))
                  (when (eq (car-safe (get-text-property p 'display)) 'image)
                    (cl-incf images))
                  (setq p (next-single-property-change p 'display nil (point-max))))
                (should (> images 0))))))))))

(etaf-define-component etaf-tanks-test--appearance-host (&key appearance session)
  "Host SESSION's battle inside an explicitly provided APPEARANCE."
  :setup (etaf-appearance-provide appearance)
  :render (etaf-tanks-view session))

(defun etaf-tanks-test--surface-background ()
  "Return the most common background colour painted in the current buffer."
  (let ((counts (make-hash-table :test #'equal))
        (end (point-max)))
    (cl-loop for i from 1 below (min end 4000)
             for face = (get-text-property i 'face)
             for color = (and (consp face) (plist-get face :background))
             when color
             do (puthash color (1+ (gethash color counts 0)) counts))
    (let ((best nil) (best-count 0))
      (maphash (lambda (color count)
                 (when (> count best-count)
                   (setq best color best-count count)))
               counts)
      best)))

(defun etaf-tanks-test--luminance (color)
  "Return the relative luminance of COLOR."
  (apply #'+ (cl-mapcar (lambda (weight channel) (* weight channel))
                        '(0.2126 0.7152 0.0722)
                        (color-name-to-rgb color))))

(ert-deftest etaf-tanks-appearance-follows-the-host ()
  "Switching the provided appearance repaints the battle surface.
The battle used to read the frame mode once when it mounted, so the game kept
its old palette after a theme switch while the desktop around it followed the
new one."
  (etaf-tanks-test--with-sessions (session)
    (let* ((appearance (etaf-ref 'light))
           (buffer (generate-new-buffer " *tanks-appearance*")))
      (unwind-protect
          (progn
            (etaf-mount buffer
                        (etaf-view (etaf-tanks-test--appearance-host
                                    :appearance appearance :session session))
                        '(:viewport-width 1000 :viewport-height 40))
            (switch-to-buffer buffer)
            (let ((light (etaf-tanks-test--surface-background)))
              (should light)
              (etaf-set-value appearance 'dark)
              (let ((dark (etaf-tanks-test--surface-background)))
                (should dark)
                (should-not (equal light dark))
                (should (< (etaf-tanks-test--luminance dark)
                           (etaf-tanks-test--luminance light))))))
        (kill-buffer buffer)))))

(ert-deftest etaf-tanks-doctor-follows-the-configured-godot-runtime ()
  "The capability check reports the configured runtime, not a cache path."
  (let* ((directory (make-temp-file "etaf-tanks-doctor" t))
         (program (expand-file-name "godot" directory)))
    (unwind-protect
        (progn
          (with-temp-file program
            (insert "#!/bin/sh\n"))
          (set-file-modes program #o755)
          (let ((etaf-gamekit-godot-program program))
            (let ((fact (car (plist-get (etaf-tanks-doctor) :required))))
              (should (equal (car fact) "Godot runtime"))
              (should (cadr fact))))
          (let ((etaf-gamekit-godot-program (expand-file-name "absent" directory)))
            (let ((fact (car (plist-get (etaf-tanks-doctor) :required))))
              (should-not (cadr fact))
              (should (string-match-p "etaf-gamekit-install-godot" (nth 2 fact))))))
      (delete-directory directory t))))

(provide 'etaf-tanks-tests)
;;; etaf-tanks-tests.el ends here
