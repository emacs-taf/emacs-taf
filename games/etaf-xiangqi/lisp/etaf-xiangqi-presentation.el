;;; -*- lexical-binding: t; -*-
;;; etaf-xiangqi-presentation.el --- Paced, scope-owned computer move presentation
;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Code:
(require 'etaf)
(require 'etaf-gamekit)
(require 'etaf-xiangqi-model)

(cl-defstruct (etaf-xiangqi--presentation (:constructor etaf-xiangqi--make-presentation))
  session graphic (alive t) before started pending timer scope
  (view (etaf-ref nil :test #'equal)) (phase (etaf-ref nil))
  (last (etaf-ref nil :test #'equal)) (motion (etaf-ref nil)))

(defun etaf-xiangqi--same-position-p (left right)
  "Compare detached LEFT and RIGHT positions, ignoring observer metadata."
  (and (equal (plist-get left :observation) (plist-get right :observation))
       (equal (plist-get left :action_count) (plist-get right :action_count))
       (eq (plist-get left :terminal) (plist-get right :terminal))))

(defun etaf-xiangqi--presentation-cancel (presentation)
  "Discard pending presentation work without changing the native match."
  (setf (etaf-xiangqi--presentation-pending presentation) nil
        (etaf-xiangqi--presentation-before presentation) nil
        (etaf-xiangqi--presentation-started presentation) nil)
  (when-let* ((timer (etaf-xiangqi--presentation-timer presentation)))
    (cancel-timer timer)
    (setf (etaf-xiangqi--presentation-timer presentation) nil))
  (when-let* ((scope (etaf-xiangqi--presentation-scope presentation)))
    (etaf-scope-stop scope)
    (setf (etaf-xiangqi--presentation-scope presentation) nil))
  (etaf-batch
    (setf (etaf-value (etaf-xiangqi--presentation-motion presentation)) nil
          (etaf-value (etaf-xiangqi--presentation-phase presentation)) nil)))

(defun etaf-xiangqi--presentation-land (presentation move)
  "Land MOVE only if it is still the pending move in PRESENTATION."
  (when (and (etaf-xiangqi--presentation-alive presentation)
             (eq move (etaf-xiangqi--presentation-pending presentation)))
    (let* ((session (etaf-xiangqi--presentation-session presentation))
           (native (etaf-gamekit-observation session))
           (current (and (not (memq (etaf-gamekit-status session) '(closed failed)))
                         (etaf-xiangqi--same-position-p native (plist-get move :after)))))
      (etaf-batch
        (etaf-xiangqi--presentation-cancel presentation)
        (setf (etaf-value (etaf-xiangqi--presentation-view presentation)) native
              (etaf-value (etaf-xiangqi--presentation-last presentation)) (and current move))))))

(defun etaf-xiangqi--presentation-start-motion (presentation move)
  "Start MOVE's shared-clock transition after the minimum response interval."
  (when (and (etaf-xiangqi--presentation-alive presentation)
             (eq move (etaf-xiangqi--presentation-pending presentation)))
    (setf (etaf-xiangqi--presentation-timer presentation) nil)
    (if (or (not (etaf-xiangqi--presentation-graphic presentation))
            (not etaf-animation-enabled) etaf-animation-paused
            (memq (etaf-gamekit-status (etaf-xiangqi--presentation-session presentation)) '(closed failed))
            (not (etaf-xiangqi--same-position-p
                  (etaf-gamekit-observation (etaf-xiangqi--presentation-session presentation))
                  (plist-get move :after))))
        (etaf-xiangqi--presentation-land presentation move)
      (let* ((from (plist-get move :from)) (to (plist-get move :to))
             (distance (sqrt (+ (expt (- (car to) (car from)) 2)
                                (expt (- (cdr to) (cdr from)) 2))))
             (scope (etaf-effect-scope :detached t :name 'xiangqi-move)))
        (setf (etaf-xiangqi--presentation-scope presentation) scope)
        (etaf-scope-run scope
          (lambda ()
            (let* ((target (etaf-ref 0.0))
                   (progress (etaf-transition
                              target :duration (min 0.45 (max 0.25 (* 0.06 distance)))
                              :easing 'ease-in-out :name 'xiangqi-move
                              :on-complete (lambda () (etaf-xiangqi--presentation-land presentation move)))))
              (etaf-batch
                (setf (etaf-value (etaf-xiangqi--presentation-motion presentation))
                      (list :move move :progress progress)
                      (etaf-value (etaf-xiangqi--presentation-phase presentation)) 'moving
                      (etaf-value target) 1.0)))))))))

(defun etaf-xiangqi--presentation-reply (presentation view)
  "Prepare the computer's accepted VIEW for paced presentation."
  (let* ((before (etaf-xiangqi--presentation-before presentation))
         (table (etaf-xiangqi--table before))
         (move (etaf-xiangqi--parse-move (plist-get (plist-get view :bot) :label)))
         (from (plist-get move :from)) (to (plist-get move :to)))
    (unless (and move (= (plist-get view :action_count) (1+ (plist-get before :action_count))))
      (error "Computer response has no matching move"))
    (setq move (append move
                       (list :piece (etaf-xiangqi--cell table (car from) (cdr from))
                             :captured (etaf-xiangqi--cell table (car to) (cdr to))
                             :after view)))
    (setf (etaf-xiangqi--presentation-pending presentation) move)
    (let ((delay (min 0.6 (max 0 (- 0.6 (- (float-time) (etaf-xiangqi--presentation-started presentation)))))))
      (if (> delay 0)
          (setf (etaf-xiangqi--presentation-timer presentation)
                (run-at-time delay nil #'etaf-xiangqi--presentation-start-motion presentation move))
        (etaf-xiangqi--presentation-start-motion presentation move)))))

(defun etaf-xiangqi--presentation-update (presentation _data)
  "Refresh from the latest backend state without publishing a reply prematurely."
  (let* ((session (etaf-xiangqi--presentation-session presentation))
         (view (etaf-gamekit-observation session))
         (status (etaf-gamekit-status session)) (failure (etaf-gamekit-last-error session))
         (before (etaf-xiangqi--presentation-before presentation))
         (pending (etaf-xiangqi--presentation-pending presentation)))
    (when (and view (etaf-xiangqi--presentation-alive presentation))
      (cond
       ((or failure (memq status '(closed failed)))
        (etaf-xiangqi--presentation-cancel presentation)
        (setf (etaf-value (etaf-xiangqi--presentation-view presentation)) view))
       ((and pending (etaf-xiangqi--same-position-p view (plist-get pending :after))) nil)
       ((and before (not pending) (plist-get view :bot)
             (= (plist-get view :action_count) (1+ (plist-get before :action_count))))
        (etaf-xiangqi--presentation-reply presentation view))
       ((and before (not pending) (eq status 'busy)
             (etaf-xiangqi--same-position-p view before)) nil)
       (t
        ;; Reset/load/history or a new human move supersedes any delayed reply.
        (let* ((shown (etaf-value (etaf-xiangqi--presentation-view presentation)))
               (changed (or (not (etaf-xiangqi--same-position-p view shown))
                            (and (plist-get shown :bot) (not (plist-get view :bot))))))
          (etaf-batch
            (etaf-xiangqi--presentation-cancel presentation)
            (when changed (setf (etaf-value (etaf-xiangqi--presentation-last presentation)) nil))
            (setf (etaf-value (etaf-xiangqi--presentation-view presentation)) view))))))))

(defun etaf-xiangqi--presentation-create (session graphic)
  "Create a scope-owned presentation of SESSION, animating only with GRAPHIC."
  (let ((presentation (etaf-xiangqi--make-presentation :session session :graphic graphic)))
    (etaf-watch (lambda () (list (etaf-gamekit-view session)
                                 (etaf-gamekit-status session)
                                 (etaf-gamekit-last-error session)))
      (lambda (data _old) (etaf-xiangqi--presentation-update presentation data))
      :immediate t :test #'equal :name 'xiangqi-presentation)
    (etaf-on-scope-dispose
     (lambda ()
       (setf (etaf-xiangqi--presentation-alive presentation) nil)
       (etaf-xiangqi--presentation-cancel presentation)))
    presentation))

(defun etaf-xiangqi--presentation-begin (presentation view arguments)
  "Start a computer request from VIEW with ARGUMENTS, retaining its visible board."
  (etaf-xiangqi--presentation-cancel presentation)
  (setf (etaf-xiangqi--presentation-before presentation) view
        (etaf-xiangqi--presentation-started presentation) (float-time))
  (etaf-batch
    (setf (etaf-value (etaf-xiangqi--presentation-view presentation)) view
          (etaf-value (etaf-xiangqi--presentation-last presentation)) nil
          (etaf-value (etaf-xiangqi--presentation-phase presentation)) 'thinking)
    (etaf-gamekit-action (etaf-xiangqi--presentation-session presentation) "bot" arguments)))

(defun etaf-xiangqi--move-description (move)
  "Describe a landed computer MOVE, including a captured piece when present."
  (let ((from (plist-get move :from)) (to (plist-get move :to))
        (captured (plist-get move :captured)))
    (format "电脑：%s %c%d → %c%d%s"
            (etaf-xiangqi--name (plist-get move :piece))
            (+ ?a (cdr from)) (- 9 (car from)) (+ ?a (cdr to)) (- 9 (car to))
            (if captured (concat "，吃" (etaf-xiangqi--name captured)) ""))))

(provide 'etaf-xiangqi-presentation)
;;; etaf-xiangqi-presentation.el ends here
