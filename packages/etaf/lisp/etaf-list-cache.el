;;; etaf-list-cache.el --- Cached lists with background revalidation -*- lexical-binding: t; -*-

;; Copyright (C) 2026 ETAF contributors
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; A reader's sidebar lists change slowly and are requested often.  This module
;; keeps one cache per session in the stale-while-revalidate style: every list
;; is stored under a key together with the time it arrived, so a caller can
;; show it at once and compare it with a fresh reply in the background.  A
;; reply that equals the cached rows needs no repaint at all, which is what
;; keeps a section switch instant and free of flicker.
;;
;; The policy lives here, so every application refreshes the same way:
;;
;;   * `etaf-list-cache-stale-p' decides when an entry is old enough;
;;   * `etaf-list-cache-next' picks the next background refresh — the stalest
;;     list first, then a list that was never loaded, one at a time;
;;   * `etaf-list-cache-arm' runs a caller-supplied function on a slow timer,
;;     and `etaf-list-cache-disarm' stops it when the session goes away.
;;
;; The cache is a display shortcut, never the source of truth: applications
;; keep their own rows, requests and repainting, and the backend reply still
;; replaces the entry on every load.

;;; Code:

(require 'cl-lib)

(cl-defstruct (etaf-list-cache
                (:conc-name etaf-list-cache--)
                (:constructor etaf-list-cache--create
                              (&key entries interval grace started-at timer busy
                                    failures retry-at blocked max-backoff stop-codes)))
  "Per-session list cache and background refresh policy.
ENTRIES maps a key to its (:rows :total :at) entry.  INTERVAL is the
freshness of an entry in seconds, GRACE the quiet period after starting
before a background refresh may begin, STARTED-AT when the cache was started,
TIMER the armed repeating timer and BUSY whether a background refresh is in
flight."
  (entries (make-hash-table :test #'equal))
  (interval 120)
  (grace 3)
  started-at
  timer
  busy
  (failures 0)
  retry-at
  blocked
  (max-backoff 1800)
  (stop-codes '("auth" "blocked")))

(cl-defun etaf-list-cache-create
    (&key interval grace max-backoff stop-codes)
  "Return a list cache with INTERVAL seconds of freshness and GRACE seconds.
INTERVAL defaults to 120 and GRACE to 3.  A background refresh never starts in
the GRACE seconds after `etaf-list-cache-arm' or `etaf-list-cache-start', so a
newly opened reader is not competing with a prefetch.

A failed background load is retried with exponential backoff (INTERVAL, then
double, capped at MAX-BACKOFF seconds) until a load succeeds; a load that fails
with one of STOP-CODES (auth and blocked by default, which mean a human
must act) pauses background refreshes until a load succeeds again."
  (etaf-list-cache--create :interval (or interval 120)
                           :grace (or grace 3)
                           :max-backoff (or max-backoff 1800)
                           :stop-codes (or stop-codes '("auth" "blocked"))))

(cl-defun etaf-list-cache-put (cache key rows total &key version at)
  "Cache ROWS and TOTAL under KEY in CACHE and return the stored entry.
The entry records the time it arrived, which is what the staleness rule and
the background refresh order read.  VERSION, when the backend offers a version
token, is stored for `etaf-list-cache-version' so a caller can send it with the
next request and answer a not-modified reply with `etaf-list-cache-touch'.
AT optionally preserves a snapshot's observation time (seconds since epoch).
It must be a nonnegative number; a future time is clamped to now."
  (when (and at (not (and (numberp at) (>= at 0))))
    (signal 'wrong-type-argument (list 'nonnegative-number-p at)))
  (puthash key (list :rows rows :total total
                     :at (if at (min at (float-time)) (float-time)) :version version)
           (etaf-list-cache--entries cache)))

(defun etaf-list-cache-version (cache key)
  "Return KEY's stored version token, or nil.
The token is whatever the caller passed to `etaf-list-cache-put'; the cache
never interprets it."
  (plist-get (etaf-list-cache-entry cache key) :version))

(defun etaf-list-cache-touch (cache key &optional version)
  "Mark KEY's entry as just checked, without replacing its rows.
A backend that answers that nothing changed for a conditional request reports
it through this function, so the entry becomes fresh again and no repaint is
needed.  VERSION replaces the stored token when the reply carries a new one."

  (when-let* ((entry (etaf-list-cache-entry cache key)))
    (plist-put entry :at (float-time))
    (when version (plist-put entry :version version))
    (gethash key (etaf-list-cache--entries cache))))

(defun etaf-list-cache-note-success (cache)
  "Record that a load succeeded: clear the failure backoff and any pause.
Call it from every load path, foreground or background."
  (setf (etaf-list-cache--failures cache) 0
        (etaf-list-cache--retry-at cache) nil
        (etaf-list-cache--blocked cache) nil)
  cache)

(defun etaf-list-cache-note-failure (cache &optional code)
  "Record that a load failed with error CODE and throttle the retries.
CODE nil or anything unknown backs the next attempt off (the interval, then
double, capped at the cache's max backoff).  A CODE listed in the cache's
stop codes means a human must act (a login expired, a flow is blocked): the
cache then pauses background refreshes until some load succeeds again."
  (cl-incf (etaf-list-cache--failures cache))
  (if (and code (member code (etaf-list-cache--stop-codes cache)))
      (progn
        (setf (etaf-list-cache--blocked cache) t)
        (setf (etaf-list-cache--retry-at cache) nil))
    (let* ((failures (etaf-list-cache--failures cache))
           (delay (min (etaf-list-cache--max-backoff cache)
                       (* (etaf-list-cache--interval cache)
                          (expt 2 (1- failures))))))
      (setf (etaf-list-cache--retry-at cache) (+ (float-time) delay))))
  cache)

(defun etaf-list-cache-blocked-p (cache)
  "Return non-nil when CACHE paused background refreshes until a load succeeds."
  (and (etaf-list-cache--blocked cache) t))

(defun etaf-list-cache-retry-at (cache)
  "Return the time before which CACHE starts no background refresh, or nil."
  (etaf-list-cache--retry-at cache))

(defun etaf-list-cache-entry (cache key)
  "Return KEY's cached entry (:rows :total :at), or nil."
  (gethash key (etaf-list-cache--entries cache)))

(defun etaf-list-cache-rows (cache key)
  "Return KEY's cached rows, or nil."
  (plist-get (etaf-list-cache-entry cache key) :rows))

(defun etaf-list-cache-total (cache key)
  "Return KEY's cached total, or 0."
  (or (plist-get (etaf-list-cache-entry cache key) :total) 0))

(defun etaf-list-cache-stale-p (cache key &optional now interval)
  "Return non-nil when KEY's entry is older than INTERVAL seconds.
NOW defaults to the current time and INTERVAL to the cache's own interval.  An
entry that does not exist yet is not stale, only missing."
  (let ((entry (etaf-list-cache-entry cache key)))
    (and entry
         (> (- (or now (float-time)) (or (plist-get entry :at) 0))
            (or interval (etaf-list-cache--interval cache))))))

(defun etaf-list-cache-unchanged-p (cache key rows total)
  "Return non-nil when ROWS and TOTAL equal what KEY already holds.
A caller uses this to keep the page untouched when a background reply did not
change anything."
  (let ((entry (etaf-list-cache-entry cache key)))
    (and entry
         (equal (plist-get entry :rows) rows)
         (equal (plist-get entry :total) total))))

(defun etaf-list-cache-next (cache keys &optional now interval)
  "Return the KEY that a background refresh should load next, or nil.
KEYS is the caller's ordered list of candidates.  The stalest stale entry
comes first; when every entry is still fresh, the first KEY without an entry
is warmed so its section can paint from the cache later.  Nil while the cache
is busy, inside its grace period, or when every KEY is fresh and cached."
  (when-let* ((started (etaf-list-cache--started-at cache))
              ((not (etaf-list-cache--busy cache)))
              ((not (etaf-list-cache--blocked cache)))
              ((or (null (etaf-list-cache--retry-at cache))
                   (>= (or now (float-time)) (etaf-list-cache--retry-at cache))))
              ((>= (- (or now (float-time)) started)
                   (etaf-list-cache--grace cache))))
    (let (stale missing)
      (dolist (key keys)
        (let ((entry (etaf-list-cache-entry cache key)))
          (cond
           ((and entry (etaf-list-cache-stale-p cache key now interval)
                 (or (null stale)
                     (< (plist-get entry :at)
                        (plist-get (etaf-list-cache-entry cache stale) :at))))
            (setq stale key))
           ((and (null entry) (null missing))
            (setq missing key)))))
      (or stale missing))))

(defun etaf-list-cache-start (cache)
  "Start CACHE: begin its grace period and allow background refreshes.
A caller that already runs its own timer calls this once when its session
starts and then asks `etaf-list-cache-next' what to load."
  (setf (etaf-list-cache--started-at cache) (float-time))
  cache)

(cl-defun etaf-list-cache-arm (cache function &key interval)
  "Arm CACHE to call FUNCTION every INTERVAL seconds until disarmed.
Uses INTERVAL, or the cache's own interval.  Arming again replaces the
previous timer and restarts the grace period.  FUNCTION runs with no
arguments; the caller stops the cycle with `etaf-list-cache-disarm'."
  (etaf-list-cache-disarm cache)
  (etaf-list-cache-start cache)
  (let ((period (or interval (etaf-list-cache--interval cache))))
    (setf (etaf-list-cache--timer cache)
          (run-at-time period period function)))
  cache)

(defun etaf-list-cache-armed-p (cache)
  "Return non-nil when CACHE has a background refresh timer armed."
  (and (etaf-list-cache--timer cache) t))

(defun etaf-list-cache-busy-p (cache)
  "Return non-nil when CACHE has a background refresh in flight."
  (etaf-list-cache--busy cache))

(defun etaf-list-cache-set-busy (cache busy)
  "Record that CACHE has, or has not, a background refresh in flight.
A caller marks the cache BUSY before starting a background load and clears it
when the reply arrives, which is what keeps one refresh at a time."
  (setf (etaf-list-cache--busy cache) busy)
  cache)

(defun etaf-list-cache-disarm (cache)
  "Stop CACHE's background refresh and clear its busy marker."
  (when-let* ((timer (etaf-list-cache--timer cache)))
    (cancel-timer timer)
    (setf (etaf-list-cache--timer cache) nil))
  (setf (etaf-list-cache--busy cache) nil)
  (setf (etaf-list-cache--started-at cache) nil)
  cache)

(provide 'etaf-list-cache)
;;; etaf-list-cache.el ends here
