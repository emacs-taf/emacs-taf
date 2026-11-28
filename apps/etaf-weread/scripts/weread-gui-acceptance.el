;;; weread-gui-acceptance.el --- Real-account GUI acceptance pass -*- lexical-binding: t; -*-

;; Copyright (C) 2026 ETAF contributors
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; The maintenance probe checks layout invariants in one state; this file
;; drives the reader through every affordance the manual documents, against
;; the real account and a real frame, and records one line per step plus the
;; measured cost of the interactions that matter.  Run it in a fresh
;; `pi-skill eac instance open' instance:
;;
;;   (load "scripts/weread-gui-acceptance.el")
;;   (etaf-weread-gui-acceptance-run)     ; returns (PLIST :problems …)
;;
;; Everything goes through the real keymap (`execute-kbd-macro'); only the two
;; prompt readers and `browse-url' are replaced with deterministic answers,
;; because a scheduled run must not wait for a human, and the session writes
;; its preferences to a disposable file instead of the user's.  Each step is
;; appended to `etaf-weread-gui-acceptance-log-file' while the pass runs, so a
;; timeout still leaves the evidence behind.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'etaf-weread)

(defvar etaf-weread-gui--model)

(declare-function etaf-weread-gui-open "weread-gui-probe" (&optional size))
(declare-function etaf-weread-gui--flush "weread-gui-probe" ())
(declare-function etaf-weread-gui-check "weread-gui-probe" ())

(load (expand-file-name "weread-gui-probe.el"
                        (file-name-directory (or load-file-name
                                                 (bound-and-true-p byte-compile-current-file)
                                                 buffer-file-name)))
      nil t)

(defvar etaf-weread-gui-acceptance-log-file "/tmp/weread-acceptance.log"
  "File the acceptance pass appends every step and measurement to.")

(defvar etaf-weread-gui-acceptance--problems nil
  "Failures the current pass collected, newest first.")

(defvar etaf-weread-gui-acceptance--latencies nil
  "Measured interaction costs of the current pass, as (LABEL . MS).")

(defvar etaf-weread-gui-acceptance--steps 0
  "Number of checks the current pass ran.")

(defvar etaf-weread-gui-acceptance--settings nil
  "Disposable settings file the acceptance session uses.")

