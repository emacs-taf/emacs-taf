;;; -*- lexical-binding: t; -*-
;;; etaf-tanks-views.el --- Stage select, battle HUD, editor screen and dialogs
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; The native phase chooses the screen: the menu previews a stage, the editor
;; paints a draft and every battle phase shows the battlefield with its HUD.
;; Lisp owns only presentation state: the catalog, selection, campaign
;; origin, editor draft, settings and dialogs.

;;; Code:
(require 'cl-lib)
(require 'subr-x)
(require 'etaf-ui)
(require 'etaf-gamekit)
(require 'etaf-tanks-theme)
(require 'etaf-tanks-maps)
(require 'etaf-tanks-model)
(require 'etaf-tanks-board)
(require 'etaf-tanks-editor)
(declare-function etaf-tanks-close "etaf-tanks" (&optional instance))
(defvar etaf-tanks-appearance)
(defvar etaf-tanks-difficulty)
(defvar etaf-tanks-map-directory)

(defconst etaf-tanks--difficulties '((easy . "简单") (normal . "普通") (hard . "困难"))
  "Difficulty names in menu order.")

(defconst etaf-tanks--panel-columns 30
  "Width of the side panel in character columns.")

(defconst etaf-tanks--bonus-names
  '(("helmet" . "头盔") ("clock" . "时钟") ("shovel" . "铁锹") ("star" . "星星") ("grenade" . "手雷") ("tank" . "坦克"))
  "Display names of the bonus items.")

(cl-defstruct (etaf-tanks--ui (:constructor etaf-tanks--ui-make) (:copier nil))
  "Presentation state of one tank battle; slots hold reactive refs."
  session metrics directory appearance appearance-override settings difficulty catalog tab selection
  progress origin
  draft cursor brush brush-size pen history dirty settings-open)

;;; Catalog and selection

(defun etaf-tanks--entries (ui)
  "Return UI's built-in and custom catalog entries."
  (let ((catalog (etaf-value (etaf-tanks--ui-catalog ui))))
    (append (plist-get catalog :builtin) (plist-get catalog :custom))))

(defun etaf-tanks--entry (ui &optional key)
  "Return UI's catalog entry for KEY, defaulting to the selection."
  (let ((key (or key (etaf-value (etaf-tanks--ui-selection ui)))))
    (cl-find key (etaf-tanks--entries ui) :key (lambda (entry) (plist-get entry :key)) :test #'equal)))

(defun etaf-tanks--builtin (ui number)
  "Return UI's campaign entry for stage NUMBER, looping after the last map."
  (let ((stages (plist-get (etaf-value (etaf-tanks--ui-catalog ui)) :builtin)))
    (nth (mod (1- number) (length stages)) stages)))

(defun etaf-tanks--menu-sync (ui)
  "Show UI's selected map as the menu preview."
  (when-let* ((entry (etaf-tanks--entry ui)))
    (etaf-tanks--send (etaf-tanks--ui-session ui) "menu" (list :map (plist-get entry :text)))))

(defun etaf-tanks--select (ui key)
  "Select catalog KEY in UI and preview it."
  (unless (equal key (etaf-value (etaf-tanks--ui-selection ui)))
    (setf (etaf-value (etaf-tanks--ui-selection ui)) key)
    (etaf-tanks--menu-sync ui)))

(defun etaf-tanks--refresh-catalog (ui &optional select)
  "Reread UI's custom maps and select SELECT when given."
  (let ((catalog (etaf-value (etaf-tanks--ui-catalog ui))))
    (setf (etaf-value (etaf-tanks--ui-catalog ui))
          (list :builtin (plist-get catalog :builtin) :custom (etaf-tanks--custom-maps))))
  (when select
    (setf (etaf-value (etaf-tanks--ui-tab ui)) (if (string-prefix-p "file:" select) "custom" "builtin")
          (etaf-value (etaf-tanks--ui-selection ui)) select)))

;;; Battle flow

(defun etaf-tanks--begin (ui text stage origin)
  "Start a fresh battle in UI on map TEXT as STAGE remembered as ORIGIN."
  (setf (etaf-value (etaf-tanks--ui-origin ui)) origin)
  (etaf-tanks--send (etaf-tanks--ui-session ui) "begin"
                    (list :map text :stage stage
                          :difficulty (symbol-name (etaf-value (etaf-tanks--ui-difficulty ui))))))

(defun etaf-tanks--start-selected (ui)
  "Start the selected stage or custom map."
  (when-let* ((entry (etaf-tanks--entry ui)))
    (etaf-tanks--begin ui (plist-get entry :text) (plist-get entry :number)
                       (if (plist-get entry :builtin) '(:kind campaign) (list :kind 'custom :key (plist-get entry :key))))))

(defun etaf-tanks--campaign-p (ui)
  "Whether UI's current battle belongs to the built-in campaign."
  (eq (plist-get (etaf-value (etaf-tanks--ui-origin ui)) :kind) 'campaign))

(defun etaf-tanks--advance (ui)
  "Carry lives, score and star into the next campaign stage."
  (let* ((session (etaf-tanks--ui-session ui))
         (stage (plist-get (etaf-gamekit-observation session) :stage)))
    (when (and (etaf-tanks--campaign-p ui) (equal (etaf-tanks--phase session) "cleared"))
      (etaf-tanks--send session "next" (list :map (plist-get (etaf-tanks--builtin ui (1+ stage)) :text)
                                             :stage (1+ stage))))))

(defun etaf-tanks--retry (ui)
  "Restart the current map from the stage's opening resources."
  (let ((session (etaf-tanks--ui-session ui)))
    (when (or (not (etaf-tanks--live-p session))
              (progn (etaf-tanks--pause-for-input session)
                     (etaf-confirm-dialog "重新开始本关？当前进度会丢失。")))
      (etaf-tanks--send session "restart"))))

(defun etaf-tanks--leave-battle (ui)
  "Return from a battle to the editor for test plays, otherwise the menu."
  (let ((session (etaf-tanks--ui-session ui)))
    (when (or (not (etaf-tanks--live-p session))
              (progn (etaf-tanks--pause-for-input session)
                     (etaf-confirm-dialog "放弃这场战斗并返回？")))
      (if (eq (plist-get (etaf-value (etaf-tanks--ui-origin ui)) :kind) 'draft)
          (etaf-tanks--editor-sync ui)
        (etaf-tanks--menu-sync ui)))))

(defun etaf-tanks--toggle-pause (ui)
  "Pause or resume UI's battle."
  (let ((session (etaf-tanks--ui-session ui)))
    (when (member (etaf-tanks--phase session) '("intro" "play"))
      (etaf-tanks--send session "pause"))))

(defun etaf-tanks--drive (ui direction)
  "Drive UI's tank toward DIRECTION, an ETAF direction symbol."
  (if (etaf-value (etaf-tanks--ui-settings-open ui))
      'release
    (etaf-tanks--send (etaf-tanks--ui-session ui) "drive"
                      (list :direction (pcase direction ('up "n") ('down "s") ('left "w") (_ "e"))))
    'handled))

(defun etaf-tanks--snapshot (ui operation)
  "Pause UI's battle and run snapshot OPERATION on a prompted path."
  (let ((session (etaf-tanks--ui-session ui)))
    (if (and (equal operation "save") (not (member (etaf-tanks--phase session) '("intro" "play"))))
        (message "坦克大战：只有战斗中才能存档")
      (etaf-tanks--pause-for-input session)
      (let ((path (etaf-call-with-input
                   (lambda ()
                     (read-file-name (if (equal operation "save") "保存战斗到：" "读取战斗：")
                                     nil nil (equal operation "load") "tanks.json")))))
        (when (and path (not (string-empty-p path)))
          (when (equal operation "load")
            (setf (etaf-value (etaf-tanks--ui-origin ui)) '(:kind loaded)))
          (etaf-tanks--send session operation (list :path (expand-file-name path))))))))

(defun etaf-tanks--record (ui phase)
  "Remember UI's result when the native PHASE ends a battle."
  (let* ((session (etaf-tanks--ui-session ui))
         (observation (etaf-gamekit-observation session))
         (stage (plist-get observation :stage))
         (origin (etaf-value (etaf-tanks--ui-origin ui)))
         (campaign (or (eq (plist-get origin :kind) 'campaign)
                       (and (eq (plist-get origin :kind) 'loaded)
                            (equal (plist-get observation :title)
                                   (plist-get (etaf-tanks--builtin ui stage) :name))))))
    (when campaign
      (when (eq (plist-get origin :kind) 'loaded)
        (setf (etaf-value (etaf-tanks--ui-origin ui)) '(:kind campaign)))
      (setf (etaf-value (etaf-tanks--ui-progress ui))
            (etaf-tanks--progress-record
             (etaf-value (etaf-tanks--ui-progress ui)) (intern (plist-get observation :difficulty))
             (and (equal phase "cleared") (1+ (mod (1- stage) 20)))
             (plist-get (plist-get observation :tally) :score))))))

;;; Settings

(defun etaf-tanks--apply-settings (ui settings)
  "Use SETTINGS for UI and send them to the native world."
  (setf (etaf-value (etaf-tanks--ui-settings ui)) settings)
  (etaf-tanks--send (etaf-tanks--ui-session ui) "settings" (etaf-tanks--native-settings settings)))

(defun etaf-tanks--set-setting (ui key value)
  "Change one setting KEY of UI to VALUE."
  (etaf-tanks--apply-settings ui (plist-put (copy-sequence (etaf-value (etaf-tanks--ui-settings ui))) key value)))

(defun etaf-tanks--save-defaults (ui)
  "Save UI's settings and difficulty as the defaults for new instances."
  (let ((settings (etaf-value (etaf-tanks--ui-settings ui))))
    (customize-save-variable 'etaf-tanks-game-speed (plist-get settings :speed))
    (customize-save-variable 'etaf-tanks-tank-speed (plist-get settings :tank-speed))
    (customize-save-variable 'etaf-tanks-sensitivity (plist-get settings :sensitivity))
    (customize-save-variable 'etaf-tanks-drive-mode (plist-get settings :drive))
    (customize-save-variable 'etaf-tanks-frame-rate (plist-get settings :frame-rate))
    (customize-save-variable 'etaf-tanks-board-size (plist-get settings :board))
    (customize-save-variable 'etaf-tanks-difficulty (etaf-value (etaf-tanks--ui-difficulty ui)))
    (message "坦克大战：已保存为默认设置")))

(defun etaf-tanks--display-sync (ui display)
  "Point UI's native canvas at its strip directory with DISPLAY.
DISPLAY is (THEME DEVICE-BLOCK DEVICE-LINE) for the current board."
  (when (and (etaf-tanks--ui-directory ui) display)
    (etaf-tanks--send (etaf-tanks--ui-session ui) "display"
                      (list :directory (etaf-tanks--ui-directory ui) :theme (symbol-name (nth 0 display))
                            :block (nth 1 display) :line (nth 2 display)))))

;;; Editor

(defun etaf-tanks--editor-sync (ui)
  "Send UI's draft and cursor to the native editor preview."
  (let ((draft (etaf-value (etaf-tanks--ui-draft ui))) (cursor (etaf-value (etaf-tanks--ui-cursor ui))))
    (etaf-tanks--send (etaf-tanks--ui-session ui) "edit"
                      (list :map (etaf-tanks--draft-text draft) :x (car cursor) :y (cdr cursor)
                            :size (if (memq (etaf-value (etaf-tanks--ui-brush ui)) etaf-tanks--marks) 2
                                    (etaf-value (etaf-tanks--ui-brush-size ui)))))))

(defun etaf-tanks--editor-open (ui draft)
  "Edit DRAFT in UI from a clean history."
  (setf (etaf-value (etaf-tanks--ui-draft ui)) draft
        (etaf-value (etaf-tanks--ui-history ui)) nil
        (etaf-value (etaf-tanks--ui-dirty ui)) nil
        (etaf-value (etaf-tanks--ui-pen ui)) t
        (etaf-value (etaf-tanks--ui-cursor ui)) (cons 0 0))
  (etaf-tanks--editor-sync ui))

(defun etaf-tanks--editor-edit-selected (ui)
  "Edit the selected custom map, or a copy of the selected stage."
  (when-let* ((entry (etaf-tanks--entry ui)) (map (etaf-tanks--map-parse (plist-get entry :text))))
    (etaf-tanks--editor-open
     ui (list :name (if (plist-get entry :builtin) (concat (plist-get map :name) " 改") (plist-get map :name))
              :counts (plist-get map :counts) :rows (plist-get map :rows)
              :file (and (not (plist-get entry :builtin)) (plist-get entry :file))))))

(defun etaf-tanks--editor-new (ui)
  "Edit a new empty map in UI."
  (etaf-tanks--editor-open ui (list :name "新地图" :counts (list 20 6 3 1) :rows (etaf-tanks--blank-rows 40 30))))

(defun etaf-tanks--editor-change (ui draft)
  "Replace UI's draft with DRAFT, keeping undo history."
  (let ((old (etaf-value (etaf-tanks--ui-draft ui))))
    (unless (equal old draft)
      (setf (etaf-value (etaf-tanks--ui-history ui)) (seq-take (cons old (etaf-value (etaf-tanks--ui-history ui))) 200)
            (etaf-value (etaf-tanks--ui-draft ui)) draft
            (etaf-value (etaf-tanks--ui-dirty ui)) t)
      (etaf-tanks--editor-sync ui))))

(defun etaf-tanks--editor-undo (ui)
  "Restore UI's previous draft."
  (when-let* ((history (etaf-value (etaf-tanks--ui-history ui))))
    (setf (etaf-value (etaf-tanks--ui-draft ui)) (car history)
          (etaf-value (etaf-tanks--ui-history ui)) (cdr history)
          (etaf-value (etaf-tanks--ui-dirty ui)) t)
    (etaf-tanks--editor-sync ui)))

(defun etaf-tanks--editor-paint (ui)
  "Paint UI's brush at its cursor."
  (let* ((cursor (etaf-value (etaf-tanks--ui-cursor ui)))
         (result (etaf-tanks--draft-paint (etaf-value (etaf-tanks--ui-draft ui)) (car cursor) (cdr cursor)
                                          (etaf-value (etaf-tanks--ui-brush ui))
                                          (etaf-value (etaf-tanks--ui-brush-size ui)))))
    (if (stringp result) (message "坦克大战：%s" result) (etaf-tanks--editor-change ui result))))

(defun etaf-tanks--editor-move (ui direction &optional move-only)
  "Move UI's cursor toward DIRECTION and paint unless MOVE-ONLY.
Painting is the default while the pen is on, so a held arrow draws a stroke;
MOVE-ONLY steps the cursor without changing the map."
  (if (etaf-value (etaf-tanks--ui-settings-open ui))
      'release
    (let* ((cursor (etaf-value (etaf-tanks--ui-cursor ui)))
           (size (etaf-tanks--draft-size (etaf-value (etaf-tanks--ui-draft ui))))
           (x (min (1- (car size)) (max 0 (+ (car cursor) (pcase direction ('left -1) ('right 1) (_ 0))))))
           (y (min (1- (cadr size)) (max 0 (+ (cdr cursor) (pcase direction ('up -1) ('down 1) (_ 0)))))))
      (setf (etaf-value (etaf-tanks--ui-cursor ui)) (cons x y))
      (if (and (etaf-value (etaf-tanks--ui-pen ui)) (not move-only))
          (etaf-tanks--editor-paint ui)
        (etaf-tanks--editor-sync ui))
      'handled)))

(defun etaf-tanks--editor-brush (ui brush)
  "Choose BRUSH for UI's editor."
  (setf (etaf-value (etaf-tanks--ui-brush ui)) brush)
  (etaf-tanks--editor-sync ui))

(defun etaf-tanks--editor-save (ui &optional ask)
  "Write UI's draft to its file, asking for a file when ASK or new."
  (let* ((draft (etaf-value (etaf-tanks--ui-draft ui)))
         (file (or (and (not ask) (plist-get draft :file))
                   (let ((answer (etaf-call-with-input
                                  (lambda ()
                                    (make-directory etaf-tanks-map-directory t)
                                    (read-file-name "保存地图到：" (file-name-as-directory etaf-tanks-map-directory) nil nil
                                                    (concat (replace-regexp-in-string
                                                             "[/\\\\:*?\"<>| ]+" "-"
                                                             (let ((name (string-trim (plist-get draft :name))))
                                                               (if (string-empty-p name) "map" name)))
                                                            ".txt"))))))
                     (and answer (not (string-empty-p answer)) (expand-file-name answer))))))
    (when file
      (when (and (not (equal file (plist-get draft :file))) (file-exists-p file)
                 (not (etaf-confirm-dialog (format "覆盖 %s？" (file-name-nondirectory file)))))
        (setq file nil))
      (when file
        (etaf-tanks--write-file file (etaf-tanks--draft-text draft))
        (setf (etaf-value (etaf-tanks--ui-draft ui)) (plist-put (copy-sequence draft) :file file)
              (etaf-value (etaf-tanks--ui-dirty ui)) nil)
        (etaf-tanks--refresh-catalog ui)
        (message "坦克大战：地图已保存到 %s" (abbreviate-file-name file))))))

(defun etaf-tanks--editor-load (ui)
  "Open a map file into UI's editor."
  (let ((file (etaf-call-with-input
               (lambda () (read-file-name "打开地图：" (file-name-as-directory etaf-tanks-map-directory) nil t)))))
    (when (and file (file-regular-p file))
      (let ((map (etaf-tanks--map-parse (with-temp-buffer (insert-file-contents file nil 0 65536) (buffer-string)))))
        (if (not map) (message "坦克大战：%s 里没有 map: 段落" (abbreviate-file-name file))
          (etaf-tanks--editor-open ui (list :name (plist-get map :name) :counts (plist-get map :counts)
                                            :rows (plist-get map :rows) :file (expand-file-name file))))))))

(defun etaf-tanks--editor-close (ui)
  "Leave UI's editor for the menu, confirming unsaved changes."
  (when (or (not (etaf-value (etaf-tanks--ui-dirty ui)))
            (etaf-confirm-dialog "地图尚未保存，仍然返回？"))
    (when-let* ((file (plist-get (etaf-value (etaf-tanks--ui-draft ui)) :file)))
      (etaf-tanks--refresh-catalog ui (concat "file:" file)))
    (etaf-tanks--menu-sync ui)))

(defun etaf-tanks--editor-test (ui)
  "Play UI's draft as a one-off battle unless the native world rejects it."
  (let ((problem (etaf-gamekit-view (etaf-tanks--ui-session ui) :map_error)))
    (if (and (stringp problem) (not (string-empty-p problem)))
        (message "坦克大战：%s" problem)
      (etaf-tanks--begin ui (etaf-tanks--draft-text (etaf-value (etaf-tanks--ui-draft ui))) 1 '(:kind draft)))))

;;; Layout

(defun etaf-tanks--layout (metrics viewport size screen preferred)
  "Return the board geometry and arrangement for SIZE blocks on SCREEN.
METRICS are the current buffer's display metrics and VIEWPORT the
Runtime's (PIXELS . ROWS).  Blocks are PREFERRED pixels when they fit.  The
side panel sits right of the board; a battle moves a compact HUD below it
when that allows larger blocks."
  (let* ((char (plist-get metrics :char-width)) (line (plist-get metrics :line-height))
         (pixels (or (car viewport) (* 120 char))) (rows (or (cdr viewport) 44))
         (beside (- pixels (* (+ 7 etaf-tanks--panel-columns) char)))
         (below (- pixels (* 4 char))))
    (if (not (plist-get metrics :graphic))
        (let ((geometry (etaf-tanks--board-geometry size metrics nil)))
          (list :board geometry
                :stacked (< beside (* (plist-get geometry :columns) char))))
      (let* ((side (etaf-tanks--fit-block size preferred beside (* (- rows 4) line)))
             (under (etaf-tanks--fit-block size preferred below (* (- rows 8) line)))
             (stacked (and (eq screen 'battle) (> under side))))
        (list :board (etaf-tanks--board-geometry size metrics (if stacked under side))
              :stacked stacked)))))

;;; Panels

(defun etaf-tanks--enemy-icons (remaining)
  "Return reserve icon lines for REMAINING enemies, ten per line."
  (cl-loop for start from 0 below (max 1 remaining) by 10
           collect (string-join (make-list (min 10 (- remaining start)) "■") " ")))

(etaf-define-component etaf-tanks--menu-panel (&key ui map-error)
  "Choose a stage or custom map, the difficulty and the next action."
  :bindings ((catalog (etaf-tanks--ui-catalog ui)) (selection (etaf-tanks--ui-selection ui))
             (tab (etaf-tanks--ui-tab ui)) (progress (etaf-tanks--ui-progress ui))
             (difficulty (etaf-tanks--ui-difficulty ui))
             (entry (etaf-computed (lambda () (etaf-value selection) (etaf-value catalog) (etaf-tanks--entry ui))
                                   :test #'equal))
             (cleared (etaf-computed (lambda () (etaf-tanks--progress-cleared (etaf-value progress) (etaf-value difficulty)))
                                     :test #'equal)))
  :view
  (column :ref 'tanks-menu :width (list 'ch etaf-tanks--panel-columns) :item-gap '(lh 1)
    (etaf-tabs :active tab
               :items '((:key "builtin" :label "战役" :ref tanks-tab-builtin)
                        (:key "custom" :label "自定义" :ref tanks-tab-custom))
               :on-change (lambda (value) (setf (etaf-value tab) value)))
    (etaf-tile-grid :if (equal (etaf-value tab) "builtin") :rows 4 :columns 5 :cell-width 5
      :cell-ref (lambda (r c) (intern (format "tanks-stage-%02d" (+ 1 c (* 5 r)))))
      :cell-text (lambda (r c)
                   (let ((number (+ 1 c (* 5 r))))
                     (format " %s%02d " (if (memq number (etaf-value cleared)) "✓" " ") number)))
      :cell-color (lambda (r c)
                    (if (equal (format "stage-%02d" (+ 1 c (* 5 r))) (etaf-value selection))
                        (etaf-tanks--color :ui-button-primary-fg)
                      (etaf-tanks--color :ui-fg)))
      :cell-background (lambda (r c)
                         (if (equal (format "stage-%02d" (+ 1 c (* 5 r))) (etaf-value selection))
                             (etaf-tanks--color :ui-button-primary-bg)
                           (etaf-tanks--color :ui-panel-bg)))
      :cell-label (lambda (r c)
                    (let ((stage (nth (+ c (* 5 r)) (plist-get (etaf-value catalog) :builtin))))
                      (format "第 %d 关 %s" (plist-get stage :number) (plist-get stage :name))))
      :on-cell-focus (lambda (r c) (etaf-tanks--select ui (format "stage-%02d" (+ 1 c (* 5 r)))))
      :on-cell-press (lambda (r c)
                       (etaf-tanks--select ui (format "stage-%02d" (+ 1 c (* 5 r))))
                       (etaf-tanks--start-selected ui)))
    (column :if (equal (etaf-value tab) "custom") :width 'stretch
      (etaf-label :if (null (plist-get (etaf-value catalog) :custom))
                  :text "还没有自定义地图：按 N 新建，或在下方导入。" :variant 'muted :wrap-mode 'word)
      (etaf-button :for (custom (seq-take (plist-get (etaf-value catalog) :custom) 12)) :key (plist-get custom :key)
                   :label (truncate-string-to-width (plist-get custom :name) (- etaf-tanks--panel-columns 4) nil nil "…")
                   :variant (if (equal (plist-get custom :key) (etaf-value selection)) 'secondary 'ghost)
                   :on-press (lambda () (etaf-tanks--select ui (plist-get custom :key)))))
    (column
      (etaf-label :ref 'tanks-stage-name :variant 'strong
                  :text (let ((value (etaf-value entry)))
                          (if (plist-get value :builtin)
                              (format "第 %d 关 · %s" (plist-get value :number) (plist-get value :name))
                            (or (plist-get value :name) "未选择地图"))))
      (etaf-label :text (if (etaf-value entry) (etaf-tanks--entry-summary (etaf-value entry)) "") :variant 'muted)
      (grid :grid-template-columns '((fr 1) (fr 1)) :gap '((lh 0) (ch 2)) :width 'stretch
        (etaf-label :for (kind (and (etaf-value entry) (etaf-tanks--entry-roster (etaf-value entry))))
                    :key (car kind) :text (cdr kind) :variant 'muted)))
    (etaf-segmented :options etaf-tanks--difficulties :bind difficulty)
    (etaf-alert :if (etaf-value map-error) :title "地图无法游玩" :message (or (etaf-value map-error) "") :variant 'warning)
    (grid :grid-template-columns '((fr 1) (fr 1)) :gap '((lh 0) (ch 1)) :width 'stretch
      (etaf-button :label "出击 · g" :ref 'tanks-start :disabled (or (null (etaf-value entry)) (and (etaf-value map-error) t))
                   :on-press (lambda () (etaf-tanks--start-selected ui)))
      (etaf-button :label "编辑 · e" :ref 'tanks-edit :variant 'secondary :disabled (null (etaf-value entry))
                   :on-press (lambda () (etaf-tanks--editor-edit-selected ui)))
      (etaf-button :label "新建 · n" :ref 'tanks-new-map :variant 'ghost :on-press (lambda () (etaf-tanks--editor-new ui)))
      (etaf-button :label "导入" :ref 'tanks-import :variant 'ghost :on-press (lambda () (etaf-tanks--editor-load ui))))
    (etaf-label :variant 'muted
                :text (format "最高分 %d · 已通关 %d / 20"
                              (etaf-tanks--progress-best (etaf-value progress) (etaf-value difficulty))
                              (length (etaf-value cleared))))))

(etaf-define-component etaf-tanks--tally-card (&key ui tally phase stage)
  "Summarize a finished stage and offer the next step."
  :view
  (column :ref 'tanks-tally :width 'stretch
   (etaf-card :title (if (equal (etaf-value phase) "cleared") (format "第 %d 关 · 肃清" (etaf-value stage)) "战斗结束")
    (etaf-label :for (index '(0 1 2 3)) :key index :variant 'muted
                :text (format "%s  %2d 辆  %5d 分" (aref etaf-tanks--kind-names index)
                              (nth index (plist-get (etaf-value tally) :kills))
                              (nth index (plist-get (etaf-value tally) :points))))
    (etaf-label :text (format "总分 %d" (or (plist-get (etaf-value tally) :score) 0)) :variant 'strong)
    (etaf-button :if (and (equal (etaf-value phase) "cleared") (etaf-tanks--campaign-p ui))
                 :label (format "第 %d 关 · n" (1+ (etaf-value stage))) :ref 'tanks-next
                 :on-press (lambda () (etaf-tanks--advance ui)))
    (etaf-button :label (if (equal (etaf-value phase) "cleared") "再打一次 · r" "重新挑战 · r") :ref 'tanks-retry
                 :variant (if (and (equal (etaf-value phase) "cleared") (etaf-tanks--campaign-p ui)) 'ghost 'primary)
                 :on-press (lambda () (etaf-tanks--retry ui))))))

(etaf-define-component etaf-tanks--battle-panel (&key ui hud tally events phase paused stage title compact)
  "Show the battle summary, effects, result and controls.
COMPACT arranges the essentials in three rows under the board."
  :render
  (let* ((summary (etaf-value hud)) (ended (and (member (etaf-value phase) '("cleared" "over")) t))
         (event (car (last (etaf-value events))))
         (difficulty (alist-get (intern (or (plist-get (etaf-gamekit-observation (etaf-tanks--ui-session ui)) :difficulty) "normal"))
                                etaf-tanks--difficulties))
         (effects (delq nil (list (and (eq t (plist-get summary :shield)) "护盾")
                                  (and (eq t (plist-get summary :freeze)) "敌军冻结")
                                  (and (eq t (plist-get summary :fortify)) "基地加固")
                                  (and (plist-get summary :bonus)
                                       (concat "奖励：" (alist-get (plist-get summary :bonus) etaf-tanks--bonus-names nil nil #'equal))))))
         (pause-label (if (eq t (etaf-value paused)) "继续 · p" "暂停 · p")))
    (if compact
        (etaf-view
         (column :ref 'tanks-hud :width 'stretch
           (flex :width 'stretch :justify-content 'space-between
             (etaf-label :variant 'strong :text (format "第 %d 关 %s · %s" (etaf-value stage) (etaf-value title) difficulty))
             (etaf-label :text (format "敌 %d+%d · ♥ %d · ★ %d · %d 分" (plist-get summary :remaining) (plist-get summary :field)
                                       (plist-get summary :lives) (plist-get summary :star) (plist-get summary :score))))
           (row :item-gap '(ch 1)
             (etaf-button :if (not ended) :label pause-label :ref 'tanks-pause :on-press (lambda () (etaf-tanks--toggle-pause ui)))
             (etaf-button :if (and ended (equal (etaf-value phase) "cleared") (etaf-tanks--campaign-p ui))
                          :label "下一关 · n" :ref 'tanks-next :on-press (lambda () (etaf-tanks--advance ui)))
             (etaf-button :label "重开 · r" :ref 'tanks-retry :variant 'ghost :on-press (lambda () (etaf-tanks--retry ui)))
             (etaf-button :label "返回 · m" :ref 'tanks-leave :variant 'ghost :on-press (lambda () (etaf-tanks--leave-battle ui)))
             (etaf-label :text (string-join effects " · ") :variant 'muted))
           (etaf-label :text (if event (concat (plist-get event :title) "：" (plist-get event :detail)) " ") :variant 'muted)))
      (etaf-view
       (column :ref 'tanks-hud :width (list 'ch etaf-tanks--panel-columns) :item-gap '(lh 1)
         (column
           (etaf-label :ref 'tanks-stage-title :variant 'strong :text (format "第 %d 关 · %s" (etaf-value stage) (etaf-value title)))
           (etaf-label :text (format "%s · 待出 %d · 在场 %d" difficulty (plist-get summary :remaining) (plist-get summary :field))
                       :variant 'muted))
         (column :ref 'tanks-reserve
           (etaf-label :for (line (seq-map-indexed (lambda (text index) (cons index text)) (etaf-tanks--enemy-icons (plist-get summary :remaining))))
                       :key (car line) :text (cdr line)
                       :color (etaf-tanks--color :ui-danger-fg)))
         (grid :grid-template-columns '((fr 1) (fr 1)) :gap '((lh 0) (ch 2)) :width 'stretch
           (etaf-label :ref 'tanks-lives :text (format "生命 ♥ %d" (plist-get summary :lives)))
           (etaf-label :ref 'tanks-score :text (format "得分 %d" (plist-get summary :score)))
           (etaf-label :text (format "火力 %s" (concat (make-string (plist-get summary :star) ?★)
                                                       (make-string (- 3 (plist-get summary :star)) ?☆))))
           (etaf-label :text (format "击毁 %d / %d" (apply #'+ (plist-get summary :kills)) (plist-get summary :total))))
         (row :item-gap '(ch 1)
           (etaf-tag :for (effect (or effects (list "无增益"))) :key effect :text effect
                     :variant (if effects 'info 'neutral)))
         (etaf-tanks--tally-card :if ended :ui ui :tally tally :phase phase :stage stage)
         (grid :grid-template-columns '((fr 1) (fr 1)) :gap '((lh 0) (ch 1)) :width 'stretch
           (etaf-button :label pause-label :ref 'tanks-pause :variant 'secondary :disabled ended
                        :on-press (lambda () (etaf-tanks--toggle-pause ui)))
           (etaf-button :label "重开 · r" :ref 'tanks-restart :variant 'ghost :disabled ended
                        :on-press (lambda () (etaf-tanks--retry ui)))
           (etaf-button :label "存档 · C-s" :ref 'tanks-save :variant 'ghost :disabled ended
                        :on-press (lambda () (etaf-tanks--snapshot ui "save")))
           (etaf-button :label "读档 · C-o" :ref 'tanks-load :variant 'ghost
                        :on-press (lambda () (etaf-tanks--snapshot ui "load")))
           (etaf-button :label (if (eq (plist-get (etaf-value (etaf-tanks--ui-origin ui)) :kind) 'draft) "回编辑 · m" "菜单 · m")
                        :ref 'tanks-leave :variant 'ghost :on-press (lambda () (etaf-tanks--leave-battle ui))))
         (column :ref 'tanks-event
           (etaf-tag :if event :text (or (plist-get event :title) "") :variant (intern (or (plist-get event :kind) "info")))
           (etaf-label :text (or (plist-get event :detail) "方向键驾驶，f 开火。") :variant 'muted :wrap-mode 'word)))))))

;;; Dialogs

(defun etaf-tanks--percent (value)
  "Return speed VALUE as a slider percentage aligned to ten."
  (* 10 (max 5 (min 20 (round (* 10 value))))))

(etaf-define-component etaf-tanks--settings-dialog (&key ui)
  "Adjust speeds, input timing, frame rate, appearance and board size live."
  :bindings ((settings (etaf-tanks--ui-settings ui)) (open (etaf-tanks--ui-settings-open ui))
             (appearance (etaf-tanks--ui-appearance ui))
             (appearance-override (etaf-tanks--ui-appearance-override ui)))
  :view
  (etaf-dialog :open open :title "设置" :width '(ch 56) :compact t :close-label nil
               :on-close (lambda () (setf (etaf-value open) nil))
    (column :ref 'tanks-settings :item-gap '(lh 1)
      (etaf-slider :label "游戏速度（%）" :min 50 :max 200 :step 10
                   :value (etaf-tanks--percent (plist-get (etaf-value settings) :speed))
                   :on-change (lambda (value) (etaf-tanks--set-setting ui :speed (/ value 100.0))))
      (etaf-slider :label "我方坦克速度（%）" :min 50 :max 200 :step 10
                   :value (etaf-tanks--percent (plist-get (etaf-value settings) :tank-speed))
                   :on-change (lambda (value) (etaf-tanks--set-setting ui :tank-speed (/ value 100.0))))
      (column
        (etaf-label :text "方向键灵敏度" :variant 'strong)
        (etaf-segmented :options '((auto . "跟随系统") (sensitive . "灵敏") (standard . "标准") (smooth . "平滑"))
                        :value (plist-get (etaf-value settings) :sensitivity)
                        :on-change (lambda (value) (etaf-tanks--set-setting ui :sensitivity value)))
        (etaf-label :text "灵敏：松键即停；平滑：按键间隔大时不顿挫。" :variant 'muted))
      (column
        (etaf-label :text "驾驶方式" :variant 'strong)
        (etaf-segmented :options '((hold . "按住行驶") (latch . "点按持续"))
                        :value (plist-get (etaf-value settings) :drive)
                        :on-change (lambda (value) (etaf-tanks--set-setting ui :drive value))))
      (column
        (etaf-label :text "画面帧率" :variant 'strong)
        (etaf-segmented :options '((30 . "30 帧") (60 . "60 帧"))
                        :value (if (>= (plist-get (etaf-value settings) :frame-rate) 45) 60 30)
                        :on-change (lambda (value) (etaf-tanks--set-setting ui :frame-rate value))))
      (column
        (etaf-label :text "外观" :variant 'strong)
        (etaf-segmented :options '((light . "浅色") (dark . "深色"))
                        :value (etaf-value appearance)
                        :on-change (lambda (value)
                                     (etaf-batch
                                       (setf (etaf-value appearance-override) value)))))
      (expr (when (plist-get (etaf-tanks--ui-metrics ui) :graphic)
              (etaf-view
               (column
                 (etaf-label :text "画面大小" :variant 'strong)
                 (etaf-segmented :options '((small . "小") (medium . "中") (large . "大"))
                                 :value (plist-get (etaf-value settings) :board)
                                 :on-change (lambda (value) (etaf-tanks--set-setting ui :board value)))
                 (etaf-label :text "窗口放不下时自动缩小。" :variant 'muted)))))
      (row :item-gap '(ch 1)
        (etaf-button :label "保存为默认" :ref 'tanks-settings-save :variant 'secondary
                     :on-press (lambda () (etaf-tanks--save-defaults ui)))
        (etaf-button :label "恢复默认" :ref 'tanks-settings-reset :variant 'ghost
                     :on-press (lambda () (etaf-tanks--apply-settings ui (etaf-tanks--default-settings))))
        (etaf-button :label "完成" :ref 'tanks-settings-done
                     :on-press (lambda () (setf (etaf-value open) nil)))))))

(defconst etaf-tanks--help-notes
  '("守住底部的雄鹰基地，击毁本关全部敌车即过关。基地被击中、或生命耗尽，战斗结束。敌车从上方出生点分批出场，场上数量有上限。"
    "敌车：普通车慢；快速车跑得快；重炮车炮弹飞得快；装甲车要打 4 炮，颜色随剩余装甲变化。闪红光的敌车被击毁后掉落奖励：头盔护盾、时钟冻结、铁锹加固基地、星星升级火力、手雷全灭、坦克加命。"
    "地形：砖墙可打穿；钢板要三星火力才能打穿；河流挡车不挡弹；树林遮挡视线；冰面会打滑。"
    "设置中的游戏速度、坦克速度、方向键灵敏度、驾驶方式和帧率立即生效。打开帮助、设置或文件提示会先暂停战斗，关闭后须主动继续。")
  "Rules and workflow notes; bindings come from the active key scope.")

;;; Root

(defun etaf-tanks--keys (ui screen)
  "Return the application keys of UI for SCREEN."
  (let* ((session (etaf-tanks--ui-session ui))
         (common (list (list "s" (lambda () (etaf-tanks--pause-for-input session)
                                    (setf (etaf-value (etaf-tanks--ui-settings-open ui)) t))
                             "设置")
                       (list "t" (lambda ()
                                   (etaf-batch
                                     (setf (etaf-value (etaf-tanks--ui-appearance-override ui))
                                           (if (eq (etaf-value (etaf-tanks--ui-appearance ui)) 'dark)
                                               'light 'dark))))
                             "亮暗主题")
                       (list "<f1>" #'etaf-help "规则与按键")
                       (list "q" (lambda () (etaf-tanks-close session)) "退出"))))
    (append
     (pcase screen
       ('battle
        (list (list "f" (lambda () (etaf-tanks--send session "fire")) "开火")
              (list "x" (lambda () (etaf-tanks--send session "stop")) "停车")
              (list "S-<up>" (lambda () (etaf-tanks--send session "aim" '(:direction "n"))) "向北转向")
              (list "S-<down>" (lambda () (etaf-tanks--send session "aim" '(:direction "s"))) "向南转向")
              (list "S-<left>" (lambda () (etaf-tanks--send session "aim" '(:direction "w"))) "向西转向")
              (list "S-<right>" (lambda () (etaf-tanks--send session "aim" '(:direction "e"))) "向东转向")
              (list "p" (lambda () (etaf-tanks--toggle-pause ui)) "暂停或继续")
              (list "r" (lambda () (etaf-tanks--retry ui)) "重开本关")
              (list "n" (lambda () (etaf-tanks--advance ui)) "下一关")
              (list "m" (lambda () (etaf-tanks--leave-battle ui)) "返回")
              (list "C-s" (lambda () (etaf-tanks--snapshot ui "save")) "存档")
              (list "C-o" (lambda () (etaf-tanks--snapshot ui "load")) "读档")))
       ('editor
        (append
         (mapcar (lambda (brush)
                   (list (nth 2 brush) (lambda () (etaf-tanks--editor-brush ui (car brush)))
                         (concat "画笔：" (cadr brush))))
                 etaf-tanks--brushes)
         (list (list "f" (lambda () (etaf-tanks--editor-paint ui)) "原地绘制")
               (list "S-<left>" (lambda () (etaf-tanks--editor-move ui 'left t)) "只左移")
               (list "S-<right>" (lambda () (etaf-tanks--editor-move ui 'right t)) "只右移")
               (list "S-<up>" (lambda () (etaf-tanks--editor-move ui 'up t)) "只上移")
               (list "S-<down>" (lambda () (etaf-tanks--editor-move ui 'down t)) "只下移")
               (list "d" (lambda () (setf (etaf-value (etaf-tanks--ui-pen ui)) (not (etaf-value (etaf-tanks--ui-pen ui)))))
                     "移动时绘制")
               (list "b" (lambda () (setf (etaf-value (etaf-tanks--ui-brush-size ui)) (- 3 (etaf-value (etaf-tanks--ui-brush-size ui))))
                           (etaf-tanks--editor-sync ui))
                     "笔刷大小")
               (list "u" (lambda () (etaf-tanks--editor-undo ui)) "撤销")
               (list "p" (lambda () (etaf-tanks--editor-test ui)) "试玩")
               (list "C-s" (lambda () (etaf-tanks--editor-save ui)) "保存地图")
               (list "m" (lambda () (etaf-tanks--editor-close ui)) "返回菜单"))))
       ('menu
        (list (list "g" (lambda () (etaf-tanks--start-selected ui)) "出击")
              (list "e" (lambda () (etaf-tanks--editor-edit-selected ui)) "编辑地图")
              (list "n" (lambda () (etaf-tanks--editor-new ui)) "新建地图")
              (list "d" (lambda () (let* ((order (mapcar #'car etaf-tanks--difficulties))
                                          (current (etaf-value (etaf-tanks--ui-difficulty ui))))
                                     (setf (etaf-value (etaf-tanks--ui-difficulty ui))
                                           (or (cadr (memq current order)) (car order)))))
                    "切换难度"))))
     common)))

(defun etaf-tanks--focus-target (ui screen)
  "Return the Host that should hold focus when SCREEN appears in UI."
  (if (eq screen 'menu)
      (let ((entry (etaf-tanks--entry ui)))
        (if (and entry (plist-get entry :builtin) (equal (etaf-value (etaf-tanks--ui-tab ui)) "builtin"))
            (intern (format "tanks-stage-%02d" (plist-get entry :number)))
          'tanks-start))
    'tanks-board))

(defun etaf-tanks--focus-screen (ui screen app-ref)
  "Focus SCREEN's entry only while UI's APP-REF still owns keyboard focus."
  (when (memq screen '(menu battle editor))
    (when-let* ((runtime (etaf-current-runtime)))
      (let* ((focus (etaf-focused-host-ref runtime))
             (ancestry (and focus (gethash focus
                                          (etaf-runtime-host-ancestries runtime (list focus))))))
        ;; Publication may replace a control inside this game, but must not
        ;; reenter it after the user returned to the host or another app.
        (when (and (or (null focus) (memq app-ref ancestry))
                   (not (cl-some
                         (lambda (ref)
                           (eq (plist-get (etaf-runtime-host-props-for runtime ref)
                                          :focus-scope)
                               'modal))
                         ancestry)))
          (etaf-focus runtime (etaf-tanks--focus-target ui screen)))))))

(etaf-define-component etaf-tanks--app (&key session graphic)
  "Compose one tank battle over SESSION.
GRAPHIC shows native frames from a private directory the instance owns."
  :bindings ((app-ref (etaf-local-ref 'application))
             (metrics (etaf-computed (lambda () (etaf-tanks--metrics graphic)) :test #'equal))
             (directory (and graphic (make-temp-file "etaf-tanks-" t)))
             (appearance-override (etaf-ref (unless (eq etaf-tanks-appearance 'auto)
                                               etaf-tanks-appearance)))
             (appearance (etaf-appearance-mode appearance-override))
             (builtin (etaf-tanks--builtin-stages))
             (progress (etaf-ref (etaf-tanks--progress-read)))
             (ui (etaf-tanks--ui-make
                  :session session :metrics (etaf-value metrics) :directory directory
                  :appearance appearance :appearance-override appearance-override
                  :settings (etaf-ref (etaf-tanks--default-settings))
                  :difficulty (etaf-ref etaf-tanks-difficulty)
                  :catalog (etaf-ref (list :builtin builtin :custom (etaf-tanks--custom-maps)))
                  :tab (etaf-ref "builtin")
                  :selection (etaf-ref (plist-get (or (cl-find-if-not
                                                       (lambda (stage)
                                                         (memq (plist-get stage :number)
                                                               (etaf-tanks--progress-cleared (etaf-value progress) etaf-tanks-difficulty)))
                                                       builtin)
                                                      (car builtin))
                                                  :key))
                  :progress progress :origin (etaf-ref nil)
                  :draft (etaf-ref (list :name "新地图" :counts (list 20 6 3 1) :rows (etaf-tanks--blank-rows 40 30)))
                  :cursor (etaf-ref (cons 0 0)) :brush (etaf-ref ?#) :brush-size (etaf-ref 1) :pen (etaf-ref t)
                  :history (etaf-ref nil) :dirty (etaf-ref nil) :settings-open (etaf-ref nil)))
             (theme (etaf-computed (lambda () (if (eq (etaf-value appearance) 'dark)
                                                  etaf-tanks--dark-theme etaf-tanks--light-theme))
                                   :test #'equal))
             (connected (etaf-computed (lambda () (and (memq (etaf-gamekit-status session) '(ready busy)) t))))
             (phase (etaf-computed (lambda () (etaf-gamekit-view session :phase)) :test #'equal))
             (screen (etaf-computed (lambda () (pcase (etaf-value phase)
                                                 ('nil 'loading) ("menu" 'menu) ("edit" 'editor) (_ 'battle)))))
             (paused (etaf-computed (lambda () (etaf-gamekit-view session :paused))))
             (stage (etaf-computed (lambda () (etaf-gamekit-view session :stage))))
             (title (etaf-computed (lambda () (etaf-gamekit-view session :title)) :test #'equal))
             (hud (etaf-computed (lambda () (etaf-gamekit-view session :hud)) :test #'equal))
             (tally (etaf-computed (lambda () (etaf-gamekit-view session :tally)) :test #'equal))
             (events (etaf-computed (lambda () (etaf-gamekit-view session :events)) :test #'equal))
             (map-error (etaf-computed (lambda () (let ((text (etaf-gamekit-view session :map_error)))
                                                    (and (stringp text) (not (string-empty-p text)) text)))
                                       :test #'equal))
             (observed-size (etaf-computed (lambda () (etaf-gamekit-view session :size)) :test #'equal))
             (frame (etaf-computed (lambda () (and graphic (etaf-gamekit-view session :frame))) :test #'equal))
             (world (etaf-computed (lambda () (and (not graphic) (etaf-gamekit-view session :world))) :test #'equal))
             (board-size (etaf-computed
                          (lambda ()
                            (pcase (etaf-value screen)
                              ('editor (etaf-tanks--draft-size (etaf-value (etaf-tanks--ui-draft ui))))
                              ('battle (or (etaf-value observed-size) (list 40 30)))
                              (_ (let ((entry (etaf-tanks--entry ui)))
                                   (if entry (list (plist-get entry :width) (plist-get entry :height)) (list 40 30))))))
                          :test #'equal))
             (viewport (etaf-computed (lambda () (etaf-viewport)) :test #'equal))
             (layout (etaf-computed (lambda () (etaf-tanks--layout
                                                 (etaf-value metrics) (etaf-value viewport) (etaf-value board-size) (etaf-value screen)
                                                 (alist-get (plist-get (etaf-value (etaf-tanks--ui-settings ui)) :board)
                                                            etaf-tanks--block-sizes 16)))
                                    :test #'equal))
             (geometry (etaf-computed (lambda () (plist-get (etaf-value layout) :board)) :test #'equal))
             (display (etaf-computed (lambda () (let ((board (etaf-value geometry)))
                                                  (and graphic (list (etaf-value appearance)
                                                                     (plist-get board :device-block)
                                                                     (plist-get board :device-line)))))
                                     :test #'equal))
             (text (etaf-computed
                    (lambda ()
                      (unless graphic
                        (let ((palette (etaf-value appearance)))
                          (pcase (etaf-value screen)
                            ('battle (when-let* ((data (etaf-value world)))
                                       (etaf-tanks--text-board (plist-get data :terrain) palette data)))
                            ('editor (let ((cursor (etaf-value (etaf-tanks--ui-cursor ui))))
                                       (etaf-tanks--text-board
                                        (plist-get (etaf-value (etaf-tanks--ui-draft ui)) :rows) palette nil
                                        (list (car cursor) (cdr cursor)
                                              (if (memq (etaf-value (etaf-tanks--ui-brush ui)) etaf-tanks--marks) 2
                                                (etaf-value (etaf-tanks--ui-brush-size ui)))))))
                            (_ (when-let* ((entry (etaf-tanks--entry ui))
                                           (map (etaf-tanks--map-parse (plist-get entry :text))))
                                 (etaf-tanks--text-board (plist-get map :rows) palette)))))))
                    :test #'equal)))
  :setup
  (progn
    (etaf-theme-provide theme)
    (when directory
      (etaf-on-unmounted (lambda () (when (file-directory-p directory) (delete-directory directory t)))))
    (etaf-watch connected
                (lambda (now _old)
                  (when now
                    (etaf-tanks--apply-settings ui (etaf-value (etaf-tanks--ui-settings ui)))
                    (etaf-tanks--display-sync ui (etaf-value display))
                    (etaf-tanks--menu-sync ui)))
                :immediate t)
    (etaf-watch display (lambda (now _old) (etaf-tanks--display-sync ui now)))
    (etaf-watch phase (lambda (now old)
                        (when (and (member now '("cleared" "over")) (member old '("intro" "play")))
                          (etaf-tanks--record ui now))))
    (etaf-on-mounted (lambda () (etaf-tanks--focus-screen ui (etaf-value screen) app-ref)))
    (etaf-watch screen (lambda (now _old) (etaf-tanks--focus-screen ui now app-ref)) :flush 'post)
    (etaf-watch viewport
                (lambda (_size _old)
                  (when-let* ((buffer (etaf-gamekit-buffer session))
                              (runtime (etaf-runtime-for-buffer buffer))
                              (bounds (etaf-host-ref-size runtime 'tanks-root)))
                    (dolist (window (get-buffer-window-list buffer nil t))
                      (when (>= (window-body-width window t) (car bounds)) (set-window-hscroll window 0))
                      (when (>= (window-body-height window) (cdr bounds))
                        (set-window-start window (with-current-buffer buffer (point-min)) t)))))
                :flush 'post))
  :render
  (let* ((current (etaf-value screen)) (arrangement (etaf-value layout))
         (stacked (plist-get arrangement :stacked)) (board (plist-get arrangement :board))
         (width (+ 4 (plist-get board :columns) (if stacked 0 (+ 3 etaf-tanks--panel-columns))))
         (fits (>= (or (car (etaf-value viewport)) 0) (* width (plist-get (etaf-value metrics) :char-width))))
         (canvas (etaf-view (etaf-gamekit-frame-canvas
                             :frame frame :text text :geometry geometry :directory directory
                             :background (etaf-tanks--color :ui-bg)
                             :label "战场" :ref 'tanks-board)))
         (panel (pcase current
                  ('menu (etaf-view (etaf-tanks--menu-panel :ui ui :map-error map-error)))
                  ('editor (etaf-view (etaf-tanks--editor-panel
                                       :draft (etaf-tanks--ui-draft ui) :brush (etaf-tanks--ui-brush ui)
                                       :brush-size (etaf-tanks--ui-brush-size ui) :pen (etaf-tanks--ui-pen ui)
                                       :history (etaf-tanks--ui-history ui)
                                       :map-error map-error :dirty (etaf-tanks--ui-dirty ui)
                                       :on-change (lambda (index value)
                                                    (let ((draft (copy-sequence (etaf-value (etaf-tanks--ui-draft ui)))))
                                                      (etaf-tanks--editor-change
                                                       ui (plist-put draft :counts
                                                                     (let ((counts (copy-sequence (plist-get draft :counts))))
                                                                       (setf (nth index counts) value) counts)))))
                                       ;; The name is not part of the preview: record it without a
                                       ;; history step or a native round trip per keystroke.
                                       :on-name (lambda (value)
                                                  (setf (etaf-value (etaf-tanks--ui-draft ui))
                                                        (plist-put (copy-sequence (etaf-value (etaf-tanks--ui-draft ui)))
                                                                   :name (replace-regexp-in-string "\n" " " value))
                                                        (etaf-value (etaf-tanks--ui-dirty ui)) t))
                                       :on-resize (lambda (width height)
                                                    (let* ((draft (etaf-value (etaf-tanks--ui-draft ui)))
                                                           (size (etaf-tanks--draft-size draft)))
                                                      (etaf-tanks--editor-change
                                                       ui (etaf-tanks--draft-resize draft (or width (car size)) (or height (cadr size))))
                                                      (let ((cursor (etaf-value (etaf-tanks--ui-cursor ui)))
                                                            (size (etaf-tanks--draft-size (etaf-value (etaf-tanks--ui-draft ui)))))
                                                        (setf (etaf-value (etaf-tanks--ui-cursor ui))
                                                              (cons (min (car cursor) (1- (car size))) (min (cdr cursor) (1- (cadr size))))))
                                                      (etaf-tanks--editor-sync ui)))
                                       :on-save (lambda () (etaf-tanks--editor-save ui))
                                       :on-save-as (lambda () (etaf-tanks--editor-save ui t))
                                       :on-test (lambda () (etaf-tanks--editor-test ui))
                                       :on-new (lambda () (when (or (not (etaf-value (etaf-tanks--ui-dirty ui)))
                                                                    (etaf-confirm-dialog "放弃未保存的修改并新建？"))
                                                            (etaf-tanks--editor-new ui)))
                                       :on-open (lambda () (when (or (not (etaf-value (etaf-tanks--ui-dirty ui)))
                                                                     (etaf-confirm-dialog "放弃未保存的修改并打开？"))
                                                             (etaf-tanks--editor-load ui)))
                                       :on-close (lambda () (etaf-tanks--editor-close ui))
                                       :on-brush (lambda (brush) (etaf-tanks--editor-brush ui brush))
                                       :on-paint (lambda () (etaf-tanks--editor-paint ui))
                                       :on-undo (lambda () (etaf-tanks--editor-undo ui))
                                       :on-size (lambda ()
                                                  (setf (etaf-value (etaf-tanks--ui-brush-size ui)) (- 3 (etaf-value (etaf-tanks--ui-brush-size ui))))
                                                  (etaf-tanks--editor-sync ui))
                                       :on-pen (lambda () (setf (etaf-value (etaf-tanks--ui-pen ui)) (not (etaf-value (etaf-tanks--ui-pen ui))))))))
                  ('battle (when (etaf-value hud)
                             (etaf-view (etaf-tanks--battle-panel :ui ui :hud hud :tally tally :events events :phase phase
                                                                  :paused paused :stage stage :title title :compact stacked))))
                  (_ (etaf-view (etaf-label :text "正在开赴战场…" :variant 'muted))))))
    (etaf-view
     (flex :ref app-ref :width 'stretch :height 'stretch :flex-direction 'column
           :on-focus-leave (lambda () (etaf-tanks--pause-for-input session))
           :align-items (if fits 'center 'flex-start)
             :background-color (etaf-tanks--color :ui-bg) :color (etaf-tanks--color :ui-fg)
             :on-direction (pcase current
                             ('battle (lambda (direction) (etaf-tanks--drive ui direction)))
                             ('editor (lambda (direction) (etaf-tanks--editor-move ui direction))))
             :keys (etaf-tanks--keys ui current)
             :aria-label "坦克大战" :help etaf-tanks--help-notes
             :on-help-open (lambda () (etaf-tanks--pause-for-input session))
       ;; Share only surplus height: keep the whole table slightly above center.
       (box :flex-grow 2 :flex-basis '(lh 0) :min-height '(lh 0))
       (column :ref 'tanks-root :flex-shrink 0 :width (list 'ch width)
               :padding '((lh 1) (ch 2)) :item-gap '(lh 1)
         (flex :width 'stretch :justify-content 'space-between :align-items 'center
           (row :item-gap '(ch 2)
             (etaf-label :text "坦克大战" :variant 'strong)
             (etaf-label :text (pcase current ('menu "选择关卡") ('editor "地图编辑") ('battle "战斗") (_ "")) :variant 'muted))
           (row :item-gap '(ch 1)
             (etaf-button :label "设置 · s" :ref 'tanks-settings-open :variant 'ghost
                          :on-press (lambda () (etaf-tanks--pause-for-input session)
                                      (setf (etaf-value (etaf-tanks--ui-settings-open ui)) t)))
             (etaf-button :label (if (eq (etaf-value appearance) 'dark) "浅色 · t" "深色 · t") :ref 'tanks-theme :variant 'ghost
                          :on-press (lambda ()
                                      (etaf-batch
                                        (setf (etaf-value appearance-override)
                                              (if (eq (etaf-value appearance) 'dark) 'light 'dark)))))
             (etaf-button :label "说明 · F1" :ref 'tanks-help :variant 'ghost
                          :on-press #'etaf-help)))
         (expr (if stacked
                   (etaf-view (column :item-gap '(lh 1) (expr canvas) (expr panel)))
                 (etaf-view (row :item-gap '(ch 3) (expr canvas) (expr panel)))))
         (etaf-alert :if (etaf-gamekit-last-error session) :title "操作未生效"
                     :message (or (etaf-gamekit-last-error session) "") :variant 'danger))
       (box :flex-grow 3 :flex-basis '(lh 0) :min-height '(lh 0))
       (etaf-tanks--settings-dialog :ui ui)))))

(defun etaf-tanks--view (session)
  "Compose SESSION's application view from public ETAF and GameKit APIs."
  (let ((graphic (and (display-graphic-p) (image-type-available-p 'png))))
    (etaf-view (etaf-tanks--app :session session :graphic graphic))))

(defun etaf-tanks-view (session)
  "Return SESSION's reactive View for embedding in a host such as etaf-desktop.

The caller owns SESSION's display and lifecycle; release it with
`etaf-gamekit-close'."
  (etaf-tanks--view session))

(provide 'etaf-tanks-views)
;;; etaf-tanks-views.el ends here
