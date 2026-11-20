;;; etaf-list-cache-tests.el --- Cached list revalidation behavior -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; The cache, the staleness rule, the candidate order and the timer are public
;; behavior: a session shows a list at once, compares it in the background and
;; refreshes the stalest list first.

;;; Code:
(require 'ert)
(require 'etaf)

(defun etaf-list-cache-test-wait (predicate)
  "Process timers until PREDICATE succeeds, with a bounded deadline."
  (let ((deadline (+ (float-time) 2)))
    (while (and (not (funcall predicate)) (< (float-time) deadline))
      (accept-process-output nil 0.005))
    (should (funcall predicate))))

(ert-deftest etaf-list-cache-stores-rows-total-and-time ()
  "Putting a list stores its rows, total and arrival time."
  (let ((cache (etaf-list-cache-create)))
    (should (null (etaf-list-cache-entry cache '(:shelf))))
    (etaf-list-cache-put cache '(:shelf) '(1 2 3) 7)
    (let ((entry (etaf-list-cache-entry cache '(:shelf))))
      (should (equal '(1 2 3) (plist-get entry :rows)))
      (should (equal 7 (plist-get entry :total)))
      (should (numberp (plist-get entry :at))))
    (should (equal '(1 2 3) (etaf-list-cache-rows cache '(:shelf))))
    (should (equal 7 (etaf-list-cache-total cache '(:shelf))))
    (should (equal 0 (etaf-list-cache-total cache '(:reading))))
    (etaf-list-cache-put cache :restored '(4) 1 :at 0)
    (should (= 0 (plist-get (etaf-list-cache-entry cache :restored) :at)))
    (should (etaf-list-cache-stale-p cache :restored))
    (should-error (etaf-list-cache-put cache :restored '(5) 1 :at -1)
                  :type 'wrong-type-argument)
    (should (equal '(4) (etaf-list-cache-rows cache :restored)))
    (etaf-list-cache-put cache :future nil 0 :at (+ (float-time) 1000))
    (should (<= (plist-get (etaf-list-cache-entry cache :future) :at) (float-time)))))

(ert-deftest etaf-list-cache-staleness-follows-the-interval ()
  "An entry is fresh inside the interval, stale beyond it, and missing is neither."
  (let* ((cache (etaf-list-cache-create :interval 100))
         (now (float-time)))
    ;; Missing is not stale: it is a prefetch candidate instead.
    (should-not (etaf-list-cache-stale-p cache '(:shelf) now))
    (etaf-list-cache-put cache '(:shelf) '(1) 1)
    (should-not (etaf-list-cache-stale-p cache '(:shelf) (+ now 99) 100))
    (should (etaf-list-cache-stale-p cache '(:shelf) (+ now 101) 100))
    ;; The caller may override the cache's own interval.
    (should (etaf-list-cache-stale-p cache '(:shelf) (+ now 1) 0))
    (should-not (etaf-list-cache-stale-p cache '(:shelf) now 0))))

(ert-deftest etaf-list-cache-detects-an-unchanged-reply ()
  "Equal rows and total count as unchanged; anything else does not."
  (let ((cache (etaf-list-cache-create)))
    (should-not (etaf-list-cache-unchanged-p cache '(:shelf) '(1) 1))
    (etaf-list-cache-put cache '(:shelf) '(1 2) 2)
    (should (etaf-list-cache-unchanged-p cache '(:shelf) '(1 2) 2))
    (should-not (etaf-list-cache-unchanged-p cache '(:shelf) '(1 3) 2))
    (should-not (etaf-list-cache-unchanged-p cache '(:shelf) '(1 2) 3))))

(ert-deftest etaf-list-cache-next-prefers-stale-then-missing ()
  "The stalest stale list wins; otherwise the first unloaded list is warmed."
  (let* ((cache (etaf-list-cache-create :interval 100 :grace 0))
         (keys '(:shelf :reading :finished)))
    ;; Nothing before the cache starts.
    (should-not (etaf-list-cache-next cache keys (float-time)))
    (etaf-list-cache-start cache)
    (let ((now (float-time)))
      ;; All keys are missing: warm them in order.
      (should (eq :shelf (etaf-list-cache-next cache keys now)))
      (etaf-list-cache-put cache :shelf '(1) 1)
      (should (eq :reading (etaf-list-cache-next cache keys now)))
      (etaf-list-cache-put cache :reading '(2) 1)
      (etaf-list-cache-put cache :finished '(3) 1)
      ;; Everything is fresh: no work.
      (should-not (etaf-list-cache-next cache keys now))
      ;; When every entry is stale the oldest one goes first, wherever it is
      ;; in KEYS.
      (should (eq :shelf (etaf-list-cache-next cache keys (+ now 400))))
      (etaf-list-cache-put cache :shelf '(1) 1)
      (should (eq :reading (etaf-list-cache-next cache keys (+ now 400))))
      ;; A busy cache never starts a second refresh.
      (etaf-list-cache-set-busy cache t)
      (should (etaf-list-cache-busy-p cache))
      (should-not (etaf-list-cache-next cache keys (+ now 800)))
      (etaf-list-cache-set-busy cache nil)
      (should (etaf-list-cache-next cache keys (+ now 800))))))

(ert-deftest etaf-list-cache-arm-runs-and-disarm-stops ()
  "Arming runs the function on the timer; disarming stops it for good."
  (let* ((cache (etaf-list-cache-create :interval 0.02 :grace 0))
         (calls 0)
         (function (lambda () (cl-incf calls))))
    (etaf-list-cache-start cache)
    (should-not (etaf-list-cache-armed-p cache))
    (etaf-list-cache-arm cache function :interval 0.02)
    (should (etaf-list-cache-armed-p cache))
    (etaf-list-cache-test-wait (lambda () (>= calls 2)))
    ;; Arming again replaces the previous timer instead of adding one: only the
    ;; new timer exists, so one disarm stops every tick.
    (etaf-list-cache-arm cache function :interval 0.02)
    (should (etaf-list-cache-armed-p cache))
    (let ((at-rearm calls))
      (etaf-list-cache-test-wait (lambda () (>= calls (+ at-rearm 2))))
      (etaf-list-cache-disarm cache)
      (should-not (etaf-list-cache-armed-p cache))
      (let ((at-disarm calls))
        (accept-process-output nil 0.15)
        (should (equal at-disarm calls)))))
  ;; A disarmed cache starts no background work either.
  (let* ((cache (etaf-list-cache-create :interval 100 :grace 0))
         (keys '(:shelf)))
    (etaf-list-cache-start cache)
    (etaf-list-cache-put cache :shelf '(1) 1)
    (etaf-list-cache-disarm cache)
    (should-not (etaf-list-cache-next cache keys (+ (float-time) 1000)))))

(ert-deftest etaf-list-cache-backs-off-after-a-failure ()
  "A failed refresh waits longer before the next attempt, and success clears it."
  (let* ((cache (etaf-list-cache-create :interval 10 :grace 0))
         (keys '(:shelf)))
    (etaf-list-cache-start cache)
    (etaf-list-cache-put cache :shelf '(1) 1)
    (etaf-list-cache-note-failure cache "external")
    (let ((first (etaf-list-cache-retry-at cache)))
      (should first)
      ;; Inside the backoff nothing is due, however stale the entry is.
      (should-not (etaf-list-cache-next cache keys (- first 1) 0))
      (should (eq :shelf (etaf-list-cache-next cache keys (+ first 1) 0)))
      (etaf-list-cache-note-failure cache "external")
      (let ((second (etaf-list-cache-retry-at cache)))
        ;; The second failure waits twice as long as the first.
        (should (> second first))
        (should (eq :shelf (etaf-list-cache-next cache keys (+ second 1) 0)))))
    (etaf-list-cache-note-success cache)
    (should-not (etaf-list-cache-retry-at cache))
    (should (eq :shelf (etaf-list-cache-next cache keys (+ (float-time) 500) 0)))))

(ert-deftest etaf-list-cache-pauses-on-a-stop-code ()
  "A failure that needs a human pauses refreshes until a load succeeds."
  (let* ((cache (etaf-list-cache-create :interval 10 :grace 0))
         (keys '(:shelf)))
    (etaf-list-cache-start cache)
    (etaf-list-cache-put cache :shelf '(1) 1)
    (etaf-list-cache-note-failure cache "external")
    (should-not (etaf-list-cache-blocked-p cache))
    (etaf-list-cache-note-failure cache "auth")
    (should (etaf-list-cache-blocked-p cache))
    ;; No background refresh starts again, however long the caller waits.
    (should-not (etaf-list-cache-next cache keys (+ (float-time) 100000) 0))
    (etaf-list-cache-note-success cache)
    (should-not (etaf-list-cache-blocked-p cache))
    (should (etaf-list-cache-next cache keys (+ (float-time) 100) 0))))

(ert-deftest etaf-list-cache-touch-marks-a-not-modified-reply ()
  "A version token is stored and a not-modified answer only refreshes the time."
  (let* ((cache (etaf-list-cache-create :interval 100 :grace 0))
         (now (float-time)))
    (etaf-list-cache-put cache :shelf '(1 2) 2 :version "v1")
    (should (equal "v1" (etaf-list-cache-version cache :shelf)))
    (should (etaf-list-cache-stale-p cache :shelf (+ now 200) 100))
    (etaf-list-cache-touch cache :shelf "v2")
    (should (equal "v2" (etaf-list-cache-version cache :shelf)))
    (should (equal '(1 2) (etaf-list-cache-rows cache :shelf)))
    (should-not (etaf-list-cache-stale-p cache :shelf (+ (float-time) 10) 100))
    ;; Touching a key that was never loaded does nothing.
    (should-not (etaf-list-cache-touch cache :reading "v9"))))

(provide 'etaf-list-cache-tests)
;;; etaf-list-cache-tests.el ends here
