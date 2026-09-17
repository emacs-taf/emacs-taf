# Workspace performance measurements

[中文](manual.zh-CN.md)

The workspace owns one measurement driver. Packages register their maintained
workloads in `benchmarks/performance-scenarios.el`; they do not implement their
own timers, profiler collectors or baseline comparators. Package runtimes remain
ordinary dependencies of the workloads.

## Run a measured change

```sh
make perf-list
python3 scripts/performance.py run --mode batch --scenario 'ebox.focus.*' --diagnose
python3 scripts/performance.py run --mode gui --scenario gallery.review.mouse --diagnose
```

Use `--scenario` repeatedly to select a related group. `--scenario-file FILE`
loads an additional explicit workload entry; `--load-path DIR` adds a public
package root. GUI runs use the existing `emacsclient` server and normal Emacs
configuration. `--server NAME` selects an existing named server. GUI measurement
allows background operation by default and records focus before and after every
sample. Keep the rendered window available and avoid editing its test buffer.
Background timing does not certify foreground input latency. `--foreground`
activates the current frame once and requires focus during latency samples;
`--focus-policy foreground` requires focus without activating it. Diagnostic
passes always allow background execution and retain their actual focus state.
Window-scoped screenshots and recordings do not require foreground activation.

Finish compilation before GUI acceptance. Preflight records the process, package
origins and loaded files. It rejects another checkout, an active profiler, and
loaded packages edited or rebuilt after Emacs started. Restart the same native
Emacs and run `M-x server-start` to establish a fresh code generation. This is a
conservative freshness check; the tool does not hot-reload package implementations.

Defaults are three sets with ten latency samples per scenario. Batch sets use
fresh Emacs processes per scenario and set, isolating unrelated workloads' caches
and retained state; GUI sets use fresh fixtures in the same native process.
Scenarios marked `series` retain their fixture within one set and declare that
steady-state condition in the catalog. Setup is outside the timed operation.
For a quick screen, use `--sets 1 --samples 3`; it cannot certify repeatability.

Record a baseline by keeping the resulting `result.json`. Compare a change with:

```sh
python3 scripts/performance.py run --mode gui --scenario gallery.review.mouse --foreground --baseline /path/to/baseline/result.json
python3 scripts/performance.py compare /path/to/before/result.json /path/to/after/result.json
python3 scripts/performance.py summarize /path/to/result.json --scenario gallery.review.mouse --details
```

Every sample must pass the scenario's visible/semantic verification and context
checks. All slow samples, including GC, remain in the report. Each scenario has
its own maximum-latency budget and there is a separate 500 ms hard limit. A
baseline comparison checks p95 and maximum independently, with a 2 ms regression
allowance. Different workloads, drivers, sample coverage, focus/display conditions or machines
are incomparable. Changed source revisions are expected and recorded.

`passed` means the selected latency gate passed; `failed` means measured latency
or a baseline gate failed; `screened` means a smaller valid run completed;
`unverified` means evidence is missing, invalid or incomplete. Exit codes are
0 for a completed passing/screening run, 1 for a latency regression or budget
failure, and 2 for invalid evidence. A completed operation is not automatically
a performance pass. `acceptance_eligible` separately records sufficient sample
coverage. Existing `make verify` continues to run the complete batch correctness
and Research Shelf verification workflow.

## Read the diagnosis

`--diagnose` runs three additional passes after latency sampling:

| Pass | Evidence | Interpretation |
| --- | --- | --- |
| Trace | Public provider reports, update owners, projection decisions, rejected proofs and exclusive Ebox phases | Locate the expensive part of the data flow. |
| CPU | Sampled self/inclusive weights, call stacks, function names and source locations | Find candidate functions to investigate; weights are estimates, not exact per-call times. |
| Memory | Allocation weights and call stacks | Explain allocation pressure and GC; allocation is not proof of a leak. |

