#!/usr/bin/env python3
"""Run registered Emacs performance scenarios and explain reproducible evidence.

CLI: list, run, summarize, compare, cancel, gate. JSON schema 1 keeps raw
samples, verification, context, provider phases, sampled CPU/allocation stacks
and source revisions. Warmups and diagnostic samples never enter formal latency
statistics. gate runs every scenario that declares :gate back to back in a GUI
server and checks the budget classes in GATE_CLASSES.
"""
import argparse
from collections import Counter, defaultdict
from datetime import datetime, timezone
import fnmatch
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import subprocess
import sys
import tempfile
import time
import uuid

ROOT = Path(__file__).resolve().parents[1]
DRIVER = ROOT / "benchmarks/performance-driver.el"
GATE_RUNNER = ROOT / "benchmarks/performance-gate.el"
# Operation budgets in microseconds, excluding redisplay.  "rows" scales by the
# scenario's row count.  Every class with a twin also requires end-to-end time
# within GATE_TWIN_SLACK_US of the plain-buffer twin; "redisplay" classes
# compare only the time after the operation, whose own cost the row budget bounds.
GATE_CLASSES = {
    "local": {"op_p50": 50, "op_p95": 200, "cons_p50": 200, "flat": True},
    "propagate": {"op_p50": 200, "flat": True},
    "structure": {"op_p50": 300, "flat": True},
    "rows": {"op_p50_per_row": 40, "redisplay": True},
    "info": {},
}
GATE_TWIN_SLACK_US = 200
# Size independence: the largest size's op p50 may not exceed the smallest's
# by more than this factor plus slack.
GATE_FLAT_FACTOR = 1.5
GATE_FLAT_SLACK_US = 20
PHASES = ("source", "style", "plan", "layout", "projection", "transaction")
WARMUP_PROTOCOL = "recorded-before-latency-per-scenario-set-v1"
LIBRARY_CODE_PROTOCOL = "entry-lisp-examples-load-history-v1"


def read_json(path):
    def invalid_constant(value):
        raise ValueError(f"Non-finite JSON number: {value}")
    return json.loads(Path(path).read_text(encoding="utf-8"), parse_constant=invalid_constant)


def write_json(path, value):
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    temporary.replace(path)


def discover(root, extra):
    """Resolve scenario entry files and public package roots without shell code."""
    if (root / "workspace.json").is_file():
        packages = [root / name for name in read_json(root / "workspace.json")["repositories"]]
    else:
        packages = [root] + sorted(p for p in root.parent.iterdir()
                                   if p.is_dir() and (p / (p.name + ".el")).is_file() and p != root)
    entries = ([Path(p).resolve() for p in extra] if extra else
               [p / "benchmarks/performance-scenarios.el" for p in [root] + packages
                if (p / "benchmarks/performance-scenarios.el").is_file()])
    return list(dict.fromkeys(entries)), list(dict.fromkeys(packages))


def source_snapshot(packages):
    result = {}
    for package in packages:
        def git(*arguments):
            return subprocess.check_output(["git", "-C", str(package), *arguments], stderr=subprocess.DEVNULL)
        try:
            digest = hashlib.sha256(git("diff", "--binary", "HEAD"))
            for relative in git("ls-files", "--others", "--exclude-standard", "-z").split(b"\0"):
                if relative:
                    file = package / os.fsdecode(relative)
                    digest.update(relative)
                    digest.update(os.fsencode(os.readlink(file)) if file.is_symlink() else file.read_bytes())
            result[package.name] = {
                "path": str(package), "revision": git("rev-parse", "HEAD").decode().strip(),
                "status": git("status", "--porcelain").decode(),
                "change_digest": digest.hexdigest(),
            }
        except (OSError, subprocess.CalledProcessError):
            result[package.name] = jj_source_snapshot(package)
    return result


def jj_source_snapshot(package):
    """Describe an index-less jj workspace like its colocated Git HEAD view."""
    def jj(*arguments):
        return subprocess.check_output(["jj", "--no-pager", *arguments], cwd=package,
                                       stderr=subprocess.DEVNULL)
    try:
        if not (package / ".jj").is_dir():
            raise OSError("no jj workspace")
        return {"path": str(package),
                "revision": jj("log", "--no-graph", "-r", "@-", "-T", "commit_id").decode().strip(),
                "status": jj("diff", "-r", "@", "--summary").decode(),
                "change_digest": hashlib.sha256(jj("diff", "-r", "@", "--git")).hexdigest()}
    except (OSError, subprocess.CalledProcessError):
        return {"path": str(package), "revision": None}


def form(function, configuration):
    return ("(progn (when (and (fboundp 'taf-benchmark-running-p) (taf-benchmark-running-p)) "
            '(error "A performance job is already running")) '
            f"(load {json.dumps(str(DRIVER), ensure_ascii=False)} nil t t) "
            f"({function} {json.dumps(str(configuration), ensure_ascii=False)}))")


def client_command(args, expression):
    return [args.emacsclient, *(["-s", args.server] if getattr(args, "server", None) else []), "--eval", expression]


def native_preflight(args, paths, directory):
    """Reject unknown live code generations; never hot-reload or create Emacs."""
    output = directory / "native-preflight.json"
    configuration = directory / "native-preflight-configuration.json"
    write_json(configuration, {"output": str(output), "mode": "gui", "code_roots": list(map(str, paths))})
    process = subprocess.run(client_command(args, form("taf-benchmark-probe", configuration)),
                             capture_output=True, text=True, timeout=15)
    (directory / "native-preflight.log").write_text(process.stdout + process.stderr, encoding="utf-8")
    if process.returncode or not output.exists():
        raise ValueError("Existing Emacs server is unavailable; start its server with M-x server-start")
    probe = read_json(output)
    environment = probe["environment"]
    if not environment.get("graphic") or probe.get("running") or probe.get("profiler_active"):
        raise ValueError("GUI preflight requires a graphical frame and no existing benchmark or profiler")
    for library in probe.get("libraries", []):
        if library["loaded"] and (not library.get("file") or not Path(library["file"]).resolve().is_relative_to(Path(library["root"]).resolve())):
            raise ValueError(f"Loaded {library['feature']} comes from {library.get('file')}, "
                             f"outside the selected checkout {library['root']}")
    started = environment["emacs_start"]
    loaded = [Path(path).resolve() for path in probe.get("loaded_files", [])]
    stale = []
    for root in paths:
        root = root.resolve()
        if not any(file.is_relative_to(root) for file in loaded):
            continue
        candidates = list(root.glob("*.el")) + list(root.glob("*.elc"))
        for directory_name in ("lisp", "examples"):
            candidates.extend((root / directory_name).glob("*.el"))
            candidates.extend((root / directory_name).glob("*.elc"))
        stale.extend(str(file) for file in candidates if file.stat().st_mtime > started)
    probe["stale_code_files"] = stale
    write_json(output, probe)
    if stale:
        raise ValueError(f"Loaded packages were edited or rebuilt after this Emacs started ({len(stale)} files). "
                         "Finish compilation, restart the same native Emacs and run M-x server-start; "
                         f"see {output}")
    return probe


