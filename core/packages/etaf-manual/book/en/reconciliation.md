# Reconciliation

A write and the page it changes are two separate facts. After a committed mutation a Data Controller loads the current page again, so the displayed data agrees with what the provider committed; when the provider cannot say whether the write took effect, no rollback may be assumed and the outcome stays uncertain. This chapter defines the outcome envelope, the five reconciliation states, the retry that reloads a committed write without replaying it, and what remains known after cancellation or timeout. [Data Controllers](data-controllers.md) defines the mutation calls and their statuses; [Asynchronous Model](async.md) defines the cancellation and timeout conditions.

## The outcome envelope

<!-- index: mutation outcome; certainty; external-unknown; reconciliation token -->

#### Function: etaf-data-mutation-outcome (controller)

Return a copy of CONTROLLER's latest mutation outcome envelope.

**Arguments.** CONTROLLER is a live Controller.

**Semantics.** The reader returns a fresh tree, so inspecting or editing it cannot change the Controller. With no mutation yet the value is nil. Every write publishes an envelope while it is pending: `:pending-p` is non-nil and `:certainty` is `external-unknown` until the provider answers. A completed envelope carries `:certainty`, the raw mutation result, the condition when the write failed, the operation and its id, and an opaque reconciliation token. A failed batch additionally carries the completed prefix under `:results`. The envelope is a reactive value: reading it in a View or an effect follows mutation changes. Callers treat the token as opaque and do not write the envelope.

**Returns.** A deep copy of the latest outcome envelope, or nil before any write.

**Errors.** `error→ etaf-data-stopped-error` when CONTROLLER has been stopped; `error→ wrong-type-argument` when it is not a Controller.

The three certainties answer one question: does the provider know what happened to the write?

| `:certainty` | Meaning |
| --- | --- |
| `committed` | The write took effect. A v1 callback's normal return means this; a v2 outcome states it explicitly |
| `rolled-back` | The provider explicitly reports that the write did not take effect |
| `external-unknown` | The outcome cannot be determined: a rejection, cancellation, timeout or unclassified v2 result |

A committed write starts one reconciliation load of the current query and page. The outcome envelope is updated with the settled token; a rejected, cancelled or timed-out write is published as a failure, and its certainty stays `external-unknown` unless the provider had already reported a committed result.

## The five reconciliation states

<!-- index: reconciliation-pending; reconciled; reconciliation-error; rolled-back; external-unknown -->

#### Function: etaf-data-reconciliation-state (controller)

Return CONTROLLER's current reconciliation state symbol, if any.

**Arguments.** CONTROLLER is a live Controller.

**Semantics.** The state describes the last write that produced an outcome. A pending write has no state yet — its envelope still carries `:pending-p` — and a Controller that has never written returns nil. The state machine has five symbols:

| State | Meaning |
| --- | --- |
| `reconciliation-pending` | A committed write is waiting for its refresh to finish |
| `reconciled` | The refresh succeeded and the page reflects the committed write |
| `reconciliation-error` | The refresh failed; the write stays committed and may be retried as a read |
| `rolled-back` | The provider reported that the write did not take effect |
| `external-unknown` | The write's effect cannot be determined |

A committed write enters `reconciliation-pending` and leaves it for `reconciled` or `reconciliation-error`; retrying a failed refresh keeps `reconciliation-error` until one succeeds. A rolled-back outcome reports `rolled-back`, and every uncertain outcome, including a cancelled or timed-out write, reports `external-unknown`.

**Returns.** The state symbol, or nil when no write has produced an outcome.

**Errors.** `error→ etaf-data-stopped-error` when CONTROLLER has been stopped; `error→ wrong-type-argument` when it is not a Controller.

## Retrying a committed write

<!-- index: retry; reconciliation error; no write replay -->

#### Function: etaf-data-retry-reconciliation (controller)

Reload a committed mutation without replaying its source mutation.

**Arguments.** CONTROLLER is a live Controller.

**Semantics.** The operation is allowed only for a committed outcome whose reconciliation state is `reconciliation-pending` or `reconciliation-error`; unknown and rolled-back outcomes are deliberately not retried, because reloading cannot settle them. The retry starts a load of the current page and returns its synchronous result, or nil while asynchronous work is pending or when no retry is eligible. It never calls the source's mutation capability again, so retrying is safe for a write that may already be committed. Observe `etaf-data-status` and `etaf-data-reconciliation-state` to distinguish a completed retry from a pending one; a successful retry ends in `reconciled`. Nothing retries automatically.

**Returns.** The synchronous loaded page, or nil while pending or ineligible.

**Errors.** `error→ etaf-data-stopped-error` when CONTROLLER has been stopped; `error→ wrong-type-argument` when it is not a Controller.

**See also.** `etaf-data-mutate`, `etaf-data-reconciliation-state`.

## Uncertain external results

<!-- index: recovery; cancelled write; timeout; rollback -->

A rejection, a cancellation, a timeout and an unclassified v2 result all leave the write's effect undetermined, and none of them certifies a rollback: the provider may have committed the write before the answer was lost. The safe recovery is a read, not a replay — reload the page or retry reconciliation for a committed write — and the application decides when that read is worth doing. Only the provider's explicit `rolled-back` outcome means the write did not take effect. Cancelling the refresh that follows a committed write never changes that known result, and a cancelled write stays `external-unknown`.

| Failure | What remains |
| --- | --- |
| A committed write's refresh fails | The write stays `committed`; state `reconciliation-error`; `etaf-data-retry-reconciliation` may run the read again |
| A committed write's refresh succeeds | State `reconciled`; the page reflects the write |
| The provider reports `rolled-back` | Outcome and state `rolled-back`; the write is not retried |
| A write is rejected, cancelled or times out | Outcome and state `external-unknown`; a read may settle the page, but the write is not replayed |
| A batch fails partway | The completed prefix is under `:results`; certainty stays `external-unknown` |
| The Controller is stopped | Outcomes become unreadable: readers signal `etaf-data-stopped-error` |
