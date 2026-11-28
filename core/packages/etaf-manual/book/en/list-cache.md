# List Cache

A list cache is a display shortcut for slow-changing lists that are requested often. It stores each list under a key together with the time it arrived, so a session can paint a section at once and compare it with a fresh reply in the background — stale-while-revalidate. The cache keeps only the policy that every application would otherwise repeat: when an entry is old enough, which list to refresh next, how failures back off, and when a failure needs a human. It is never the source of truth; the backend reply replaces the entry on every load, and the application keeps its own rows, requests and repainting. This chapter defines the cache, the entry operations, the freshness rules, the refresh chooser, the timer and the failure policy. [Data Controllers](data-controllers.md) supplies the pages a cache mirrors; [Asynchronous Model](async.md) defines the adapter a background load may return.

## The cache model

<!-- index: list cache; entry; interval; grace; backoff; stop codes; stale-while-revalidate -->

A cache maps a key to an entry of `:rows`, `:total`, `:at` and an optional `:version`, where `:at` is the time the list arrived or was last checked. Four policy values come from `etaf-list-cache-create`: the freshness interval, the quiet grace period after starting or arming, the maximum backoff, and the stop codes that mean a human must act. A cache is expected to live for one session; it starts no work by itself, and it holds at most one background refresh at a time through its busy marker. Consumers keep their own data; the cache only remembers what the last reply looked like and when.

## Creating a cache

<!-- index: etaf-list-cache-create; freshness interval; grace period; max backoff -->

#### Function: etaf-list-cache-create (&key interval grace max-backoff stop-codes)

Return a list cache with INTERVAL seconds of freshness and GRACE seconds.

**Arguments.** INTERVAL is the freshness of an entry in seconds; it defaults to 120. GRACE is the quiet period after starting or arming during which no background refresh begins; it defaults to 3. MAX-BACKOFF caps the retry delay in seconds and defaults to 1800. STOP-CODES is the list of failure codes after which background refreshes pause until a load succeeds; it defaults to `("auth" "blocked")`.

**Semantics.** The returned cache owns only policy and stored entries. A background refresh never starts inside the grace period, so a newly opened section does not compete with a prefetch. Failed refreshes back off by doubling from INTERVAL up to MAX-BACKOFF, and a stop code pauses them entirely until `etaf-list-cache-note-success` records a load that worked.

**Returns.** The new cache.

**Errors.** None.

**See also.** `etaf-list-cache-start`, `etaf-list-cache-arm`, `etaf-list-cache-note-failure`.

## Storing and reading entries

<!-- index: etaf-list-cache-put; version token; arrival time; touch -->

#### Function: etaf-list-cache-put (cache key rows total &key version at)

Cache ROWS and TOTAL under KEY and return the stored entry.

**Arguments.** CACHE is a list cache; KEY identifies the list. ROWS and TOTAL are the accepted reply. VERSION is an optional opaque backend version token. AT is an optional nonnegative observation time in seconds since the epoch, for restoring a persisted snapshot; omitting it records the current time.

**Semantics.** The entry replaces any previous entry for KEY and records the time it arrived, which is what the staleness rule and the background refresh order read. A future AT is clamped to the current time, and an invalid AT leaves the cache unchanged. The cache never interprets the version token; it only keeps it so a caller can send it with the next conditional request and answer a not-modified reply with `etaf-list-cache-touch`.

**Returns.** The stored entry plist.

**Errors.** `error→ wrong-type-argument` when AT is present and not a nonnegative number; the cache is unchanged.

**Example.** `(etaf-list-cache-put cache '(:shelf) '(1 2) 2 :version "v1")` stores rows, total and the token and returns the entry.

**See also.** `etaf-list-cache-entry`, `etaf-list-cache-touch`.

#### Function: etaf-list-cache-version (cache key)

Return KEY's stored version token, or nil.

**Arguments.** CACHE is a list cache; KEY identifies the list.

**Semantics.** The token is whatever the caller passed to `etaf-list-cache-put` or `etaf-list-cache-touch`; the cache never interprets it. A key without an entry has no token.

**Returns.** The stored token, or nil.

**Errors.** None.

#### Function: etaf-list-cache-touch (cache key &optional version)

Mark KEY's entry as just checked without replacing its rows.

**Arguments.** CACHE is a list cache; KEY identifies the list. VERSION, when non-nil, replaces the stored token.

**Semantics.** A backend that answers that nothing changed for a conditional request reports it here: the entry's arrival time becomes the current time, so it is fresh again and no repaint is needed, while its rows and total stay as they were. Touching a key that has no entry does nothing and returns nil.

**Returns.** The touched entry, or nil when KEY has no entry.

**Errors.** None.

**See also.** `etaf-list-cache-put`, `etaf-list-cache-unchanged-p`.