def catalog(args, entries, paths, directory):
    output = directory / "catalog.json"
    configuration = directory / "catalog-configuration.json"
    write_json(configuration, {"output": str(output), "scenario_files": list(map(str, entries)),
                               "load_paths": list(map(str, paths)), "code_roots": list(map(str, paths))})
    command = [args.emacs, "-Q", "--batch", "--eval", "(setq load-prefer-newer t native-comp-jit-compilation nil)",
               "--eval", form("taf-benchmark-catalog", configuration)]
    result = subprocess.run(command, capture_output=True, text=True, timeout=60)
    (directory / "catalog.log").write_text(result.stdout + result.stderr, encoding="utf-8")
    if result.returncode or not output.exists():
        raise ValueError(f"Scenario catalog failed; see {directory / 'catalog.log'}")
    return read_json(output)


def percentile(values, fraction):
    ordered = sorted(values)
    return ordered[max(0, math.ceil(len(ordered) * fraction) - 1)]


def finite_nonnegative(value):
    return isinstance(value, (float, int)) and not isinstance(value, bool) and math.isfinite(value) and value >= 0


def library_code_strategy(libraries):
    """Normalize execution format without equating versions' module inventories."""
    if not isinstance(libraries, list) or any(
            not isinstance(row, dict) or row.get("format") not in ("source", "compiled", "native")
            or not all(isinstance(row.get(key), str) and row[key] for key in ("package", "library", "file", "origin"))
            for row in libraries):
        return "unknown"
    formats = {row["format"] for row in libraries}
    if not formats:
        return "not-applicable"
    if formats == {"source"}:
        return "interpreted"
    return "mixed" if "source" in formats else "compiled"


def valid_sample(sample, mode, require_foreground=False):
    if not isinstance(sample, dict):
        return False
    if not all(finite_nonnegative(sample.get(key)) for key in ("wall_ms", "action_ms", "settle_ms", "gc_ms", "setup_ms")):
        return False
    if not (sample.get("correct") is True and sample.get("environment_stable") is True):
        return False
    if sample.get("action_ms", 0) > sample["wall_ms"] + .01 or sample.get("gc_ms", 0) > sample["wall_ms"] + .1:
        return False
    if not isinstance(sample.get("allocations"), list) or not sample["allocations"]:
        return False
    if not all(finite_nonnegative(value) for value in sample["allocations"]):
        return False
    before, after = sample.get("before"), sample.get("after")
    required = ("pid", "emacs", "system", "buffer", "graphic", "font", "width", "height", "frame", "window")
    if not isinstance(before, dict) or not isinstance(after, dict):
        return False
    strategy = library_code_strategy(before.get("runtime_libraries"))
    if strategy in ("mixed", "unknown") or strategy != library_code_strategy(after.get("runtime_libraries")):
        return False
    disposing = (before.get("dispose_buffer") is True and after.get("dispose_buffer") is True
                 and sample.get("target_disposed") is True
                 and isinstance(before.get("buffer"), str) and after.get("buffer") is None)
    if before.get("dispose_buffer", False) != after.get("dispose_buffer", False):
        return False
    if before.get("dispose_buffer") is True and not disposing:
        return False
    if any(key not in before or key not in after or
           (before[key] != after[key] and not (disposing and key == "buffer")) for key in required):
        return False
    if before.get("context") != after.get("context") or before.get("text_scale") != after.get("text_scale"):
        return False
    if sample.get("diagnostic_kind") == "trace":
        seen = {report.get("provider") for report in sample.get("reports", [])}
        if not set(sample.get("required_providers", [])).issubset(seen):
            return False
        total = 0.0
        for report in sample.get("reports", []):
            phases = report.get("phases", [])
            if report.get("provider") == "ebox" and phases:
                values = [phase.get("ms") for phase in phases]
                if not all(finite_nonnegative(value) for value in values):
                    return False
                if not finite_nonnegative(report.get("ms")) or abs(sum(values) - report["ms"]) > .1:
                    return False
                total += sum(values)
        if total > sample["wall_ms"] + .1:
            return False
    if not all(isinstance(context.get("foreground"), bool) for context in (before, after)):
        return False
    return mode != "gui" or (before.get("graphic") is True and after.get("graphic") is True
                             and (not require_foreground or
                                  (before["foreground"] is True and after["foreground"] is True)))


def stable_context(context):
    """Native code may change between revisions; backend availability may not."""
    if isinstance(context, dict):
        return {key: value for key, value in context.items() if key not in ("native_hash", "native_path")}
    return context


def sample_environments(samples):
    """Retain comparable display and capability variants for a sample phase."""
    environments = [{**{key: sample.get("before", {}).get(key) for key in
                     ("emacs", "system", "font", "width", "height", "graphic", "foreground", "text_scale", "native_jit")},
                     "foreground_after": sample.get("after", {}).get("foreground"),
                     "code_strategy": library_code_strategy(sample.get("before", {}).get("runtime_libraries")),
                     "context": stable_context(sample.get("before", {}).get("context"))}
                    for sample in samples]
    return sorted({json.dumps(e, sort_keys=True): e for e in environments}.values(),
                  key=lambda item: json.dumps(item, sort_keys=True))


def acceptance_coverage(settings):
    """Require complete per-set warmup and formal sample coverage."""
    return settings["sets"] >= 3 and settings["samples"] >= 30 and settings["warmups"] >= 5


def merge_profiles(samples):
    profiles = {}
    for kind in ("cpu", "memory"):
        functions = {}
        stacks = Counter()
        total = 0
        for sample in samples:
            profile = ((sample.get("profile") or {}).get(kind) or {})
            total += profile.get("total", 0)
            for row in profile.get("functions", []):
                key = (row["function"], row.get("file"), row.get("line"))
                target = functions.setdefault(key, {**row, "self": 0, "inclusive": 0})
                target["self"] += row["self"]
                target["inclusive"] += row["inclusive"]
            for stack in profile.get("stacks", []):
                stacks[tuple(stack["stack"])] += stack["weight"]
        profiles[kind] = {
            "unit": "samples" if kind == "cpu" else "bytes", "total": total,
            "functions": sorted(functions.values(), key=lambda r: r["inclusive"], reverse=True),
            "stacks": [{"weight": weight, "stack": list(stack)} for stack, weight in stacks.most_common(20)],
        }
    return profiles