These diagnostic samples never enter latency statistics. CPU and allocation
profilers run separately, without the provider recorder. Low CPU sample counts
are explicitly identified; increase `--diagnostic-samples` for a targeted case.
No GC threshold is changed by the driver. Before/after GC settings are recorded
as dynamic state because the framework can temporarily change them during its
documented render burst. Font, geometry, target, backend capability and source
generation remain validation conditions.

Ebox's public observer supplies exclusive `source`, `style`, `plan`, `layout`,
`projection` and `transaction` milliseconds. Nested stages are charged to their
innermost phase. `transaction` includes remaining commit work, TP preparation,
publication and acceptance; TP's separate duration overlaps that phase. The
report also shows time outside Ebox, which can include application code, input
dispatch, asynchronous waiting and driver overhead. Medians of separate phases
need not add up to the median of whole operations.

Investigation hints identify full source preparation during state-only changes,
unexpected layout, expanded root ownership and GC. They point to evidence and
do not assert a root cause. Small applications may legitimately update a root.
Inspect the stage costs and stacks before changing architecture. Native calls
can be attributed to the Emacs/module boundary; Rust/C internals require their
native profiler. The report records the loaded module hash when a workload
provides it.

## Evidence and failure handling

Evidence defaults to `~/.cache/emacs-taf/performance/` (or `$XDG_CACHE_HOME`).
`--output-dir DIR` selects an empty directory. Existing evidence is never
overwritten. `result.json` is the compact comparison/report entry; per-set JSON,
configuration files, profiler summaries and logs preserve the complete run.
Progress records the scenario, sample and stage before setup or invocation.

`--timeout` bounds a setup/action/settlement step; `--run-timeout` bounds each
set. A timed-out batch process owned by the tool is terminated. A GUI timeout
requests cancellation through the same server and leaves Emacs running. If
Emacs itself cannot answer, the report retains the active stage; interrupt the
stuck operation with `C-g`. `python3 scripts/performance.py cancel` cancels the
current tool job. A failure preserves its partial evidence.

GUI timing ends when the explicit settlement predicate succeeds and forced
redisplay returns. It does not measure physical hardware input or OS compositor
presentation. Batch results do not certify GUI latency. Visual appearance still
requires the maintained GUI workflow and inspection of a current window capture.

## Register a scenario once

The supported registration and fixture API is documented in
[`performance-driver.el`](../benchmarks/performance-driver.el). A scenario owns
its application setup, action and verification; the shared driver owns execution.
Use only provider interfaces declared by their public entries.

```elisp
;;; -*- lexical-binding: t; -*-
(taf-benchmark-register
 "example.counter" :version 1 :modes '(batch gui) :budget-ms 10
 :impact 'local :isolation 'series :description "One visible counter update"
 :setup
 (lambda (_mode)
   (let ((buffer (generate-new-buffer " *Counter benchmark*")) (count 0))
     (list :buffer buffer
           :invoke (lambda (_sample)
                     (with-current-buffer buffer
                       (erase-buffer) (insert (number-to-string (cl-incf count)))))
           :verify (lambda ()
                     (with-current-buffer buffer
                       (equal (buffer-string) (number-to-string count))))
           :cleanup (lambda () (when (buffer-live-p buffer) (kill-buffer buffer)))))))
```

`:prepare` resolves input targets after the GUI buffer is displayed, before the
timer starts. `:ready` waits for initial loading, and `:settled` defines the
completion of asynchronous actions (5 ms polling resolution is recorded).
`:observe` accepts a report sink and returns a cleanup/collection function,
called after timing and profiling stop. `:required-providers` detects missing
expected observations. `:environment` returns JSON-safe capability facts.
Verification returns exactly `t` or a short failure string. Cleanup releases only
the fixture's resources. The final GUI fixture stays available for inspection.

Keep scenario inputs, versions and verification stable across an A/B comparison.
Register new application scenarios with their owning package and validate the
adapter; subsequent runs require only the shared command. The tool's command,
timeout, asynchronous, failure and comparison regressions run in workspace
`make check` through `tests/tools/test_performance.py`.