(defun etaf-weread-gui-acceptance--log (fmt &rest args)
  "Append one timestamped line to the acceptance log; return it."
  (let ((line (format "%s %s" (format-time-string "%H:%M:%S") (apply #'format fmt args))))
    (write-region (concat line "\n") nil etaf-weread-gui-acceptance-log-file 'append)
    line))

(defun etaf-weread-gui-acceptance--check (step ok &optional detail)
  "Record STEP as passed or failed, with DETAIL on failure."
  (cl-incf etaf-weread-gui-acceptance--steps)
  (if ok
      (etaf-weread-gui-acceptance--log "ok   %s" step)
    (push (format "%s%s" step (if detail (format " — %s" detail) ""))
          etaf-weread-gui-acceptance--problems)
    (etaf-weread-gui-acceptance--log "FAIL %s%s" step
                                     (if detail (format " — %s" detail) ""))))

(defun etaf-weread-gui-acceptance--state ()
  "Return the acceptance session's detached state."
  (etaf-weread-state etaf-weread-gui--model))

(defun etaf-weread-gui-acceptance--wait (predicate &optional seconds)
  "Wait until PREDICATE holds or SECONDS pass; return its last value."
  (let ((deadline (+ (float-time) (or seconds 20))))
    (while (and (not (funcall predicate)) (< (float-time) deadline))
      (sit-for 0.1))
    (funcall predicate)))

(defmacro etaf-weread-gui-acceptance--timed (label &rest body)
  "Run BODY and record how long it took under LABEL."
  (declare (indent 1))
  `(let ((started (float-time)))
     (prog1 (progn ,@body)
       (push (cons ,label (round (* 1000 (- (float-time) started))))
             etaf-weread-gui-acceptance--latencies))))

(defun etaf-weread-gui-acceptance--keys (keys &optional wait)
  "Send KEYS through the real command loop and apply the renderer's updates.
WAIT is the quiet time after the keys, default 0.15 seconds.  A key that
closes the reader (`q') leaves nothing to flush, so the flush is skipped."
  (when-let* ((buffer (get-buffer etaf-weread-buffer-name)))
    (with-current-buffer buffer
      (execute-kbd-macro (kbd keys))))
  (sit-for (or wait 0.15))
  (when (get-buffer etaf-weread-buffer-name)
    (etaf-weread-gui--flush)))

(defmacro etaf-weread-gui-acceptance--step (label &rest body)
  "Run BODY as one named step; a signaled error fails LABEL but not the pass."
  (declare (indent 1))
  `(condition-case error
       (progn ,@body)
     (error (etaf-weread-gui-acceptance--check ,label nil (error-message-string error)))))

(defun etaf-weread-gui-acceptance--prompt-stub (answer)
  "Return a `read-string' replacement that always gives ANSWER."
  (lambda (&rest _) answer))

(defun etaf-weread-gui-acceptance--layout-matrix ()
  "Resize the frame through every layout and check each canvas.
The check waits for the model to adopt the new layout before it reads the
canvas."
  (dolist (size '((150 . 40) (100 . 28) (60 . 20)))
    (set-frame-size (selected-frame) (car size) (cdr size))
    (let ((expected (etaf-weread--layout-for (car size))))
      (etaf-weread-gui-acceptance--wait
       (lambda ()
         (eq expected
             (plist-get (etaf-weread-gui-acceptance--state) :layout)))
       8)
      (sit-for 0.4))
    (etaf-weread-gui--flush)
    (etaf-weread-gui-acceptance--check
     (format "layout %sx%s" (car size) (cdr size))
     (null (etaf-weread-gui-check))
     (format "%S" (etaf-weread-gui-check))))
  (set-frame-size (selected-frame) 150 40)
  (sit-for 1.5))

(defun etaf-weread-gui-acceptance--stall (label seconds keys)
  "Send KEYS for SECONDS under a 50ms timer and record timer lateness.
The timer measures how late a fixed 50 ms schedule runs while the reader
repaints, which is what a person feels as jank."
  (let ((samples nil)
        (index 0)
        (started (float-time))
        (timer nil)
        (final nil))
    (setq timer (run-at-time 0.05 0.05
                             (lambda ()
                               (let ((late (- (float-time)
                                              (+ started (* (cl-incf index) 0.05)))))
                                 (push late samples)))))
    (unwind-protect
        (let ((deadline (+ (float-time) seconds)))
          (while (< (float-time) deadline)
            (etaf-weread-gui-acceptance--keys keys 0.2)))
      (cancel-timer timer))
    (setq final (list :samples (length samples)
                      :max-ms (round (* 1000 (apply #'max 0.0 samples)))
                      :over-20 (cl-count-if (lambda (x) (> x 0.02)) samples)
                      :over-100 (cl-count-if (lambda (x) (> x 0.1)) samples)))
    (push (cons label (plist-get final :max-ms)) etaf-weread-gui-acceptance--latencies)
    (etaf-weread-gui-acceptance--log "stall %s %S" label final)
    (etaf-weread-gui-acceptance--check (format "smooth %s" label)
                                       (< (plist-get final :max-ms) 250)
                                       (format "max lateness %sms" (plist-get final :max-ms)))
    final))

;;; ---------------------------------------------------------------------------
;;; Phases
;;; ---------------------------------------------------------------------------

(defun etaf-weread-gui-acceptance--browse ()
  "Accept the shelf, its sections, panes, search, index and statistics."
  ;; Mount and shelf.
  (let ((timeout 40))
    (etaf-weread-gui-acceptance--timed
     "mount+shelf"
     (progn
       (setq etaf-weread-gui-acceptance--settings
             (make-temp-file "weread-acceptance-" nil ".eld"))
       (let ((etaf-weread-settings-file etaf-weread-gui-acceptance--settings))
         (etaf-weread-gui-open "150x40"))
       (etaf-weread-gui-acceptance--wait
        (lambda () (> (or (plist-get (etaf-weread-gui-acceptance--state) :rows-total) 0) 0))
        timeout))))
  (let ((state (etaf-weread-gui-acceptance--state)))
    (etaf-weread-gui-acceptance--check "shelf rows" (> (plist-get state :rows-total) 0))
    (etaf-weread-gui-acceptance--check "account signed in"
                                       (let ((account (plist-get state :account)))
                                         (and account (not (string-empty-p (or (plist-get account :name) ""))))))
    (etaf-weread-gui-acceptance--check "shelf summary" (not (string-empty-p (or (plist-get state :summary) "")))))

  ;; List navigation.
  (etaf-weread-gui-acceptance--step "list selection and paging"
    (etaf-weread-gui-acceptance--keys "<down><down>" 0.2)
    (etaf-weread-gui-acceptance--check "<down> moves down"
                                       (= 2 (plist-get (etaf-weread-gui-acceptance--state) :selection)))
    (etaf-weread-gui-acceptance--keys "<up>" 0.2)
    (etaf-weread-gui-acceptance--check "<up> moves up"
                                       (= 1 (plist-get (etaf-weread-gui-acceptance--state) :selection)))
    (etaf-weread-gui-acceptance--keys "<end>" 0.2)
    (let ((state (etaf-weread-gui-acceptance--state)))
      (etaf-weread-gui-acceptance--check "End goes last"
                                         (= (1- (plist-get state :rows-total))
                                            (plist-get state :selection))))
    (etaf-weread-gui-acceptance--keys "<home>" 0.2)
    (etaf-weread-gui-acceptance--check "Home goes first"
                                       (= 0 (plist-get (etaf-weread-gui-acceptance--state) :selection)))
    (etaf-weread-gui-acceptance--keys "<next>" 0.2)
    (etaf-weread-gui-acceptance--check "<next> pages down"
                                       (> (plist-get (etaf-weread-gui-acceptance--state) :selection) 0))
    (etaf-weread-gui-acceptance--keys "<prior><home>" 0.2)
    (etaf-weread-gui-acceptance--check "<prior> pages back"
                                       (= 0 (plist-get (etaf-weread-gui-acceptance--state) :selection))))

  ;; Sections and filters (real reloads).
  (dolist (case '(("s" . :shelf) ("2" . :reading) ("3" . :finished)
                  ("4" . :notebook) ("6" . :stats) ("7" . :index)))
    (etaf-weread-gui-acceptance--step (format "section %s" (car case))
      (etaf-weread-gui-acceptance--keys (car case) 0.3)
      (etaf-weread-gui-acceptance--wait
       (lambda () (eq (cdr case) (plist-get (etaf-weread-gui-acceptance--state) :section))) 15)
      (etaf-weread-gui-acceptance--check (format "section %s" (car case))
                                         (eq (cdr case) (plist-get (etaf-weread-gui-acceptance--state) :section)))))
  ;; Store search through the real command with a stubbed prompt.
  (etaf-weread-gui-acceptance--step "store search"
    (cl-letf (((symbol-function 'read-string)
               (etaf-weread-gui-acceptance--prompt-stub "三体")))
      (etaf-weread-gui-acceptance--keys "5" 0.5))
    (etaf-weread-gui-acceptance--wait
     (lambda () (eq :search (plist-get (etaf-weread-gui-acceptance--state) :mode))) 25)
    (etaf-weread-gui-acceptance--wait
     (lambda () (> (or (plist-get (etaf-weread-gui-acceptance--state) :rows-total) 0) 0)) 25)
    (let ((state (etaf-weread-gui-acceptance--state)))
      (etaf-weread-gui-acceptance--check
       "store search shown"
       (or (eq :search (plist-get state :mode))
           (eq :search (plist-get state :section)))
       (format "mode=%s section=%s" (plist-get state :mode) (plist-get state :section)))
      (etaf-weread-gui-acceptance--check "store results" (> (plist-get state :rows-total) 0))
      (etaf-weread-gui-acceptance--check "store query kept" (equal "三体" (plist-get state :query)))))

  ;; Book detail, highlights, chapter scroll, browser and export.
  (etaf-weread-gui-acceptance--step "detail pane"
    (etaf-weread-gui-acceptance--keys "s" 0.3)
    (etaf-weread-gui-acceptance--wait
     (lambda () (> (or (plist-get (etaf-weread-gui-acceptance--state) :rows-total) 0) 0)) 20)
    (etaf-weread-gui-acceptance--keys "RET" 0.5)
    (etaf-weread-gui-acceptance--wait
     (lambda () (plist-get (plist-get (etaf-weread-gui-acceptance--state) :detail) :title)) 15)
    (etaf-weread-gui-acceptance--check "detail follows selection"
                                       (plist-get (plist-get (etaf-weread-gui-acceptance--state) :detail) :title))
    (etaf-weread-gui-acceptance--keys "v" 0.5)
    (etaf-weread-gui-acceptance--wait
     (lambda () (plist-get (etaf-weread-gui-acceptance--state) :notes)) 15)
    (etaf-weread-gui-acceptance--check "highlights pane loads"
                                       (let ((notes (plist-get (etaf-weread-gui-acceptance--state) :notes)))
                                         (and notes (> (or (plist-get notes :count) 0) 0))))
    (etaf-weread-gui-acceptance--keys "v" 0.3))

  (etaf-weread-gui-acceptance--step "chapter list scroll"
    (let* ((state (etaf-weread-gui-acceptance--state))
           (chapters (length (or (plist-get (plist-get state :detail) :chapters) nil)))
           (rows (or (plist-get state :pane-rows) 1)))
      (if (<= chapters rows)
          (etaf-weread-gui-acceptance--check "chapter list scroll" t "list fits, nothing to scroll")
        (etaf-weread-gui-acceptance--keys "C-v" 0.3)
        (etaf-weread-gui-acceptance--check "chapter list scroll"
                                           (> (plist-get (etaf-weread-gui-acceptance--state) :pane-scroll) 0))
        (etaf-weread-gui-acceptance--keys "M-v" 0.3))))

  (etaf-weread-gui-acceptance--step "open in browser"
    (let ((opened nil))
      (cl-letf (((symbol-function 'browse-url) (lambda (url &rest _) (setq opened url))))
        (etaf-weread-gui-acceptance--keys "o" 0.3))
      (etaf-weread-gui-acceptance--check "open in browser reports a URL"
                                         (and opened (string-match-p "weread.qq.com" opened))
                                         (format "%S" opened))))

  (etaf-weread-gui-acceptance--step "export notes"
    (let ((etaf-weread-export-directory (make-temp-file "weread-acceptance-export-" t)))
      (etaf-weread-gui-acceptance--keys "E" 0.5)
      (etaf-weread-gui-acceptance--wait
       (lambda ()
         (let ((message (plist-get (etaf-weread-gui-acceptance--state) :message)))
           (and message (string-match-p "导出" message))))
       30)
      (etaf-weread-gui-acceptance--check
       "E exports the notes"
       (string-match-p "导出"
                       (or (plist-get (etaf-weread-gui-acceptance--state) :message) ""))
       (format "%S" (plist-get (etaf-weread-gui-acceptance--state) :message)))))

  ;; Local highlight index: view and filter what is stored.
  (etaf-weread-gui-acceptance--step "local index"
    (etaf-weread-gui-acceptance--keys "i" 0.5)
    (etaf-weread-gui-acceptance--wait
     (lambda () (eq :index (plist-get (etaf-weread-gui-acceptance--state) :section))) 15)
    (etaf-weread-gui-acceptance--check "index section"
                                       (eq :index (plist-get (etaf-weread-gui-acceptance--state) :section)))
    (cl-letf (((symbol-function 'read-string)
               (etaf-weread-gui-acceptance--prompt-stub "组件")))
      (etaf-weread-gui-acceptance--keys "/" 0.5))
    (etaf-weread-gui-acceptance--check "index filter"
                                       (equal "组件"
                                              (plist-get (etaf-weread-gui-acceptance--state) :index-query))))

  ;; Statistics section.
  (etaf-weread-gui-acceptance--step "statistics"
    (etaf-weread-gui-acceptance--keys "6" 1)
    (etaf-weread-gui-acceptance--check "stats loaded"
                                       (plist-get (etaf-weread-gui-acceptance--state) :stats))))


(defun etaf-weread-gui-acceptance--press-cost (label key count)
  "Press KEY COUNT times and record each repaint's cost under LABEL.
The measurement is the real key through the command loop plus the renderer
flush it triggers, which is what a person waits for between two repaints."
  (let ((values nil))
    (dotimes (_ count)
      (let ((started (float-time)))
        (etaf-weread-gui-acceptance--keys key 0)
        (let ((elapsed (round (* 1000 (- (float-time) started)))))
          (push elapsed values)
          (push (cons label elapsed) etaf-weread-gui-acceptance--latencies))))
    (let* ((sorted (sort (copy-sequence values) #'<))
           (median (nth (/ (length sorted) 2) sorted))
           (maximum (car (last sorted))))
      (etaf-weread-gui-acceptance--log "press %s n=%s median=%sms max=%sms"
                                       label (length values) median maximum)
      (etaf-weread-gui-acceptance--check (format "%s press median" label)
                                         (< median 250)
                                         (format "median=%sms max=%sms" median maximum))
      (list :median median :max maximum))))

(defun etaf-weread-gui-acceptance--smoothness ()
  "Measure timer lateness while the reader repaints under real keys."
  (etaf-weread-gui-acceptance--step "smooth shelf selection"
    (etaf-weread-gui-acceptance--keys "v" 0.4)
    (etaf-weread-gui-acceptance--keys "s" 0.4)
    (etaf-weread-gui-acceptance--keys "<home>" 0.3)
    (etaf-weread-gui-acceptance--press-cost "shelf selection" "<down>" 8)
    (etaf-weread-gui-acceptance--stall "shelf selection" 1.6 "<down>"))
  (etaf-weread-gui-acceptance--step "smooth section switch"
    (etaf-weread-gui-acceptance--timed "section switch"
      (etaf-weread-gui-acceptance--keys "4" 0.5))
    (etaf-weread-gui-acceptance--check "section switch lands"
                                       (eq :notebook
                                           (plist-get (etaf-weread-gui-acceptance--state) :section)))))

(defun etaf-weread-gui-acceptance--close ()
  "Close the reader and check the buffer is gone."
  (etaf-weread-gui-acceptance--step "close"
    (etaf-weread-gui-acceptance--keys "q" 0.5)
    (etaf-weread-gui-acceptance--check "q closes the reader"
                                       (not (get-buffer etaf-weread-buffer-name)))))

(defun etaf-weread-gui-acceptance-run ()
  "Run the whole acceptance pass and return (PLIST :problems …).
The pass uses the real account and the real keymap; the session keeps its
preferences in a disposable file, so the user's settings are untouched."
  (setq etaf-weread-gui-acceptance--problems nil
        etaf-weread-gui-acceptance--latencies nil
        etaf-weread-gui-acceptance--steps 0)
  (etaf-weread-gui-acceptance--log "== acceptance start ==")
  (unwind-protect
      (progn
        (etaf-weread-gui-acceptance--browse)
        (etaf-weread-gui-acceptance--smoothness)
        (etaf-weread-gui-acceptance--layout-matrix)
        (etaf-weread-gui-acceptance--close))
    (when (and etaf-weread-gui-acceptance--settings
               (file-exists-p etaf-weread-gui-acceptance--settings))
      (ignore-errors (delete-file etaf-weread-gui-acceptance--settings))))
  (let ((report (list :steps etaf-weread-gui-acceptance--steps
                      :problems (nreverse etaf-weread-gui-acceptance--problems)
                      :latencies (nreverse etaf-weread-gui-acceptance--latencies))))
    (etaf-weread-gui-acceptance--log "== acceptance done: %S ==" report)
    report))

(provide 'weread-gui-acceptance)
;;; weread-gui-acceptance.el ends here