def findings(case):
    """Generate evidence-based investigation hints, never assert a root cause."""
    result = []
    phases = case.get("phases_ms", {})
    profiles = case.get("profiles", {})
    functions = profiles.get("cpu", {}).get("functions", [])
    if case["impact"] == "metadata" and phases.get("layout", 0) > 0.01:
        result.append({"kind": "layout_on_state_only_update",
                       "evidence_ms": phases["layout"],
                       "investigate": "A state-only scenario performed layout; inspect style effects and projection admission."})
    if case["impact"] == "metadata" and any(
            "prepare-declarative-root" in row["function"] for row in functions):
        result.append({"kind": "full_source_preparation",
                       "investigate": "CPU samples include complete author-root preparation during a state-only update."})
    if case.get("root_owner_updates") and case.get("over_budget") and case["impact"] in ("metadata", "local"):
        result.append({"kind": "expanded_owner_scope", "updates": case["root_owner_updates"],
                       "investigate": "The published owner includes the constraint root; inspect layout dependencies and rejected local proofs."})
    if case.get("gc_ms") and max(case["gc_ms"]) > 0:
        result.append({"kind": "gc_in_interaction", "worst_gc_ms": max(case["gc_ms"]),
                       "investigate": "GC is included in latency. Inspect allocation hotspots and retained lifetimes; do not discard these samples."})
    if functions and profiles["cpu"]["total"] < 30:
        result.append({"kind": "limited_cpu_samples", "samples": profiles["cpu"]["total"],
                       "investigate": "Function percentages have low resolution; increase diagnostic samples for this scenario."})
    if case.get("diagnostic_count") and not phases:
        result.append({"kind": "provider_phases_unavailable",
                       "investigate": "The loaded provider did not expose phase timings; CPU stacks remain available."})
    return result


def analyze(raw_runs, descriptors, settings):
    cases = {}
    overall_valid = all(run.get("status") == "completed" for run in raw_runs)
    expected = settings["sets"] * settings["samples"]
    for descriptor in descriptors:
        identifier = descriptor["id"]
        all_samples = [s for run in raw_runs for s in run.get("samples", []) if s["scenario"] == identifier]
        warmups = [s for s in all_samples if s.get("phase") == "warmup"]
        samples = [s for s in all_samples if not s.get("diagnostic") and s.get("phase") != "warmup"]
        diagnostics = [s for s in all_samples if s.get("diagnostic")]
        invalid = [s for s in all_samples if not valid_sample(
            s, settings["mode"], settings.get("focus_policy") == "foreground" and not s.get("diagnostic"))]
        combinations = {(s.get("set"), s.get("sample")) for s in samples}
        wanted = {(group, number) for group in range(1, settings["sets"] + 1)
                  for number in range(settings["samples"])}
        warmup_wanted = {(group, number) for group in range(1, settings["sets"] + 1)
                         for number in range(settings["warmups"])}
        diagnostic_wanted = ({(group, number, kind) for group in range(1, settings["sets"] + 1)
                              for number in range(settings["diagnostic_samples"])
                              for kind in ("trace", "cpu", "memory")} if settings["diagnose"] else set())
        valid = (len(samples) == expected and combinations == wanted and not invalid
                 and len(warmups) == len(warmup_wanted)
                 and {(s.get("set"), s.get("sample")) for s in warmups} == warmup_wanted
                 and len(diagnostics) == len(diagnostic_wanted)
                 and {(s.get("set"), s.get("sample"), s.get("diagnostic_kind")) for s in diagnostics} == diagnostic_wanted)
        overall_valid &= valid
        values = [s["wall_ms"] for s in samples if finite_nonnegative(s.get("wall_ms"))]
        warmup_values = [s["wall_ms"] for s in warmups if finite_nonnegative(s.get("wall_ms"))]
        failures = []
        identity = ("set", "sample", "phase", "diagnostic_kind")
        for run in raw_runs:
            active = run.get("active") or {}
            if run.get("status") != "completed" and active.get("scenario") == identifier:
                failures.append({**{key: active.get(key) for key in identity},
                                 "stage": "cleanup" if run.get("cleanup_error") and not run.get("error") else active.get("stage"),
                                 "reason": run.get("error") or run.get("cleanup_error") or run.get("status")})
        for sample in invalid:
            if not any(all(failure[key] == sample.get(key) for key in identity)
                       for failure in failures):
                failures.append({**{key: sample.get(key) for key in identity},
                                 "stage": "verification",
                                 "reason": sample.get("verification") or (
                                     "Execution context changed" if not sample.get("environment_stable")
                                     else "Sample failed measurement validation")})
        latency_rows = warmups + samples
        latency_failures = [failure for failure in failures if failure["phase"] != "diagnostic"]
        incomplete = [failure for failure in latency_failures
                      if not any(all(failure[key] == sample.get(key) for key in identity)
                                 for sample in latency_rows)]
        warmup_failures = [failure for failure in failures if failure["phase"] == "warmup"]
        code_strategies = {library_code_strategy(sample.get(side, {}).get("runtime_libraries"))
                           for sample in all_samples for side in ("before", "after")}
        libraries = {json.dumps(row, sort_keys=True): row
                     for sample in all_samples for side in ("before", "after")
                     for row in sample.get(side, {}).get("runtime_libraries", [])}
        unmapped_native = {row["file"]: row for sample in all_samples for side in ("before", "after")
                           for row in sample.get(side, {}).get("unmapped_native_libraries", [])}
        code_valid = len(code_strategies) == 1 and not code_strategies.intersection({"mixed", "unknown"})
        code_error = (None if code_valid else
                      "Runtime library load formats are missing, mixed or changed during the scenario")
        valid &= code_valid
        overall_valid &= code_valid
        phase_samples = defaultdict(list)
        root_updates = 0
        strategies = Counter()
        rejections = Counter()
        native_diagnostics = Counter()
        for sample in diagnostics:
            phases = defaultdict(float)
            for report in sample.get("reports", []):
                for field in ("native_declined", "native_fallback"):
                    if report.get(field):
                        native_diagnostics[(field, report[field])] += 1
                if report["provider"] != "ebox":
                    continue
                strategies[(report["strategy"], report["projection"])] += 1
                root_updates += (report.get("root_id") is not None and report["root_id"] in report.get("owners", []))
                if report.get("rejections") not in (None, "nil"):
                    rejections[report["rejections"]] += 1
                for phase in report.get("phases", []):
                    phases[phase["phase"]] += phase["ms"]
            for name, value in phases.items():
                phase_samples[name].append(value)
            if phases:
                phase_samples["outside_ebox"].append(sample["wall_ms"] - sum(phases.values()))
        case = {**descriptor, "valid": valid, "count": len(samples), "expected_count": expected,
                "runtime_code": {"strategies": sorted(code_strategies), "reason": code_error,
                                 "libraries": sorted(libraries.values(), key=lambda row: row["file"]),
                                 "unmapped_native_libraries": sorted(unmapped_native.values(), key=lambda row: row["file"])},
                "invalid_count": len(invalid), "samples_ms": values,
                "gc_ms": [s["gc_ms"] for s in samples if finite_nonnegative(s.get("gc_ms"))],
                "cpu_ms": [s["cpu_ms"] for s in samples if finite_nonnegative(s.get("cpu_ms"))],
                "allocation_cons_counts": [s["allocations"][0] for s in samples if s.get("allocations")],
                "environments": sample_environments(samples),
                "sets": [{"set": number, "samples_ms": [s["wall_ms"] for s in samples if s["set"] == number]}
                         for number in range(1, settings["sets"] + 1)],
                "warmups": {"count": len(warmups), "expected_count": len(warmup_wanted),
                            "attempted_count": len(warmups) + sum(f["phase"] == "warmup" for f in incomplete),
                            "invalid_count": sum(s.get("phase") == "warmup" for s in invalid),
                            "samples_ms": warmup_values, "max_ms": max(warmup_values, default=None),
                            "environments": sample_environments(warmups),
                            "sets": [{"set": number, "samples_ms": [s["wall_ms"] for s in warmups if s["set"] == number]}
                                     for number in range(1, settings["sets"] + 1)],
                            "failures": warmup_failures},
                "all_latency": {"attempted_count": len(latency_rows) + len(incomplete),
                                "count": len(latency_rows), "max_ms": max(values + warmup_values, default=None),
                                "failures": latency_failures},
                "failures": failures,
                "diagnostic_count": len(diagnostics),
                "latency_outcomes": [{"set": s["set"], "sample": s["sample"],
                                      "wall_ms": s["wall_ms"], "value": s["outcome"]}
                                     for s in samples if s.get("outcome") is not None],
                "phases_ms": {name: statistics_median(v) for name, v in phase_samples.items()},
                "root_owner_updates": root_updates,
                "native_diagnostics": [{"kind": kind, "reason": reason, "count": count}
                                       for (kind, reason), count in native_diagnostics.items()],
                "strategies": [{"strategy": strategy, "projection": projection, "count": count}
                               for (strategy, projection), count in strategies.items()],
                "rejections": dict(rejections), "profiles": merge_profiles(diagnostics)}
        if values:
            case.update(p50_ms=statistics_median(values), p95_ms=percentile(values, .95),
                        p99_ms=percentile(values, .99), max_ms=max(values),
                        over_budget=sum(value > descriptor["budget_ms"] for value in values))
        else:
            case.update(p50_ms=None, p95_ms=None, p99_ms=None, max_ms=None, over_budget=0)
        case["over_hard_limit"] = sum(value > 500 for value in values + warmup_values)
        case["findings"] = findings(case)
        cases[identifier] = case
    return cases, overall_valid


