# Performance Engineering

The framework keeps a small timing contract: a Runtime can emit one flat report for each stage of an operation it performs, and an observer receives those reports. Performance engineering is what consumes that contract — the optional recorder in `etaf-performance-*`, which turns reports into retained operation records and portable reports, and the workspace's scenario and budget tools, which measure end-to-end work through a mounted application. This chapter defines the recorder's public interface, describes what a recorded operation contains, and states the measurement and diagnosis rules that make a number trustworthy. It adds nothing to the rendering path: when no observer is attached, operations run directly and the recorder is not loaded into any decision.

## The recorder and the report model

<!-- index: operation; stage; report; observer contract -->

Three levels describe one measurement. An *operation* is one bounded unit of runtime work, opened with a kind and a label and closed when the work finishes; a Runtime runs at most one operation at a time, and a nested call joins the open one instead of opening a second. A *stage* is one provider report emitted inside an operation — the Runtime's own timings, and, when the work wrote a buffer, the Ebox flush report that describes the write. A *report* is the retained, portable view of completed operations: immutable operation records plus an environment snapshot, a summary and a machine-readable operation list.

The recorder does not time anything itself. The Runtime and its providers time their own stages and emit flat plists; the recorder validates nothing that arrives through the prepared observer port, collates the reports of one operation, and keeps the closed operation in a bounded ring. That division is why enabling recording changes what you see, not what the framework does.

Attaching the recorder is explicit and per Runtime. A Runtime accepts one observer; `etaf-performance-start` claims it, `etaf-performance-stop` releases it, and a Runtime owned by a different observer is not silently taken over. The mode `etaf-performance-mode` is the convenience wrapper: it attaches the recorder to the Runtime of the current buffer and detaches it when turned off.

## The recorder lifecycle

<!-- index: recorder lifecycle; retention bound -->

#### Function: etaf-performance-mode (&optional arg)

Record operations for the Runtime mounted in the current buffer.

**Arguments.** ARG follows the minor-mode convention: nil or omitted enables the mode, a positive number enables it, zero or a negative number disables it, and `toggle` flips it.

**Semantics.** Enabling looks up the buffer's mounted Runtime and attaches the recorder through `etaf-performance-start`; if the buffer has no Runtime the mode stays off and the command reports it. Disabling detaches the attachment this mode created. The variable `etaf-performance-mode` reports the state, and the mode line shows `ETAF-Perf` while recording.

**Returns.** The mode variable.

**Errors.** error→ `user-error` `"Current buffer has no mounted ETAF runtime"` when enabling in a buffer without one. An attachment failure such as a foreign observer propagates its own condition and leaves the mode off.

**See also.** `etaf-performance-start`, `etaf-performance-stop`.

#### Function: etaf-performance-start (runtime)

Attach the recorder to mounted RUNTIME and return RUNTIME.

**Arguments.** RUNTIME is a mounted Runtime.

**Semantics.** Attachment is idempotent for this recorder: calling it again while this recorder owns the Runtime keeps the same attachment and pending operations. A Runtime already owned by a different observer is rejected rather than replaced, so two recorders never split one Runtime's reports. Unfinished operations whose later stages never arrive are discarded when the attachment ends.

**Returns.** RUNTIME.

**Errors.** error→ `etaf-runtime-error` when RUNTIME is not mounted. error→ `error` `"ETAF runtime already has a different observer"` when another observer owns it.

**Example.**

```elisp
(let* ((buffer (etaf-mount "*work*" view))
       (runtime (etaf-runtime-for-buffer buffer)))
  (etaf-performance-start runtime)
  (etaf-performance-with-operation (runtime 'refresh "reload")
    (etaf-set-value count 1)))
```

**See also.** `etaf-performance-stop`, `etaf-performance-mode`.

#### Function: etaf-performance-stop (runtime)

Detach this recorder from RUNTIME and return RUNTIME.

**Arguments.** RUNTIME is a Runtime.

**Semantics.** The recorder's attachment, its pending operations and the ownership of the observer are released together. If another observer already replaced the recorder's sink, that observer is left intact and only the recorder's bookkeeping is discarded. Stopping a Runtime the recorder never attached is a no-op.

**Returns.** RUNTIME.

**Errors.** error→ `wrong-type-argument` `(etaf-runtime-p X)` when RUNTIME is not a Runtime object.