#### Function: etaf-list-cache-entry (cache key)

Return KEY's cached entry (:rows :total :at), or nil.

**Arguments.** CACHE is a list cache; KEY identifies the list.

**Returns.** The entry plist, or nil when KEY was never stored.

**Errors.** None.

#### Function: etaf-list-cache-rows (cache key)

Return KEY's cached rows, or nil.

**Arguments.** CACHE is a list cache; KEY identifies the list.

**Returns.** The stored rows, or nil when KEY was never stored.

**Errors.** None.

#### Function: etaf-list-cache-total (cache key)

Return KEY's cached total, or 0.

**Arguments.** CACHE is a list cache; KEY identifies the list.

**Returns.** The stored total, or 0 when KEY was never stored.

**Errors.** None.

## Freshness and unchanged replies

<!-- index: stale-p; unchanged-p; missing versus stale -->

#### Function: etaf-list-cache-stale-p (cache key &optional now interval)

Return non-nil when KEY's entry is older than INTERVAL seconds.

**Arguments.** CACHE is a list cache; KEY identifies the list. NOW overrides the current time and INTERVAL the cache's own interval, both for deterministic callers.

**Semantics.** An entry is stale when the time since its arrival is strictly greater than the interval. A key without an entry is missing rather than stale — it is a prefetch candidate instead — so a caller that wants to know whether it has something to show reads the entry as well.

**Returns.** Non-nil when the entry exists and is older than the interval; nil otherwise.

**Errors.** None.

#### Function: etaf-list-cache-unchanged-p (cache key rows total)

Return non-nil when ROWS and TOTAL equal what KEY already holds.

**Arguments.** CACHE is a list cache; KEY identifies the list. ROWS and TOTAL are a fresh reply.

**Semantics.** A caller compares a background reply with this before repainting: when the reply is unchanged, the page can be left exactly as it is, which is what keeps a section switch free of flicker. A key without an entry is never unchanged.

**Returns.** Non-nil when the entry exists and both values are `equal`; nil otherwise.

**Errors.** None.

**See also.** `etaf-list-cache-touch`, `etaf-list-cache-put`.

## Choosing the next refresh

<!-- index: etaf-list-cache-next; refresh order; prefetch; one in flight -->

#### Function: etaf-list-cache-next (cache keys &optional now interval)

Return the KEY that a background refresh should load next, or nil.

**Arguments.** CACHE is a list cache. KEYS is the caller's ordered list of candidates. NOW and INTERVAL override the current time and the freshness interval as in `etaf-list-cache-stale-p`.

**Semantics.** The stalest stale entry comes first; when every entry is fresh, the first candidate without an entry is returned so its section can be warmed before it is opened. The call answers nil while the cache has not been started, has a refresh in flight, is paused in its grace period or by a stop code, or is inside a failure backoff — that is what keeps one refresh at a time — and also when every candidate is fresh and cached. The application loads the returned key and reports the outcome through `etaf-list-cache-put` plus `etaf-list-cache-note-success` or `etaf-list-cache-note-failure`.

**Returns.** A key from KEYS, or nil when no refresh should start.

**Errors.** None.

**See also.** `etaf-list-cache-start`, `etaf-list-cache-set-busy`.

## Starting, arming and disarming

<!-- index: etaf-list-cache-start; etaf-list-cache-arm; background timer; disarm -->

#### Function: etaf-list-cache-start (cache)

Start CACHE: begin its grace period and allow background refreshes.

**Arguments.** CACHE is a list cache.

**Semantics.** Starting records the time the cache became active, which opens the grace period and lets `etaf-list-cache-next` return candidates. A caller that already runs its own timer calls this once when its session starts and then asks what to load.

**Returns.** CACHE.

**Errors.** None.

**See also.** `etaf-list-cache-next`, `etaf-list-cache-arm`.

#### Function: etaf-list-cache-arm (cache function &key interval)

Arm CACHE to call FUNCTION every INTERVAL seconds until disarmed.

**Arguments.** CACHE is a list cache. FUNCTION is a zero-argument function, usually one that loads the key `etaf-list-cache-next` returns. INTERVAL overrides the cache's own interval as the timer period.

**Semantics.** Arming disarms any previous cycle first, starts the cache again and installs one repeating timer, so arming twice replaces the timer instead of adding one and restarts the grace period. The function runs on the Emacs timer queue; `etaf-list-cache-disarm` stops the cycle for good.

**Returns.** CACHE.

**Errors.** None.

**See also.** `etaf-list-cache-disarm`, `etaf-list-cache-armed-p`.

#### Function: etaf-list-cache-armed-p (cache)

Return non-nil when CACHE has a background refresh timer armed.

**Arguments.** CACHE is a list cache.