def statistics_median(values):
    ordered = sorted(values)
    midpoint = len(ordered) // 2
    return ordered[midpoint] if len(ordered) % 2 else (ordered[midpoint - 1] + ordered[midpoint]) / 2


def compare(before, after, allowance=2.0):
    """Compare complete matching workloads; invalid evidence is incomparable."""
    if before.get("schema") != 1 or after.get("schema") != 1:
        return {"status": "incomparable", "reason": "Unsupported report schema"}
    if not before.get("valid") or not after.get("valid"):
        return {"status": "incomparable", "reason": "A run has missing or invalid samples"}
    for report in (before, after):
        settings = report.get("settings", {})
        expected = settings.get("sets", 0) * settings.get("samples", 0)
        if expected <= 0 or not report.get("cases"):
            return {"status": "incomparable", "reason": "Empty or unspecified sample coverage"}
        if (not isinstance(settings.get("warmups"), int) or isinstance(settings["warmups"], bool)
                or settings["warmups"] < 0 or settings.get("warmup_protocol") != WARMUP_PROTOCOL):
            return {"status": "incomparable", "reason": "Missing or unsupported warmup protocol"}
        if settings.get("library_code_protocol") != LIBRARY_CODE_PROTOCOL:
            return {"status": "incomparable", "reason": "Missing or unsupported runtime library code evidence"}
        if report.get("acceptance_eligible") is not acceptance_coverage(settings):
            return {"status": "incomparable", "reason": "Acceptance eligibility does not match sample coverage"}
        for name, case in report["cases"].items():
            code = case.get("runtime_code", {})
            strategy = library_code_strategy(code.get("libraries"))
            if (strategy in ("mixed", "unknown") or code.get("strategies") != [strategy]
                    or any(environment.get("code_strategy") != strategy
                           for environment in case.get("environments", []) + case.get("warmups", {}).get("environments", []))):
                return {"status": "incomparable", "reason": f"{name}: missing, mixed or inconsistent runtime library code formats"}
            values = case.get("samples_ms", [])
            groups = case.get("sets", [])
            if (not case.get("valid") or len(values) != expected or case.get("count") != expected
                    or not all(finite_nonnegative(value) for value in values)
                    or len(groups) != settings["sets"]
                    or {group.get("set") for group in groups} != set(range(1, settings["sets"] + 1))
                    or any(len(group.get("samples_ms", [])) != settings["samples"] for group in groups)
                    or sorted(values) != sorted(value for group in groups for value in group["samples_ms"])
                    or case.get("p95_ms") != percentile(values, .95) or case.get("max_ms") != max(values)):
                return {"status": "incomparable", "reason": f"{name}: incomplete or inconsistent latency evidence"}
            warmups = case.get("warmups", {})
            warmup_values = warmups.get("samples_ms", [])
            warmup_groups = warmups.get("sets", [])
            warmup_expected = settings["sets"] * settings["warmups"]
            if (warmups.get("count") != warmup_expected or warmups.get("expected_count") != warmup_expected
                    or warmups.get("attempted_count") != warmup_expected or warmups.get("invalid_count") != 0
                    or warmups.get("failures") != [] or len(warmup_values) != warmup_expected
                    or not all(finite_nonnegative(value) for value in warmup_values)
                    or len(warmup_groups) != settings["sets"]
                    or {group.get("set") for group in warmup_groups} != set(range(1, settings["sets"] + 1))
                    or any(len(group.get("samples_ms", [])) != settings["warmups"] for group in warmup_groups)
                    or sorted(warmup_values) != sorted(value for group in warmup_groups for value in group["samples_ms"])
                    or warmups.get("max_ms") != max(warmup_values, default=None)):
                return {"status": "incomparable", "reason": f"{name}: incomplete or inconsistent warmup evidence"}
            combined = case.get("all_latency", {})
            if (combined.get("count") != expected + warmup_expected
                    or combined.get("attempted_count") != expected + warmup_expected
                    or combined.get("max_ms") != max(values + warmup_values)
                    or combined.get("failures") != []):
                return {"status": "incomparable", "reason": f"{name}: inconsistent complete latency evidence"}
    if before["settings"]["mode"] != after["settings"]["mode"] or before.get("machine") != after.get("machine"):
        return {"status": "incomparable", "reason": "Execution mode or machine differs"}
    if before.get("tool_identity") != after.get("tool_identity") or any(
            before["settings"].get(field) != after["settings"].get(field)
            for field in ("sets", "samples", "warmups", "warmup_protocol", "library_code_protocol", "boundary", "focus_policy")):
        return {"status": "incomparable", "reason": "Measurement driver, boundary, warmups or sample grouping differs"}
    if before["cases"].keys() != after["cases"].keys():
        return {"status": "incomparable", "reason": "Scenario coverage differs"}
    rows = []
    for name, current in after["cases"].items():
        previous = before["cases"][name]
        if previous["runtime_code"]["strategies"] != current["runtime_code"]["strategies"]:
            return {"status": "incomparable", "reason": f"{name}: runtime library execution strategy differs"}
        for field in ("version", "isolation", "budget_ms", "source_sha256", "environments", "expected_count"):
            if previous.get(field) != current.get(field):
                return {"status": "incomparable", "reason": f"{name}: {field} differs"}
        if previous["warmups"].get("environments") != current["warmups"].get("environments"):
            return {"status": "incomparable", "reason": f"{name}: warmup environments differ"}
        for metric in ("p95_ms", "max_ms"):
            delta = current[metric] - previous[metric]
            rows.append({"scenario": name, "metric": metric, "before_ms": previous[metric],
                         "after_ms": current[metric], "delta_ms": delta, "regressed": delta > allowance})
    return {"status": "regressed" if any(row["regressed"] for row in rows) else "passed",
            "allowance_ms": allowance, "rows": rows,
            "acceptance_eligible": bool(before.get("acceptance_eligible") and after.get("acceptance_eligible"))}