**See also.** `etaf-performance-start`.

#### Function: etaf-performance-clear ()

Clear completed and unfinished performance records.

**Semantics.** Every retained operation and every pending operation is dropped. If the performance panel is open, it is reverted so it shows the empty set. The recorder's attachments are untouched: recording continues after a clear.

**Returns.** Nil.

**See also.** `etaf-performance-records`, `etaf-performance-show`.

#### Variable: etaf-performance-max-records

Maximum completed operations retained by the recorder.

**Semantics.** The default is 200. The recorder keeps a ring of this size, so the oldest completed operation is dropped when the bound is exceeded; lowering the value rebuilds the ring around the newest records the next time an operation completes. Zero stops retention: the next completion drops the retained set and keeps nothing. The bound covers completed operations only; an operation still in flight is not counted.

**See also.** `etaf-performance-records`, `etaf-performance-clear`.

## Running an operation

<!-- index: operation boundary; nesting -->

#### Macro: etaf-performance-with-operation ((runtime kind label) &rest body)

Evaluate BODY through RUNTIME's canonical operation boundary.

**Arguments.** RUNTIME is a mounted Runtime, KIND is an operation symbol and LABEL is a descriptive string. BODY is the work.

**Semantics.** The macro opens one operation, evaluates BODY and closes the operation with the body's status. A nested `etaf-performance-with-operation` on the same Runtime joins the open operation instead of opening a second, and a nested call on another Runtime is not observed by this one. The operation's reports are emitted only while the recorder owns the Runtime's observer.

**Returns.** The value of BODY.

**Errors.** Errors and quits from BODY are recorded as the operation's status, then re-signaled unchanged; the operation still closes.

**Example.** A refresh that writes a ref and reads back the recorded stage durations.

```elisp
(etaf-performance-with-operation (runtime 'refresh "reload")
  (etaf-set-value query "etaf"))
```

**See also.** `etaf-performance-call-operation`, `etaf-performance-records`.

#### Function: etaf-performance-call-operation (runtime kind label function)

Call FUNCTION as KIND and LABEL through RUNTIME's operation boundary.

**Arguments.** RUNTIME is a mounted Runtime, KIND is an operation symbol, LABEL is a string and FUNCTION is a zero-argument function.

**Semantics.** The function form of `etaf-performance-with-operation`, for a callback that must be passed as a function rather than written in place.

**Returns.** FUNCTION's result.

**Errors.** error→ `etaf-runtime-error` `"ETAF runtime is not mounted"` when RUNTIME is not mounted. error→ `wrong-type-argument` `(symbolp KIND)`, `(stringp LABEL)` or `(functionp FUNCTION)` for the wrong argument types. FUNCTION's own errors are recorded and re-signaled.

**See also.** `etaf-performance-with-operation`.

## The operation record

<!-- index: operation record; elapsed; garbage collection -->

#### Function: etaf-performance-operation-p (x)

Return non-nil when X is a completed operation record.

**Semantics.** Use it to check a value from a collection before reading slots from it; the slot readers otherwise signal `wrong-type-argument`.

**Returns.** Non-nil for an operation record, nil for anything else.

**See also.** `etaf-performance-records`.

#### Function: etaf-performance-operation-id (x)

Access slot "id" of `etaf-performance-operation' struct X.

**Semantics.** The identity is an integer, unique within its Runtime and increasing in call order. A nested call reports the enclosing operation's identity.

**Returns.** The integer identity.

**Errors.** error→ `wrong-type-argument` `(etaf-performance-operation X)` for another value.

**See also.** `etaf-performance-operation-kind`, `etaf-performance-operation-label`.

#### Function: etaf-performance-operation-runtime-id (x)

Access slot "runtime-id" of `etaf-performance-operation' struct X.

**Semantics.** The value is the integer observer report identity of the Runtime that produced the record, the identity `etaf-performance-records` filters by and a portable report carries as `:runtime-id`. It stays stable while the Runtime lives and still identifies historical records after its buffer name is reused or the Runtime is unmounted.

**Returns.** The integer report identity.

**Errors.** error→ `wrong-type-argument` `(etaf-performance-operation X)` for another value.

**See also.** `etaf-performance-records`, `etaf-performance-operation-id`.

#### Function: etaf-performance-operation-kind (x)

