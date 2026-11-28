;;; etaf-agenda-views-pages.el --- Page views of etaf-agenda -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; Pure view projections for the six agenda pages (Today, Calendar, List,
;; Project, Habits, Review) plus reusable row, tile, badge and progress bar
;; components.  All colours come from `etaf-agenda-color', all dimensions follow
;; `etaf-agenda-layout', and square habit/heatmap cells render via `etaf-ui-icon'
;; (`tile-filled' / `tile-outline') for strict 1:1 aspect ratio without
;; inflating line height.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'etaf)
(require 'etaf-ui)
(require 'etaf-agenda-theme)
(require 'etaf-agenda-layout)
(require 'etaf-agenda-model)

;;; ---------------------------------------------------------------------------
;;; Shared visual atoms
;;; ---------------------------------------------------------------------------

(defconst etaf-agenda-views--row-pad '((lh 0) (ch 1) (lh 0) (ch 0))
  "Single source of truth for horizontal padding of banners, headers and rows.
Left edge is always Col 0 (so `▎', page titles, section headers and hairlines
share one exact left axis with zero leftward overhang); right edge reserves
1ch inside the full-width hairline and `:select' band.")

(defun etaf-agenda-views--border (role)
  "Return a 1px solid border declaration using theme ROLE."
  (list '(px 1) 'solid (etaf-agenda-color role)))

(defun etaf-agenda-views--hover ()
  "Return hover declarations for unselected interactive surfaces."
  (list :background-color (etaf-agenda-color :hover)))

(defun etaf-agenda-views--hover-text (&optional role)
  "Return foreground-only hover declarations for lightweight inline text links."
  (list :color (etaf-agenda-color (or role :accent))))

(defun etaf-agenda-views--heat-color (count)
  "Return 4-level heatmap colour for daily completion COUNT."
  (cond ((or (null count) (<= count 0)) (etaf-agenda-color :heat0))
        ((= count 1) (etaf-agenda-color :heat1))
        ((= count 2) (etaf-agenda-color :heat2))
        (t (etaf-agenda-color :heat3))))

(etaf-define-component etaf-agenda-pill (&key text fg bg border bold trim)
  "Render a compact 1-line semantic badge pill.
When BG is filled without an outer BORDER, a 1px top/bottom TRIM matching the
containing row background prevents pills on consecutive rows from welding."
  :render
  (let ((trim-edge (when (and bg (not border))
                     (list '(px 1) 'solid (or trim (etaf-agenda-color :bg))))))
    (etaf-view
     (box :flex-shrink 0 :height '(lh 1)
          :padding '((lh 0) (ch 1))
          :background-color bg
          :border (when border (list '(px 1) 'solid border))
          :border-top trim-edge
          :border-bottom trim-edge
          :font-weight (if bold 'bold 'normal)
          :color fg
       (text (expr (or text "")))))))

(etaf-define-component etaf-agenda-square-tile
    (&key filled color size cell-cols help on-press selected)
  "Render a strict 1:1 square tile using `etaf-ui-icon'.
FILLED non-nil paints `tile-filled'; nil paints `tile-outline'.
CELL-COLS locks the horizontal stride in character columns.
Colour-encoded micro-tiles use `:pointer' and `help-echo' instead of
background hover fills so dense matrices stay calm and never corrupt
tile colours."
  :render
  (etaf-view
   (box :width (list 'ch (or cell-cols 2)) :flex-shrink 0 :height '(lh 1)
        :background-color (when selected (etaf-agenda-color :accent-soft))
        :pointer (when on-press 'hand)
     (etaf-ui-icon :name (if filled 'tile-filled 'tile-outline)
                   :size (or size 0.82)
                   :color color
                   :min-width 1
                   :help-echo help
                   :on-press on-press))))

(etaf-define-component etaf-agenda-hrule (&key pad color)
  "Render a single-line vertically centered horizontal hairline.
Because `─' sits at 50% of the line box, it yields balanced breathing space
above and below the rule in one line without hugging CJK baselines."
  :render
  (etaf-view
   (box :width 'stretch :min-width '(ch 0) :height '(lh 1)
        :padding (list '(lh 0) (list 'ch (or pad 0)))
        :overflow 'hidden :wrap-mode 'none
        :color (etaf-agenda-color (or color :line-soft))
     (text (expr (make-string 240 ?─))))))

(etaf-define-component etaf-agenda-segmented (&key value options on-change)
  "Render a crisp unified 1px-bordered horizontal segmented selector."
  :render
  (etaf-view
   (flex :flex-direction 'row :align-items 'center :flex-shrink 0
         :role 'tablist :focus-group 'horizontal
         :border (etaf-agenda-views--border :line)
     (expr
      (cl-mapcar
       (lambda (option idx)
         (let* ((key (car option))
                (caption (cdr option))
                (selected (equal key value)))
           (etaf-view
            (box :flex-shrink 0 :height '(lh 1)
                 :padding '((lh 0) (ch 1))
                 :border-left (when (> idx 0) (etaf-agenda-views--border :line-soft))
                 :background-color (when selected (etaf-agenda-color :accent-soft))
                 :color (if selected (etaf-agenda-color :accent) (etaf-agenda-color :muted))
                 :font-weight (if selected 'bold 'normal)
                 :hover-style (unless selected (etaf-agenda-views--hover))
                 :role 'tab :aria-selected (and selected t) :tab-index 0
                 :pointer (unless selected 'hand)
                 :on-press (lambda ()
                             (when (and on-change (not selected))
                               (funcall on-change key)))
              (text (expr caption))))))
       options
       (number-sequence 0 (1- (length options))))))))

(etaf-define-component etaf-agenda-hbar (&key ratio width color track)
  "Render a crisp bold 1-line horizontal progress bar of WIDTH columns."
  :render
  (let* ((w (max 6 (or width 16)))
         (r (max 0.0 (min 1.0 (or ratio 0.0))))
         (filled (if (and (> r 0.0) (zerop (round (* w r))))
                     1
                   (round (* w r))))
         (empty (max 0 (- w filled))))
    (etaf-view
     (flex :flex-direction 'row :align-items 'center
           :width (list 'ch w) :height '(lh 1) :flex-shrink 0
       (box :if (> filled 0) :width (list 'ch filled) :height '(lh 1)
            :flex-shrink 0 :font-weight 'bold :color color
         (text (expr (make-string filled ?━))))
       (box :if (> empty 0) :width (list 'ch empty) :height '(lh 1)
            :flex-shrink 0 :font-weight 'bold
            :color (or track (etaf-agenda-color :bar-track))
         (text (expr (make-string empty ?━))))))))

(etaf-define-component etaf-agenda-section-head
    (&key title count badge-text accent hint on-hint action-label on-action)
  "Render a clean section header flush at Col 0 (aligned with page title and `▎')."
  :render
  (let* ((accent-col (etaf-agenda-color (or accent :accent)))
         (soft-key (pcase accent
                     (:danger :danger-soft)
                     (:warning :warning-soft)
                     (:ok :ok-soft)
                     (:info :info-soft)
                     (:accent :accent-soft)
                     (_ :surface2)))
         (badge-fg (if (memq accent '(:danger :warning :ok :info :accent))
                       accent-col
                     (etaf-agenda-color :muted))))
    (etaf-view
     (flex :flex-direction 'row :align-items 'center
           :width 'stretch :height '(lh 1)
           :padding '((lh 0) (ch 1) (lh 0) (ch 0))
       ;; Flush at Col 0 — identical left edge to page title, hairline and `▎'
       (box :flex-shrink 0 :font-weight 'bold
            :color (if (eq accent :danger) accent-col (etaf-agenda-color :ink))
         (text (expr title)))
       (box :width '(ch 1) :flex-shrink 0 "")
       (etaf-agenda-pill :text (or badge-text (number-to-string (or count 0)))
                         :fg badge-fg
                         :bg (etaf-agenda-color soft-key))
       (box :flex-grow 1 :flex-basis '(px 0) :min-width '(ch 1) "")
       (box :if hint :flex-shrink 0
            :color (etaf-agenda-color :dim)
            :pointer (when on-hint 'hand)
            :hover-style (when on-hint (etaf-agenda-views--hover-text :accent))
            :on-press on-hint
         (text (expr hint)))
       (box :if action-label :flex-shrink 0
            :padding (when hint '((lh 0) (ch 0) (lh 0) (ch 1)))
            :color (etaf-agenda-color :muted)
            :role 'button :tab-index 0 :pointer (when on-action 'hand)
            :hover-style (when on-action (etaf-agenda-views--hover-text :accent))
            :on-press on-action
         (text (expr action-label)))))))

;;; ---------------------------------------------------------------------------
;;; Inline capture & inline edit rows
;;; ---------------------------------------------------------------------------

(etaf-define-component etaf-agenda-capture-row (&key model placeholder on-submit on-cancel)
  "Render an aligned in-place capture input row inside Col 0..W."
  :render
  (etaf-view
   (flex :flex-direction 'row :align-items 'center
         :width 'stretch :height '(lh 1)
         :padding etaf-agenda-views--row-pad
         :border-bottom (etaf-agenda-views--border :accent)
     (box :width '(ch 1) :flex-shrink 0 "")
     (box :width '(ch 2) :flex-shrink 0 :color (etaf-agenda-color :accent)
          :font-weight 'bold
       (text "+"))
     (box :width '(ch 1) :flex-shrink 0 "")
     (box :flex-grow 1 :flex-basis '(ch 0) :min-width '(ch 0)
       (etaf-text-input :bind (plist-get model :draft)
                        :label "新建条目"
                        :hide-label t
                        :variant 'plain
                        :width 'stretch
                        :placeholder (or placeholder "记一条：明天 15:00 评审 !1 #标签 @工作 +项目 ~30m")
                        :ref 'etaf-agenda-draft
                        :on-submit on-submit
                        :on-cancel on-cancel)))))

(etaf-define-component etaf-agenda-entry-row
    (&key model row plan show-context on-select on-toggle on-open
          on-edit-submit on-edit-cancel)
  "Render one entry row on a strict 2-axis grid so every title aligns cleanly.
Col 0..1: flush selection bar on `:select' bg; Col 2..3: uniform 2ch icon
directly beneath the section title; Col 4: 1ch gap; Col 5+: aligned title."
  :render
  (let* ((id (plist-get row :id))
         (selected (equal (plist-get plan :selected) id))
         (editing (and (equal (plist-get plan :editing) id)
                       (not (equal (plist-get plan :inspector-id) id))))
         (done (plist-get row :done))
         (kind (plist-get row :kind))
         (section (plist-get row :section))
         (prio (plist-get row :priority))
         (st-badge (plist-get row :status-badge))
         (status (plist-get row :status))
         (raw-time (plist-get row :time-label))
         (trailing-time (when raw-time
                          (let ((sched (plist-get row :scheduled))
                                (day (plist-get plan :day)))
                            (if (and sched day (not (equal sched day)))
                                (format "%s %s" (etaf-agenda--short-date-label sched)
                                        (substring raw-time 0 (min 5 (length raw-time))))
                              raw-time))))
         (meta (or (plist-get row :meta) ""))
         (is-event (equal kind "event"))
         (is-note (member kind '("note" "question")))
         (layout (plist-get plan :layout))
         (tier (plist-get layout :tier))
         (narrow (eq tier 'narrow))
         (inner-cols (plist-get layout :inner-cols))
         (show-ctx-col (and show-context
                            (eq (plist-get plan :area) 'all)
                            (>= inner-cols 76)))
         (show-status-col (not narrow))
         (raw-ctx (or (plist-get row :project-name)
                      (plist-get row :area-name)
                      "收件箱"))
         ;; Unified Time/Meta cell (<= 11ch, right-aligned in its own fixed rail)
         (time-cell (cond
                     ((and trailing-time (not done)) trailing-time)
                     ((not (string-empty-p meta)) meta)
                     (t "")))
         (time-color (cond
                      ((and trailing-time (not done)) (etaf-agenda-color :info))
                      (done (etaf-agenda-color :ok))
                      ((eq section 'overdue) (etaf-agenda-color :danger))
                      ((string-match-p "今天截止\\|过期" meta) (etaf-agenda-color :warning))
                      (t (etaf-agenda-color :muted))))
         (show-trail (not (and is-note (null prio) (null st-badge)
                               (string-empty-p time-cell))))
         (mark (plist-get row :mark))
         (mark-color (cond
                      (done (etaf-agenda-color :ok))
                      ((eq section 'overdue) (etaf-agenda-color :danger))
                      ((eq section 'migrated) (etaf-agenda-color :warning))
                      (is-event (etaf-agenda-color :info))
                      ((equal kind "question") (etaf-agenda-color :warning))
                      ((equal kind "note") (etaf-agenda-color :muted))
                      (selected (etaf-agenda-color :accent))
                      (t (etaf-agenda-color :muted))))
         ;; Fixed tabular right-rail width so every P1/P2, Status, Time and
         ;; Project/Area column stays locked on razor-straight vertical axes.
         (trail-cols (if (not show-trail)
                         0
                       (+ 1
                          (if show-status-col 7 0) ;; 6ch pill + 1ch gap
                          5                         ;; 4ch prio + 1ch gap
                          11                        ;; 11ch time/meta column
                          (if show-ctx-col 15 0)))) ;; 2ch gap + 13ch context
         (title-budget (max 12 (- inner-cols 5 trail-cols))))
    (etaf-view
     (flex :flex-direction 'row :align-items 'center
           :width 'stretch :height '(lh 1)
           :padding '((lh 0) (ch 1) (lh 0) (ch 0))
           :background-color (when selected (etaf-agenda-color :select))
           :role 'button :tab-index 0 :pointer (unless editing 'hand)
           :ref (intern (concat "agenda-row-" id))
           :on-press (lambda ()
                       (if selected
                           (when on-open (funcall on-open id))
                         (when on-select (funcall on-select id))))
       ;; Col 0: flush selection bar `▎' (exact same X as page/section titles!)
       ;; `▎' occupies only the leftmost ~25% of 1ch, leaving clean breathing space.
       (box :width '(ch 1) :flex-shrink 0 :height '(lh 1)
            :color (etaf-agenda-color :accent)
         (text (expr (if selected "▎" ""))))
       ;; Col 1..2: flush-left uniform 2ch icon slot (zero drift across icon types).
       ;; Pass :min-width 1 to `etaf-ui-icon' so SVG icons share the exact same
       ;; flush-left origin as `etaf-check-mark' (zero horizontal drift).
       (box :width '(ch 2) :flex-shrink 0 :height '(lh 1)
            :color mark-color
            :pointer (when (eq (car mark) 'box) 'hand)
            :help-echo (when (eq (car mark) 'box)
                         (if done "撤销完成（x）" "标记完成（x）"))
            :on-press (when (eq (car mark) 'box)
                        (lambda () (when on-toggle (funcall on-toggle id))))
         (expr
          (cond
           ((eq (car mark) 'box)
            (etaf-view (etaf-check-mark :state (intern (cdr mark))
                                        :color mark-color)))
           (is-event
            (etaf-view (etaf-ui-icon :name 'clock :set 'svg :size 0.94
                                     :min-width 1 :color mark-color)))
           ((equal kind "note")
            (etaf-view (etaf-ui-icon :name 'minus :set 'svg :size 0.86
                                     :min-width 1 :color mark-color)))
           (t
            (etaf-view (box :width '(ch 2) :text-align 'center
                         (text (expr (cdr mark)))))))))
       ;; Col 4: exact 1ch gap
       (box :width '(ch 1) :flex-shrink 0 "")
       ;; Col 5+: Title OR inline editor (100% straight vertical axis!)
       ;; Scope hover to the homogeneous title box so native `mouse-face'
       ;; preserves the title's own ink (e.g. :dim on done items) and never
       ;; overwrites checkboxes, SVG icons, priority/status pills or dates.
       (expr
        (if editing
            (etaf-view
             (box :flex-grow 1 :flex-basis '(ch 0) :min-width '(ch 8) :height '(lh 1)
               (etaf-text-input :bind (plist-get model :edit-draft)
                                :label "编辑标题"
                                :hide-label t
                                :variant 'plain
                                :width 'stretch
                                :ref 'etaf-agenda-edit
                                :on-submit on-edit-submit
                                :on-cancel on-edit-cancel)))
          (etaf-view
           (box :flex-grow 1 :flex-basis '(ch 0) :min-width '(ch 0)
                :height '(lh 1) :wrap-mode 'none :overflow 'hidden
                :font-weight (if selected 'bold 'normal)
                :color (cond (done (etaf-agenda-color :dim))
                             (is-note (etaf-agenda-color :muted))
                             (t (etaf-agenda-color :ink)))
                :hover-style (unless selected (etaf-agenda-views--hover-text :accent))
             (text (expr (etaf-agenda-clip-text (plist-get row :title) title-budget)))))))
       ;; Fixed-width tabular right columns: [Status 6ch] [Prio 4ch] [Time/Meta 11ch] [Context 13ch]
       (expr
        (when (and (not editing) show-trail)
          (let ((trim-col (if selected (etaf-agenda-color :select) (etaf-agenda-color :bg))))
            (list
             (etaf-view
              (flex :flex-direction 'row :align-items 'center :flex-shrink 0
                    :padding '((lh 0) (ch 0) (lh 0) (ch 1))
                ;; Col A: Status pill (6ch fixed)
                (expr
                 (when show-status-col
                   (list
                    (if st-badge
                        (etaf-view
                         (box :width '(ch 6) :flex-shrink 0 :height '(lh 1)
                           (etaf-agenda-pill
                            :text st-badge
                            :trim trim-col
                            :fg (etaf-agenda-color (if (equal status "doing") :info :warning))
                            :bg (etaf-agenda-color (if (equal status "doing") :info-soft :warning-soft)))))
                      (etaf-view (box :width '(ch 6) :flex-shrink 0 :height '(lh 1) "")))
                    (etaf-view (box :width '(ch 1) :flex-shrink 0 "")))))
                ;; Col B: Priority pill (4ch fixed)
                (expr
                 (if (and prio (not done))
                     (etaf-view
                      (box :width '(ch 4) :flex-shrink 0 :height '(lh 1)
                        (etaf-agenda-pill
                         :text (format "P%d" prio)
                         :bold t
                         :trim trim-col
                         :fg (etaf-agenda-color (pcase prio (1 :danger) (2 :warning) (_ :muted)))
                         :bg (etaf-agenda-color (pcase prio (1 :danger-soft) (2 :warning-soft) (_ :surface2))))))
                   (etaf-view (box :width '(ch 4) :flex-shrink 0 :height '(lh 1) ""))))
                (box :width '(ch 1) :flex-shrink 0 "")
                ;; Col C: Time / Due / Estimate / Done (11ch fixed, right-aligned)
                (box :width '(ch 11) :flex-shrink 0 :height '(lh 1)
                     :text-align 'right :overflow 'hidden :wrap-mode 'none
                     :color time-color
                  (text (expr (etaf-agenda-clip-text time-cell 11))))
                ;; Col D: Project / Area context (13ch fixed, right-aligned flush to W - 1ch)
                (expr
                 (when show-ctx-col
                   (list
                    (etaf-view (box :width '(ch 2) :flex-shrink 0 ""))
                    (etaf-view
                     (box :width '(ch 13) :flex-shrink 0 :height '(lh 1)
                          :text-align 'right :overflow 'hidden :wrap-mode 'none
                          :color (etaf-agenda-color :dim)
                       (text (expr (etaf-agenda-clip-text raw-ctx 13))))))))))))))))))

;;; ---------------------------------------------------------------------------
;;; 1. Today Page
;;; ---------------------------------------------------------------------------

(etaf-define-component etaf-agenda-today-page
    (&key model plan on-select on-toggle on-open on-prev-day on-next-day on-today
          on-migrate-overdue on-clear-area on-draft-submit on-draft-cancel
          on-edit-submit on-edit-cancel)
  "Render the Today page: clean day banner and flow sections."
  :render
  (let* ((counts (plist-get plan :counts))
         (open-n (plist-get counts :open))
         (done-n (plist-get counts :done))
         (total-n (+ open-n done-n))
         (ratio (if (zerop total-n) 0.0 (/ (float done-n) total-n)))
         (is-today (equal (plist-get plan :day) (etaf-agenda--today)))
         (narrow (eq (plist-get (plist-get plan :layout) :tier) 'narrow))
         (short-p (plist-get (plist-get plan :layout) :short))
         (inner-cols (plist-get (plist-get plan :layout) :inner-cols))
         (area (plist-get plan :area))
         (drafting (plist-get plan :drafting))
         (sections (seq-filter
                    (lambda (sec)
                      (or (not (plist-get sec :hide-when-empty))
                          (plist-get sec :rows)
                          (and drafting (eq (plist-get drafting :target)
                                            (plist-get sec :id)))))
                    (plist-get plan :day-sections))))
    (etaf-view
     (column :width 'stretch :item-gap '(lh 0)
       ;; Day banner flush at Col 0 (exact same left edge as hairline, headers & `▎')
       (flex :flex-direction 'row :align-items 'center
             :width 'stretch :height '(lh 1)
             :padding '((lh 0) (ch 1) (lh 0) (ch 0))
             :gap '((lh 0) (ch 1))
         (box :flex-shrink 0 :font-weight 'bold :color (etaf-agenda-color :ink)
           (text (expr (plist-get plan :day-label))))
         (box :flex-shrink 0 :color (etaf-agenda-color :muted)
           (text (expr (format "%s · 第 %d 周"
                               (plist-get plan :weekday-label)
                               (plist-get plan :week)))))
         (expr
          (when (not (eq area 'all))
            (etaf-view
             (box :flex-shrink 0 :height '(lh 1)
                  :padding '((lh 0) (ch 1))
                  :background-color (etaf-agenda-color :accent-soft)
                  :color (etaf-agenda-color :accent)
                  :pointer 'hand
                  :on-press on-clear-area
               (text (expr (format "%s ×" (plist-get plan :area-label))))))))
         (box :flex-grow 1 :flex-basis '(px 0) :min-width '(ch 1) "")
         ;; Progress bar & count sit to the left of the right-anchored stepper so
         ;; changing digit widths (0/4 vs 12/20) never shift the ‹ / 今天 / › buttons.
         (expr
          (if (not narrow)
              (etaf-view
               (flex :flex-direction 'row :align-items 'center :flex-shrink 0
                     :gap '((lh 0) (ch 1))
                 (etaf-agenda-hbar :ratio ratio :width 10
                                   :color (etaf-agenda-color :ok))
                 (box :flex-shrink 0 :color (etaf-agenda-color :muted)
                   (text (expr (format "%d/%d" done-n total-n))))))
            (etaf-view
             (box :flex-shrink 0 :color (etaf-agenda-color :muted)
               (text (expr (format "%d/%d" done-n total-n)))))))
         ;; Right-anchored compact date stepper
         (flex :flex-direction 'row :align-items 'center :flex-shrink 0
               :border (unless narrow (etaf-agenda-views--border :line))
           (box :padding '((lh 0) (ch 1)) :color (etaf-agenda-color :muted)
                :role 'button :tab-index 0 :pointer 'hand
                :hover-style (etaf-agenda-views--hover)
                :on-press on-prev-day
             (text "‹"))
           (box :padding '((lh 0) (ch 1))
                :color (if is-today (etaf-agenda-color :dim) (etaf-agenda-color :ink))
                :border-left (unless narrow (etaf-agenda-views--border :line-soft))
                :border-right (unless narrow (etaf-agenda-views--border :line-soft))
                :role 'button :tab-index (unless is-today 0)
                :pointer (unless is-today 'hand)
                :hover-style (unless is-today (etaf-agenda-views--hover))
                :on-press (unless is-today on-today)
             (text "今天"))
           (box :padding '((lh 0) (ch 1)) :color (etaf-agenda-color :muted)
                :role 'button :tab-index 0 :pointer 'hand
                :hover-style (etaf-agenda-views--hover)
                :on-press on-next-day
             (text "›"))))
       (etaf-agenda-hrule :color :line)
       ;; Sections in natural flow rhythm
       (expr
        (apply
         #'append
         (cl-mapcar
          (lambda (sec idx)
            (let* ((sid (plist-get sec :id))
                   (rows (plist-get sec :rows))
                   (show-draft (and drafting (eq (plist-get drafting :target) sid))))
              (if (and (eq sid 'migrated) rows (not show-draft))
                  ;; Quiet bottom migrated strip aligned inside Col 0..W
                  (append
                   (list (etaf-view (etaf-agenda-hrule :color :line-soft)))
                   (cl-mapcar
                    (lambda (row ridx)
                      (let* ((rid (plist-get row :id))
                             (sel (equal (plist-get plan :selected) rid))
                             (meta (or (plist-get row :meta) ""))
                             (prefix-str (format "已迁移 %d 项" (length rows)))
                             (budget (max 10 (- inner-cols
                                                (if (= ridx 0) (+ (string-width prefix-str) 8) 8)
                                                (string-width meta)))))
                        (etaf-view
                         (flex :flex-direction 'row :align-items 'center
                               :width 'stretch :height '(lh 1)
                               :padding '((lh 0) (ch 1) (lh 0) (ch 0))
                               :background-color (when sel (etaf-agenda-color :select))
                               :role 'button :tab-index 0 :pointer 'hand
                               :ref (intern (concat "agenda-row-" rid))
                               :on-press (lambda ()
                                           (if sel
                                               (when on-open (funcall on-open rid))
                                             (when on-select (funcall on-select rid))))
                           (box :width '(ch 1) :flex-shrink 0 :color (etaf-agenda-color :accent)
                             (text (expr (if sel "▎" ""))))
                           (box :width '(ch 2) :flex-shrink 0
                                :color (etaf-agenda-color :warning)
                             (text "→"))
                           (box :width '(ch 1) :flex-shrink 0 "")
                           (box :if (= ridx 0) :flex-shrink 0
                                :padding '((lh 0) (ch 2) (lh 0) (ch 0))
                                :color (etaf-agenda-color :muted)
                             (text (expr prefix-str)))
                           (box :flex-grow 1 :flex-basis '(ch 0) :min-width '(ch 0)
                                :height '(lh 1) :wrap-mode 'none :overflow 'hidden
                                :color (if sel (etaf-agenda-color :ink) (etaf-agenda-color :muted))
                                :hover-style (unless sel (etaf-agenda-views--hover-text :accent))
                             (text (expr (etaf-agenda-clip-text (plist-get row :title) budget))))
                           (box :flex-shrink 0 :padding '((lh 0) (ch 0) (lh 0) (ch 2))
                                :color (etaf-agenda-color :dim)
                             (text (expr meta)))))))
                    rows
                    (number-sequence 0 (1- (length rows)))))
                (delq nil
                      (list
                       ;; True Gestalt proximity: 2lh between sections > 1lh below header
                       (when (> idx 0)
                         (etaf-view (box :height (if short-p '(lh 1) '(lh 2)))))
                       (etaf-view
                        (etaf-agenda-section-head
                         :title (plist-get sec :title)
                         :count (plist-get sec :count)
                         :accent (plist-get sec :accent)
                         :hint (when (and (eq sid 'overdue) rows) (plist-get sec :hint))
                         :on-hint (when (eq sid 'overdue) on-migrate-overdue)))
                       (when (and (not short-p) (or rows show-draft (plist-get sec :empty)))
                         (etaf-view (box :height '(lh 1))))
                       (when show-draft
                         (etaf-view
                          (etaf-agenda-capture-row
                           :model model
                           :placeholder (pcase sid
                                          ('events "记一场日程：15:00-16:00 评审 +项目")
                                          ('notes "记一笔想法或 ? 记一个问题…")
                                          (_ "记一条待办：明天 15:00 评审 !1 #标签 @工作 +项目 ~30m"))
                           :on-submit on-draft-submit
                           :on-cancel on-draft-cancel)))
                       (if rows
                           (etaf-view
                            (column :width 'stretch :item-gap '(lh 0)
                              (expr
                               (mapcar
                                (lambda (row)
                                  (etaf-view
                                   (etaf-agenda-entry-row
                                    :model model :row row :plan plan
                                    :show-context t
                                    :on-select on-select
                                    :on-toggle on-toggle
                                    :on-open on-open
                                    :on-edit-submit on-edit-submit
                                    :on-edit-cancel on-edit-cancel)))
                                rows))))
                         (when (and (not show-draft) (plist-get sec :empty))
                           (etaf-view
                            (box :padding '((lh 0) (ch 1)) :height '(lh 1)
                                 :color (etaf-agenda-color :dim)
                              (text (expr (plist-get sec :empty))))))))))))
          sections
          (number-sequence 0 (1- (length sections))))))))))

;;; ---------------------------------------------------------------------------
;;; 2. Calendar Page (Month + Week view, accurate 7-column budget)
;;; ---------------------------------------------------------------------------

(defconst etaf-agenda-views--weekdays ["一" "二" "三" "四" "五" "六" "日"]
  "Monday-first weekday labels.")

(etaf-define-component etaf-agenda-calendar-cell
    (&key cell plan cell-cols week-lines first-col last-col last-row
          sel-row sel-col row-idx col-idx on-pick)
  "Render one equal-width day cell of the month grid with zero-jitter borders.
All 4 edges of the selected cell light up in `:accent' solely by swapping the
colours of pre-allocated shared 1px grid borders (top owned by the row above,
left owned by the column to the left or col 0's own left edge) with zero
horizontal or vertical text jitter."
  :render
  (let* ((cell-day (plist-get cell :day))
         (selected (equal cell-day (plist-get plan :day)))
         (is-today (plist-get cell :today))
         (in-month (plist-get cell :in-month))
         (chips (plist-get cell :chips))
         (room (max 1 (- week-lines 1)))
         (extra (max 0 (- (length chips) room)))
         (chip-budget (max 4 (- cell-cols 4)))
         (b-left (when first-col
                   (etaf-agenda-views--border
                    (if (and (eql row-idx sel-row) (eql sel-col 0))
                        :accent :line))))
         (b-right (etaf-agenda-views--border
                   (cond
                    (last-col
                     (if (and (eql row-idx sel-row) (eql sel-col col-idx))
                         :accent :line))
                    ((and (eql row-idx sel-row)
                          (or (eql sel-col col-idx)
                              (eql sel-col (1+ col-idx))))
                     :accent)
                    (t :line-soft))))
         (b-bottom (etaf-agenda-views--border
                    (cond
                     (last-row
                      (if (and (eql row-idx sel-row) (eql sel-col col-idx))
                          :accent :line))
                     ((and (eql col-idx sel-col)
                           (or (eql sel-row row-idx)
                               (eql sel-row (1+ row-idx))))
                      :accent)
                     (t :line-soft)))))
    (etaf-view
     (flex :flex-direction 'column
           :flex-grow 1 :flex-basis '(px 0) :min-width (list 'ch (max 6 cell-cols))
           :height (list 'lh week-lines)
           :box-sizing 'border-box :overflow 'hidden
           :background-color (when selected (etaf-agenda-color :accent-soft))
           :border-left b-left
           :border-right b-right
           :border-bottom b-bottom
           :role 'button :tab-index 0 :pointer nil
           :on-press (lambda () (when on-pick (funcall on-pick cell-day)))
       (column :width 'stretch :item-gap '(lh 0) :padding '((lh 0) (ch 1))
         (flex :flex-direction 'row :align-items 'center
               :width 'stretch :height '(lh 1)
           (box :flex-shrink 0
                :font-weight (if (or selected is-today) 'bold 'normal)
                :color (cond ((or selected is-today) (etaf-agenda-color :accent))
                             ((not in-month) (etaf-agenda-color :dim))
                             (t (etaf-agenda-color :ink)))
             (text (expr (number-to-string (% cell-day 100)))))
           (box :if (and is-today (>= cell-cols 11)) :flex-shrink 0
                :padding '((lh 0) (ch 0) (lh 0) (ch 1))
                :font-weight 'bold
                :color (etaf-agenda-color :accent)
             (text "今"))
           (box :flex-grow 1 :flex-basis '(px 0) "")
           (box :if (> extra 0) :flex-shrink 0
                :color (if selected (etaf-agenda-color :accent) (etaf-agenda-color :muted))
             (text (expr (format "+%d" extra)))))
         (expr
          (mapcar
           (lambda (chip)
             (let* ((ckind (plist-get chip :kind))
                    (cdone (plist-get chip :done))
                    (cprio (plist-get chip :priority))
                    (dot (if (equal ckind "event") "│ " "▪ "))
                    (dcol (cond (cdone (etaf-agenda-color :ok))
                                ((equal ckind "event") (etaf-agenda-color :info))
                                ((eql cprio 1) (etaf-agenda-color :danger))
                                ((eql cprio 2) (etaf-agenda-color :warning))
                                (t (etaf-agenda-color :accent))))
                    (label (if (plist-get chip :time-short)
                               (format "%s %s" (plist-get chip :time-short)
                                       (plist-get chip :title))
                             (plist-get chip :title))))
               (etaf-view
                (flex :flex-direction 'row :align-items 'center
                      :width 'stretch :height '(lh 1) :overflow 'hidden
                  (box :flex-shrink 0 :color dcol (text (expr dot)))
                  (box :flex-grow 1 :flex-basis '(ch 0) :min-width '(ch 0)
                       :height '(lh 1) :wrap-mode 'none :overflow 'hidden
                       :color (if cdone (etaf-agenda-color :dim) (etaf-agenda-color :muted))
                    (text (expr (etaf-agenda-clip-text label chip-budget))))))))
           (seq-take chips room))))))))

(etaf-define-component etaf-agenda-week-column
    (&key wd wd-short plan cell-cols body-lines col-idx sel-col on-pick)
  "Render one full-height equal-width day column in the 7-column Week Grid.
All 4 edges of the selected column light up in `:accent' solely by swapping
colours on pre-allocated shared 1px column borders with zero text jitter."
  :render
  (let* ((cell-day (plist-get wd :day))
         (selected (equal cell-day (plist-get plan :day)))
         (is-today (plist-get wd :today))
         (events (plist-get wd :events))
         (tasks (plist-get wd :tasks))
         (ev-n (length events))
         (tk-n (length tasks))
         (total (+ ev-n tk-n))
         (col-bg (if selected (etaf-agenda-color :accent-soft) (etaf-agenda-color :bg)))
         (card-bg (if selected (etaf-agenda-color :surface2) (etaf-agenda-color :info-soft)))
         (trim (list '(px 1) 'solid col-bg))
         (has-div (and (> ev-n 0) (> tk-n 0)))
         ;; Use rich 2-line event cards whenever room permits; fall back to
         ;; 1-line event strips on very short or meeting-heavy columns.
         (card-h (if (and (>= body-lines 10)
                          (or (<= (+ (* 2 ev-n) (if has-div 1 0) tk-n) body-lines)
                              (<= (* 2 ev-n) (max 4 (- body-lines 4)))))
                     2
                   1))
         (max-ev (min ev-n (max 0 (/ (max 0 (- body-lines (if (> tk-n 0) 2 0))) card-h))))
         (used-ev (* max-ev card-h))
         (rem-after-ev (max 0 (- body-lines used-ev (if (and (> max-ev 0) (> tk-n 0)) 1 0))))
         (need-overflow (or (< max-ev ev-n) (> tk-n rem-after-ev)))
         (tk-room (if need-overflow (max 0 (1- rem-after-ev)) rem-after-ev))
         (ev-show (seq-take events max-ev))
         (tk-show (seq-take tasks (min tk-n tk-room)))
         (hidden (max 0 (- total (+ (length ev-show) (length tk-show)))))
         (show-div (and (> (length ev-show) 0) (or (> (length tk-show) 0) (> hidden 0))))
         (text-budget (max 4 (- cell-cols 4)))
         (card-budget (max 4 (- cell-cols 5)))
         (b-left (when (eql col-idx 0)
                   (etaf-agenda-views--border (if (eql sel-col 0) :accent :line))))
         (b-right (etaf-agenda-views--border
                   (cond
                    ((eql col-idx 6) (if (eql sel-col 6) :accent :line))
                    ((or (eql sel-col col-idx) (eql sel-col (1+ col-idx))) :accent)
                    (t :line-soft))))
         (b-top (etaf-agenda-views--border (if selected :accent :line)))
         (b-bottom (etaf-agenda-views--border (if selected :accent :line))))
    (etaf-view
     (flex :flex-direction 'column
           :flex-grow 1 :flex-basis '(px 0) :min-width (list 'ch (max 6 cell-cols))
           :height (list 'lh (1+ body-lines))
           :box-sizing 'border-box :overflow 'hidden
           :background-color (when selected (etaf-agenda-color :accent-soft))
           :border-top b-top
           :border-bottom b-bottom
           :border-left b-left
           :border-right b-right
           :role 'button :tab-index 0 :pointer nil
           :on-press (lambda () (when on-pick (funcall on-pick cell-day)))
       ;; Row 0: Weekday + Day number + optional 今 + total count
       (flex :flex-direction 'row :align-items 'center
             :width 'stretch :height '(lh 1) :padding '((lh 0) (ch 1))
             :border-bottom (etaf-agenda-views--border (if selected :accent :line))
         (box :flex-shrink 0 :font-weight 'bold
              :color (if (or selected is-today)
                         (etaf-agenda-color :accent)
                       (etaf-agenda-color :muted))
           (text (expr wd-short)))
         (box :width '(ch 1) :flex-shrink 0 "")
         (box :flex-shrink 0 :font-weight 'bold
              :color (if (or selected is-today)
                         (etaf-agenda-color :accent)
                       (etaf-agenda-color :ink))
           (text (expr (number-to-string (% cell-day 100)))))
         (box :if (and is-today (>= cell-cols 12)) :flex-shrink 0
              :padding '((lh 0) (ch 0) (lh 0) (ch 1))
              :font-weight 'bold :color (etaf-agenda-color :accent)
           (text "今"))
         (box :flex-grow 1 :flex-basis '(px 0) "")
         (box :if (and (> total 0) (>= cell-cols 9)) :flex-shrink 0
              :color (if selected (etaf-agenda-color :accent) (etaf-agenda-color :dim))
           (text (expr (number-to-string total)))))
       ;; Body: Events block + subtle divider + Tasks list
       (column :width 'stretch :height (list 'lh body-lines)
               :item-gap '(lh 0) :padding '((lh 0) (ch 1)) :overflow 'hidden
         ;; Timed event cards
         (expr
          (mapcar
           (lambda (row)
             (let* ((tlabel (plist-get row :time-label))
                    (tshort (if (and tlabel (>= (length tlabel) 5))
                                (substring tlabel 0 5)
                              "全天"))
                    (title (or (plist-get row :title) "")))
               (if (= card-h 2)
                   (etaf-view
                    (flex :flex-direction 'row :width 'stretch :height '(lh 2)
                          :background-color card-bg
                          :border-top trim :border-bottom trim
                          :overflow 'hidden
                      (column :width '(ch 1) :height '(lh 2) :flex-shrink 0
                              :item-gap '(lh 0) :color (etaf-agenda-color :info)
                        (box :height '(lh 1) (text "▎"))
                        (box :height '(lh 1) (text "▎")))
                      (column :flex-grow 1 :flex-basis '(ch 0) :min-width '(ch 0)
                              :height '(lh 2) :item-gap '(lh 0) :overflow 'hidden
                        (box :height '(lh 1) :wrap-mode 'none :overflow 'hidden
                             :font-weight 'bold :color (etaf-agenda-color :info)
                          (text (expr (etaf-agenda-clip-text tshort card-budget))))
                        (box :height '(lh 1) :wrap-mode 'none :overflow 'hidden
                             :color (etaf-agenda-color :ink)
                          (text (expr (etaf-agenda-clip-text title card-budget)))))))
                 (etaf-view
                  (flex :flex-direction 'row :align-items 'center
                        :width 'stretch :height '(lh 1)
                        :background-color card-bg
                        :border-top trim :border-bottom trim
                        :overflow 'hidden
                    (box :width '(ch 1) :flex-shrink 0 :color (etaf-agenda-color :info)
                      (text "▎"))
                    (box :flex-grow 1 :flex-basis '(ch 0) :min-width '(ch 0)
                         :height '(lh 1) :wrap-mode 'none :overflow 'hidden
                         :color (etaf-agenda-color :ink)
                      (text (expr (etaf-agenda-clip-text
                                   (format "%s %s" tshort title) card-budget)))))))))
           ev-show))
         ;; Thin hairline separating events from tasks
         (expr
          (when show-div
            (list (etaf-view (etaf-agenda-hrule :color :line-soft)))))
         ;; Tasks
         (expr
          (mapcar
           (lambda (row)
             (let* ((done (plist-get row :done))
                    (prio (plist-get row :priority))
                    (dcol (cond (done (etaf-agenda-color :ok))
                                ((eql prio 1) (etaf-agenda-color :danger))
                                ((eql prio 2) (etaf-agenda-color :warning))
                                (t (etaf-agenda-color :accent)))))
               (etaf-view
                (flex :flex-direction 'row :align-items 'center
                      :width 'stretch :height '(lh 1) :overflow 'hidden
                  (box :flex-shrink 0 :color dcol (text "▪ "))
                  (box :flex-grow 1 :flex-basis '(ch 0) :min-width '(ch 0)
                       :height '(lh 1) :wrap-mode 'none :overflow 'hidden
                       :color (if done (etaf-agenda-color :dim) (etaf-agenda-color :muted))
                    (text (expr (etaf-agenda-clip-text
                                 (or (plist-get row :title) "") text-budget))))))))
           tk-show))
         ;; Overflow count when column exceeds viewport height
         (box :if (> hidden 0) :height '(lh 1) :wrap-mode 'none :overflow 'hidden
              :color (etaf-agenda-color :accent)
           (text (expr (format "+%d 项" hidden)))))))))

(etaf-define-component etaf-agenda-year-month-card
    (&key month-data plan card-pad-v card-hrule card-inner-cols on-pick on-zoom-month)
  "Render one floating borderless mini-month card in the 12-month Year Grid.
Uses invariant card geometry (zero jitter): selected month gets a softly
rounded `:surface' fill and `:accent' title rule, current month shows a padded
`今' badge, and day cells align right across 7 `space-between' tabular columns."
  :render
  (let* ((m (plist-get month-data :month))
         (ym (plist-get month-data :ym))
         (m-count (plist-get month-data :count))
         (weeks (plist-get month-data :weeks))
         (cur-day (plist-get plan :day))
         (today (or (plist-get plan :today) (etaf-agenda--today)))
         (dark-p (plist-get (etaf-agenda-palette) :dark))
         (sel-month (= ym (/ cur-day 100)))
         (curr-month (= ym (/ today 100)))
         (first-day (+ (* ym 100) 1))
         (pad-v (or card-pad-v 0))
         (use-hrule (not (null card-hrule)))
         (card-lines (+ 8 (if use-hrule 1 0) (if (> pad-v 0) 2 0)))
         (card-bg (if sel-month (etaf-agenda-color :surface) (etaf-agenda-color :bg)))
         (pill-trim (list '(px 1) 'solid card-bg))
         (gui-p (display-graphic-p))
         (char-px (if gui-p
                      (max 6 (or (plist-get (ignore-errors (etaf-display-metrics))
                                            :char-width)
                                 8))
                    1))
         (inner-cols (or card-inner-cols 18))
         (pill-pad-px (cond ((not gui-p) 0)
                            ((>= inner-cols 21) 3)
                            ((>= inner-cols 19) 2)
                            (t 0)))
         (cell-w (if (> pill-pad-px 0)
                     (list 'px (+ (* 2 char-px) (* 2 pill-pad-px)))
                   '(ch 2)))
         (cell-pad (list '(lh 0) (list 'px pill-pad-px)))
         (badge-pad (if gui-p '((lh 0) (px 4)) '((lh 0) (ch 0))))
         (idle-fg (if dark-p (etaf-agenda-color :dim) (etaf-agenda-color :muted))))
    (etaf-view
     (column :flex-grow 1 :flex-basis '(px 0) :min-width '(ch 16)
             :height (list 'lh card-lines) :item-gap '(lh 0)
             :padding (list (list 'lh pad-v) '(ch 1))
             :border (etaf-agenda-views--border (if sel-month :accent :bg))
             :border-radius (when gui-p '(px 5))
             :box-sizing 'border-box
             :background-color (when sel-month (etaf-agenda-color :surface))
       ;; Row 0: Month title (click zooms into Month view), padded 今 badge & count
       (flex :flex-direction 'row :align-items 'center
             :width 'stretch :height '(lh 1) :gap '((lh 0) (ch 1))
             :border-bottom (unless use-hrule
                              (etaf-agenda-views--border (if sel-month :accent :line-soft)))
         (box :flex-shrink 0 :font-weight 'bold
              :color (if (or sel-month curr-month)
                         (etaf-agenda-color :accent)
                       (etaf-agenda-color :ink))
              :role 'button :tab-index 0 :pointer 'hand
              :help-echo (format "进入 %d 月月视图" m)
              :hover-style (unless (or sel-month curr-month)
                             (etaf-agenda-views--hover-text :accent))
              :on-press (lambda () (when on-zoom-month (funcall on-zoom-month first-day)))
           (text (expr (format "%d 月" m))))
         (box :if curr-month :flex-shrink 0 :height '(lh 1)
              :padding badge-pad
              :background-color (etaf-agenda-color :accent-soft)
              :color (etaf-agenda-color :accent) :font-weight 'bold
              :border-top pill-trim :border-bottom pill-trim
           (text "今"))
         (box :flex-grow 1 :flex-basis '(px 0) "")
         (box :if (> m-count 0) :flex-shrink 0
              :color (if sel-month (etaf-agenda-color :accent) (etaf-agenda-color :muted))
           (text (expr (format "%d 项" m-count)))))
       ;; Optional centered horizontal hairline with natural half-line breathing room
       (etaf-agenda-hrule :if use-hrule
                          :color (if sel-month :accent :line-soft))
       ;; Weekday header aligned right over the 7 tabular day columns
       (flex :flex-direction 'row :justify-content 'space-between :align-items 'center
             :width 'stretch :height '(lh 1)
         (expr
          (mapcar (lambda (wl)
                    (etaf-view
                     (box :width cell-w :padding cell-pad :flex-shrink 0 :height '(lh 1)
                          :text-align 'right :color (etaf-agenda-color :dim)
                       (text (expr wl)))))
                  (append etaf-agenda-views--weekdays nil))))
       ;; 6 Monday-first week rows with cushioned heat tiles
       (expr
        (mapcar
         (lambda (wk)
           (etaf-view
            (flex :flex-direction 'row :justify-content 'space-between :align-items 'center
                  :width 'stretch :height '(lh 1)
              (expr
               (mapcar
                (lambda (cell)
                  (if (null cell)
                      (etaf-view (box :width cell-w :padding cell-pad
                                      :flex-shrink 0 :height '(lh 1) ""))
                    (let* ((d (plist-get cell :day))
                           (dom (plist-get cell :dom))
                           (is-sel (equal d cur-day))
                           (is-today (plist-get cell :today))
                           (cnt (plist-get cell :count))
                           (bg (cond (is-sel (etaf-agenda-color :accent))
                                     (is-today (etaf-agenda-color :accent-soft))
                                     ((>= cnt 6) (etaf-agenda-color :warning-soft))
                                     ((>= cnt 3) (etaf-agenda-color :ok-soft))
                                     (t nil)))
                           (fg (cond (is-sel (etaf-agenda-color :bg))
                                     (is-today (etaf-agenda-color :accent))
                                     ((>= cnt 6) (etaf-agenda-color :warning))
                                     ((>= cnt 3) (etaf-agenda-color :ok))
                                     ((>= cnt 1) (etaf-agenda-color :ink))
                                     (t idle-fg)))
                           (fw (if (or is-sel is-today (>= cnt 1)) 'bold 'normal)))
                      (etaf-view
                       (box :width cell-w :padding cell-pad :flex-shrink 0 :height '(lh 1)
                            :text-align 'right
                            :background-color bg
                            :border-top (when bg pill-trim)
                            :border-bottom (when bg pill-trim)
                            :color fg :font-weight fw
                            :role 'button :tab-index 0 :pointer 'hand
                            :help-echo (format "%s · %d 项（点击查看，再点进月视图）"
                                               (etaf-agenda--date-label d) cnt)
                            :on-press (lambda ()
                                        (if is-sel
                                            (when on-zoom-month (funcall on-zoom-month d))
                                          (when on-pick (funcall on-pick d))))
                         (text (expr (number-to-string dom))))))))
                wk)))))
         weeks))))))

(etaf-define-component etaf-agenda-calendar-page
    (&key model plan on-pick-day on-zoom-month on-prev-month on-next-month on-today
          on-mode on-draft-submit on-draft-cancel)
  "Render the Calendar page in Year, Month or 7-Column Week Grid mode.
Anchors the mode switcher on the left and the equal-width period stepper on
the right with the variable-width period title beside it so switching modes
never shifts any clickable control."
  :render
  (let* ((layout (plist-get plan :layout))
         (tier (plist-get layout :tier))
         (narrow (eq tier 'narrow))
         (cell-cols (plist-get layout :cal-cell-cols))
         (cal-inner-w (plist-get layout :cal-inner-cols))
         (body-rows (plist-get layout :body-rows))
         (mode (plist-get plan :calendar-mode))
         (year-p (eq mode 'year))
         (week-p (eq mode 'week))
         (weeks (plist-get plan :weeks))
         (nweeks (max 1 (length weeks)))
         (year-months (plist-get plan :year-months))
         (year-summary (plist-get plan :year-summary))
         (drafting (plist-get plan :drafting))
         (draft-cal (and drafting (eq (plist-get drafting :target) 'calendar)))
         ;; Fill vertically down to the bottom of the stage, leaving exactly
         ;; 1 empty row above the footer hairline (the stage's 1lh bottom pad).
         ;; Fixed lines inside body-rows: top pad(1) + bottom pad(1) + header(1)
         ;; + header gap(1) + weekday/column-header row(1, Month/Week only) + optional capture(2).
         (avail-lines (- body-rows (+ 5 (if draft-cal 2 0))))
         (base-week-lines (max 3 (/ (max 0 avail-lines) nweeks)))
         (extra-week-lines (if (>= avail-lines (* 3 nweeks))
                               (% avail-lines nweeks)
                             0))
         (week-body-lines (max 8 avail-lines))
         ;; Year floating grid: 4x3 (wide), 3x4 (medium), 2x6 (narrow).
         ;; Distribute vertical breathing room across the full stage height so
         ;; desktop frames fill cleanly without dead bottom voids while compact
         ;; windows stay crisp and scroll smoothly.
         (year-cols (etaf-agenda-layout-year-columns
                     cal-inner-w
                     (etaf-agenda-plan-char-px plan (etaf-current-runtime))))
         (year-rows (/ 12 year-cols))
         (year-col-gap (if (>= cal-inner-w 94) 3 2))
         (year-card-inner (max 14 (- (/ (max 32 (- cal-inner-w (* (1- year-cols) year-col-gap)))
                                        year-cols)
                                     2)))
         ;; Stage overhead inside body-rows: stage pads(2) + header(1) + header hrule(1)
         ;; + optional capture(2) + summary row(1) + optional summary hrule(0 or 1).
         (yr-grid-avail (- body-rows (+ 6 (if draft-cal 2 0))))
         (yr-tall-card (and (= year-rows 3) (>= yr-grid-avail 32)))
         (yr-card-pad-v (if yr-tall-card 1 0))
         (yr-card-hrule (or yr-tall-card (>= yr-grid-avail 29) (> year-rows 3)))
         (yr-card-lines (+ 8 (if yr-card-hrule 1 0) (if yr-tall-card 2 0)))
         (yr-summary-hrule (cond
                            (yr-tall-card (>= yr-grid-avail 33))
                            (t (or yr-card-hrule (>= yr-grid-avail 27)))))
         (yr-effective-avail (+ yr-grid-avail (if yr-summary-hrule 0 1)))
         (yr-slack (max 0 (- yr-effective-avail (* year-rows yr-card-lines))))
         (yr-row-gap
          (cond
           ((> year-rows 3) 1)
           (yr-tall-card
            (cond ((>= yr-slack 4) 2)
                  ((>= yr-slack 2) 1)
                  (t 0)))
           (t (if (>= yr-slack 4) 2 1))))
         (yr-pre-summary-gap
          (if (= year-rows 3)
              (max 0 (- yr-slack (* (1- year-rows) yr-row-gap)))
            0))
         (yr-num (or (plist-get year-summary :year) (/ (plist-get plan :day) 10000)))
         (yr-total (or (plist-get year-summary :total) 0))
         (yr-active (or (plist-get year-summary :active-days) 0))
         (yr-busy-m (plist-get year-summary :busiest-month))
         (yr-busy-c (or (plist-get year-summary :busiest-count) 0))
         (yr-summary-text
          (cond
           ((<= yr-total 0) (format "%d 全年  暂无日程与待办" yr-num))
           (narrow (format "%d 全年 · %d 项 · 活跃 %d 天" yr-num yr-total yr-active))
           (t (format "%d 全年  %d 项日程与待办 · 活跃 %d 天 · 最忙 %d 月 (%d 项)"
                      yr-num yr-total yr-active yr-busy-m yr-busy-c))))
         (week-days (plist-get plan :week-days))
         (day (plist-get plan :day))
         (today (or (plist-get plan :today) (etaf-agenda--today)))
         (in-curr-period
          (pcase mode
            ('year (= (/ day 10000) (/ today 10000)))
            ('week (= (etaf-agenda--week-start day) (etaf-agenda--week-start today)))
            (_ (= (/ day 100) (/ today 100)))))
         (header-title
          (pcase mode
            ('year (or (plist-get plan :year-label) (format "%d 年" (/ day 10000))))
            ('week (format "%s · 第 %d 周"
                           (plist-get plan :month-label)
                           (plist-get plan :week)))
            (_ (plist-get plan :month-label))))
         (prev-label (if narrow "‹"
                       (pcase mode ('year "‹ 上年") ('week "‹ 上周") (_ "‹ 上月"))))
         (mid-label (pcase mode ('year "本年") ('week "本周") (_ "本月")))
         (next-label (if narrow "›"
                       (pcase mode ('year "下年 ›") ('week "下周 ›") (_ "下月 ›"))))
         (mode-options (if narrow
                           '((year . "年") (month . "月") (week . "周"))
                         '((year . "年视图") (month . "月视图") (week . "周视图")))))
    (etaf-view
     (column :width 'stretch :item-gap '(lh 0)
       ;; Zero-jump Calendar header:
       ;; Left: anchored [年视图 | 月视图 | 周视图]
       ;; Right: variable-width period title + equal-width right-anchored stepper
       (flex :flex-direction 'row :align-items 'center
             :width 'stretch :height '(lh 1) :gap '((lh 0) (ch 2))
         (box :flex-shrink 0
           (etaf-agenda-segmented :value mode
                                  :options mode-options
                                  :on-change on-mode))
         (box :flex-grow 1 :flex-basis '(px 0) :min-width '(ch 1) "")
         (box :flex-shrink 0 :font-weight 'bold :color (etaf-agenda-color :ink)
           (text (expr header-title)))
         (flex :flex-direction 'row :align-items 'center :flex-shrink 0
               :border (etaf-agenda-views--border :line)
           (box :padding '((lh 0) (ch 1)) :color (etaf-agenda-color :muted)
                :role 'button :tab-index 0 :pointer 'hand
                :hover-style (etaf-agenda-views--hover)
                :on-press on-prev-month
             (text (expr prev-label)))
           (box :padding '((lh 0) (ch 1))
                :color (if in-curr-period (etaf-agenda-color :dim) (etaf-agenda-color :ink))
                :border-left (etaf-agenda-views--border :line-soft)
                :border-right (etaf-agenda-views--border :line-soft)
                :role 'button :tab-index (unless in-curr-period 0)
                :pointer (unless in-curr-period 'hand)
                :hover-style (unless in-curr-period (etaf-agenda-views--hover))
                :on-press (unless in-curr-period on-today)
             (text (expr mid-label)))
           (box :padding '((lh 0) (ch 1)) :color (etaf-agenda-color :muted)
                :role 'button :tab-index 0 :pointer 'hand
                :hover-style (etaf-agenda-views--hover)
                :on-press on-next-month
             (text (expr next-label)))))
       (expr
        (if year-p
            (etaf-view (etaf-agenda-hrule :color :line-soft))
          (etaf-view (box :height '(lh 1)))))
       ;; Optional inline capture row for selected day
       (expr
        (when draft-cal
          (etaf-view
           (column :width 'stretch :item-gap '(lh 0)
             (etaf-agenda-capture-row
              :model model
              :placeholder (format "记入 %s：14:00 评审 / 待办标题…"
                                   (plist-get plan :day-label))
              :on-submit on-draft-submit
              :on-cancel on-draft-cancel)
             (box :height '(lh 1))))))
       ;; Floating Year Grid OR 7-Column Week Calendar Grid OR 7-Column Month Calendar Grid
       (expr
        (cond
         (year-p
          (etaf-view
           (column :width 'stretch :item-gap '(lh 0)
             (column :width 'stretch :item-gap (list 'lh yr-row-gap)
               (expr
                (mapcar
                 (lambda (ridx)
                   (let ((slice (seq-subseq year-months
                                            (* ridx year-cols)
                                            (min 12 (* (1+ ridx) year-cols)))))
                     (etaf-view
                      (flex :flex-direction 'row :width 'stretch
                            :height (list 'lh yr-card-lines)
                            :gap (list '(lh 0) (list 'ch year-col-gap))
                        (expr
                         (mapcar
                          (lambda (md)
                            (etaf-view
                             (etaf-agenda-year-month-card
                              :month-data md :plan plan
                              :card-pad-v yr-card-pad-v
                              :card-hrule yr-card-hrule
                              :card-inner-cols year-card-inner
                              :on-pick on-pick-day
                              :on-zoom-month on-zoom-month)))
                          slice))))))
                 (number-sequence 0 (1- year-rows)))))
             (box :if (> yr-pre-summary-gap 0)
                  :height (list 'lh yr-pre-summary-gap))
             (etaf-agenda-hrule :if yr-summary-hrule :color :line-soft)
             (flex :flex-direction 'row :align-items 'center
                   :width 'stretch :height '(lh 1) :gap '((lh 0) (ch 2))
                   :border-top (unless yr-summary-hrule
                                 (etaf-agenda-views--border :line-soft))
               (box :flex-grow 1 :flex-basis '(px 0) :min-width '(ch 0)
                    :overflow 'hidden :wrap-mode 'none
                    :color (etaf-agenda-color :muted)
                 (text (expr yr-summary-text)))
               (flex :if (not narrow) :flex-direction 'row :align-items 'center
                     :flex-shrink 0 :gap '((lh 0) (ch 1))
                 (box :flex-shrink 0 :font-weight 'bold :color (etaf-agenda-color :ink)
                   (text "1–2"))
                 (etaf-agenda-pill :text "3–5"
                                   :fg (etaf-agenda-color :ok)
                                   :bg (etaf-agenda-color :ok-soft)
                                   :bold t)
                 (etaf-agenda-pill :text "6+"
                                   :fg (etaf-agenda-color :warning)
                                   :bg (etaf-agenda-color :warning-soft)
                                   :bold t)
                 (etaf-agenda-pill :text "今日"
                                   :fg (etaf-agenda-color :accent)
                                   :bg (etaf-agenda-color :accent-soft)
                                   :bold t)
                 (etaf-agenda-pill :text "选中"
                                   :fg (etaf-agenda-color :bg)
                                   :bg (etaf-agenda-color :accent)
                                   :bold t))))))
         (week-p
          (let ((sel-col (cl-position day week-days
                                      :key (lambda (w) (plist-get w :day))
                                      :test #'equal)))
            (etaf-view
             (flex :flex-direction 'row :width 'stretch
                   :height (list 'lh (1+ week-body-lines))
               (expr
                (cl-mapcar
                 (lambda (wd cidx)
                   (etaf-view
                    (etaf-agenda-week-column
                     :wd wd
                     :wd-short (aref etaf-agenda-views--weekdays cidx)
                     :plan plan
                     :cell-cols cell-cols
                     :body-lines week-body-lines
                     :col-idx cidx
                     :sel-col sel-col
                     :on-pick on-pick-day)))
                 week-days
                 (number-sequence 0 (1- (length week-days)))))))))
         (t
          ;; Month grid with shared-edge 4-sided zero-jitter selection borders
          (let ((sel-row nil) (sel-col nil))
            (cl-loop for wk in weeks for r from 0 do
                     (cl-loop for cell in wk for c from 0 do
                              (when (equal (plist-get cell :day) day)
                                (setq sel-row r sel-col c))))
            (etaf-view
             (column :width 'stretch :item-gap '(lh 0)
               ;; Weekday header row (owns top outer frame & row-0 top shared edge)
               (flex :flex-direction 'row :width 'stretch :height '(lh 1)
                 (expr
                  (cl-mapcar
                   (lambda (wl cidx)
                     (etaf-view
                      (box :flex-grow 1 :flex-basis '(px 0)
                           :min-width (list 'ch (max 6 cell-cols))
                           :height '(lh 1) :padding '((lh 0) (ch 1))
                           :box-sizing 'border-box
                           :border-top (etaf-agenda-views--border :line)
                           :border-left (when (= cidx 0)
                                          (etaf-agenda-views--border :line))
                           :border-right (etaf-agenda-views--border
                                          (if (= cidx 6) :line :bg))
                           :border-bottom (etaf-agenda-views--border
                                           (if (and (eql sel-row 0) (eql sel-col cidx))
                                               :accent :line))
                           :font-weight 'bold :color (etaf-agenda-color :muted)
                        (text (expr wl)))))
                   (append etaf-agenda-views--weekdays nil)
                   (number-sequence 0 6))))
               ;; Weeks
               (expr
                (cl-mapcar
                 (lambda (week widx)
                   (let ((is-last (= widx (1- nweeks)))
                         (row-lines (+ base-week-lines (if (< widx extra-week-lines) 1 0))))
                     (etaf-view
                      (flex :flex-direction 'row :width 'stretch
                            :height (list 'lh row-lines)
                        (expr
                         (cl-mapcar
                          (lambda (cell cidx)
                            (etaf-view
                             (etaf-agenda-calendar-cell
                              :cell cell :plan plan
                              :cell-cols cell-cols
                              :week-lines row-lines
                              :first-col (= cidx 0)
                              :last-col (= cidx 6)
                              :last-row is-last
                              :sel-row sel-row
                              :sel-col sel-col
                              :row-idx widx
                              :col-idx cidx
                              :on-pick on-pick-day)))
                          week
                          (number-sequence 0 6)))))))
                 weeks
                 (number-sequence 0 (1- nweeks))))))))))))))

;;; ---------------------------------------------------------------------------
;;; 3. List Page
;;; ---------------------------------------------------------------------------

(etaf-define-component etaf-agenda-list-page
    (&key model plan on-grouping on-toggle-completed on-select on-toggle on-open
          on-draft-submit on-draft-cancel on-edit-submit on-edit-cancel)
  "Render the grouped List page with segmented grouping control."
  :render
  (let* ((groups (plist-get plan :list-groups))
         (total (apply #'+ (mapcar (lambda (g) (plist-get g :count)) groups)))
         (show-done (plist-get plan :show-completed))
         (short-p (plist-get (plist-get plan :layout) :short))
         (drafting (plist-get plan :drafting)))
    (etaf-view
     (column :width 'stretch :item-gap '(lh 0)
       (flex :flex-direction 'row :align-items 'center
             :width 'stretch :height '(lh 1) :gap '((lh 0) (ch 2))
             :padding '((lh 0) (ch 1) (lh 0) (ch 0))
         (box :flex-shrink 0 :font-weight 'bold :color (etaf-agenda-color :ink)
           (text "清单"))
         (box :flex-shrink 0
           (etaf-agenda-segmented :value (plist-get plan :grouping)
                                  :options '((time . "时间") (area . "领域")
                                             (project . "项目") (status . "状态"))
                                  :on-change on-grouping))
         (box :flex-grow 1 :flex-basis '(px 0) :min-width '(ch 1) "")
         ;; Count sits left of the right-anchored equal-width toggle so clicking
         ;; 隐藏已完成 <-> 显示已完成 never shifts the button horizontally.
         (box :flex-shrink 0 :color (etaf-agenda-color :dim)
           (text (expr (format "%d 条" total))))
         (box :flex-shrink 0 :color (etaf-agenda-color :muted)
              :role 'button :tab-index 0 :pointer 'hand
              :hover-style (etaf-agenda-views--hover-text :ink)
              :on-press on-toggle-completed
           (text (expr (if show-done "隐藏已完成" "显示已完成")))))
       (etaf-agenda-hrule :color :line)
       (expr
        (when (and drafting (eq (plist-get drafting :target) 'list))
          (etaf-view
           (column :width 'stretch :item-gap '(lh 0)
             (etaf-agenda-capture-row :model model
                                      :on-submit on-draft-submit
                                      :on-cancel on-draft-cancel)
             (box :height '(lh 1))))))
       (expr
        (if (null groups)
            (list (etaf-view
                   (etaf-empty :title "没有符合条件的条目"
                               :description "按 a 记一条新任务，或调整顶部的搜索与领域筛选。")))
          (apply
           #'append
           (cl-mapcar
            (lambda (grp idx)
              (delq nil
                    (list
                     (when (> idx 0)
                       (etaf-view (box :height (if short-p '(lh 1) '(lh 2)))))
                     (etaf-view
                      (etaf-agenda-section-head
                       :title (plist-get grp :title)
                       :count (plist-get grp :count)
                       :accent (plist-get grp :accent)))
                     (when (not short-p)
                       (etaf-view (box :height '(lh 1))))
                     (etaf-view
                      (column :width 'stretch :item-gap '(lh 0)
                        (expr
                         (mapcar
                          (lambda (row)
                            (etaf-view
                             (etaf-agenda-entry-row
                              :model model :row row :plan plan
                              :show-context (not (memq (plist-get plan :grouping) '(area project)))
                              :on-select on-select :on-toggle on-toggle :on-open on-open
                              :on-edit-submit on-edit-submit :on-edit-cancel on-edit-cancel)))
                          (plist-get grp :rows))))))))
            groups
            (number-sequence 0 (1- (length groups)))))))))))

;;; ---------------------------------------------------------------------------
;;; 4. Project Page (real progress bar + stages + stage/task creation)
;;; ---------------------------------------------------------------------------

(etaf-define-component etaf-agenda-project-page
    (&key model plan on-select on-toggle on-open on-add-stage on-add-task-in-stage
          on-add-project on-draft-submit on-draft-cancel on-edit-submit on-edit-cancel)
  "Render the Project page with real completion progress bar and stages."
  :render
  (let* ((proj (plist-get plan :project-plan))
         (pid (plist-get proj :id))
         (done (plist-get proj :done))
         (total (plist-get proj :total))
         (pct (plist-get proj :progress))
         (stages (plist-get proj :stages))
         (loose (plist-get proj :loose))
         (drafting (plist-get plan :drafting))
         (short-p (plist-get (plist-get plan :layout) :short))
         (inner-cols (plist-get (plist-get plan :layout) :inner-cols))
         (pct-str (format "%d/%d · %d%%" done total pct))
         (bar-cols (max 14 (- inner-cols (string-width pct-str) 3))))
    (etaf-view
     (column :width 'stretch :item-gap '(lh 0)
       (expr
        (if (null pid)
            (etaf-view
             (column :width 'stretch :item-gap '(lh 0)
               (expr
                (when (and drafting (eq (plist-get drafting :target) 'project))
                  (etaf-view
                   (column :width 'stretch :item-gap '(lh 0)
                     (etaf-agenda-capture-row
                      :model model
                      :placeholder "记一条任务（可用 +项目名 自动建项目）…"
                      :on-submit on-draft-submit
                      :on-cancel on-draft-cancel)
                     (box :height '(lh 1))))))
               (etaf-empty :title "还没有项目"
                           :description "在左侧点击「项目 +」或按 P 创建第一个项目，也可以用「任务 +项目名」捕捉。"
                           :action-label "+ 创建项目"
                           :on-action on-add-project)))
          (etaf-view
           (column :width 'stretch :item-gap '(lh 0)
             ;; Project header flush at Col 0 (exact same left edge as stages & `▎')
             (flex :flex-direction 'row :align-items 'center
                   :width 'stretch :height '(lh 1)
                   :padding '((lh 0) (ch 1) (lh 0) (ch 0))
               (box :flex-shrink 0 :font-weight 'bold :color (etaf-agenda-color :ink)
                 (text (expr (plist-get proj :name))))
               (box :width '(ch 2) :flex-shrink 0 "")
               (box :flex-grow 1 :flex-basis '(ch 0) :min-width '(ch 0)
                    :height '(lh 1) :wrap-mode 'none :overflow 'hidden
                    :color (etaf-agenda-color :muted)
                 (text (expr (plist-get proj :goal))))
               (box :flex-shrink 0 :padding '((lh 0) (ch 0) (lh 0) (ch 2))
                    :color (etaf-agenda-color :accent)
                    :role 'button :tab-index 0 :pointer 'hand
                    :hover-style (etaf-agenda-views--hover-text :ink)
                    :on-press on-add-stage
                 (text "+ 新阶段")))
             (box :height '(lh 1))
             ;; Full progress bar flush at Col 0 .. W - 1ch
             (flex :flex-direction 'row :align-items 'center
                   :width 'stretch :height '(lh 1)
                   :padding '((lh 0) (ch 1) (lh 0) (ch 0))
               (etaf-agenda-hbar :ratio (if (zerop total) 0.0 (/ (float done) total))
                                 :width bar-cols
                                 :color (etaf-agenda-color :ok))
               (box :flex-grow 1 :flex-basis '(px 0) :min-width '(ch 1) "")
               (box :flex-shrink 0 :font-weight 'bold :color (etaf-agenda-color :ok)
                 (text (expr pct-str))))
             (etaf-agenda-hrule :color :line)
             ;; Unstaged inline draft
             (expr
              (when (and drafting (eq (plist-get drafting :target) 'project)
                         (null (plist-get drafting :stage)))
                (etaf-view
                 (column :width 'stretch :item-gap '(lh 0)
                   (etaf-agenda-capture-row
                    :model model
                    :placeholder (format "添加到项目「%s」…" (plist-get proj :name))
                    :on-submit on-draft-submit
                    :on-cancel on-draft-cancel)
                   (box :height '(lh 1))))))
             ;; Stages
             (expr
              (apply
               #'append
               (cl-mapcar
                (lambda (st idx)
                  (let* ((sid (plist-get st :id))
                         (srows (plist-get st :rows))
                         (show-st-draft (and drafting
                                             (eq (plist-get drafting :target) 'project)
                                             (equal (plist-get drafting :stage) sid))))
                    (delq nil
                          (list
                           (when (> idx 0)
                             (etaf-view (box :height (if short-p '(lh 1) '(lh 2)))))
                           (etaf-view
                            (etaf-agenda-section-head
                             :title (plist-get st :title)
                             :badge-text (format "%d/%d"
                                                 (plist-get st :done)
                                                 (plist-get st :count))
                             :accent :info
                             :action-label "+ 添加"
                             :on-action (lambda ()
                                          (when on-add-task-in-stage
                                            (funcall on-add-task-in-stage sid)))))
                           (when (not short-p)
                             (etaf-view (box :height '(lh 1))))
                           (when show-st-draft
                             (etaf-view
                              (etaf-agenda-capture-row
                               :model model
                               :placeholder (format "添加到阶段「%s」…" (plist-get st :title))
                               :on-submit on-draft-submit
                               :on-cancel on-draft-cancel)))
                           (if srows
                               (etaf-view
                                (column :width 'stretch :item-gap '(lh 0)
                                  (expr
                                   (mapcar
                                    (lambda (row)
                                      (etaf-view
                                       (etaf-agenda-entry-row
                                        :model model :row row :plan plan
                                        :show-context nil
                                        :on-select on-select :on-toggle on-toggle :on-open on-open
                                        :on-edit-submit on-edit-submit :on-edit-cancel on-edit-cancel)))
                                    srows))))
                             (unless show-st-draft
                               (etaf-view
                                (box :padding '((lh 0) (ch 1)) :height '(lh 1)
                                     :color (etaf-agenda-color :dim)
                                  (text "该阶段暂无条目")))))))))
                stages
                (number-sequence 0 (1- (length stages))))))
             ;; Loose unstaged rows
             (expr
              (when loose
                (etaf-view
                 (column :width 'stretch :item-gap '(lh 0)
                   (box :height (if short-p '(lh 1) '(lh 2)))
                   (etaf-agenda-section-head :title "未分阶段" :count (length loose) :accent :muted)
                   (box :if (not short-p) :height '(lh 1))
                   (expr
                    (mapcar
                     (lambda (row)
                       (etaf-view
                        (etaf-agenda-entry-row
                         :model model :row row :plan plan :show-context nil
                         :on-select on-select :on-toggle on-toggle :on-open on-open
                         :on-edit-submit on-edit-submit :on-edit-cancel on-edit-cancel)))
                     loose))))))
             (expr
              (when (and (null stages) (null loose))
                (etaf-view
                 (etaf-empty :title "这个项目还没有条目"
                             :description "按 a 为该项目添加任务，或按 A 新建项目阶段。"))))))))))))

;;; ---------------------------------------------------------------------------
;;; 5. Habits Page (merged deduplicated 21-day 1:1 square matrix!)
;;; ---------------------------------------------------------------------------

(etaf-define-component etaf-agenda-habits-page
    (&key model plan on-select on-toggle-day on-open on-draft-submit on-draft-cancel)
  "Render the Habits page: single unified 21-day 1:1 square matrix."
  :render
  (let* ((habits (plist-get plan :habits))
         (day (or (plist-get plan :habit-anchor) (etaf-agenda--today)))
         (habit-day (plist-get plan :habit-day))
         (drafting (plist-get plan :drafting))
         (layout (plist-get plan :layout))
         (narrow (eq (plist-get layout :tier) 'narrow))
         (inner-cols (plist-get layout :inner-cols))
         (span (if narrow 14 etaf-agenda-habit-days))
         (start-day (etaf-agenda--shift day (- (1- span))))
         (wk1-lbl (etaf-agenda--short-date-label start-day))
         (wk2-lbl (etaf-agenda--short-date-label (etaf-agenda--shift start-day 7)))
         (wk3-lbl (when (>= span 21)
                    (etaf-agenda--short-date-label (etaf-agenda--shift start-day 14))))
         (name-cols (if narrow 16 20))
         (tile-cols (if (and (not narrow) (>= (- inner-cols name-cols 18) 67)) 3 2))
         (tile-size (if (= tile-cols 3) 0.86 0.80))
         (wk-gap 2)
         (wk-cols (* 7 tile-cols))
         (wk-stride (+ wk-cols wk-gap)))
    (etaf-view
     (column :width 'stretch :item-gap '(lh 0)
       (flex :flex-direction 'row :align-items 'center
             :width 'stretch :height '(lh 1) :gap '((lh 0) (ch 2))
             :padding '((lh 0) (ch 1) (lh 0) (ch 0))
         (box :flex-shrink 0 :font-weight 'bold :color (etaf-agenda-color :ink)
           (text "习惯打卡"))
         (box :flex-shrink 0 :color (etaf-agenda-color :muted)
           (text (expr (format "近 %d 天 · 点击任意正方格即可补卡" span))))
         (box :flex-grow 1 :flex-basis '(px 0) "")
         (box :flex-shrink 0 :color (etaf-agenda-color :dim)
           (text (expr (format "当前光标日 %s" (etaf-agenda--short-date-label habit-day))))))
       (etaf-agenda-hrule :color :line)
       ;; In-place habit capture row
       (expr
        (when (and drafting (eq (plist-get drafting :target) 'habits))
          (etaf-view
           (column :width 'stretch :item-gap '(lh 0)
             (etaf-agenda-capture-row
              :model model
              :placeholder "每天 睡前阅读 30 分钟 / 工作日 晨跑"
              :on-submit on-draft-submit
              :on-cancel on-draft-cancel)
             (box :height '(lh 1))))))
       (expr
        (if (null habits)
            (etaf-view
             (etaf-empty :title "还没有习惯"
                         :description "按 a 记一条，例如「每天 读书」或「工作日 晨跑」。"))
          (etaf-view
           (column :width 'stretch :item-gap '(lh 0)
             ;; Date scale header aligned with habit titles at Col 1 inside Col 0..W
             (flex :flex-direction 'row :align-items 'center
                   :width 'stretch :height '(lh 1)
                   :padding '((lh 0) (ch 1) (lh 0) (ch 0))
               (box :width '(ch 1) :flex-shrink 0 "")
               (box :width (list 'ch (+ name-cols 2)) :flex-shrink 0
                    :color (etaf-agenda-color :dim)
                 (text "习惯"))
               (box :width (list 'ch wk-stride) :flex-shrink 0 :color (etaf-agenda-color :dim)
                 (text (expr wk1-lbl)))
               (expr
                (if wk3-lbl
                    (list
                     (etaf-view (box :width (list 'ch wk-stride) :flex-shrink 0
                                     :color (etaf-agenda-color :dim)
                                  (text (expr wk2-lbl))))
                     (etaf-view
                      (flex :flex-direction 'row :align-items 'center
                            :width (list 'ch wk-cols) :flex-shrink 0
                        (box :flex-shrink 0 :color (etaf-agenda-color :dim)
                          (text (expr wk3-lbl)))
                        (box :flex-grow 1 :flex-basis '(px 0) "")
                        (box :width (list 'ch tile-cols) :flex-shrink 0 :font-weight 'bold
                             :color (etaf-agenda-color :accent)
                          (text "今")))))
                  (list
                   (etaf-view
                    (flex :flex-direction 'row :align-items 'center
                          :width (list 'ch wk-cols) :flex-shrink 0
                      (box :flex-shrink 0 :color (etaf-agenda-color :dim)
                        (text (expr wk2-lbl)))
                      (box :flex-grow 1 :flex-basis '(px 0) "")
                      (box :width (list 'ch tile-cols) :flex-shrink 0 :font-weight 'bold
                           :color (etaf-agenda-color :accent)
                        (text "今")))))))
               (box :flex-grow 1 :flex-basis '(px 0) "")
               (box :flex-shrink 0 :color (etaf-agenda-color :dim)
                 (text "达标 / 连击")))
             (etaf-agenda-hrule :color :line-soft)
             ;; Habit rows: `▎' flush at Col 0 (exact same left edge as `习惯打卡')
             (expr
              (apply
               #'append
               (mapcar
                (lambda (h)
                  (let* ((hid (plist-get h :id))
                         (selected (equal (plist-get plan :selected) hid))
                         (measured (plist-get h :measured))
                         (target (or (plist-get h :target) 1))
                         (left (max 0 (- target measured)))
                         (streak (or (plist-get h :streak) 0))
                         (cells (last (plist-get h :cells) span)))
                    (list
                     (etaf-view
                      (flex :flex-direction 'row :align-items 'center
                            :width 'stretch :height '(lh 2)
                            :padding '((lh 0) (ch 1) (lh 0) (ch 0))
                            :background-color (when selected (etaf-agenda-color :select))
                        ;; Flush 2-row left cyan accent bar at Col 0 (aligned with `习惯打卡')
                        (column :width '(ch 1) :height '(lh 2) :flex-shrink 0 :item-gap '(lh 0)
                                :color (etaf-agenda-color :accent)
                          (box :height '(lh 1) (text (expr (if selected "▎" ""))))
                          (box :height '(lh 1) (text (expr (if selected "▎" "")))))
                        ;; Name + remaining status (exact name-cols + 2ch matching header).
                        ;; Keep outer matrix row calm without row-wide hover so
                        ;; the 21 independent colour-coded day tiles never clash
                        ;; or get blackened; only the single-line title hovers.
                        (column :width (list 'ch (+ name-cols 2)) :flex-shrink 0 :item-gap '(lh 0)
                          (box :height '(lh 1) :wrap-mode 'none :overflow 'hidden
                               :font-weight (if selected 'bold 'normal)
                               :color (etaf-agenda-color :ink)
                               :role 'button :tab-index 0 :pointer 'hand
                               :help-echo "点击选中习惯，再次点击打开详情"
                               :hover-style (unless selected (etaf-agenda-views--hover-text :accent))
                               :on-press (lambda ()
                                           (if selected
                                               (when on-open (funcall on-open hid))
                                             (when on-select (funcall on-select hid))))
                            (text (expr (etaf-agenda-clip-text (plist-get h :title) name-cols))))
                          (box :height '(lh 1)
                               :color (if (zerop left)
                                          (etaf-agenda-color :ok)
                                        (etaf-agenda-color :warning))
                            (text (expr (if (zerop left) "已达成"
                                          (format "差 %d 次" left))))))
                        ;; 21 strict 1:1 square tiles grouped by week
                        (flex :flex-direction 'row :align-items 'center :flex-shrink 0
                          (expr
                           (apply
                            #'append
                            (cl-mapcar
                             (lambda (cell cidx)
                               (let* ((cday (plist-get cell :day))
                                      (cdone (plist-get cell :done))
                                      (is-cur-day (and selected (equal cday habit-day)))
                                      (is-today (equal cday day)))
                                 (delq nil
                                       (list
                                        (when (and (> cidx 0) (zerop (% cidx 7)))
                                          (etaf-view (box :width (list 'ch wk-gap) :flex-shrink 0 "")))
                                        (etaf-view
                                         (etaf-agenda-square-tile
                                          :filled (or cdone (not is-today))
                                          :color (cond
                                                  (cdone (etaf-agenda-color :ok))
                                                  (is-today (etaf-agenda-color :accent))
                                                  (t (etaf-agenda-color :heat0)))
                                          :size tile-size
                                          :cell-cols tile-cols
                                          :selected is-cur-day
                                          :help (format "%s · %s（点击切换）"
                                                        (etaf-agenda--date-label cday)
                                                        (if cdone "已打卡" "未打卡"))
                                          :on-press (lambda ()
                                                      (when on-toggle-day
                                                        (funcall on-toggle-day hid cday)))))))))
                             cells
                             (number-sequence 0 (1- (length cells)))))))
                        (box :flex-grow 1 :flex-basis '(px 0) "")
                        ;; Weekly ratio + streak
                        (column :flex-shrink 0 :item-gap '(lh 0) :cross-align 'end
                          (box :height '(lh 1) :font-weight 'bold
                               :color (if (zerop left)
                                          (etaf-agenda-color :ok)
                                        (etaf-agenda-color :ink))
                            (text (expr (format "%d/%d" measured target))))
                          (box :height '(lh 1)
                               :color (if (>= streak 2)
                                          (etaf-agenda-color :ok)
                                        (etaf-agenda-color :dim))
                            (text (expr (if (>= streak 2)
                                            (format "连 %d 天" streak)
                                          "—")))))))
                     (etaf-view (box :height '(lh 1))))))
                habits)))
             ;; Crisp 1:1 square legend aligned at Col 1 directly under habit names
             (flex :flex-direction 'row :align-items 'center :width 'stretch :height '(lh 1)
                   :padding '((lh 0) (ch 1)) :gap '((lh 0) (ch 3))
               (flex :flex-direction 'row :align-items 'center
                 (etaf-agenda-square-tile :filled t :color (etaf-agenda-color :ok) :size 0.72 :cell-cols 2)
                 (box :color (etaf-agenda-color :muted) (text "已完成")))
               (flex :flex-direction 'row :align-items 'center
                 (etaf-agenda-square-tile :filled nil :color (etaf-agenda-color :accent) :size 0.72 :cell-cols 2)
                 (box :color (etaf-agenda-color :muted) (text "今日待打卡")))
               (flex :flex-direction 'row :align-items 'center
                 (etaf-agenda-square-tile :filled t :color (etaf-agenda-color :heat0) :size 0.72 :cell-cols 2)
                 (box :color (etaf-agenda-color :muted) (text "未打卡"))))))))))))

;;; ---------------------------------------------------------------------------
;;; 6. Review Page (KPI strip + dual bars + 4-level 1:1 square heatmap)
;;; ---------------------------------------------------------------------------

(etaf-define-component etaf-agenda-review-page
    (&key model plan on-prev-month on-next-month on-today on-draft-submit on-draft-cancel)
  "Render the Monthly Review page without duplicating right-rail insights."
  :render
  (let* ((rev (plist-get plan :review))
         (drafting (plist-get plan :drafting))
         (areas (seq-take (plist-get rev :areas) 5))
         (projects (seq-take (plist-get rev :projects) 5))
         (moved (seq-take (plist-get rev :moved) 5))
         (daily (plist-get rev :daily))
         (max-area (max 1 (cl-reduce #'max areas :key #'cdr :initial-value 1)))
         (max-proj (max 1 (cl-reduce #'max projects :key #'cdr :initial-value 1)))
         (layout (plist-get plan :layout))
         (narrow (eq (plist-get layout :tier) 'narrow))
         (short-p (plist-get layout :short))
         (inner-cols (plist-get layout :inner-cols))
         (half-cols (if narrow inner-cols (max 24 (/ (- inner-cols 4) 2))))
         (area-bar-w (max 8 (- half-cols 14)))
         (proj-bar-w (max 8 (- half-cols 20)))
         (heat-tile-w (max 2 (min 4 (/ (max 1 (- inner-cols 5))
                                       (max 1 (length daily))))))
         (kpis (list (list "已完成" (plist-get rev :done) :ok)
                     (list "新建" (plist-get rev :created) :info)
                     (list "迁移" (plist-get rev :migrated) :warning)
                     (list "放弃" (plist-get rev :dropped) :muted)))
         (is-curr-month (= (/ (plist-get plan :day) 100)
                           (/ (etaf-agenda--today) 100))))
    (etaf-view
     (column :width 'stretch :item-gap '(lh 0)
       ;; Header (mirrors Calendar header: fixed title left, period label + stepper right)
       (flex :flex-direction 'row :align-items 'center
             :width 'stretch :height '(lh 1) :gap '((lh 0) (ch 2))
         (box :flex-shrink 0 :font-weight 'bold :color (etaf-agenda-color :ink)
           (text "月度回顾"))
         (box :flex-grow 1 :flex-basis '(px 0) :min-width '(ch 1) "")
         (box :flex-shrink 0 :font-weight 'bold :color (etaf-agenda-color :ink)
           (text (expr (plist-get plan :month-label))))
         (flex :flex-direction 'row :align-items 'center :flex-shrink 0
               :border (etaf-agenda-views--border :line)
           (box :padding '((lh 0) (ch 1)) :color (etaf-agenda-color :muted)
                :role 'button :tab-index 0 :pointer 'hand
                :hover-style (etaf-agenda-views--hover) :on-press on-prev-month
             (text "‹ 上月"))
           (box :padding '((lh 0) (ch 1))
                :color (if is-curr-month (etaf-agenda-color :dim) (etaf-agenda-color :ink))
                :border-left (etaf-agenda-views--border :line-soft)
                :border-right (etaf-agenda-views--border :line-soft)
                :role 'button :tab-index (unless is-curr-month 0)
                :pointer (unless is-curr-month 'hand)
                :hover-style (unless is-curr-month (etaf-agenda-views--hover))
                :on-press (unless is-curr-month on-today)
             (text "本月"))
           (box :padding '((lh 0) (ch 1)) :color (etaf-agenda-color :muted)
                :role 'button :tab-index 0 :pointer 'hand
                :hover-style (etaf-agenda-views--hover) :on-press on-next-month
             (text "下月 ›"))))
       (box :height '(lh 1))
       ;; Optional in-place capture row when user clicks '+ 新建' or presses 'a' on Review
       (expr
        (when (and drafting (eq (plist-get drafting :target) 'review))
          (etaf-view
           (column :width 'stretch :item-gap '(lh 0)
             (etaf-agenda-capture-row
              :model model
              :placeholder "记一条待办或复盘行动项：明天 10:00 …"
              :on-submit on-draft-submit
              :on-cancel on-draft-cancel)
             (box :height '(lh 1))))))
       ;; Airy 4-column KPI strip (generous vertical breathing inside 1px border)
       (flex :flex-direction 'row :width 'stretch
             :padding '((lh 1) (ch 1))
             :border (etaf-agenda-views--border :line)
         (expr
          (cl-mapcar
           (lambda (item idx)
             (etaf-view
              (column :flex-grow 1 :flex-basis '(px 0) :item-gap '(lh 0)
                      :padding '((lh 0) (ch 2))
                      :border-left (when (> idx 0) (etaf-agenda-views--border :line-soft))
                (box :height '(lh 1) :font-weight 'bold
                     :color (etaf-agenda-color (nth 2 item))
                  (text (expr (number-to-string (or (nth 1 item) 0)))))
                (box :height '(lh 1) :color (etaf-agenda-color :muted)
                  (text (expr (nth 0 item)))))))
           kpis
           (number-sequence 0 3))))
       (box :height '(lh 1))
       ;; Dual-column horizontal breakdown with clean heading breathing
       (flex :flex-direction (if narrow 'column 'row) :width 'stretch
             :gap '((lh 1) (ch 4))
         (column :flex-grow 1 :flex-basis '(px 0) :min-width '(ch 0)
                 :item-gap (if short-p '(lh 0) '(lh 1))
           (box :height '(lh 1) :font-weight 'bold :color (etaf-agenda-color :muted)
             (text "按领域完成"))
           (expr
            (if (null areas)
                (list (etaf-view (box :height '(lh 1) :color (etaf-agenda-color :dim)
                                   (text "本月暂无已完成条目"))))
              (cl-mapcar
               (lambda (pair idx)
                 (etaf-view
                  (flex :flex-direction 'row :align-items 'center
                        :width 'stretch :height '(lh 1)
                    (box :width '(ch 8) :flex-shrink 0 :overflow 'hidden
                         :color (etaf-agenda-color :ink)
                      (text (expr (etaf-agenda-clip-text (car pair) 8))))
                    (box :width '(ch 1) :flex-shrink 0 "")
                    (etaf-agenda-hbar :ratio (/ (float (cdr pair)) max-area)
                                      :width area-bar-w
                                      :color (etaf-agenda-area-color idx))
                    (box :flex-grow 1 :flex-basis '(px 0) :min-width '(ch 1) "")
                    (box :width '(ch 3) :flex-shrink 0 :text-align 'right
                         :color (etaf-agenda-color :muted)
                      (text (expr (number-to-string (cdr pair))))))))
               areas
               (number-sequence 0 (1- (length areas)))))))
         (column :flex-grow 1 :flex-basis '(px 0) :min-width '(ch 0)
                 :item-gap (if short-p '(lh 0) '(lh 1))
           (box :height '(lh 1) :font-weight 'bold :color (etaf-agenda-color :muted)
             (text "按项目完成"))
           (expr
            (if (null projects)
                (list (etaf-view (box :height '(lh 1) :color (etaf-agenda-color :dim)
                                   (text "本月暂无项目条目完成"))))
              (cl-mapcar
               (lambda (pair idx)
                 (etaf-view
                  (flex :flex-direction 'row :align-items 'center
                        :width 'stretch :height '(lh 1)
                    (box :width '(ch 14) :flex-shrink 0 :overflow 'hidden
                         :color (etaf-agenda-color :ink)
                      (text (expr (etaf-agenda-clip-text (car pair) 14))))
                    (box :width '(ch 1) :flex-shrink 0 "")
                    (etaf-agenda-hbar :ratio (/ (float (cdr pair)) max-proj)
                                      :width proj-bar-w
                                      :color (etaf-agenda-area-color (1+ idx)))
                    (box :flex-grow 1 :flex-basis '(px 0) :min-width '(ch 1) "")
                    (box :width '(ch 3) :flex-shrink 0 :text-align 'right
                         :color (etaf-agenda-color :muted)
                      (text (expr (number-to-string (cdr pair))))))))
               projects
               (number-sequence 0 (1- (length projects))))))))
       (etaf-agenda-hrule :color :line-soft)
       ;; 4-level 1:1 square daily heatmap spanning stage cleanly
       (column :width 'stretch :item-gap '(lh 0)
         (flex :flex-direction 'row :align-items 'center :width 'stretch :height '(lh 1)
           (box :flex-shrink 0 :font-weight 'bold :color (etaf-agenda-color :muted)
             (text (expr (if daily
                             (format "每日完成热力（%s – %s）"
                                     (etaf-agenda--date-label (car (car daily)))
                                     (etaf-agenda--date-label (car (car (last daily)))))
                           "每日完成热力（未来月份暂无记录）"))))
           (box :flex-grow 1 :flex-basis '(px 0) "")
           (flex :flex-direction 'row :align-items 'center :flex-shrink 0
             (box :color (etaf-agenda-color :dim) :padding '((lh 0) (ch 1) (lh 0) (ch 0)) (text "少"))
             (etaf-agenda-square-tile :filled t :color (etaf-agenda-color :heat0) :size 0.72 :cell-cols 2)
             (etaf-agenda-square-tile :filled t :color (etaf-agenda-color :heat1) :size 0.72 :cell-cols 2)
             (etaf-agenda-square-tile :filled t :color (etaf-agenda-color :heat2) :size 0.72 :cell-cols 2)
             (etaf-agenda-square-tile :filled t :color (etaf-agenda-color :heat3) :size 0.72 :cell-cols 2)
             (box :color (etaf-agenda-color :dim) :padding '((lh 0) (ch 0) (lh 0) (ch 1)) (text "多"))))
         (box :height '(lh 1))
         (flex :flex-direction 'row :flex-wrap 'wrap :align-items 'center
               :width 'stretch :min-height '(lh 1)
           (expr
            (apply
             #'append
             (cl-mapcar
              (lambda (pair idx)
                (delq nil
                      (list
                       (when (and (> idx 0) (zerop (% idx 7)))
                         (etaf-view (box :width '(ch 1) :flex-shrink 0 "")))
                       (etaf-view
                        (etaf-agenda-square-tile
                         :filled t
                         :color (etaf-agenda-views--heat-color (cdr pair))
                         :size 0.88
                         :cell-cols heat-tile-w
                         :help (format "%s：完成 %d 项"
                                       (etaf-agenda--date-label (car pair))
                                       (cdr pair)))))))
              daily
              (number-sequence 0 (1- (length daily))))))))
       (etaf-agenda-hrule :color :line-soft)
       ;; High-frequency migration procrastination alert
       (column :width 'stretch :item-gap '(lh 0)
         (box :height '(lh 1) :font-weight 'bold :color (etaf-agenda-color :warning)
           (text "高频迁移警示"))
         (box :height '(lh 1))
         (expr
          (if (null moved)
              (list (etaf-view (box :height '(lh 1) :color (etaf-agenda-color :dim)
                                 (text "本月没有被推迟的条目，执行节奏很稳。"))))
            (mapcar
             (lambda (pair)
               (etaf-view
                (flex :flex-direction 'row :align-items 'center
                      :width 'stretch :height '(lh 1) :gap '((lh 0) (ch 2))
                  (box :flex-grow 1 :flex-basis '(ch 0) :min-width '(ch 0)
                       :height '(lh 1) :wrap-mode 'none :overflow 'hidden
                       :color (etaf-agenda-color :ink)
                    (text (expr (car pair))))
                  (etaf-agenda-pill :text (format "推过 %d 次" (cdr pair))
                                    :fg (etaf-agenda-color :warning)
                                    :bg (etaf-agenda-color :warning-soft)))))
             moved))))))))

(provide 'etaf-agenda-views-pages)
;;; etaf-agenda-views-pages.el ends here
