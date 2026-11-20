# Resource

A Resource is a Scope-owned value with a loader: it runs the loader, stores the outcome in a reactive state, and exposes a status, the last successful value and the failure. It is the single-value companion of the [Data Controller](data-controllers.md), and it uses the asynchronous lifecycle of the [Asynchronous Model](async.md) whenever the loader cannot finish in the call that starts it. This chapter defines the constructor and readers, the status machine, loading, cancellation and disposal, value retention and cleanup, and the shipped example. [Reactivity](reactivity.md#scopes) defines the Scope that owns a Resource.

## The Resource model

<!-- index: Resource; loader; status; keep-value; Resource Scope -->

A Resource holds a loader function, a child Scope, one current request, an optional timeout and a reactive state with the status, the value and the error. A loader may return an ordinary value, an `etaf-resource-result` carrying a cleanup function, or an asynchronous adapter from `etaf-async`. A failure inside the loader, or a rejection delivered later, is recorded in the state instead of being thrown at the caller; errors raised by the Resource's own cleanup or while publishing to observers still signal normally.

The status is one of six symbols:

| Status | Meaning |
| --- | --- |
| `idle` | Created with `:immediate nil`; no request has run |
| `loading` | A request is running and no previous value is retained |
| `refreshing` | A request is running while `:keep-value` retains the previous value |
| `success` | The last request completed with a value |
| `error` | The last request failed or timed out |
| `cancelled` | The pending request was cancelled |

The state is a reactive ref, so reading `etaf-resource-status`, `etaf-resource-value` or `etaf-resource-error` inside a View subscribes that render to the Resource: a completion repaints the part of the tree that reads it. The three readers are also ordinary functions usable outside rendering.

One Resource runs one request at a time. A new load makes the previous request obsolete before it starts, so only the current request can publish an outcome. The Resource owns a child Scope under its parent; a parent that stops disposes its Resources, which is how unmounting a Component releases the Resources its `:bindings` created. A Resource created without any parent Scope is detached and must be disposed by its creator ([Reactivity](reactivity.md#scopes)).

## Creating a Resource

<!-- index: etaf-resource; immediate; keep-value; timeout -->

#### Function: etaf-resource (loader &key (immediate t) scope name timeout keep-value)

Create a Scope-owned Resource backed by LOADER.

**Arguments.** LOADER is a function that produces one result: an ordinary value, an `etaf-resource-result`, or an `etaf-async` adapter. IMMEDIATE, when non-nil (the default), loads before `etaf-resource` returns; nil leaves the Resource `idle`. SCOPE is the parent Scope. NAME labels the Resource in diagnostics. TIMEOUT is nil or a positive number of seconds applied to asynchronous waiting only. KEEP-VALUE non-nil retains the last successful value across a reload.

**Semantics.** The Resource creates a child Scope under SCOPE or the active Scope; without either it is detached and its creator must dispose it. With IMMEDIATE the loader runs before the constructor returns, so a synchronous loader has already produced its outcome while an asynchronous one leaves the Resource `loading` ([Asynchronous Model](async.md)). A loader failure is recorded in the state and does not prevent the constructor from returning; when a signal escapes the immediate load — a cleanup or publication error — the constructor disposes the Resource and propagates the condition.

**Returns.** The new Resource.

**Errors.** `error→ wrong-type-argument` with data `(functionp LOADER)` when LOADER is not a function; `error→ etaf-async-error` when TIMEOUT is neither nil nor a positive number; any condition a signal from the immediate load propagates after disposing the Resource.

**Example.**

```elisp
(let ((resource (etaf-resource (lambda () "ready"))))
  (list (etaf-resource-status resource)
        (etaf-resource-value resource)))
;; ⇒ (success "ready")
```

**See also.** `etaf-resource-result`, `etaf-async`, [Reactivity](reactivity.md#scopes).

## Loading and reloading

<!-- index: reload; refreshing; retry; cleanup timing -->

#### Function: etaf-resource-load (resource)

Reload RESOURCE and return it, without waiting for asynchronous completion.

**Arguments.** RESOURCE is an active Resource.

**Semantics.** A previous pending request is made obsolete before the new one starts, so only the current request can publish. The status becomes `loading`, or `refreshing` when `:keep-value` retains a value; without `:keep-value` the previous value is cleared and its cleanup has run before the call returns. A synchronous loader completes during the call and an asynchronous one completes later. A loader failure — a signal inside the loader or a rejection delivered later — is recorded in the state and not signaled; cleanup, publication and rendering errors still signal normally, with the new outcome already recorded when they do. Nothing retries automatically: a call after an error, timeout or cancellation simply runs the loader again.

**Returns.** RESOURCE.

**Errors.** `error→ etaf-resource-error` with data `("ETAF Resource is not active")` when RESOURCE is not a Resource or has been disposed.

With `:keep-value` the old value and its cleanup stay in place until a new result is accepted, so a failure, cancellation or timeout keeps the last successful value; that is what lets a panel keep showing the previous data while a refresh is in flight. Without it a reload clears the value immediately and a failure leaves no value behind.

The old cleanup runs at the moment the old value is given up: on that immediate clear, when a replacement is accepted, or on disposal. A cleanup may start a new load or dispose the Resource; the request that delivered the replacement is still discarded if it became obsolete meanwhile.

## Cancelling and disposing

<!-- index: cancel; dispose; release -->

#### Function: etaf-resource-cancel (resource)

Cancel RESOURCE's pending load without disposing it, and return RESOURCE.

**Semantics.** The pending request is made obsolete, the adapter's cancel function runs when it provided one, and the first late completion is discarded with its cleanup. The state becomes `cancelled` with `(etaf-async-cancelled)` as its error, while `:keep-value` retains the last value. With no pending request the call changes nothing. The Resource can load again afterwards.

**Returns.** RESOURCE.

**Errors.** `error→ etaf-resource-error` with data `("ETAF Resource is not active")` when RESOURCE is not a Resource or has been disposed.

#### Function: etaf-resource-dispose (resource)

Dispose RESOURCE and return cleanup errors collected by its Scope.

**Semantics.** Disposal marks the Resource inactive, makes a pending request obsolete, runs the current value's cleanup once, and stops the Resource's Scope and everything it owns. Later loads and cancels signal `etaf-resource-error`. A parent Scope that stops disposes its Resources the same way, so a Component's `:bindings` Resource is released on unmount. Disposing an already disposed Resource returns nil.

**Returns.** The list of teardown conditions collected by the Scope, or nil when it stopped cleanly.

**Errors.** `error→ wrong-type-argument` when RESOURCE is not a Resource. Cleanup errors are collected into the return value instead of being signaled.

**See also.** `etaf-resource`, `etaf-resource-cancel`, [Reactivity](reactivity.md#scopes).

## Reading state

<!-- index: etaf-resource-status; etaf-resource-value; etaf-resource-error -->

#### Function: etaf-resource-status (resource)

Return RESOURCE status: idle, loading, refreshing, success, error or cancelled.

**Arguments.** RESOURCE is a Resource.

**Returns.** One of the six status symbols described in [The Resource model](#the-resource-model).

**See also.** `etaf-resource-load`, `etaf-resource-cancel`.

#### Function: etaf-resource-value (resource)

Return RESOURCE's successful value, or nil before success.

**Arguments.** RESOURCE is a Resource.

**Returns.** The value of the most recent successful outcome. With `:keep-value` the retained value is still returned during a refresh and after a failure, cancellation or timeout; without it a reload clears the value.

**See also.** `etaf-resource-result`, `etaf-resource-status`.

#### Function: etaf-resource-error (resource)

Return RESOURCE's current loader failure or cancellation condition, or nil.

**Arguments.** RESOURCE is a Resource.

**Returns.** The failure of the current state, or nil when the last outcome succeeded or nothing has run. A cancellation is `(etaf-async-cancelled)` and a timeout is `(etaf-async-timeout TIMEOUT)`; a loader failure is the condition the loader signaled or the data delivered to the adapter's reject function.

**Semantics.** This function and the identically named error condition are separate bindings. The condition is signaled for an invalid Resource operation; loader failures never signal and are read through this function.

**See also.** `etaf-resource`, `etaf-async`, `etaf-resource-error`.

A Component can own a Resource and render its readers directly; because the state is reactive, each completion repaints what reads it.

```elisp :run
(etaf-define-component demo-resource-status ()
  :bindings ((resource (etaf-resource (lambda () "rows"))))
  :view (column
          (text (expr (format "Status: %s" (etaf-resource-status resource))))
          (text (expr (format "Value: %S" (etaf-resource-value resource))))))
(etaf-view (demo-resource-status))
```

## Loader results and cleanup

<!-- index: etaf-resource-result; cleanup; discard -->

#### Function: etaf-resource-result (value &key cleanup)

Return a Resource loader result containing VALUE and optional CLEANUP.

**Arguments.** VALUE is the value to publish. CLEANUP, when non-nil, is a zero-argument function.

**Semantics.** Use it when the loader opened something that must be released. The Resource runs CLEANUP once, when it gives the value up: on a reload without `:keep-value`, when a replacement is accepted, on disposal, and when a first completion that arrived after cancellation is discarded even though its value is never published. Duplicate completions of one request are ignored, so a cleanup runs once. One result belongs to one Resource: cleanup ownership follows the value, so a loader must transfer each result to only one.

**Returns.** The result wrapper.

**Errors.** `error→ wrong-type-argument` with data `(functionp CLEANUP)` when CLEANUP is neither nil nor a function.

**Example.**

```elisp
(let* ((released nil)
       (resource (etaf-resource
                  (lambda ()
                    (etaf-resource-result
                     "rows" :cleanup (lambda () (setq released t)))))))
  (list (etaf-resource-value resource) released))
;; ⇒ ("rows" nil)
```

**See also.** `etaf-resource`, `etaf-resource-load`.

## The shipped example

<!-- index: etaf-resource-example-open; etaf-resource-example-close -->

#### Function: etaf-resource-example-open ()

Mount the asynchronous Resource example in *ETAF Resource Example* and return that buffer.

**Arguments.** None.

**Semantics.** Mounts the shipped example: a Resource completed by a native timer from its loader, with `:keep-value t` and a five-second timeout. Its buttons reload, simulate a failure and cancel; the panel shows the status, the last value, the failure message and the number of cleanups that have run. Repeated opens replace the previous mount, releasing its pending work and loaded value.

**Returns.** The mounted buffer; an interactive call displays it.

**Example.** `M-x etaf-resource-example-open`, then use the RELOAD, SIMULATE FAILURE and CANCEL buttons.

**See also.** `etaf-resource-example-close`.

#### Function: etaf-resource-example-close ()

Unmount and kill *ETAF Resource Example*.

**Arguments.** None.

**Semantics.** Unmounts the example when it is mounted and kills its buffer, which cancels pending work and releases the loaded value. Repeated closing is harmless.

**Returns.** nil.

**Errors.** None.

**See also.** `etaf-resource-example-open`.

## Errors and recovery

<!-- index: etaf-resource-error; not active; cleanup errors -->

#### Error: etaf-resource-error

Invalid ETAF Resource operation. Its parent condition is `etaf-reactive-error`.

**Semantics.** Signals that a Resource operation cannot be carried out because its target is invalid or no longer active. Catch it with `condition-case`; failed calls do not return a value. The data is the message `("ETAF Resource is not active")`. Loader failures are not this condition: they are recorded in the state and read with `etaf-resource-error`.

**Recovery.** A disposed Resource cannot be revived; create a new one, and fix the caller that disposed it early. The failed call changed nothing.

**See also.** `etaf-resource-load`, `etaf-resource-cancel`, `etaf-resource-error`.

| Failure | What remains |
| --- | --- |
| The loader signals, or a rejection arrives later | Status `error`, the condition in `etaf-resource-error`, and the value the retention mode dictates |
| The wait times out | Status `error` with `(etaf-async-timeout TIMEOUT)` recorded, and the cancel function has run |
| The request is cancelled | Status `cancelled` with `(etaf-async-cancelled)` recorded; `:keep-value` keeps the value |
| The request is replaced | The old request cannot publish; its first late completion is discarded with its cleanup |
| The Resource is disposed | Inactive with pending work cancelled and the current cleanup run; later loads signal `etaf-resource-error` |
| An observer signals during publication | The new state is already recorded and the condition propagates |