Access slot "kind" of `etaf-performance-operation' struct X.

**Semantics.** The kind is the symbol the caller passed to the operation boundary, such as `refresh`, `event` or a package-defined name. Grouping by kind is what `etaf-performance-summary` does.

**Returns.** The operation symbol.

**Errors.** error→ `wrong-type-argument` `(etaf-performance-operation X)` for another value.

**See also.** `etaf-performance-operation-label`, `etaf-performance-summary`.

#### Function: etaf-performance-operation-label (x)

Access slot "label" of `etaf-performance-operation' struct X.

**Semantics.** The label is the descriptive string the caller passed; it complements the kind, for example kind `refresh` with label `"reload"`. The recorder keeps a defensive copy.

**Returns.** The label string.

**Errors.** error→ `wrong-type-argument` `(etaf-performance-operation X)` for another value.

**See also.** `etaf-performance-operation-kind`.

#### Function: etaf-performance-operation-status (x)

Access slot "status" of `etaf-performance-operation' struct X.

**Semantics.** One of `success` (the work returned normally), `error` (it signaled) and `quit` (it was interrupted). The status describes the operation's own outcome, not the state of the buffer, which the revision slots in the portable report describe.

**Returns.** One of the three status symbols.

**Errors.** error→ `wrong-type-argument` `(etaf-performance-operation X)` for another value.

**See also.** `etaf-performance-report-data`.

#### Function: etaf-performance-operation-elapsed (x)

Access slot "elapsed" of `etaf-performance-operation' struct X.

**Semantics.** The wall-clock duration of the whole operation in milliseconds, measured from opening to closing. It includes the time of the stages inside it; it is not the sum of their durations, because stage durations may overlap.

**Returns.** A non-negative float in milliseconds.

**Errors.** error→ `wrong-type-argument` `(etaf-performance-operation X)` for another value.

**See also.** `etaf-performance-operation-gc-elapsed`, `etaf-performance-operation-stage-summary`.

#### Function: etaf-performance-operation-gc-count (x)

Access slot "gc-count" of `etaf-performance-operation' struct X.

**Semantics.** How many garbage collections ran during the operation. A high count with a moderate elapsed time points at allocation pressure rather than at slow code.

**Returns.** A non-negative integer.

**Errors.** error→ `wrong-type-argument` `(etaf-performance-operation X)` for another value.

**See also.** `etaf-performance-operation-gc-elapsed`.

#### Function: etaf-performance-operation-gc-elapsed (x)

Access slot "gc-elapsed" of `etaf-performance-operation' struct X.

**Semantics.** The time spent in those garbage collections, in milliseconds. The operation's own elapsed time includes it.

**Returns.** A non-negative float in milliseconds.

**Errors.** error→ `wrong-type-argument` `(etaf-performance-operation X)` for another value.

**See also.** `etaf-performance-operation-gc-count`.

#### Function: etaf-performance-operation-stages (x)

Access slot "stages" of `etaf-performance-operation' struct X.

**Semantics.** The flat provider reports of the operation, in the sequence they were emitted: the Runtime's own stages and the buffer-flush reports of the providers that wrote during it. The list is a defensive copy; changing it does not change the retained record.

**Returns.** A list of stage records.

**Errors.** error→ `wrong-type-argument` `(etaf-performance-operation X)` for another value.

**See also.** `etaf-performance-stage-name`, `etaf-performance-operation-stage-summary`.

#### Function: etaf-performance-operation-stage-summary (operation)

Summarize flat provider stages in OPERATION by category.

**Semantics.** Each result contains `:category`, `:count` and `:duration-ms`, sorted by summed duration from largest to smallest. The duration is a sum of provider durations that may overlap, so it ranks categories but is never exclusive time; read the operation's elapsed time for the whole.

**Returns.** A list of `(:category :count :duration-ms)` plists.

**Errors.** error→ `wrong-type-argument` `(etaf-performance-operation-p OPERATION)` when OPERATION is not an operation record.

**Example.** After a ref write inside an operation, the summary of the operation above is a runtime category with one stage and an ebox category with one stage, ebox first when its flush was longer.

**See also.** `etaf-performance-stage-category`, `etaf-performance-summary`.

## The stage record

<!-- index: stage record; provider; category -->

#### Function: etaf-performance-stage-name (x)

Access slot "name" of `etaf-performance-stage' struct X.