def summarize(report, selected=None, details=False):
    print(f"status={report.get('status')} mode={report.get('settings', {}).get('mode')} "
          f"focus={report.get('settings', {}).get('focus_policy', 'unspecified')} "
          f"valid={report.get('valid')} acceptance_eligible={report.get('acceptance_eligible')}")
    for name, case in report.get("cases", {}).items():
        if selected and not fnmatch.fnmatchcase(name, selected):
            continue
        warmups = case.get("warmups", {})
        combined = case.get("all_latency", {})
        maximum = warmups.get("max_ms")
        total_maximum = combined.get("max_ms")
        print(f"{name}: runtime-code={','.join(case.get('runtime_code', {}).get('strategies', [])) or 'unknown'}")
        print(f"{name}: warmups={warmups.get('count', 0)}/{warmups.get('expected_count', 0)} "
              f"max={'unavailable' if maximum is None else f'{maximum:.2f}'} ms "
              f"failures={len(warmups.get('failures', []))}; "
              f"all-latency={combined.get('count', 0)}/{combined.get('attempted_count', 0)} completed/attempted "
              f"max={'unavailable' if total_maximum is None else f'{total_maximum:.2f}'} ms "
              f"failures={len(combined.get('failures', []))} hard-limit={case.get('over_hard_limit', 0)}")
        for failure in case.get("failures", []):
            phase = failure.get("diagnostic_kind") if failure["phase"] == "diagnostic" else failure["phase"]
            print(f"  {phase} set {failure['set']} sample {failure['sample']} "
                  f"{failure['stage']}: {failure['reason']}")
        if not case.get("samples_ms"):
            print(f"{name}: no valid completion ({case.get('count', 0)}/{case.get('expected_count')})")
            continue
        print(f"{name}: n={case['count']} p50={case['p50_ms']:.2f} p95={case['p95_ms']:.2f} "
              f"max={case['max_ms']:.2f} ms budget={case['budget_ms']} "
              f"slow={case['over_budget']} invalid={case['invalid_count']}")
        if report.get("settings", {}).get("mode") == "gui":
            print("  focus conditions: " + ", ".join(sorted({
                "foreground" if environment.get("foreground") and environment.get("foreground_after") else
                "background" if not environment.get("foreground") and not environment.get("foreground_after") else
                "changed during sample" for environment in case.get("environments", [])})))
        if details:
            counts = Counter(row["format"] for row in case.get("runtime_code", {}).get("libraries", []))
            if counts:
                print("  runtime library formats: " + ", ".join(f"{kind}={count}" for kind, count in sorted(counts.items())))
            unmapped = case.get("runtime_code", {}).get("unmapped_native_libraries", [])
            if unmapped:
                print(f"  external native libraries without known source origin: {len(unmapped)} (outside classified scope)")
            if case.get("latency_outcomes"):
                worst = max(case["latency_outcomes"], key=lambda row: row["wall_ms"])
                value = json.dumps(worst["value"], ensure_ascii=False, sort_keys=True)
                print(f"  slowest outcome (set {worst['set']}, sample {worst['sample']}): {value[:1400]}")
            phases = case.get("phases_ms", {})
            if phases:
                print("  exclusive diagnostic phase medians (ms): " + " ".join(
                    f"{name}={phases[name]:.2f}" for name in (*PHASES, "outside_ebox") if name in phases))
            for diagnostic in case.get("native_diagnostics", []):
                print(f"  {diagnostic['kind']} ({diagnostic['count']}): {diagnostic['reason']}")
            for kind in ("cpu", "memory"):
                profile = case.get("profiles", {}).get(kind, {})
                total = profile.get("total", 0)
                if total:
                    print(f"  {kind}: {total} {profile['unit']} (diagnostic only)")
                    for row in sorted(profile["functions"], key=lambda row: row["self"], reverse=True)[:6]:
                        print(f"    self={100 * row['self'] / total:.1f}% incl={100 * row['inclusive'] / total:.1f}% "
                              f"{row['function']} {row.get('file', '')}:{row.get('line') or ''}")
            for finding in case.get("findings", []):
                print(f"  {finding['kind']}: {finding['investigate']}")
    if report.get("comparison"):
        print("comparison=" + report["comparison"]["status"])
        if report["comparison"].get("reason"):
            print(report["comparison"]["reason"])
    for error in report.get("errors", []):
        print("UNVERIFIED: " + str(error))
    return 2 if not report.get("valid") else int(report.get("status") == "failed")


