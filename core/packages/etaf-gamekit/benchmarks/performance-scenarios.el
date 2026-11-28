;;; -*- lexical-binding: t; -*-
;;; performance-scenarios.el --- External engine and character surface workloads

;; SPDX-License-Identifier: GPL-3.0-or-later
;; Workload adapters for the workspace performance driver. All session and
;; rendering access goes through supported package interfaces.

;;; Code:
(require 'etaf-gamekit)
(require 'etaf-ui)
(declare-function taf-benchmark-register "performance-driver" (id &rest properties))
(defconst etaf-gamekit-benchmark--directory
  (file-name-directory (or load-file-name buffer-file-name)))

(etaf-gamekit-register-backend 'gamekit-grid-benchmark
  :title "Character transport workload" :features '(benchmark)
  :launch (lambda (options)
            (list "python3" (expand-file-name "grid-source.py" etaf-gamekit-benchmark--directory)
                  "--density" (number-to-string (plist-get options :density)))) :replace t)

(defun etaf-gamekit-benchmark--text (session)
  "Read SESSION's visible plain text."
  (with-current-buffer (etaf-gamekit-buffer session)
    (buffer-substring-no-properties (point-min) (point-max))))

(etaf-define-component etaf-gamekit-benchmark--grid-view (&key session)
  :bindings ((rows (etaf-computed (lambda () (etaf-gamekit-view session :rows)) :test #'equal))
             (status (etaf-computed (lambda () (etaf-gamekit-view session :status)) :test #'equal)))
  :view
  (column
    (etaf-label :text (or (etaf-value status) "Starting"))
    (etaf-text-grid :columns 80 :rows 24
      :row-text (lambda (row) (or (nth row (etaf-value rows)) "")))))

(etaf-gamekit-define-game etaf-gamekit-benchmark--grid-game
  :title "Character transport workload" :backend 'gamekit-grid-benchmark
  :view (lambda (session) (etaf-view (etaf-gamekit-benchmark--grid-view :session session))))

(defun etaf-gamekit-benchmark--grid (mode density &optional fps)
  "Create a DENSITY character fixture for MODE, optionally streaming at FPS."
  (let* ((session (etaf-gamekit-start etaf-gamekit-benchmark--grid-game :options (list :density density)))
         (runtime (etaf-runtime-for-buffer (etaf-gamekit-buffer session)))
         (expected 0) (seen nil) (accepted nil) (started nil) (before 0) snapshot)
    (cl-labels
        ((inspect ()
           (let ((text (etaf-gamekit-benchmark--text session))
                 (frame (plist-get (etaf-gamekit-observation session) :frame)))
             (when frame (cl-pushnew frame accepted))
             (when (string-match "Frame \\([0-9]+\\)" text)
               (cl-pushnew (string-to-number (match-string 1 text)) seen))
             (when (and (eq (etaf-gamekit-status session) 'ready)
                        (>= (or frame -1) expected)
                        (string-match-p (format "Frame %08d" frame) text))
               (setq snapshot (etaf-gamekit-observation session))
               t))))
      (list
       :buffer (etaf-gamekit-buffer session)
       :ready (lambda ()
                (if (eq mode 'batch) (etaf-runtime-refit runtime 1200 45)
                  (etaf-refit runtime (selected-window)))
                (when (inspect)
                  (if (and fps (not started))
                      (progn (setq started t) (etaf-gamekit-action session "play" (list :fps fps)) nil)
                    t)))
       :invoke (lambda (_index)
                 (setq seen nil accepted nil
                       before (plist-get (etaf-gamekit-observation session) :frame)
                       expected (1+ before))
                 (unless fps (etaf-gamekit-action session "step")))
       :settled #'inspect
       :outcome (lambda () (list :produced (- (plist-get snapshot :frame) before)
                                 :accepted_observed (length accepted)
                                 :displayed_observed (length (cl-remove-if
                                                             (lambda (n) (<= n before)) seen))
                                 :final_frame (plist-get snapshot :frame) :density_percent density))
       :verify (lambda ()
                 (let ((text (etaf-gamekit-benchmark--text session))
                       (rows (plist-get snapshot :rows)))
                   (cond ((etaf-gamekit-last-error session) (etaf-gamekit-last-error session))
                         ((not (cl-every (lambda (row) (string-match-p (regexp-quote row) text)) rows))
                          "Displayed grid differs from the backend's latest rows")
                         (t t))))
       :cleanup (lambda () (etaf-gamekit-close session)
                  (when (buffer-live-p (etaf-gamekit-buffer session))
                    (kill-buffer (etaf-gamekit-buffer session))))))))

(dolist (density '(1 20 100))
  (let ((amount density))
    (taf-benchmark-register
     (format "etaf-gamekit.grid.step.%d" amount)
     :version 1 :modes '(batch gui) :isolation 'series :impact 'subtree :budget-ms (/ 1000.0 30)
     :description (format "External 80x24 frame changing %d%% of cells" amount)
     :setup (lambda (mode) (etaf-gamekit-benchmark--grid mode amount)))
    (dolist (rate '(10 20 30))
      (let ((fps rate))
        (taf-benchmark-register
         (format "etaf-gamekit.grid.stream.%d.%d" amount fps)
         :version 1 :modes '(batch gui) :isolation 'series :impact 'subtree
         :budget-ms (+ (/ 1000.0 fps) 33.333)
         :description (format "Next displayed frame at %d Hz; 80x24; %d%% cells change" fps amount)
         :setup (lambda (mode) (etaf-gamekit-benchmark--grid mode amount fps)))))))

(etaf-define-component etaf-gamekit-benchmark--kernel-view (&key session kind)
  :view
  (text (expr
         (pcase kind
           ('tabletop (format "Pool %s" (plist-get (plist-get (etaf-gamekit-view session :state) :G) :pool)))
           ('simultaneous (if (eq t (etaf-gamekit-view session :terminal)) "Terminal" "Playing"))))))

(etaf-gamekit-define-game etaf-gamekit-benchmark--tabletop
  :title "Native turn transition" :backend 'boardgame-io
  :options (list :game (expand-file-name "../tests/fixtures/tabletop.cjs" etaf-gamekit-benchmark--directory)
                 :player "0" :seed "benchmark")
  :view (lambda (session)
          (etaf-view (etaf-gamekit-benchmark--kernel-view :session session :kind 'tabletop))))

(etaf-gamekit-define-game etaf-gamekit-benchmark--simultaneous
  :title "Native joint transition" :backend 'openspiel
  :options '(:game "matrix_rps" :player 0 :seed 42)
  :view (lambda (session)
          (etaf-view (etaf-gamekit-benchmark--kernel-view :session session :kind 'simultaneous))))

(defun etaf-gamekit-benchmark--kernel (mode kind)
  "Measure native KIND actions through a game instance and its view in MODE."
  (let* ((session (etaf-gamekit-start (if (eq kind 'tabletop)
                                       etaf-gamekit-benchmark--tabletop
                                     etaf-gamekit-benchmark--simultaneous)))
         (runtime (etaf-runtime-for-buffer (etaf-gamekit-buffer session))) expected)
    (list
     :buffer (etaf-gamekit-buffer session)
     :ready (lambda ()
              (if (eq mode 'batch) (etaf-runtime-refit runtime 1200 45)
                (etaf-refit runtime (selected-window)))
              (eq (etaf-gamekit-status session) 'ready))
     :invoke
     (lambda (index)
       (let ((advance (cl-evenp index)))
         (pcase kind
           ('tabletop
            (setq expected (if advance "Pool 11" "Pool 12"))
            (etaf-gamekit-action session (if advance "move" "undo")
                                (when advance '(:name "claim" :args [1]))))
           ('simultaneous
            (setq expected (if advance "Terminal" "Playing"))
            (etaf-gamekit-action session (if advance "joint-action" "reset")
                                (when advance '(:actions [0 1])))))))
     :settled (lambda () (and (eq (etaf-gamekit-status session) 'ready)
                              (string-match-p expected (etaf-gamekit-benchmark--text session))))
     :verify (lambda () (or (etaf-gamekit-last-error session) t))
     :outcome (lambda () (list :backend (symbol-name (plist-get (etaf-gamekit-game-info session) :backend))
                               :display expected))
     :cleanup (lambda () (etaf-gamekit-close session) (kill-buffer (etaf-gamekit-buffer session))))))

(dolist (kind '(tabletop simultaneous))
  (let ((operation kind))
    (taf-benchmark-register
     (format "etaf-gamekit.kernel.%s" operation)
     :version 1 :modes '(batch gui) :isolation 'series :impact 'subtree :budget-ms 16.67
     :description "Native kernel action through a game instance to its painted observation"
     :setup (lambda (mode) (etaf-gamekit-benchmark--kernel mode operation)))))

(provide 'etaf-gamekit-performance-scenarios)
;;; performance-scenarios.el ends here