**Semantics.** The stage name the provider reported, such as `runtime-operation` for the Runtime's closing stage or `flush` for an Ebox buffer write.

**Returns.** A symbol.

**Errors.** error→ `wrong-type-argument` `(etaf-performance-stage X)` for another value.

**See also.** `etaf-performance-stage-provider`.

#### Function: etaf-performance-stage-provider (x)

Access slot "provider" of `etaf-performance-stage' struct X.

**Semantics.** The symbol naming the layer that emitted the report, such as `etaf` or `ebox`. The provider tells you where to look for the owner of a cost.

**Returns.** A symbol.

**Errors.** error→ `wrong-type-argument` `(etaf-performance-stage X)` for another value.

**See also.** `etaf-performance-stage-category`.

#### Function: etaf-performance-stage-category (x)

Access slot "category" of `etaf-performance-stage' struct X.

**Semantics.** The public grouping used by summaries: a report from the ETAF Runtime itself becomes `runtime`, and every other provider keeps its own name, so `flush` reports group under `ebox`. The category is what you trend; the provider is what you name.

**Returns.** A symbol.

**Errors.** error→ `wrong-type-argument` `(etaf-performance-stage X)` for another value.

**See also.** `etaf-performance-operation-stage-summary`.

#### Function: etaf-performance-stage-status (x)

Access slot "status" of `etaf-performance-stage' struct X.

**Semantics.** One of `success`, `error` and `quit`, or nil when the provider does not report one. A missing status means the provider considered the stage normal.

**Returns.** A status symbol or nil.

**Errors.** error→ `wrong-type-argument` `(etaf-performance-stage X)` for another value.

**See also.** `etaf-performance-operation-status`.

#### Function: etaf-performance-stage-duration (x)

Access slot "duration" of `etaf-performance-stage' struct X.

**Semantics.** The stage's own duration in milliseconds, measured by its provider. Provider durations may overlap across stages, so they are compared individually or grouped by category, never summed into an exclusive total.

**Returns.** A non-negative float in milliseconds.

**Errors.** error→ `wrong-type-argument` `(etaf-performance-stage X)` for another value.

**See also.** `etaf-performance-stage-metadata`.

#### Function: etaf-performance-stage-metadata (x)

