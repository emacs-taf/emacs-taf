# Asynchronous Model

Not every loader finishes in the call that starts it: a file read, a SQLite query or a subprocess may complete later, from a timer or a process filter. Resources and Data Controllers run such work through one shared lifecycle. The loader returns an *asynchronous adapter* describing how to start the work; the owner that received it starts the work, applies an optional timeout, records exactly one outcome, and discards obsolete completions. This chapter describes the adapter and the rules every owner applies. The [Resource](resources.md), [Data Sources](data-sources.md) and [Data Controllers](data-controllers.md) chapters, together with the [Reconciliation](reconciliation.md) and [List Cache](list-cache.md) chapters, define the owners themselves; [Reactivity](reactivity.md#scopes) defines the Scope that owns the work and [Reactivity](reactivity.md#errors-and-recovery) the parent condition of the errors below.

## The load lifecycle

<!-- index: async adapter; load request; pending request; obsolete request -->

A loader or a Data source operation may return an ordinary value, a result wrapper, or an asynchronous adapter. The first two complete their request in the same call. The adapter is lazy: constructing it starts nothing. The owner begins a request by calling the loader with its own Scope active and then driving what came back, so the adapter has no state and no lifecycle of its own — it is not a promise that can be awaited, and returning it from somewhere other than a loader or source operation starts nothing.

Each request produces at most one outcome. The adapter's RESOLVE delivers an ordinary result and its REJECT delivers condition data; the first of the two completes the request, and anything delivered afterwards cannot reach the owner's state. While the request is pending the owner holds it together with the timeout and the cancel handle, and a new load makes the previous request obsolete before it starts.

The owner runs the loader, the adapter's start function and the completion callbacks with the owner's Scope active, so effects, child Scopes and cleanups created there belong to the owner and are released with it ([Reactivity](reactivity.md#scopes)). Completion may arrive from a native timer or process filter, later and on the Emacs thread; an adapter therefore schedules its own completion and never blocks the call that starts it. A completion callback is outside any reactive batch, so an owner publishes its outcome as one update, and application code that writes several values at completion opens an `etaf-batch` ([Reactivity](reactivity.md#asynchronous-code)).

A loader failure becomes observable state rather than an error thrown at the caller: a synchronous loader error and a REJECT are treated alike, and the owner records the condition where the application reads its status, value and error. Errors raised by the owner's own publication, rendering or cleanup are not loader failures and still signal normally.

## Describing an asynchronous operation

<!-- index: etaf-async; lazy loader; start function -->

An adapter is written with one function, `etaf-async`, which captures START and nothing else. The owner supplies the RESOLVE and REJECT pair when it starts the request, so one adapter value describes work that has not been started yet.

#### Function: etaf-async (start)

Describe a lazy asynchronous loader using START.

**Arguments.** START is a function called with two arguments, RESOLVE and REJECT, both functions. It starts the work without blocking and may return a zero-argument cancel function or nil.

**Semantics.** The return value is a descriptor, not a running operation: it captures START and expects an owning Resource or Data Controller to start it. When the owner starts the request it calls START once with a RESOLVE and a REJECT that complete that one request. RESOLVE takes the ordinary loader result; REJECT takes Emacs condition data. The first of the two completes the request, and later completions are ignored. Returning nil instead of a cancel function means only that the owner has no external work to stop; the request still becomes obsolete when it is replaced, cancelled or disposed, and its late completion is discarded.

**Returns.** The asynchronous descriptor.

**Errors.** `error→ wrong-type-argument` with data `(functionp START)` when START is not a function.

**Example.**

```elisp
(let ((resource (etaf-resource
                 (lambda ()
                   (etaf-async (lambda (resolve _reject)
                                 (funcall resolve 'rows)
                                 nil))))))
  (list (etaf-resource-status resource)
        (etaf-resource-value resource)))
;; ⇒ (success rows)
```

**See also.** `etaf-resource`, `etaf-resource-result`, `etaf-data-source`.

```elisp :figure Load settles once; cancel and timeout share the same path
(etaf-view
 (column :width '(ch 44) :item-gap '(lh 0)
   (row :item-gap '(ch 1)
     (box :padding '((lh 0) (ch 2)) :background-color (etaf-theme-token :ui-panel-bg "#f6f8fa") (text "load"))
     (box :padding '((lh 0) (ch 2)) :background-color (etaf-theme-token :ui-accent-soft-bg "#ddf4ff")
          (text :color (etaf-theme-token :ui-accent "#0969da") "完成一次"))
     (box :padding '((lh 0) (ch 2)) :background-color (etaf-theme-token :ui-disabled-bg "#e5e7eb")
          (text :color (etaf-theme-token :ui-disabled-fg "#687386") "取消"))
     (box :padding '((lh 0) (ch 2)) :background-color (etaf-theme-token :ui-disabled-bg "#e5e7eb")
          (text :color (etaf-theme-token :ui-disabled-fg "#687386") "超时")))
   (text :color (etaf-theme-token :ui-muted-fg "#526174") "晚到的结果被丢弃；取消与超时沿同一路径结算。")))
```

## Completing once

<!-- index: resolve; reject; condition data; first completion -->

RESOLVE receives the ordinary loader result, the same value the loader would have returned synchronously; when the owner defines a result wrapper such as `etaf-resource-result`, RESOLVE receives that wrapper instead, so a result can carry cleanup. REJECT receives Emacs condition data, a proper list whose first element is a symbol. Because the data is recorded and can be re-signaled as a condition, it is validated: malformed data is replaced by `etaf-async-error` data `("Rejection must be condition data" VALUE)`, so the owner always records a well-formed failure.

A repeated call to either function, or a call that arrives after the request became obsolete, is ignored silently. That is what makes a one-shot adapter safe even when its event source is noisy: timers may fire and process filters may run, and a completion delivered after the request ended simply does not reach the owner.

## Cancellation

<!-- index: cancellation; cancel function; superseded request -->

START may return a zero-argument cancel function, and the owner calls it at most once when the request is cancelled, replaced, disposed or timed out. The request is made obsolete first, so a completion that the cancel function itself triggers is discarded rather than published. Returning nil instead means the external work cannot be stopped; the request is still invalidated and its completion is still ignored, so an adapter without a cancel function remains safe to replace.

Cancellation never retries automatically and never rolls back external work. The owner is free to start a new request — a cancelled read can be loaded again — and a superseded write is handled by reconciliation rather than replayed silently (the [Reconciliation](reconciliation.md) chapter).

## Timeout

<!-- index: timeout; :timeout; timed out wait -->

An owner may give a request a timeout in seconds, nil or a positive number, applied to asynchronous waiting only. When the wait exceeds it, the owner aborts the request exactly like a cancellation: it runs the cancel function, records the outcome as `etaf-async-timeout` data `(TIMEOUT)`, and discards any completion that arrives later. A request that completes or is cancelled releases its timer, so a timeout cannot fire after another outcome was recorded. An owner validates its timeout before starting any work; a value that is not nil or a positive number signals `etaf-async-error` with data `("Timeout must be nil or positive seconds" VALUE)`.

## Late results

<!-- index: late result; discard; cleanup on discard -->

Once a request has an outcome its later results are ignored. Once a request has been replaced, cancelled, timed out or released, its first later completion is discarded: a plain value is dropped, while a result wrapper's cleanup runs at that moment instead of being published, so a resource a loader opened does not leak. Completions after the first discarded one are ignored.

Discarding is silent when the request was replaced or released, and records the cancellation or timeout condition when it became obsolete for that reason; each owner chapter states the statuses its surface reports. In every case an obsolete completion leaves the owner's published state untouched.

## Subprocesses

<!-- index: subprocess; command-line backend; process job -->

Many applications talk to a backend through a command-line program that prints one answer and exits. `etaf-process-run` runs such a program without blocking Emacs and reports one result, after which the job is gone. The protocol, the meaning of the exit code and of the output fields, stays with the caller; the job only guarantees how the result is collected and delivered.

#### Function: etaf-process-run (command &key callback timeout environment directory (output 'string) (coding 'utf-8-unix) name)

Run COMMAND without blocking and return a job.

**Arguments.**

- COMMAND is a non-empty list of strings: the program and its arguments. No shell is involved.
- CALLBACK is nil or a function of one argument, the result plist.
- TIMEOUT is nil or a positive number of seconds.
- ENVIRONMENT is a list of `"NAME=VALUE"` strings placed in front of `process-environment`, so they override inherited values.
- DIRECTORY is nil or the working directory; nil uses `default-directory`.
- OUTPUT is `string` (the default) or `json`.
- CODING is the coding system used to decode both streams, `utf-8-unix` by default; use `binary` for raw bytes.
- NAME is nil or the process name shown in `list-processes`.

**Semantics.** The program runs with separate standard output and standard error. When it exits, both streams are read to the end before the result is delivered, so the result never misses output that was still in flight when the exit was reported. CALLBACK receives a plist:

- `:status` is `exit`, `signal`, `timeout` or `failed`, where `failed` means the program could not start.
- `:exit` is the exit code, or the signal number for `signal`.
- `:output` is standard output as a string, or with OUTPUT `json` its parsed value: objects as plists, arrays as lists, null as nil and false as `:false`. Empty or invalid JSON gives nil.
- `:stderr` is the complete standard error text.
- `:message` describes a timeout or a failure to start.

CALLBACK never runs before `etaf-process-run` returns, even when the program cannot start, so the caller can store the job first. It runs at most once. When TIMEOUT expires first, the process is stopped and the result has status `timeout`.

**Returns.** A job, to be passed to `etaf-process-cancel` and `etaf-process-live-p`.

**Errors.** `error→ wrong-type-argument` when COMMAND is not a non-empty list of strings, when TIMEOUT is not a positive number, or when OUTPUT is neither `string` nor `json`. Problems of the program itself are results, not errors.

**Example.** A Resource loads a feed through a command-line client, and replacing or releasing the Resource stops the process.

```elisp
(etaf-async
 (lambda (resolve reject)
   (let ((job (etaf-process-run
               '("feed-client" "list" "--json")
               :output 'json :timeout 20
               :callback
               (lambda (result)
                 (if (eql (plist-get result :exit) 0)
                     (funcall resolve (plist-get result :output))
                   (funcall reject
                            (list 'error (or (plist-get result :message)
                                             (plist-get result :stderr)))))))))
     (lambda () (etaf-process-cancel job)))))
```

#### Function: etaf-process-cancel (job)

Stop JOB without running its callback, and return non-nil when JOB had not settled yet.

**Semantics.** The process is deleted and the job is settled, so a result that was already on its way is discarded. Cancelling a settled job does nothing and returns nil.

#### Function: etaf-process-live-p (job)

Return non-nil while JOB has neither settled nor been cancelled.

**Semantics.** A job is live from the moment `etaf-process-run` returns until its callback has been called or it is cancelled. Use it to skip starting a second request while one is pending.

## Errors and recovery

<!-- index: etaf-async-error; etaf-async-timeout; etaf-async-cancelled -->

#### Error: etaf-async-error

Invalid asynchronous adapter or timeout. Its parent condition is `etaf-reactive-error`.

**Semantics.** Signals that an adapter or a request timeout is malformed: the work never starts, or its completion data cannot be interpreted. Catch it with `condition-case`; failed calls do not return a value. An owner that receives the condition from a start function records it as the request's failure, so it is observable exactly like a loader failure.

**Causes.** The start function returns a value that is neither a cancel function nor nil; REJECT receives data that is not condition data; an owner's TIMEOUT is not nil or a positive number. A START that is not a function is rejected earlier, with `wrong-type-argument`.

**Recovery.** Nothing runs to retry: fix the start function, its rejection data or the timeout and start a new request. The owner keeps its previous state.

**See also.** `etaf-async`, `etaf-async-timeout`, `etaf-async-cancelled`.

#### Error: etaf-async-timeout

Asynchronous wait exceeded its timeout. Its parent condition is `etaf-async-error`.

**Semantics.** The owner's timeout elapsed while the request was still pending. The owner has already run the adapter's cancel function, and this condition is recorded as the request's outcome; no later completion can publish. The data is `(TIMEOUT)`, the number of seconds allowed.

**Recovery.** A timeout never proves that the external work did not happen. A read can be started again; for a write, the outcome is uncertain, and the owner's reconciliation state describes that uncertainty (the [Reconciliation](reconciliation.md) chapter). A timeout never certifies a rollback.

**See also.** `etaf-async`, `etaf-async-error`.

#### Error: etaf-async-cancelled

Pending work was cancelled. Its parent condition is `etaf-async-error`.

**Semantics.** The owner cancelled a pending request, or superseded it with a new one. The first later completion is discarded — with its cleanup, when it carries one — and the condition is recorded as the request's outcome when the cancellation is explicit. Cancellation is deliberate, so it says nothing by itself about whether the external operation took effect.

**Recovery.** The owner may load again; a cancelled read starts over, and a superseded write is reconciled rather than replayed automatically. Like a timeout, cancellation never certifies a rollback.

**See also.** `etaf-async`, `etaf-async-error`.

| Failure | What remains |
| --- | --- |
| A loader signals, or REJECT delivers a condition | The request is complete with that condition as the owner's error state; later completions are ignored |
| The timeout elapses | The cancel function has run, `etaf-async-timeout` is recorded, and a later completion is discarded |
| The request is replaced or disposed | The previous request is obsolete; its first late completion is discarded and its cleanup runs; the new request is unaffected |
| The adapter or the timeout is malformed | `etaf-async-error` where the malformed value is detected; no request runs for it and earlier state stays |
