# Data Controllers

A Data Controller is the reactive owner of one Data Source. It holds the query, the page, the accepted items, the total, the selection, the status and the error in refs; it calls the source for pages and mutations; and it publishes every outcome as one reactive update, so a View that reads its refs follows the data. This chapter defines the constructor and its options, loading, queries and pagination, selection, mutations, cancellation and stopping, and the readers. [Data Sources](data-sources.md) defines the source protocol it drives and [Asynchronous Model](async.md) the adapter a source callback may return; [Reactivity](reactivity.md) defines refs and `etaf-value`. The five-state reconciliation machine that follows a committed write belongs to the [Reconciliation](reconciliation.md) chapter.

## The controller model

<!-- index: Data Controller; controller refs; loading; refreshing; item retention -->

A Controller owns a child Scope, reads one source, and keeps one current request at a time. Its public state lives in refs: `etaf-data-query`, `etaf-data-page`, `etaf-data-page-size`, `etaf-data-items`, `etaf-data-total`, `etaf-data-status`, `etaf-data-error` and `etaf-data-selection` each return one. Reading a ref with `etaf-value` inside a View or an effect subscribes it to the Controller, and every publication is one `etaf-batch`, so a load result updates items, total, page metadata, error and status together.

The status moves through six symbols: `idle` before the first load, `loading` while a request runs without an accepted result, `refreshing` while a reload runs with the previous items still accepted, `success` after a successful load, `error` after a failure or timeout, and `cancelled` after a cancellation. A load never clears accepted items: they stay readable during a refresh, after an error and after a cancellation until a successful load replaces them.

A Controller starts `idle`; `:initial-result` seeds it as an already successful load without touching the source. `:auto-load` makes it load once and then reload whenever the query, the page or the page size changes — the three form one composite key. With `:owner-scope`, or any active Scope, the Controller's child Scope is disposed with that owner; otherwise it is detached and the caller must `etaf-data-stop` it. Stopping cancels pending work and ignores late completions; no operation is retried automatically.

A Controller performs one request at a time. Starting a load or a write makes the previous request obsolete; two writes cannot be pending together. The `:item-key` option, falling back to the source's `:item-key` capability and then to the item itself, defines the stable identity used by selection.

## Creating a controller

<!-- index: etaf-data-controller; auto-load; initial result; owner scope -->

#### Function: etaf-data-controller (source &key query (page 1) (page-size 20) selection auto-load name item-key owner-scope initial-result timeout)

Create a reactive Data Controller for SOURCE.

**Arguments.** SOURCE is a Data source. QUERY, PAGE, PAGE-SIZE, SELECTION, ITEMS, TOTAL, STATUS, ERROR and the selection refs start from the corresponding options. AUTO-LOAD non-nil loads immediately and reloads after query or pagination changes. NAME labels the Controller in diagnostics. ITEM-KEY overrides the source's identity function for selection and selected-item state. OWNER-SCOPE is the Scope whose disposal stops the Controller. INITIAL-RESULT is a normalized source result that seeds a successful Controller without another load. TIMEOUT is nil or a positive number of seconds applied to each asynchronous operation.

**Semantics.** The Controller creates a child Scope under OWNER-SCOPE or the active Scope; without either it is detached and must be stopped by its creator. INITIAL-RESULT is normalized like a source page — a plist with `:items`, optionally `:total`, `:page` and `:page-size` — and makes the Controller start as `success` with those values; a missing `:total` counts the items. INITIAL-RESULT and AUTO-LOAD are mutually exclusive. AUTO-LOAD loads once immediately and then watches the composite query, page and page-size key, so setting any of the three reloads; a successful load records the key so it is not loaded twice. The selection watch keeps the selection snapshot and the per-identity boolean refs current, including writes made directly to the selection ref.

**Returns.** The new Controller.

**Errors.** `error→ wrong-type-argument` when SOURCE is not a Data source or ITEM-KEY is neither nil nor a function; `error→ etaf-async-error` when TIMEOUT is neither nil nor a positive number; an error with message `"ETAF Data :initial-result and :auto-load are mutually exclusive"` when both options are given.

**Example.** `(etaf-data-controller (etaf-data-memory-source '((:id 1)) :id-key :id) :auto-load t)` loads the first page at once and keeps it reactive.