def run_backend(args, configuration, log_path):
    """Run one set; retain progress and terminate only owned batch processes."""
    config = read_json(configuration)
    output = Path(config["output"])
    deadline = time.monotonic() + args.run_timeout
    log = log_path.open("w", encoding="utf-8")
    process = None
    try:
        if args.mode == "batch":
            process = subprocess.Popen([args.emacs, "-Q", "--batch", "--eval",
                                        "(setq load-prefer-newer t native-comp-jit-compilation nil)",
                                        "--eval", form("taf-benchmark-start", configuration)], stdout=log, stderr=subprocess.STDOUT)
        else:
            start = subprocess.run(client_command(args, form("taf-benchmark-start", configuration)),
                                   capture_output=True, text=True, timeout=15)
            log.write(start.stdout + start.stderr)
            log.flush()
            if start.returncode or "scheduled" not in start.stdout:
                return {"status": "error", "error": f"Cannot start native job; see {log_path}", "samples": []}
        last = {}
        while time.monotonic() < deadline:
            try:
                last = read_json(output)
            except (FileNotFoundError, json.JSONDecodeError):
                pass
            if last.get("status") and last["status"] != "running":
                if process:
                    process.wait(timeout=5)
                    if process.returncode:
                        return {**last, "status": "error", "error": f"Batch exited {process.returncode}; see {log_path}"}
                return last
            if process and process.poll() is not None:
                return {**last, "status": "error", "error": f"Batch exited {process.returncode}; see {log_path}"}
            active = last.get("active", {})
            if active and active.get("stage") != "waiting_for_foreground" and time.time() - active.get("started_at", time.time()) > args.timeout:
                raise TimeoutError(f"{active.get('scenario')}: {active.get('stage')} exceeded {args.timeout}s")
            time.sleep(.05)
        raise TimeoutError(f"Run exceeded {args.run_timeout}s")
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        if process and process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
        elif args.mode == "gui":
            try:
                subprocess.run(client_command(args, f"(taf-benchmark-cancel {json.dumps(config.get('run_id'))})"),
                               capture_output=True, timeout=2)
            except (OSError, subprocess.SubprocessError):
                log.write("Native Emacs did not answer cancellation; press C-g if it remains busy.\n")
        try:
            last = read_json(output)
        except (OSError, ValueError):
            last = {}
        return {**last, "status": "timeout" if isinstance(error, (TimeoutError, subprocess.TimeoutExpired)) else "error",
                "error": str(error)}
    finally:
        if process and process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
        log.close()


def gate_evaluate(report):
    """Return (rows, failures) for a gate REPORT; rows are display tuples."""
    rows, failures, families = [], [], defaultdict(list)
    for result in report.get("results") or []:
        name = result["id"]
        family, _, size = name.rpartition(".")
        gate = result.get("gate") or {}
        klass = gate.get("class", "info")
        if klass not in GATE_CLASSES:
            failures.append(f"{name}: unknown gate class {klass}")
            continue
        if result.get("error"):
            failures.append(f"{name}: {result['error']}")
            rows.append((name, klass, None, None, None, None, None, None, "ERROR"))
            continue
        budget = GATE_CLASSES[klass]
        op, total, cons = result["op"], result["total"], result["cons"]
        op50, op95 = percentile(op, .5), percentile(op, .95)
        total50, cons50 = percentile(total, .5), percentile(cons, .5)
        twin50 = percentile(result["twin"], .5) if result.get("twin") else None
        own = []
        if result.get("verify") is not True:
            own.append(f"verify: {result.get('verify')}")
        if result.get("twin-error"):
            own.append(f"twin: {result['twin-error']}")
        if gate.get("twin") and twin50 is None and not result.get("twin-error"):
            own.append("twin: no samples")
        if "op_p50" in budget and op50 > budget["op_p50"]:
            own.append(f"op p50 {op50:.0f} > {budget['op_p50']} us")
        if "op_p95" in budget and op95 > budget["op_p95"]:
            own.append(f"op p95 {op95:.0f} > {budget['op_p95']} us")
        if "cons_p50" in budget and cons50 > budget["cons_p50"]:
            own.append(f"cons p50 {cons50:.0f} > {budget['cons_p50']}")
        if "op_p50_per_row" in budget:
            per_row = op50 / max(1, gate.get("rows") or (int(size) if size.isdigit() else 1))
            if per_row > budget["op_p50_per_row"]:
                own.append(f"op {per_row:.1f} us/row > {budget['op_p50_per_row']}")
        if twin50 is not None and budget.get("redisplay"):
            overhead = percentile([t - o for t, o in zip(total, op)], .5)
            if overhead - twin50 > GATE_TWIN_SLACK_US:
                own.append(f"redisplay {overhead - twin50:+.0f} us over twin")
        elif twin50 is not None and total50 - twin50 > GATE_TWIN_SLACK_US:
            own.append(f"e2e {total50 - twin50:+.0f} us over twin")
        if budget.get("flat") and size.isdigit():
            families[family].append((int(size), op50, name))
        failures.extend(f"{name}: {reason}" for reason in own)
        rows.append((name, klass, op50, op95, total50, twin50, cons50, result.get("gcs"),
                     "FAIL" if own else "PASS"))
    for family, sizes in families.items():
        sizes.sort()
        (small, small50, _), (large, large50, name) = sizes[0], sizes[-1]
        if large > small and large50 > small50 * GATE_FLAT_FACTOR + GATE_FLAT_SLACK_US:
            failures.append(f"{family}: op p50 grows {small50:.0f} -> {large50:.0f} us "
                            f"from {small} to {large} rows")
    return rows, failures


def gate_print(report):
    rows, failures = gate_evaluate(report)
    frame = report.get("frame", {})
    print(f"frame {frame.get('width')}x{frame.get('height')} px font {frame.get('font')}")
    print(f"{'scenario':44} {'class':9} {'op50':>7} {'op95':>7} {'e2e50':>7} {'twin50':>7} "
          f"{'cons50':>7} {'gc':>3}  result")
    def cell(value):
        return f"{value:7.0f}" if isinstance(value, (int, float)) else f"{'-':>7}"
    for name, klass, op50, op95, total50, twin50, cons50, gcs, result in rows:
        print(f"{name:44} {klass:9} {cell(op50)} {cell(op95)} {cell(total50)} {cell(twin50)} "
              f"{cell(cons50)} {gcs if gcs is not None else '-':>3}  {result}")
    for failure in failures:
        print(f"FAIL {failure}")
    complete = report.get("status") == "done" and len(report.get("results") or []) == report.get("total")
    status = "PASS" if complete and not failures else "FAIL" if complete else "UNVERIFIED"
    print(f"{status}: {len(rows)} scenarios, {len(failures)} failures")
    return 0 if status == "PASS" else 1 if status == "FAIL" else 2


