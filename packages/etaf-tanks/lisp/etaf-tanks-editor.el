;;; -*- lexical-binding: t; -*-
;;; etaf-tanks-editor.el --- Map drafts and the map editor panel
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; A draft is plain map text held as fixed-width rows.  Every change sends the
;; whole text to the native world, which validates it and draws the cursor,
;; so the editor shows exactly what a battle on that map would play.

;;; Code:
(require 'cl-lib)
(require 'subr-x)
(require 'etaf-ui)
(require 'etaf-tanks-maps)
(require 'etaf-tanks-model)

(defconst etaf-tanks--brushes
  '((?. "空地" "1") (?# "砖墙" "2") (?@ "钢板" "3") (?~ "河流" "4") (?* "树林" "5")
    (?= "冰面" "6") (?H "基地" "7") (?P "我方" "8") (?E "敌军" "9"))
  "Editor brushes: map symbol, name and selection key.")

(defconst etaf-tanks--marks '(?H ?P ?E)
  "Symbols that always occupy one 2x2 group.")

(defun etaf-tanks--blank-rows (width height)
  "Return a playable empty WIDTH x HEIGHT map with base, player and spawns."
  (let* ((rows (cl-loop repeat height vconcat (list (make-string width ?.))))
         (bx (1- (/ width 2))) (by (- height 2))
         (stamp (lambda (x y symbol)
                  (dotimes (dy 2) (dotimes (dx 2) (aset (aref rows (+ y dy)) (+ x dx) symbol))))))
    (dolist (x (list 0 bx (- width 2))) (funcall stamp x 0 ?E))
    (funcall stamp bx by ?H)
    (funcall stamp (max 0 (- bx 4)) by ?P)
    (cl-loop for x from (1- bx) to (+ bx 2) do (aset (aref rows (1- by)) x ?#))
    (dolist (x (list (1- bx) (+ bx 2)))
      (dotimes (dy 2) (aset (aref rows (+ by dy)) x ?#)))
    (append rows nil)))

(defun etaf-tanks--draft-text (draft)
  "Return DRAFT as map text."
  (etaf-tanks--map-text (plist-get draft :name) (plist-get draft :counts) (plist-get draft :rows)))

(defun etaf-tanks--draft-size (draft)
  "Return DRAFT's (WIDTH HEIGHT) in blocks."
  (list (length (car (plist-get draft :rows))) (length (plist-get draft :rows))))

(defun etaf-tanks--clear-group (grid x y)
  "Erase the 4-connected group of GRID's symbol at X, Y."
  (let ((symbol (aref (aref grid y) x)) (stack (list (cons x y))))
    (while stack
      (pcase-let ((`(,cx . ,cy) (pop stack)))
        (when (and (<= 0 cy) (< cy (length grid)) (<= 0 cx) (< cx (length (aref grid cy)))
                   (eq (aref (aref grid cy) cx) symbol))
          (aset (aref grid cy) cx ?.)
          (push (cons (1+ cx) cy) stack) (push (cons (1- cx) cy) stack)
          (push (cons cx (1+ cy)) stack) (push (cons cx (1- cy)) stack))))))

(defun etaf-tanks--draft-paint (draft x y brush size)
  "Return DRAFT with BRUSH painted at X, Y, or a string explaining a refusal.
Terrain covers SIZE x SIZE blocks.  Base and player marks move to the
cursor; at most four enemy spawn groups exist.  Painting over part of a mark
removes the whole mark."
  (let* ((grid (vconcat (mapcar #'copy-sequence (plist-get draft :rows))))
         (height (length grid)) (width (length (aref grid 0)))
         (mark (memq brush etaf-tanks--marks))
         (span (if mark 2 size))
         (x (min x (- width span))) (y (min y (- height span))))
    (catch 'refuse
      (when (and (eq brush ?E)
                 (>= (/ (cl-loop for row across grid sum (cl-count ?E row)) 4) 4)
                 (not (cl-loop for dy below 2 thereis
                               (cl-loop for dx below 2 thereis (eq ?E (aref (aref grid (+ y dy)) (+ x dx)))))))
        (throw 'refuse "最多 4 个敌军出生点：先擦掉一个"))
      (when (memq brush '(?H ?P))
        (cl-loop for row across grid do
                 (dotimes (index (length row)) (when (eq (aref row index) brush) (aset row index ?.)))))
      (dotimes (dy span)
        (dotimes (dx span)
          (let ((cx (+ x dx)) (cy (+ y dy)))
            (when (memq (aref (aref grid cy) cx) etaf-tanks--marks)
              (etaf-tanks--clear-group grid cx cy)))))
      (dotimes (dy span)
        (dotimes (dx span) (aset (aref grid (+ y dy)) (+ x dx) brush)))
      (plist-put (copy-sequence draft) :rows (append grid nil)))))

(defun etaf-tanks--draft-resize (draft width height)
  "Return DRAFT cropped or extended with empty ground to WIDTH x HEIGHT."
  (let ((rows (plist-get draft :rows)))
    (plist-put (copy-sequence draft) :rows
               (cl-loop for y below height
                        collect (let ((row (or (nth y rows) "")))
                                  (if (>= (length row) width) (substring row 0 width)
                                    (concat row (make-string (- width (length row)) ?.))))))))

;;; Editor panel

(defun etaf-tanks--brush-label (brush)
  "Return BRUSH's display name."
  (cadr (assq brush etaf-tanks--brushes)))

(etaf-define-component etaf-tanks--editor-panel (&key draft brush brush-size pen history map-error dirty on-change on-name on-resize
                                                       on-save on-save-as on-test on-new on-open on-close on-brush on-size on-pen
                                                       on-paint on-undo)
  "Edit DRAFT's header and paint with visible controls and key guidance.
DRAFT, BRUSH, BRUSH-SIZE, PEN, HISTORY, MAP-ERROR and DIRTY are reactive
sources; the callbacks own every change."
  :view
  (column :ref 'tanks-editor :width '(ch 30) :item-gap '(lh 1)
    (column
      (etaf-label :text (if (etaf-value dirty) "地图编辑 · 未保存" "地图编辑") :variant 'strong)
      (etaf-label :text (let ((size (etaf-tanks--draft-size (etaf-value draft))))
                          (format "%d × %d 块" (car size) (cadr size)))
                  :variant 'muted))
    (etaf-text-input :label "名称" :value (plist-get (etaf-value draft) :name) :ref 'tanks-map-name
                     :on-change on-name)
    (column
      (etaf-number-input :label "宽度" :ref 'tanks-map-width :min 12 :max 52
                         :value (car (etaf-tanks--draft-size (etaf-value draft)))
                         :on-change (lambda (value) (funcall on-resize value nil)))
      (etaf-number-input :label "高度" :ref 'tanks-map-height :min 12 :max 40
                         :value (cadr (etaf-tanks--draft-size (etaf-value draft)))
                         :on-change (lambda (value) (funcall on-resize nil value))))
    (column
      (etaf-label :text (format "敌车编队 · 共 %d 辆（1–60）" (apply #'+ (plist-get (etaf-value draft) :counts)))
                  :variant 'muted)
      (etaf-number-input :for (index '(0 1 2 3)) :key index :min 0 :max 60
                         :ref (intern (format "tanks-map-kind-%d" index))
                         :label (aref etaf-tanks--kind-names index)
                         :value (nth index (plist-get (etaf-value draft) :counts))
                         :on-change (lambda (value) (funcall on-change index value))))
    (column
      (flex :width 'stretch :justify-content 'space-between
        (etaf-label :text (format "画笔：%s" (etaf-tanks--brush-label (etaf-value brush))) :variant 'strong)
        (etaf-label :text (concat (if (memq (etaf-value brush) etaf-tanks--marks) "2×2"
                                    (format "%d×%d" (etaf-value brush-size) (etaf-value brush-size)))
                                  (if (etaf-value pen) " · 连续" ""))
                    :variant 'muted))
      (etaf-label :text "方向键移动并绘制")
      (etaf-label :text "Shift+方向键 只移动")
      (etaf-label :text "1–9 换画笔，F 画一格")
      (grid :grid-template-columns '((fr 1) (fr 1) (fr 1)) :gap '((lh 0) (ch 1)) :width 'stretch
        (etaf-button :for (entry etaf-tanks--brushes) :key (car entry)
                     :ref (intern (format "tanks-brush-%s" (nth 2 entry)))
                     :label (format "%s %s" (nth 2 entry) (cadr entry))
                     :variant (if (eq (car entry) (etaf-value brush)) 'secondary 'ghost)
                     :on-press (lambda () (funcall on-brush (car entry)))))
      (grid :grid-template-columns '((fr 1) (fr 1)) :gap '((lh 0) (ch 1)) :width 'stretch
        (etaf-button :label "绘制 · f" :ref 'tanks-map-paint :on-press on-paint)
        (etaf-button :label "撤销 · u" :ref 'tanks-map-undo :variant 'secondary
                     :disabled (not (etaf-value history)) :on-press on-undo)
        (etaf-button :label "笔刷大小 · b" :ref 'tanks-brush-size :variant 'ghost :on-press on-size)
        (etaf-button :label (if (etaf-value pen) "绘制：开 · d" "绘制：关 · d") :ref 'tanks-pen
                     :variant (if (etaf-value pen) 'secondary 'ghost) :on-press on-pen)))
    (etaf-alert :if (etaf-value map-error) :title "暂不可玩" :message (or (etaf-value map-error) "") :variant 'warning)
    (grid :grid-template-columns '((fr 1) (fr 1)) :gap '((lh 0) (ch 1)) :width 'stretch
      (etaf-button :label "试玩 · p" :ref 'tanks-map-test :disabled (and (etaf-value map-error) t) :on-press on-test)
      (etaf-button :label "保存 · C-s" :ref 'tanks-map-save :variant 'secondary :on-press on-save)
      (etaf-button :label "另存为" :ref 'tanks-map-save-as :variant 'ghost :on-press on-save-as)
      (etaf-button :label "新建" :ref 'tanks-map-new :variant 'ghost :on-press on-new)
      (etaf-button :label "打开" :ref 'tanks-map-open :variant 'ghost :on-press on-open)
      (etaf-button :label "返回 · m" :ref 'tanks-map-close :variant 'ghost :on-press on-close))))

(provide 'etaf-tanks-editor)
;;; etaf-tanks-editor.el ends here