Access slot "metadata" of `etaf-performance-stage' struct X.

**Semantics.** The provider-specific fields of the report that the typed stage fields do not represent. An Ebox flush stage carries the update report's strategy, edits, lines, ranges and flush counter here, so the recorder gives the same detail as `ebox-buffer-update-report` without a second collection path. The value is a defensive copy, and it may contain any value the provider reported.

**Returns.** A plist, possibly empty.

**Errors.** error→ `wrong-type-argument` `(etaf-performance-stage X)` for another value.

**See also.** `etaf-performance-stage-duration`, `ebox-buffer-update-report`.

## Records, summaries and reports

<!-- index: portable report; summary; export -->

#### Function: etaf-performance-records (&optional runtime-id)

Return newest-first immutable snapshots of completed records. When RUNTIME-ID is non-nil, select only that integer observer report identity, available as `etaf-performance-operation-runtime-id` and as the `:runtime-id` of a portable report. This also selects historical records after unmount or reuse of a buffer name. Omitted or nil RUNTIME-ID selects all retained records.

**Arguments.** RUNTIME-ID is an integer identity or nil.

**Semantics.** Each record is an isolated copy of the retained operation, so a caller may keep, print or mutate it without affecting the recorder; the newest completed operation comes first. The identity is the Runtime's mount identity, which the portable report data carries for each operation; filtering by it is how a caller follows one Runtime across a buffer name that is reused later. Because records survive unmount, this is also the collection to read after a Runtime is disposed.

**Returns.** A list of operation records, newest first.

**Errors.** error→ `wrong-type-argument` `(integerp RUNTIME-ID)` for a non-integer, non-nil argument.

**Example.** A test asserts that one recorded operation is present after attaching the recorder and running one operation.

```elisp
(etaf-performance-with-operation (runtime 'demo "work") 42)
(etaf-performance-operation-kind (car (etaf-performance-records)))
     ⇒ demo
```

**See also.** `etaf-performance-report-data`, `etaf-performance-max-records`.

#### Function: etaf-performance-report-data (&optional (records (etaf-performance-records)))

Return a detached portable report for completed RECORDS. Omitted RECORDS selects retained records; explicit nil selects none. The versioned plist includes :format-version, :environment, :summary and :operations. Operations identify :id, :runtime-id and :buffer-name and contain flat :stages with :provider, :stage, :duration-ms and provider :metadata. Nested provider durations may overlap. This read-only operation does not clear recordings, install observers, change the Runtime or invoke recorded application code.

**Arguments.** RECORDS is a list of operation records, or nil for an empty report.

**Semantics.** The report is the exchange format: it is detached from the recorder, versioned with `:format-version` (currently 2), and ordered oldest first so a reader can replay a session in time order. Each operation also carries its revision before and after, its elapsed, status, GC counts and the stage summary; each stage carries its flat provider fields. Omitted RECORDS is not the same as explicit nil: omission reports everything retained, nil reports an empty operation list with the environment and an empty summary.

**Returns.** A plist with `:format-version`, `:generated-at`, `:environment`, `:summary` and `:operations`.

**See also.** `etaf-performance-summary`, `etaf-performance-environment-data`, `etaf-performance-export`.

#### Function: etaf-performance-summary (&optional (records (etaf-performance-records)))

Summarize completed RECORDS by operation kind and label. Omitted RECORDS selects all retained records; explicit nil selects none.

**Arguments.** RECORDS is a list of operation records.

**Semantics.** Each group is one kind and label pair, and each result contains `:count`, `:min-ms`, `:p50-ms`, `:p95-ms`, `:max-ms` and `:mean-ms`, sorted by p95 from largest to smallest. Percentiles are nearest-rank over the group's elapsed times, so a small sample reports an actual observation rather than an interpolation. The summary describes the *operations* — whole-request latency; use `etaf-performance-operation-stage-summary` for where the time went inside one.

**Returns.** A list of summary plists, or nil when there is nothing to summarize.

**Errors.** error→ `wrong-type-argument` when RECORDS is neither nil nor a list of operation records.

**See also.** `etaf-performance-report-data`, `etaf-performance-operation-stage-summary`.

#### Function: etaf-performance-copy-report ()

Copy all retained performance records to the kill ring.

**Semantics.** The command writes the same readable `;; ETAF performance report` text `etaf-performance-export` writes, then puts it on the kill ring and reports the operation count in the echo area. It is the interactive way to paste a report into a message or an issue.

**Returns.** The report string.

**See also.** `etaf-performance-export`, `etaf-performance-show`.

#### Function: etaf-performance-export (file)

Export all retained performance records to FILE.

**Arguments.** FILE is the target path. Interactively it is read from the minibuffer with a timestamped `.eld` name suggested.

**Semantics.** The file receives the same readable report text as `etaf-performance-copy-report`, written as a complete Elisp datum. An existing file is refused instead of overwritten, so an export never destroys an earlier measurement; the echo area reports the operation count and the abbreviated path.

**Returns.** FILE.

**Errors.** error→ `file-already-exists` `("File exists" FILE)` when FILE already exists. error→ `file-error` for an unwritable path or directory.

**See also.** `etaf-performance-copy-report`, `etaf-performance-report-data`.

#### Function: etaf-performance-show ()

Show retained ETAF operations and stages in a tabulated panel.

**Semantics.** The panel lists one row per operation followed by one row per stage, with identity, type, name, category, provider, sequence, duration and status columns; its header line repeats the environment snapshot so a screenshot carries its own context. In the panel, `c` runs `etaf-performance-copy-report` and `w` runs `etaf-performance-export`. Reopening the command reuses the panel buffer.

**Returns.** Nil; the panel is displayed with `pop-to-buffer`.

**See also.** `etaf-performance-copy-report`, `etaf-performance-export`, `etaf-performance-clear`.

#### Function: etaf-performance-environment-data ()

Return the environment snapshot used to interpret latency records.

**Semantics.** The snapshot is taken when a report is built, not when an operation ran, and it records the facts that make two measurements comparable or not: the Emacs version, the system type, the window system and whether the frame is graphical, the frame and window pixel sizes, the GC thresholds and percentage, the native-compilation setting, the load average, and the local power state. The power state reports the active source (`battery`, `ac` or `unknown`) and whether the system's low-power mode is on, off or unknown; on systems where that cannot be read, both are `unknown`, which is a statement about the measurement, not an error.

**Returns.** A plist with those keys.

**See also.** `etaf-performance-report-data`.

## The Ebox flush report

<!-- index: flush stage; update report -->

When an operation writes a buffer, the Runtime's provider path forwards Ebox's flush report as a stage named `flush` with the provider and category `ebox`. Its duration is the measured flush time and its metadata is the flush report: strategy, edited range count, line count, ranges and flush counter — the same information `ebox-buffer-update-report` returns and `ebox-buffer-set-observer` delivers. The recorder therefore shows per-operation cost at two levels at once: the operation's whole elapsed time, and the flush among its stages.

That stage is also how you connect a slow update to the damage that caused it. A flush whose `:lines` and `:ranges` are large did real work; a flush with one edit and a long duration points at a heavy layout or paint boundary rather than at a wide write. [Incremental Updates and Publication](incremental-updates-and-publication.md) defines the report fields, and [Tracing One Update](update-trace.md) follows the commit that produces the flush.

## Scenarios and budgets

<!-- index: performance scenario; baseline; budget -->

The recorder answers "where did this operation spend its time". The workspace's scenario tool answers "did this change make the application slower", and it is the maintained way to measure: `make perf-list` lists the scenarios packages register in `benchmarks/performance-scenarios.el`, and `scripts/performance.py run` executes one in batch or GUI mode with latency, trace, CPU and allocation passes and optional diagnosis. `python3 scripts/performance.py gate` runs the quick per-change check inside a GUI server against fixed budgets, `compare` and `summarize` inspect saved evidence, and `make verify-baseline` followed by `make verify BASELINE=…` produces and checks the batch performance gate; a final acceptance claim uses three independent sample sets.

Two rules keep the numbers meaningful. Measure the same scenario before and after a change, on the same checkout state, and treat a run whose evidence is invalid or incomplete as unverified rather than passing. And separate batch measurement from GUI measurement: batch runs approximate operation and CPU cost, while real rendering and input latency must be measured in a GUI session, because only there do redisplay and input scheduling participate.

## Diagnosis

<!-- index: dominant cost; overlap; evidence -->

A diagnosis starts from a recorded operation, not from a theory. Attach the recorder to the Runtime that is slow, exercise the exact interaction, and read `etaf-performance-show` or the operation's stage summary; the largest category is the first candidate. Then narrow it: an `ebox` flush stage with large ranges is a layout or damage problem, an `etaf` runtime stage with little Ebox time is application or reactive bookkeeping, and a high GC count with a short elapsed time points at allocation. Provider durations may overlap, so compare categories and stages within one operation rather than summing them.

Change one thing, then measure the same scenario again and compare revisions, flush counts and the stage category you expected to move; a change that improves nothing measurable should be reverted. Keep the raw evidence outside version control and inspect the compact result before opening logs. When a single operation is not the question — a scroll, a resize, a repeated edit — use the scenario tool, because one recorded operation cannot show a distribution; and when the symptom is visual or interactive, finish in the GUI, because a batch number cannot certify appearance or input latency.

## Errors and recovery

<!-- index: recorder error; observer conflict; unmount -->

The recorder's errors are ordinary argument and state errors, and none of them corrupts what was already recorded. Reading a slot from a value of the wrong type signals `wrong-type-argument` with the operation or stage predicate and the value as data; `etaf-performance-records` rejects a non-integer filter the same way; `etaf-performance-summary` rejects a non-list collection. Attaching through `etaf-performance-start` to an unmounted Runtime signals `etaf-runtime-error`, and attaching to a Runtime another observer owns signals a plain error with `"ETAF runtime already has a different observer"` and leaves the observer in place — a recorder never steals a Runtime from another observer. Turning on the mode in a buffer without a Runtime reports `user-error` and leaves the mode off.

Unfinished operations do not leak: when an attachment stops, the operations it was still collecting are discarded, and a stop after the Runtime unmounted still releases the recorder's bookkeeping and returns the Runtime, because the observer exchange is contained. Retained records survive an unmount, so a post-mortem reads `etaf-performance-records` after the buffer is gone, while a new attachment on another Runtime starts with its own pending set. `etaf-performance-clear` drops both completed and pending records, which is the recovery step when a session collected noise. A stopped recorder leaves the Runtime's observer exactly as `etaf-performance-stop` found it, so removing recording restores the unobserved path with no residue.