def gate(args, entries):
    output = (args.output or Path(os.environ.get("XDG_CACHE_HOME", Path.home() / ".cache")) /
              "emacs-taf/gate" / (datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ-") + uuid.uuid4().hex[:8] + ".json")).resolve()
    output.parent.mkdir(parents=True, exist_ok=True)
    configuration = output.with_suffix(".configuration.json")
    write_json(configuration, {"output": str(output), "scenario_files": list(map(str, entries)),
                               "scenarios": args.scenario or ["."], "samples": args.samples})
    expression = ("(progn (when (and (fboundp 'taf-gate-running-p) (taf-gate-running-p)) "
                  '(error "A gate job is already running")) '
                  f"(load {json.dumps(str(GATE_RUNNER), ensure_ascii=False)} nil t t) "
                  f"(taf-gate-start {json.dumps(str(configuration), ensure_ascii=False)}))")
    start = subprocess.run(client_command(args, expression), capture_output=True, text=True, timeout=30)
    if start.returncode or "scheduled" not in start.stdout:
        raise ValueError(f"Cannot start gate job: {start.stdout}{start.stderr}")
    deadline, report, shown = time.monotonic() + args.run_timeout, {}, 0
    while time.monotonic() < deadline:
        try:
            report = read_json(output)
        except (FileNotFoundError, json.JSONDecodeError):
            time.sleep(.1)
            continue
        done = len(report.get("results") or [])
        if done > shown:
            print(f"\r{done}/{report.get('total')} scenarios", end="", file=sys.stderr, flush=True)
            shown = done
        if report.get("status") != "running":
            break
        time.sleep(.2)
    print(file=sys.stderr)
    print(f"Evidence: {output}")
    return gate_print(report)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    for name in ("list", "run"):
        command = subparsers.add_parser(name)
        command.add_argument("--root", type=Path, default=ROOT)
        command.add_argument("--scenario-file", action="append", default=[])
        command.add_argument("--scenario", action="append", default=[])
        command.add_argument("--emacs", default="emacs")
        command.add_argument("--load-path", action="append", default=[], help="Additional public package root.")
    run = subparsers.choices["run"]
    run.add_argument("--mode", choices=("batch", "gui"), required=True)
    run.add_argument("--emacsclient", default="emacsclient")
    run.add_argument("--server", help="Existing named Emacs server; no alternate editor is started.")
    run.add_argument("--focus-policy", choices=("any", "foreground"), default="any",
                     help="GUI latency permits background by default; diagnostics always record actual focus without waiting.")
    run.add_argument("--foreground", action="store_true",
                     help="Activate Emacs once and require foreground for latency samples; diagnostics permit background.")
    run.add_argument("--samples", type=int, default=10)
    run.add_argument("--sets", type=int, default=3)
    run.add_argument("--warmups", type=int, default=5,
                     help="Recorded warmups before each scenario/set's formal latency samples (default: 5).")
    run.add_argument("--diagnose", action="store_true")
    run.add_argument("--diagnostic-samples", type=int, default=3)
    run.add_argument("--timeout", type=float, default=15)
    run.add_argument("--run-timeout", type=float, default=300)
    run.add_argument("--output-dir", type=Path)
    run.add_argument("--baseline", type=Path)
    summary = subparsers.add_parser("summarize")
    summary.add_argument("report", type=Path)
    summary.add_argument("--scenario")
    summary.add_argument("--details", action="store_true")
    comparison = subparsers.add_parser("compare")
    comparison.add_argument("before", type=Path)
    comparison.add_argument("after", type=Path)
    comparison.add_argument("--allowance-ms", type=float, default=2)
    cancel = subparsers.add_parser("cancel")
    cancel.add_argument("--emacsclient", default="emacsclient")
    cancel.add_argument("--server")
    gating = subparsers.add_parser("gate")
    gating.add_argument("--root", type=Path, default=ROOT)
    gating.add_argument("--scenario-file", action="append", default=[])
    gating.add_argument("--scenario", action="append", default=[],
                        help="Emacs regexp selecting scenario ids (default: all with :gate).")
    gating.add_argument("--server", help="Existing named GUI Emacs server (required to run).")
    gating.add_argument("--emacsclient", default="emacsclient")
    gating.add_argument("--samples", type=int, default=40)
    gating.add_argument("--run-timeout", type=float, default=900)
    gating.add_argument("--output", type=Path)
    gating.add_argument("--report", type=Path, help="Re-evaluate an existing gate report instead of running.")
    args = parser.parse_args()
    if args.command == "gate":
        if args.report:
            return gate_print(read_json(args.report))
        if not args.server:
            parser.error("gate requires --server unless --report is given")
        if not 5 <= args.samples <= 1000:
            parser.error("--samples must be between 5 and 1000")
        entries, _ = discover(args.root.resolve(), args.scenario_file)
        return gate(args, entries)
    if args.command == "summarize":
        return summarize(read_json(args.report), args.scenario, args.details)
    if args.command == "compare":
        if not math.isfinite(args.allowance_ms) or args.allowance_ms < 0:
            parser.error("--allowance-ms must be finite and nonnegative")
        result = compare(read_json(args.before), read_json(args.after), args.allowance_ms)
        print(json.dumps(result, indent=2))
        return {"passed": 0, "regressed": 1, "incomparable": 2}[result["status"]]
    if args.command == "cancel":
        return subprocess.run(client_command(args, "(taf-benchmark-cancel)"), timeout=5).returncode
    entries, paths = discover(args.root.resolve(), args.scenario_file)
    paths = list(dict.fromkeys([*paths, *(Path(path).resolve() for path in args.load_path)]))
    if not entries:
        parser.error("No benchmarks/performance-scenarios.el entries found")
    if args.command == "list":
        with tempfile.TemporaryDirectory(prefix="taf-perf-catalog-") as directory:
            for case in catalog(args, entries, paths, Path(directory)):
                if any(fnmatch.fnmatchcase(case["id"], pattern) for pattern in (args.scenario or ["*"])):
                    print(f"{case['id']:40} {','.join(case['modes']):10} {case['budget_ms']:5}ms {case['description']}")
        return 0
    if not args.scenario:
        parser.error("Select --scenario PATTERN explicitly; use list to inspect coverage")
    if not (1 <= args.samples <= 1000 and 1 <= args.sets <= 20 and 0 <= args.warmups <= 1000
            and 1 <= args.diagnostic_samples <= 100):
        parser.error("Sample/set counts are outside supported bounds")
    if not (0 < args.timeout < math.inf and 0 < args.run_timeout < math.inf):
        parser.error("Timeouts must be finite and positive")
    output = (args.output_dir or Path(os.environ.get("XDG_CACHE_HOME", Path.home() / ".cache")) /
              "emacs-taf/performance" / (datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ-") + uuid.uuid4().hex[:8])).resolve()
    output.mkdir(parents=True, exist_ok=True)
    if any(output.iterdir()):
        parser.error("Output directory must be empty; evidence is never overwritten")
    try:
        descriptors = [case for case in catalog(args, entries, paths, output)
                       if args.mode in case["modes"] and any(fnmatch.fnmatchcase(case["id"], p) for p in args.scenario)]
    except (OSError, ValueError, subprocess.SubprocessError) as failure:
        report = {"schema": 1, "status": "unverified", "valid": False, "acceptance_eligible": False,
                  "settings": {"mode": args.mode}, "errors": [str(failure)], "runs": []}
        write_json(output / "result.json", report)
        print(f"Evidence: {output}", flush=True)
        return summarize(report)
    if not descriptors:
        parser.error("No scenarios match the requested mode and pattern")
    for case in descriptors:
        case["source_sha256"] = hashlib.sha256(Path(case["source"]).read_bytes()).hexdigest()
    settings = {"mode": args.mode, "samples": args.samples, "sets": args.sets,
                "warmups": args.warmups, "warmup_protocol": WARMUP_PROTOCOL,
                "library_code_protocol": LIBRARY_CODE_PROTOCOL,
                "focus_policy": "foreground" if args.foreground else args.focus_policy,
                "diagnose": args.diagnose, "diagnostic_samples": args.diagnostic_samples,
                "timeout": args.timeout, "boundary": "invoke-settlement-redisplay-v1"}
    source_roots = list(dict.fromkeys([args.root.resolve(), *paths]))
    report = {"schema": 1, "status": "running", "valid": False, "settings": settings,
              "machine": {"node": platform.node(), "system": platform.platform(), "machine": platform.machine()},
              "sources": source_snapshot(source_roots), "runs": [], "errors": [],
              "tool_identity": {"runner": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
                                "driver": hashlib.sha256(DRIVER.read_bytes()).hexdigest()},
              "host_context": {"cpu_count": os.cpu_count(), "load_before": list(os.getloadavg()) if hasattr(os, 'getloadavg') else None},
              "acceptance_eligible": acceptance_coverage(settings),
              "not_certified": ["hardware input latency", "OS compositor presentation", "visual appearance review"]}
    write_json(output / "result.json", report)
    print(f"Evidence: {output}", flush=True)
    if args.mode == "gui":
        try:
            report["native_preflight"] = native_preflight(args, paths, output)
        except (ValueError, subprocess.SubprocessError) as failure:
            report.update(status="unverified", valid=False)
            report["errors"].append(str(failure))
            write_json(output / "result.json", report)
            return summarize(report)
    raw_runs = []
    for kind in (["latency", "trace", "cpu", "memory"] if args.diagnose else ["latency"]):
        diagnostic = kind != "latency"
        groups = [[case] for case in descriptors] if args.mode == "batch" else [descriptors]
        units = [(number, group_index, group) for number in range(1, args.sets + 1)
                 for group_index, group in enumerate(groups, 1)]
        for number, group_index, group in units:
            label = f"{kind}-{number}" + (f"-{group_index}" if len(groups) > 1 else "")
            phases = ([("diagnostic", args.diagnostic_samples)] if diagnostic
                      else [("warmup", args.warmups), ("latency", args.samples)])
            jobs = [{"id": case["id"], "set": number, "sample": sample, "phase": phase,
                     "iteration": sample + (args.warmups if phase == "latency" else 0),
                     "diagnostic": diagnostic, "diagnostic_kind": kind}
                    for case in group for phase, count in phases for sample in range(count)]
            configuration = output / (label + "-configuration.json")
            write_json(configuration, {"output": str(output / (label + ".json")), "mode": args.mode,
                                       "run_id": uuid.uuid4().hex,
                                       "scenario_files": list(map(str, entries)), "load_paths": list(map(str, paths)),
                                       "code_roots": list(map(str, paths)), "jobs": jobs, "timeout": args.timeout,
                                       "require_foreground": settings["focus_policy"] == "foreground" and not diagnostic,
                                       "foreground": bool(args.foreground and kind == "latency" and number == 1)})
            raw = run_backend(args, configuration, output / (label + ".log"))
            raw_runs.append(raw)
            report["runs"].append({"name": label, "status": raw.get("status"), "file": label + ".json",
                                   "active": raw.get("active"), "error": raw.get("error")})
            if raw.get("error"):
                report["errors"].append(raw["error"])
            print(f"{label}: {raw.get('status')} samples={len(raw.get('samples', []))}", flush=True)
            write_json(output / "result.json", report)
            if raw.get("status") != "completed":
                break
        if raw_runs[-1].get("status") != "completed":
            break
    cases, valid = analyze(raw_runs, descriptors, settings)
    report["errors"].extend(f"{name}: {case['runtime_code']['reason']}"
                            for name, case in cases.items() if case["runtime_code"]["reason"])
    report["host_context"]["load_after"] = list(os.getloadavg()) if hasattr(os, 'getloadavg') else None
    if report["tool_identity"] != {"runner": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
                                   "driver": hashlib.sha256(DRIVER.read_bytes()).hexdigest()}:
        valid = False
        report["errors"].append("Performance tool changed during measurement")
    native_artifacts = {(sample.get('before', {}).get('context', {}).get('native_path'),
                         sample.get('before', {}).get('context', {}).get('native_hash'))
                        for run in raw_runs for sample in run.get('samples', []) if isinstance(sample.get('before', {}).get('context'), dict)}
    for path, expected_hash in native_artifacts:
        if path and expected_hash and (not Path(path).is_file() or hashlib.sha256(Path(path).read_bytes()).hexdigest() != expected_hash):
            valid = False
            report["errors"].append(f"Loaded native artifact differs from the current file: {path}")
    final_sources = source_snapshot(source_roots)
    if final_sources != report["sources"]:
        valid = False
        report["errors"].append("Workspace sources changed during measurement")
    report["final_sources"] = final_sources
    if args.mode == "gui" and any(run.get("environment", {}).get("pid") != report["native_preflight"]["environment"]["pid"] for run in raw_runs):
        valid = False
        report["errors"].append("The native Emacs instance changed between sets")
    report.update(cases=cases, valid=valid)
    report["status"] = ("unverified" if not valid else "failed" if any(case.get("over_budget") or case.get("over_hard_limit") for case in cases.values())
                        else "passed" if report["acceptance_eligible"] else "screened")
    if args.baseline:
        try:
            report["comparison"] = compare(read_json(args.baseline), report)
        except (OSError, ValueError, KeyError, TypeError) as failure:
            report["comparison"] = {"status": "incomparable", "reason": str(failure)}
        if report["comparison"]["status"] == "incomparable":
            report.update(status="unverified", valid=False)
        elif report["comparison"]["status"] == "regressed":
            report["status"] = "failed"
    write_json(output / "result.json", report)
    return summarize(report, details=args.diagnose)


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError) as failure:
        print(f"UNVERIFIED: {failure}", file=sys.stderr)
        raise SystemExit(2)