**See also.** `etaf-data-load`, `etaf-data-source`, [Reactivity](reactivity.md#refs).

## Loading pages

<!-- index: load; refresh; synchronous result; error recording -->

#### Function: etaf-data-load (controller)

Start CONTROLLER's source load; return the synchronous result or nil pending.

**Arguments.** CONTROLLER is a live Controller.

**Semantics.** The call makes any previous request obsolete and starts a new load of the current query, page and page size. A synchronous source returns its page and the call returns that result; an asynchronous source returns nil while the request is pending. Before an accepted result the status is `loading`; afterwards a reload is `refreshing` and the previous items remain readable. A successful completion stores items (with `:total` defaulting to the item count) and writes back `:page` and `:page-size` when the page carries them. A synchronous source failure is recorded and re-signaled to the caller; an asynchronous failure is only recorded, so it is observed through `etaf-data-error` and the status. Loading after an error, timeout or cancellation simply runs the source again.

**Returns.** The synchronous page result, or nil while asynchronous work is pending.

**Errors.** `error→ etaf-data-stopped-error` when CONTROLLER has been stopped; `error→ wrong-type-argument` when it is not a Controller; any synchronously signaled source or normalization failure is re-signaled after being recorded.

**See also.** `etaf-data-reload`, `etaf-data-status`, `etaf-data-error`.

#### Function: etaf-data-reload (controller)

Reload CONTROLLER; return the synchronous result or nil while pending.

**Arguments.** CONTROLLER is a live Controller.

**Semantics.** Identical to `etaf-data-load`; it is the spelling to use when the intent is a refresh rather than the first load.

**Returns.** The synchronous page result, or nil while asynchronous work is pending.

**Errors.** As `etaf-data-load`.

## Queries and pagination

<!-- index: query; page; page size; next page; previous page -->

#### Function: etaf-data-query (controller)

Return CONTROLLER's query ref.

**Arguments.** CONTROLLER is a live Controller.

**Returns.** The query ref; read or write it with `etaf-value` and `etaf-set-value`.

**Errors.** `error→ etaf-data-stopped-error` when CONTROLLER has been stopped; `error→ wrong-type-argument` when it is not a Controller.

#### Function: etaf-data-set-query (controller query)

Set CONTROLLER query to QUERY and return QUERY.

**Arguments.** CONTROLLER is a live Controller; QUERY is passed to the source unchanged.

**Semantics.** The query is stored in its ref only. With AUTO-LOAD the write triggers a reload through the composite key watch; without it, the application calls `etaf-data-load` when it wants the new page.

**Returns.** QUERY.

**Errors.** `error→ etaf-data-stopped-error` when CONTROLLER has been stopped; `error→ wrong-type-argument` when it is not a Controller.

#### Function: etaf-data-page (controller)

Return CONTROLLER's page ref.

**Arguments.** CONTROLLER is a live Controller.

**Returns.** The page ref.

**Errors.** `error→ etaf-data-stopped-error` when CONTROLLER has been stopped; `error→ wrong-type-argument` when it is not a Controller.

#### Function: etaf-data-page-size (controller)

Return CONTROLLER's page-size ref.

**Arguments.** CONTROLLER is a live Controller.

**Returns.** The page-size ref.

**Errors.** `error→ etaf-data-stopped-error` when CONTROLLER has been stopped; `error→ wrong-type-argument` when it is not a Controller.

#### Function: etaf-data-set-page (controller page)

Set CONTROLLER page to PAGE and return PAGE.

**Arguments.** CONTROLLER is a live Controller; PAGE is the new page number.

**Semantics.** The page is stored in its ref; the source decides how it slices. With AUTO-LOAD the write reloads; without it, the application loads explicitly.

**Returns.** PAGE.

**Errors.** `error→ etaf-data-stopped-error` when CONTROLLER has been stopped; `error→ wrong-type-argument` when it is not a Controller.

#### Function: etaf-data-set-page-size (controller page-size)

Set CONTROLLER page size to PAGE-SIZE and return PAGE-SIZE.

**Arguments.** CONTROLLER is a live Controller; PAGE-SIZE is the new page size.

**Semantics.** The page size is stored in its ref; the source decides how it slices. With AUTO-LOAD the write reloads; without it, the application loads explicitly.

**Returns.** PAGE-SIZE.

**Errors.** `error→ etaf-data-stopped-error` when CONTROLLER has been stopped; `error→ wrong-type-argument` when it is not a Controller.

#### Function: etaf-data-next-page (controller)

Move CONTROLLER to the next page and return the new page.

**Arguments.** CONTROLLER is a live Controller.

**Semantics.** The page ref is incremented by one and the new page is returned. With AUTO-LOAD the watch loads it; without AUTO-LOAD the call loads it itself, so stepping through pages is one call either way.

**Returns.** The new page number.

**Errors.** `error→ etaf-data-stopped-error` when CONTROLLER has been stopped; `error→ wrong-type-argument` when it is not a Controller.

#### Function: etaf-data-previous-page (controller)

Move CONTROLLER to the previous page and return the new page.

**Arguments.** CONTROLLER is a live Controller.

**Semantics.** The page ref is decremented by one but never below 1, and the new page is returned. Loading follows AUTO-LOAD as in `etaf-data-next-page`.

**Returns.** The new page number.

**Errors.** `error→ etaf-data-stopped-error` when CONTROLLER has been stopped; `error→ wrong-type-argument` when it is not a Controller.

## Selection

<!-- index: selection; selected ref; selected item; item identity -->

#### Function: etaf-data-selection (controller)

Return CONTROLLER's selected identity list ref.

**Arguments.** CONTROLLER is a live Controller.

**Semantics.** The ref holds the selected identities in selection order. Writing it directly is supported: the Controller's watch updates the snapshot and the per-identity boolean refs from the new list.

**Returns.** The selection ref.

**Errors.** `error→ etaf-data-stopped-error` when CONTROLLER has been stopped; `error→ wrong-type-argument` when it is not a Controller.

#### Function: etaf-data-select (controller identity &optional (selected-p t))

Select or deselect IDENTITY in CONTROLLER.

**Arguments.** CONTROLLER is a live Controller. IDENTITY is a selection identity. SELECTED-P non-nil adds IDENTITY; nil removes it.

**Semantics.** The operation is additive: the identity is added when absent or removed when SELECTED-P is nil, and other identities are untouched. Use `etaf-data-select-one` for the single-selection semantics of tables and lists.

**Returns.** The new selection list.

**Errors.** `error→ etaf-data-stopped-error` when CONTROLLER has been stopped; `error→ wrong-type-argument` when it is not a Controller.

#### Function: etaf-data-select-one (controller identity)

Replace CONTROLLER selection with the single IDENTITY.

**Arguments.** CONTROLLER is a live Controller. IDENTITY is a selection identity, or nil to clear the selection.

**Semantics.** The selection becomes the one-element list of IDENTITY, or nil. This is the explicit single-selection operation for tables and list views; `etaf-data-select` remains additive for multi-select controls.

**Returns.** The new selection list.

**Errors.** `error→ etaf-data-stopped-error` when CONTROLLER has been stopped; `error→ wrong-type-argument` when it is not a Controller.

#### Function: etaf-data-selected-ref (controller identity)

Return CONTROLLER's stable boolean selection ref for IDENTITY.

**Arguments.** CONTROLLER is a live Controller; IDENTITY is a selection identity.

**Semantics.** The ref changes only when IDENTITY enters or leaves the selection. Repeated calls for the same identity return the same ref for the controller lifetime. Updates made through the selection APIs and writes made directly to the selection ref are both reflected, because the Controller's watch owns the synchronization.

**Returns.** The boolean ref.

**Errors.** `error→ etaf-data-stopped-error` when CONTROLLER has been stopped; `error→ wrong-type-argument` when it is not a Controller.

#### Function: etaf-data-selected-item (controller &optional item-key)

Return the loaded item matching CONTROLLER's first selected identity.

**Arguments.** CONTROLLER is a live Controller. ITEM-KEY overrides the function supplied to `etaf-data-controller`.

**Semantics.** The first identity of the selection is looked up in the loaded items with ITEM-KEY, or with the Controller's identity function, or by direct `equal` comparison when neither is available. The lookup only sees the currently loaded items; selecting an identity whose item is on another page returns nil.

**Returns.** The matching item, or nil when the selection is empty or the current page has no match.

**Errors.** `error→ etaf-data-stopped-error` when CONTROLLER has been stopped; `error→ wrong-type-argument` when it is not a Controller.

#### Function: etaf-data-item-identity (controller item)

Return ITEM's stable selection identity in CONTROLLER.

**Arguments.** CONTROLLER is a live Controller; ITEM is one loaded item.

**Semantics.** The identity comes from the Controller's explicit `:item-key`, then from the source's `:item-key` capability, and otherwise is ITEM itself. Applications use it to compare an item with selected identities without knowing which source supplied the key.

**Returns.** The identity value.

**Errors.** `error→ etaf-data-stopped-error` when CONTROLLER has been stopped; `error→ wrong-type-argument` when it is not a Controller.

## Mutations

<!-- index: mutation; pending write; mutate many; batch; certainty -->

#### Function: etaf-data-mutate (controller operation payload)

Run source OPERATION with PAYLOAD and then reconcile its result.

**Arguments.** CONTROLLER is a live Controller. OPERATION names the mutation, for example `insert`, `replace`, `update`, `delete` or `reset` for the in-memory source. PAYLOAD is the operation's input.

**Semantics.** A synchronous source returns its result and the call returns that result; an asynchronous source returns nil while the write is pending, and the application observes the status and the outcome ref. While a write is pending a second write signals `etaf-data-error` with data `("A mutation is already pending")`; a load may still replace the pending write. A v1 result is committed; a source with `:mutate-v2` returns a tagged outcome whose certainty is `committed`, `rolled-back` or `external-unknown`. A committed write triggers one reconciliation load of the current page, and the outcome ref then carries the settled envelope. A rolled-back or unclassified outcome publishes the failure instead, and the call re-signals the provider's condition. Cancellation, timeout or an unclassified failure never implies that the write was rolled back; the outcome records `external-unknown` and the [Reconciliation](reconciliation.md) chapter defines what may be retried.

**Returns.** The synchronous mutation result, or nil while an asynchronous write is pending.

**Errors.** `error→ etaf-data-error` with data `("A mutation is already pending")` when another write is pending, or as the parent condition of a failed mutation; `error→ etaf-data-stopped-error` when CONTROLLER has been stopped; `error→ wrong-type-argument` when it is not a Controller.

**See also.** `etaf-data-mutate-many`, `etaf-data-stop`.

#### Function: etaf-data-mutate-many (controller operations)

Apply OPERATIONS to CONTROLLER's source and reconcile once.

**Arguments.** CONTROLLER is a live Controller. OPERATIONS is a non-empty list of `(OPERATION PAYLOAD)` pairs applied in order.

**Semantics.** A source with the optional `:mutate-batch` capability applies the whole list atomically and returns one result per pair; any other source runs its v1 `:mutate` callback for each pair. All these callbacks must complete synchronously; an asynchronous result signals `etaf-data-error`. The committed result is a plist whose `:operation` is `mutate-many`, with `:results` in order and `:changes` when every result reports an integral change count. The batch is reconciled once, like a single write. If an operation signals, the batch stops, the failure outcome carries the completed results under `:results` with `external-unknown` certainty, and the condition is re-signaled after publication.

**Returns.** The committed result plist, or nil while the reconciliation load is pending.

**Errors.** `error→ etaf-data-error` with data naming the problem when OPERATIONS is empty or malformed, when the source lacks `:mutate` or `:mutate-batch`, when a batch callback completes asynchronously, when `:mutate-batch` returns a different number of results than operations, or as the parent condition of a signaled operation; `error→ etaf-data-stopped-error` when CONTROLLER has been stopped; `error→ wrong-type-argument` when it is not a Controller.

**See also.** `etaf-data-mutate`, `etaf-data-mutation-outcome`.

## Cancelling and stopping

<!-- index: cancel; stop; disposed controller; late completion -->

#### Function: etaf-data-cancel (controller)

Cancel CONTROLLER's pending request without stopping it; return CONTROLLER.

**Arguments.** CONTROLLER is a live Controller.

**Semantics.** The pending request is made obsolete, its adapter's cancel function runs when it supplied one, and the first late completion is discarded. The loaded items remain readable, and the Controller can load again. A cancelled write keeps `external-unknown` certainty unless its provider had already reported a committed result, and cancelling the refresh that followed a committed write never changes that known result.

**Returns.** CONTROLLER.

**Errors.** `error→ etaf-data-stopped-error` when CONTROLLER has been stopped; `error→ wrong-type-argument` when it is not a Controller.

#### Function: etaf-data-stop (controller)

Stop CONTROLLER, dispose its Scope, and return cleanup errors.

**Arguments.** CONTROLLER is a live Controller.

**Semantics.** Stopping marks the Controller stopped, stops its Scope — so the auto-load watch, the selection watch and any pending request end — clears the internal selection refs and runs the source's `:dispose` once. Afterwards every data operation signals `etaf-data-stopped-error`; the readers cannot be called either. Disposing the owner Scope, such as unmounting a Component, stops the Controller the same way. Stopping an already stopped Controller returns nil.

**Returns.** The list of cleanup conditions collected by the Scope, or nil when it stopped cleanly.

**Errors.** `error→ wrong-type-argument` when CONTROLLER is not a Controller. Cleanup errors are collected into the return value.

**See also.** `etaf-data-cancel`, `etaf-data-controller`, [Data Sources](data-sources.md#disposal-and-ownership).

## Reading state

<!-- index: etaf-data-status; etaf-data-items; etaf-data-total; etaf-data-error -->

#### Function: etaf-data-status (controller)

Return CONTROLLER's status ref.

**Arguments.** CONTROLLER is a live Controller.

**Returns.** The status ref, whose value is one of the six symbols described in [The controller model](#the-controller-model).

**Errors.** `error→ etaf-data-stopped-error` when CONTROLLER has been stopped; `error→ wrong-type-argument` when it is not a Controller.

#### Function: etaf-data-items (controller)

Return CONTROLLER's loaded items ref.

**Arguments.** CONTROLLER is a live Controller.

**Returns.** The items ref; its value is the page most recently accepted, and it stays readable through a refresh, an error and a cancellation.

**Errors.** `error→ etaf-data-stopped-error` when CONTROLLER has been stopped; `error→ wrong-type-argument` when it is not a Controller.

#### Function: etaf-data-total (controller)

Return CONTROLLER's total matching item count ref.

**Arguments.** CONTROLLER is a live Controller.

**Returns.** The total ref; a page without its own `:total` counts its items.

**Errors.** `error→ etaf-data-stopped-error` when CONTROLLER has been stopped; `error→ wrong-type-argument` when it is not a Controller.

#### Function: etaf-data-error (controller)

Return CONTROLLER's observable error ref.

**Arguments.** CONTROLLER is a live Controller.

**Semantics.** The Controller owns the ref; consumers observe it and do not write it. The value is nil without a captured failure, otherwise condition data. This function and the identically named error condition are separate bindings.

**Returns.** The error ref.

**Errors.** `error→ etaf-data-stopped-error` when CONTROLLER has been stopped; `error→ wrong-type-argument` when it is not a Controller.

A Component can own a Controller in its `:bindings` and render its refs directly; every publication repaints what reads them.

```elisp :run
(etaf-define-component demo-controller-page ()
  :bindings ((controller (etaf-data-controller
                          (etaf-data-memory-source '((:name "Ada") (:name "Grace"))
                                                   :id-key :name)
                          :auto-load t)))
  :view (column
          (text (expr (format "Status: %s" (etaf-value (etaf-data-status controller)))))
          (text (expr (format "Total: %s" (etaf-value (etaf-data-total controller)))))
          (text :for (item (etaf-value (etaf-data-items controller)))
                :key (plist-get item :name)
                (expr (format "Row: %s" (plist-get item :name))))))
(etaf-view (demo-controller-page))
```

## Errors and recovery

<!-- index: etaf-data-error; etaf-data-stopped-error; recovery -->

#### Error: etaf-data-error

Invalid ETAF data operation; parent condition for Data contract failures.

**Semantics.** Catches contract violations rather than provider failures: two pending writes, a malformed `etaf-data-mutate-many` list, an asynchronous batch, a source without the needed capability, or a mutation whose outcome is not committed. Catch it with `condition-case`; failed calls do not return a value. This condition is distinct from calling the same-named reader function to inspect a controller's captured failure.

**Causes.** `("A mutation is already pending")`; messages about a non-empty operation list, a malformed `(OPERATION PAYLOAD)` entry, a missing capability, an asynchronous batch result or a result count that differs from the operation count; `"ETAF Data mutation OPERATION was CERTAINTY"` for a non-committed outcome without its own condition.

**Recovery.** Nothing is rolled back by these failures; the Controller keeps the items and status it had, and a reconcilable committed write is retried through `etaf-data-retry-reconciliation` rather than replayed. Fix the call or the source and try again.

**See also.** `etaf-data-mutate`, `etaf-data-mutate-many`, `etaf-data-error`.

#### Error: etaf-data-stopped-error

ETAF data controller has been stopped.

**Semantics.** Signals that an operation was attempted through a Controller whose Scope has already stopped, either explicitly with `etaf-data-stop` or because its owner Scope was disposed. Catch it with `condition-case`; failed calls do not return a value.

**Recovery.** A stopped Controller cannot be revived. Create a new Controller over the same source after transferring source ownership deliberately, or keep a reference to the Controller for the lifetime of its owner.

**See also.** `etaf-data-stop`, `etaf-data-controller`.

| Failure | What remains |
| --- | --- |
| A synchronous load fails | The condition is recorded and re-signaled; items and total keep their previous values |
| An asynchronous load fails | The condition is recorded in the error ref; items and total keep their previous values |
| A reload is running | Status `refreshing`; the previously accepted items stay readable |
| A cancellation ends a load | Status `cancelled`; items stay readable, and another load may start |
| A write is pending | Status `loading` and an `external-unknown` outcome; a second write is rejected |
| A committed write | One reconciliation load settles the page and the outcome becomes `committed` |
| A write fails or is cancelled | The outcome keeps `external-unknown` certainty; no rollback is assumed |
| The Controller is stopped | All operations signal `etaf-data-stopped-error`; the source's `:dispose` has run |