**Returns.** Non-nil while a timer is installed; nil after `etaf-list-cache-disarm`.

**Errors.** None.

#### Function: etaf-list-cache-disarm (cache)

Stop CACHE's background refresh and clear its busy marker.

**Arguments.** CACHE is a list cache.

**Semantics.** Disarming cancels the timer, records no active start and clears the busy marker, so a disarmed cache starts no background work even after its entries grow old. Call it when the owning session is disposed. Disarming an already disarmed cache is harmless.

**Returns.** CACHE.

**Errors.** None.

**See also.** `etaf-list-cache-arm`, `etaf-list-cache-next`.

## Failure, backoff and busy

<!-- index: etaf-list-cache-note-failure; backoff; stop code; busy marker -->

#### Function: etaf-list-cache-note-success (cache)

Record that a load succeeded: clear the failure backoff and any pause.

**Arguments.** CACHE is a list cache.

**Semantics.** Call it from every load path, foreground or background. It resets the failure count, clears the retry time and lifts a stop-code pause, so background refreshes may start again.

**Returns.** CACHE.

**Errors.** None.

**See also.** `etaf-list-cache-note-failure`, `etaf-list-cache-blocked-p`.

#### Function: etaf-list-cache-note-failure (cache &optional code)

Record that a load failed with error CODE and throttle the retries.

**Arguments.** CACHE is a list cache. CODE is the failure category the backend reported.

**Semantics.** An unknown or missing CODE backs the next attempt off: the delay starts at the freshness interval and doubles with each further failure, capped at the maximum backoff. A CODE listed in the cache's stop codes means a human must act — a login expired, a flow is blocked — so the cache pauses background refreshes entirely until a load succeeds; it has no retry time while paused.

**Returns.** CACHE.

**Errors.** None.

**See also.** `etaf-list-cache-note-success`, `etaf-list-cache-retry-at`, `etaf-list-cache-blocked-p`.

#### Function: etaf-list-cache-blocked-p (cache)

Return non-nil when CACHE paused background refreshes until a load succeeds.

**Arguments.** CACHE is a list cache.

**Returns.** Non-nil after a stop-code failure, nil after a success.

**Errors.** None.

#### Function: etaf-list-cache-retry-at (cache)

Return the time before which CACHE starts no background refresh, or nil.

**Arguments.** CACHE is a list cache.

**Semantics.** The value is a absolute time in seconds since the epoch set by the last failure. A successful load clears it, and a stop-code failure leaves it nil while the cache is paused.

**Returns.** The retry time, or nil when no backoff is pending.

**Errors.** None.

#### Function: etaf-list-cache-busy-p (cache)

Return non-nil when CACHE has a background refresh in flight.

**Arguments.** CACHE is a list cache.

**Returns.** The busy marker as a boolean.

**Errors.** None.

**See also.** `etaf-list-cache-set-busy`.

#### Function: etaf-list-cache-set-busy (cache busy)

Record that CACHE has, or has not, a background refresh in flight.

**Arguments.** CACHE is a list cache; BUSY non-nil marks a refresh as running.

**Semantics.** A caller marks the cache busy before starting a background load and clears it when the reply arrives, which is what keeps one refresh at a time; `etaf-list-cache-next` returns nil while busy.

**Returns.** CACHE.

**Errors.** None.

```elisp :run
(etaf-define-component demo-paged-rows ()
  :bindings ((controller
              (etaf-data-controller
               (etaf-data-memory-source
                (cl-loop for i from 1 to 10000
                         collect (list :id i :name (format "第 %d 行" i)))
                :id-key :id)
               :page-size 8 :auto-load t)))
  :view
  (column :width '(ch 44) :item-gap '(lh 1)
          (text :color (etaf-theme-token :ui-muted-fg "#526174")
                (expr (format "共 %s 行；一次只渲染当前 8 行"
                              (etaf-value (etaf-data-total controller)))))
          (text :for (item (etaf-value (etaf-data-items controller)))
                :key (plist-get item :id)
                (expr (plist-get item :name)))
          (etaf-pagination :controller controller)))
(etaf-view (demo-paged-rows))
```

## Errors and recovery

| Failure | What happens |
| --- | --- |
| `etaf-list-cache-put` receives a negative or non-numeric AT | `wrong-type-argument`; the key keeps its previous entry |
| A background load fails with an ordinary code | The next attempt waits — interval, then doubled up to the maximum backoff |
| A background load fails with a stop code | Refreshes pause until `etaf-list-cache-note-success` |
| A background reply equals the cached rows and total | `etaf-list-cache-unchanged-p` lets the caller skip the repaint |
| A conditional reply is not modified | `etaf-list-cache-touch` refreshes the time and keeps the rows |
| The session is disposed | `etaf-list-cache-disarm` stops the timer and no candidate is returned |
