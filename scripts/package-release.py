#!/usr/bin/env python3
"""Build and verify the official ETAF package archive.

The workspace checkpoint supplies exact provider revisions.  Runtime resource
selection lives in release-dependencies.json.  Source export reads Git objects,
never uncommitted files or compiled caches.  Verification uses disposable Emacs
profiles with no source load paths.  User Emacs profiles are never touched.
"""
from __future__ import annotations

import argparse
import concurrent.futures
import contextlib
import functools
import hashlib
import http.server
import io
import json
import os
from pathlib import Path
import random
import re
import signal
import shutil
import subprocess
import sys
import tarfile
import tempfile
import threading
import time

import package_archive
import workspace_layout

ROOT = Path(__file__).resolve().parents[1]
# A third-party archive throttles repeated index fetches: MELPA answers 429 after
# a few.  The external dependency closure of these packages changes rarely, so
# one snapshot serves every verification until someone asks to refresh it.
STANDARD_ARCHIVE_CACHE = Path(os.environ.get(
    "ETAF_STANDARD_ARCHIVE_CACHE",
    Path.home() / ".cache" / "etaf-standard-archives"))



# An install smoke compiles the target's dependencies from source; a large
# package (telega pulls about two hundred files from MELPA) needs more than
# five minutes on a quiet machine, and this gate decides correctness, not
# latency.
INSTALL_TIMEOUT = 900
DEFAULT_ARCHIVE_URL = "https://etaf.top/packages/"
PROXY_ENV_VARS = (
    "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY",
    "http_proxy", "https_proxy", "all_proxy", "no_proxy",
)


def direct_urlopen(url, timeout=30):
    """Open URL bypassing shell proxy env vars that break localhost or etaf.top."""
    from urllib.request import ProxyHandler, build_opener
    return build_opener(ProxyHandler({})).open(url, timeout=timeout)


def compare_versions(left, right):
    """Compare dot-separated numeric package versions; return -1, 0, or 1."""
    a = tuple(int(part) for part in str(left).split("."))
    b = tuple(int(part) for part in str(right).split("."))
    length = max(len(a), len(b))
    a_pad = a + (0,) * (length - len(a))
    b_pad = b + (0,) * (length - len(b))
    return -1 if a_pad < b_pad else (1 if a_pad > b_pad else 0)


def find_stale_internal_requires(packages_by_name, target_names=None, skip_names=()):
    """Return internal ETAF dependencies whose declared minimum trails the current version.

    Only direct first-party internal dependencies are checked; `emacs`, external
    archives (GNU/NonGNU/MELPA) and skipped packages (such as upstream community
    packages) are ignored.  Returns a deterministically sorted list of records:
    {package, dependency, declared, current}.
    """
    skip = set(skip_names)
    selected = sorted(packages_by_name if target_names is None else target_names)
    stale = []
    for name in selected:
        if name in skip or name not in packages_by_name:
            continue
        pkg = packages_by_name[name]
        for dep, declared in pkg.get("requirements", ()):
            if dep == "emacs" or dep in skip or dep not in packages_by_name:
                continue
            current = packages_by_name[dep]["version"]
            if compare_versions(declared, current) < 0:
                stale.append({
                    "package": name,
                    "dependency": dep,
                    "declared": declared,
                    "current": current,
                })
    return stale


def rewrite_package_requires(entry_path, pkg_name, updates):
    """Update declared dependency minimum versions in ENTRY_PATH's Package-Requires header.

    Preserves dependency order and every other byte in ENTRY_PATH, then re-validates
    the written header via `package_archive.metadata`.  Returns (changed, header_line).
    """
    info = package_archive.metadata(entry_path.parent, pkg_name)
    source = entry_path.read_text(encoding="utf-8")
    match = re.search(r"^;; Package-Requires: (.+)$", source, re.M)
    if not match:
        raise ValueError(f"{pkg_name}: missing Package-Requires header in {entry_path}")
    new_pairs = [(dep, updates.get(dep, ver)) for dep, ver in info["requirements"]]
    new_line = ";; Package-Requires: (" + " ".join(
        f'({dep} "{ver}")' for dep, ver in new_pairs
    ) + ")"
    if match.group(0) == new_line:
        return False, new_line
    updated = source[:match.start()] + new_line + source[match.end():]
    entry_path.write_text(updated, encoding="utf-8")
    verified = package_archive.metadata(entry_path.parent, pkg_name)
    if verified["requirements"] != new_pairs:
        raise ValueError(f"{pkg_name}: rewritten Package-Requires failed validation")
    return True, new_line


def workspace_release_metadata(root=ROOT):
    """Read current header metadata and entry paths for all first-party release packages."""
    selection = json.loads((root / "release-dependencies.json").read_text(encoding="utf-8"))
    if selection.get("schema") != 1:
        raise ValueError("Unsupported release selection schema")
    names = ["etaf-install", *selection["packages"].keys()]
    meta, entries, resources = {}, {}, {}
    for name in dict.fromkeys(names):
        pkg_dir = workspace_layout.package_path(root, name)
        if not pkg_dir.is_dir():
            raise ValueError(f"Missing package directory for {name}: {pkg_dir}")
        meta[name] = package_archive.metadata(pkg_dir, name)
        entries[name] = pkg_dir / f"{name}.el"
        resources[name] = (selection["packages"].get(name) or {}).get("resources", [])
    return meta, entries, resources


def detect_changed_workspace_packages(root=ROOT, live_url=DEFAULT_ARCHIVE_URL, directory=None):
    """Return first-party package names whose shipped archive bytes differ from LIVE_URL."""
    url = live_url.rstrip("/")
    if not url.endswith(".json"):
        url = url + "/manifest.json"
    with direct_urlopen(url, timeout=20) as response:
        live = json.loads(response.read())
    live_by_name = {item["name"]: item["sha256"] for item in live.get("packages", ())}
    if directory is not None:
        manifest = package_archive.verify(directory)
        community_only = set(manifest.get("community", {}))
        return sorted(
            item["name"]
            for item in manifest["packages"]
            if item["name"] not in community_only and live_by_name.get(item["name"]) != item["sha256"]
        )
    meta, entries, resources = workspace_release_metadata(root)
    sources = {name: entries[name].parent for name in meta}
    with tempfile.TemporaryDirectory(prefix=".etaf-sync-probe-") as work:
        probe = Path(work) / "archive"
        manifest = package_archive.build(probe, sources, resources)
    return sorted(
        item["name"]
        for item in manifest["packages"]
        if live_by_name.get(item["name"]) != item["sha256"]
    )


def sync_requires(packages=None, *, changed_only=False, live_url=DEFAULT_ARCHIVE_URL,
                  directory=None, write=False, check=False, json_mode=False, root=ROOT):
    """Check or align internal ETAF Package-Requires lower bounds in workspace headers.

    Prevents version skew for native `package-upgrade` users when an upper package
    releases against newer core/extension APIs without bumping its declared minimum.
    """
    if write and check:
        raise ValueError("--write and --check cannot be combined")
    meta, entries, _ = workspace_release_metadata(root)
    if packages:
        unknown = sorted(set(packages) - set(meta))
        if unknown:
            raise ValueError(f"Unknown release package(s): {', '.join(unknown)}")
        selected = sorted(dict.fromkeys(packages))
    elif changed_only:
        selected = detect_changed_workspace_packages(root=root, live_url=live_url, directory=directory)
    else:
        selected = sorted(meta)

    stale = find_stale_internal_requires(meta, target_names=selected)
    grouped = {}
    for item in stale:
        grouped.setdefault(item["package"], {})[item["dependency"]] = item["current"]

    updated_files = []
    if write and grouped:
        for pkg, updates in sorted(grouped.items()):
            changed, _ = rewrite_package_requires(entries[pkg], pkg, updates)
            if changed:
                updated_files.append(pkg)

    payload = {
        "mode": "write" if write else ("check" if check else "preview"),
        "checked_packages": selected,
        "stale": stale,
        "updated_packages": updated_files,
        "ok": not stale or write,
    }
    if json_mode:
        print(json.dumps(payload, indent=2, sort_keys=True))
    elif not stale:
        scope_desc = f"{len(selected)} package(s)"
        print(f"Internal Package-Requires bounds are current across {scope_desc}.")
    else:
        verb = "Updated" if write else "Stale"
        print(f"{verb} internal Package-Requires lower bound(s) ({len(stale)} in {len(grouped)} package(s)):")
        for item in stale:
            print(f"  {item['package']}: {item['dependency']} {item['declared']} -> {item['current']}")
        if not write and not check:
            pkgs_flags = " ".join(f"--package {p}" for p in sorted(grouped))
            print(f"hint=python3 scripts/package-release.py sync-requires --write {pkgs_flags}")

    if check and stale:
        pkgs_flags = " ".join(f"--package {p}" for p in sorted(grouped))
        raise ValueError(
            f"Found {len(stale)} stale internal Package-Requires lower bound(s); "
            f"run: python3 scripts/package-release.py sync-requires --write {pkgs_flags}"
        )
    return 0


def resolve_auto_scope(directory, declared_targets, live_url):
    """Compare DIRECTORY against LIVE_URL before running Emacs verification.

    1) Fail fast if ANY built package modifies bytes under an already-published
       version (avoids wasting an entire install matrix + SSH upload only to
       discover immutable drift on the archive host).
    2) Fail fast if ANY changed first-party package declares a stale internal
       ETAF dependency lower bound (prevents version skew under package.el).
    3) When only a subset of packages changed (and not etaf-install), narrow
       verification to the changed targets and their transitive dependents.
    Returns (scope, targets, reason).
    """
    manifest = package_archive.verify(directory)
    url = live_url.rstrip("/")
    if not url.endswith(".json"):
        url = url + "/manifest.json"
    try:
        with direct_urlopen(url, timeout=20) as response:
            live = json.loads(response.read())
    except Exception:
        return "full", list(declared_targets), None

    live_by_file = {item["file"]: item["sha256"] for item in live.get("packages", ())}
    live_by_name = {item["name"]: item["sha256"] for item in live.get("packages", ())}
    built = {item["name"]: item for item in manifest["packages"]}

    drifting = [
        (item["name"], item["version"])
        for item in sorted(manifest["packages"], key=lambda x: x["name"])
        if item["file"] in live_by_file and live_by_file[item["file"]] != item["sha256"]
    ]
    if drifting:
        lines = [f"  bump {name} past {ver}" for name, ver in drifting]
        raise ValueError(
            f"Immutable package(s) differ from {url}; bump Version before verifying:\n"
            + "\n".join(lines)
        )

    changed = {name for name, item in built.items() if live_by_name.get(name) != item["sha256"]}
    if not changed:
        return "full", list(declared_targets), None

    community_only = set(manifest.get("community", {}))
    stale = find_stale_internal_requires(built, target_names=changed, skip_names=community_only)
    if stale:
        lines = [
            f"  {item['package']}: {item['dependency']} {item['declared']} -> {item['current']}"
            for item in stale
        ]
        pkgs = sorted({item["package"] for item in stale})
        fix_cmd = "python3 scripts/package-release.py sync-requires --write " + " ".join(
            f"--package {p}" for p in pkgs
        )
        raise ValueError(
            "Stale internal Package-Requires lower bound(s) in changed package(s):\n"
            + "\n".join(lines)
            + f"\nRun: {fix_cmd}"
        )

    if "etaf-install" in changed:
        return "full", list(declared_targets), None

    def installed_closure(name):
        found, stack = set(), [dep for dep, _ver in built.get(name, {}).get("requirements", ())]
        while stack:
            dep = stack.pop()
            if dep not in found:
                found.add(dep)
                stack.extend(d for d, _v in built.get(dep, {}).get("requirements", ()))
        return found

    all_candidates = list(dict.fromkeys([*declared_targets, *sorted(community_only)]))
    selected = [
        name for name in all_candidates
        if name != "etaf-install" and (name in changed or bool(installed_closure(name) & changed))
    ]
    if not selected or set(selected) >= {n for n in all_candidates if n != "etaf-install"}:
        return "full", list(declared_targets), None
    reason = "shipped bytes changed for " + ", ".join(sorted(changed))
    return "selected", selected, reason


def checkpoint_sources(document):
    """Return every delivery unit the workspace registry declares.

    One jjosh checkout holds every package, so the registry names the unit and
    its remote; the revision that produced a release is the checkout commit the
    publisher records, not a per-package pin.
    """
    return document.get("packages") or document.get("repositories", {})
def release_targets():
    """Return the installation targets a release must verify.

    The selection is the authority: `packages` lists everything the archive
    contains, including dependencies such as `ebox` or `ecss` that are not user
    targets, and `targets` lists the entries a user installs. Keeping one list in
    this file let the gate and the archive drift apart.
    """
    selection = json.loads((ROOT / "release-dependencies.json").read_text())
    return tuple(selection.get("targets") or sorted(selection["packages"]))


def run(args, *, cwd=None, env=None, timeout=120, log_file=None):
    """Run a bounded release subprocess and reap it on interruption or timeout."""
    process = subprocess.Popen(args, cwd=cwd, env=env, stdout=subprocess.PIPE,
                               stderr=subprocess.PIPE, start_new_session=os.name != "nt")
    try:
        stdout, stderr = process.communicate(timeout=timeout)
    except (subprocess.TimeoutExpired, KeyboardInterrupt) as interrupted:
        if os.name == "nt":
            subprocess.run(["taskkill", "/PID", str(process.pid), "/T", "/F"],
                           capture_output=True, timeout=20, check=False)
        else:
            os.killpg(process.pid, signal.SIGKILL)
        stdout, stderr = process.communicate()
        if log_file:
            # A run that ran out of time still has output worth reading, and its
            # log name is what says which target hung.
            log_file.write_bytes(stdout + b"\n--- stderr ---\n" + stderr)
        if isinstance(interrupted, subprocess.TimeoutExpired):
            raise ValueError(f"Timed out after {timeout} s: {args[0]}\n"
                             + (f"log={log_file}" if log_file else "")) from None
        raise
    if log_file:
        log_file.write_bytes(stdout + b"\n--- stderr ---\n" + stderr)
    if process.returncode:
        detail = f"log={log_file}" if log_file else (stdout + stderr).decode(errors="replace")[-4000:]
        if log_file and Path(log_file).is_file():
            # The probe's own output names the failing step; a path alone leaves
            # CI failures undiagnosable once the runner is gone.
            detail += "\n" + Path(log_file).read_text(errors="replace")[-3000:]
        raise ValueError(f"Command failed ({process.returncode}): {args[0]}\n{detail}")
    return stdout, stderr


def change_graph_binary(root):
    """Return the Jujutsu binary that owns ROOT, or nil outside a jj checkout.

    jjosh and jj write incompatible repository metadata; never fall back to
    the wrong binary when the owner is missing from PATH.
    """
    if not (root / ".jj").is_dir():
        return None
    repository = root / ".jj" / "repo"
    # A secondary workspace stores a path to the owning repository here.
    if repository.is_file():
        target = Path(repository.read_text(encoding="utf-8").strip())
        repository = target if target.is_absolute() else (repository.parent / target).resolve()
    binary = "jjosh" if repository.is_dir() and (repository / "store" / "git").is_dir() else "jj"
    if not shutil.which(binary):
        raise ValueError(f"{root}: {binary} is not on PATH; it owns this checkout")
    return binary


def package_container(root):
    """Return the first package container directory of ROOT, or nil."""
    containers = workspace_layout.package_containers(root)
    return containers[0] if containers else None


def package_directory(name):
    """Return NAME's directory in this checkout."""
    return workspace_layout.package_path(ROOT, name)


def subtree_of(name):
    """Return NAME's path inside the exported revision, or nil for sibling checkouts."""
    if not workspace_layout.package_containers(ROOT):
        return None
    path = workspace_layout.package_path(ROOT, name)
    if path.is_dir() and workspace_layout.container_root(path) == ROOT.resolve():
        return path.resolve().relative_to(ROOT.resolve()).as_posix()
    return None


def head_revision(root):
    """Return the sealed commit of ROOT.

    A jj checkout answers from its change graph; its commit IDs are the Git
    object IDs, so `git archive' can still export the tree.
    """
    binary = change_graph_binary(root)
    if binary is not None:
        raw, _ = run([binary, "--no-pager", "log", "--no-graph", "-r", "@-",
                      "-T", "commit_id"], cwd=root)
        return raw.decode().strip().splitlines()[0]
    return run(["git", "rev-parse", "HEAD"], cwd=root)[0].decode().strip()


def git_directory(source):
    """Locate the Git object store of either a normal checkout or a jj workspace."""
    binary = change_graph_binary(source)
    if binary is not None:
        return run([binary, "git", "root"], cwd=source)[0].decode().strip()
    return run(["git", "rev-parse", "--absolute-git-dir"], cwd=source)[0].decode().strip()


def export(source, revision, destination, subtree=None):
    """Export a sealed source revision; do not compile or change its checkout.

    A SUBTREE names a directory inside REVISION's tree, which is how one
    checkout of many packages exports the single package a release carries.
    """
    if not re.fullmatch(r"[0-9a-f]{40}", revision):
        raise ValueError("Source revisions must be full Git commit IDs")
    spec = f"{revision}:{subtree}" if subtree else revision
    raw, _ = run(["git", "--git-dir", git_directory(source), "archive", spec])
    destination.mkdir()
    with tarfile.open(fileobj=io.BytesIO(raw)) as archive:
        # Package resources must not import arbitrary host files through links.
        if any(member.issym() or member.islnk() for member in archive.getmembers()):
            raise ValueError(f"{source.name}: release source contains a symlink")
        archive.extractall(destination, filter="data")


def last_change(git_dir, revision, files):
    """Return the committer date of the newest commit that changed shipped files.

    The archive shows each package's freshness, so the date has to mean "this
    package changed", not "something in its repository changed" and not "the
    archive was rebuilt". Reading it from history at the sealed revision keeps
    the value reproducible: rebuilding the same revision yields the same dates.
    """
    if not files:
        raise ValueError("A package must ship at least its entry file")
    raw, _ = run(["git", "--git-dir", str(git_dir), "log", "-1",
                  "--format=%cI", revision, "--", *files])
    value = raw.decode().strip()
    if not re.fullmatch(r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(?:[+-][0-9]{2}:[0-9]{2}|Z)", value):
        raise ValueError(f"Cannot date the newest change of {revision[:12]}: {value!r}")
    return value


def community_module():
    """Import the registry helper; a release without community packages needs none."""
    import community as module
    return module


def installer_catalog_path(root):
    """Locate the file defining `etaf-install--targets' and `--system-tools'."""
    for rel in ("core/packages/etaf-install/lisp/etaf-install-catalog.el",
                "core/packages/etaf-install/etaf-install.el",
                "packages/etaf-install/lisp/etaf-install-catalog.el",
                "packages/etaf-install/etaf-install.el",
                "etaf-install.el"):
        candidate = root / rel
        if candidate.is_file():
            return candidate
    return root / "etaf-install.el"


def _parse_installer_catalog(installer_path):
    """Extract curated targets and system-tools defaults from etaf-install."""
    if not installer_path.is_file():
        return {}, {}
    text = installer_path.read_text(encoding="utf-8", errors="replace")
    targets = {}
    t_match = re.search(r"^\(defconst etaf-install--targets\s+'?\((.*?)\)\s+\"", text, re.M | re.S)
    if t_match:
        body = re.sub(r";[^\n]*", "", t_match.group(1))
        for m in re.finditer(r'\(([a-z][a-z0-9-]*)\s+"([^"]*)"\s+([a-z-]+)\s+([a-z0-9-]+)([^)]*)\)', body):
            name, label, group, open_sym, rest = m.groups()
            caps = [tok for tok in rest.split() if tok]
            targets[name] = {
                "group": group,
                "label": label,
                "open": "" if open_sym == "nil" else open_sym,
                "capabilities": caps,
            }
    sys_tools = {}
    s_match = re.search(r"^\(defconst etaf-install--system-tools\s+'?\((.*?)\)\s+\"", text, re.M | re.S)
    if s_match:
        body = re.sub(r";[^\n]*", "", s_match.group(1))
        # Tokenize simple nested S-expressions inside the alist.
        tokens = re.findall(r'"(?:\\.|[^"\\])*"|\(|\)|[^\s()]+', body)
        idx = 0

        def parse_sexp():
            nonlocal idx
            tok = tokens[idx]
            idx += 1
            if tok == "(":
                items = []
                while idx < len(tokens) and tokens[idx] != ")":
                    items.append(parse_sexp())
                if idx < len(tokens):
                    idx += 1
                return items
            if tok.startswith('"') and tok.endswith('"'):
                return tok[1:-1].replace('\\"', '"')
            return tok

        while idx < len(tokens):
            if tokens[idx] != "(":
                idx += 1
                continue
            entry = parse_sexp()
            if not entry or not isinstance(entry[0], str):
                continue
            pkg = entry[0]
            spec = {}
            pos = 1
            while pos + 1 < len(entry):
                key, val = entry[pos], entry[pos + 1]
                pos += 2
                if key == ":required" and isinstance(val, list):
                    spec["required"] = [str(v) for v in val]
                elif key == ":optional" and isinstance(val, list):
                    spec["optional"] = [str(v) for v in val]
                elif key == ":managed-engines" and isinstance(val, list):
                    spec["managed_engines"] = [
                        [str(pair[0]), str(pair[1])] for pair in val
                        if isinstance(pair, list) and len(pair) == 2
                    ]
            if spec:
                sys_tools[pkg] = spec
    return targets, sys_tools


def build_archive_catalog(root, selection, checkpoint, manifest_packages, community_names):
    """Build manifest['catalog'] for every first-party package in the archive.

    Combines workspace.json roles, release-dependencies.json overrides (when
    supplied), etaf-install.el curated defaults and package header summaries so
    installers and archive pages can discover targets dynamically from one
    authoritative manifest.
    """
    valid_groups = {"framework", "extension", "application", "game"}
    inst_targets, inst_tools = _parse_installer_catalog(installer_catalog_path(root))
    pkg_opts = selection.get("packages") or {}
    catalog = {}
    for item in manifest_packages:
        name = item["name"]
        if name in community_names:
            continue
        opts = pkg_opts.get(name) or {}
        curated = inst_targets.get(name) or {}
        role = (checkpoint.get(name) or {}).get("role")
        group = opts.get("group") or curated.get("group") or (
            role if role in valid_groups else ("framework" if name == "etaf-install" else "application")
        )
        label = opts.get("label") or curated.get("label") or item.get("summary") or name
        open_cmd = opts["open"] if "open" in opts else curated.get("open", "")
        caps = opts["capabilities"] if "capabilities" in opts else list(curated.get("capabilities", []))
        record = {
            "group": group,
            "label": str(label),
            "open": str(open_cmd or ""),
            "capabilities": [str(c) for c in caps],
        }
        tools = opts.get("system_tools") if "system_tools" in opts else inst_tools.get(name)
        if isinstance(tools, dict) and tools:
            clean_tools = {}
            if tools.get("required"):
                clean_tools["required"] = [str(t) for t in tools["required"]]
            if tools.get("optional"):
                clean_tools["optional"] = [str(t) for t in tools["optional"]]
            if tools.get("managed_engines"):
                clean_tools["managed_engines"] = [[str(a), str(b)] for a, b in tools["managed_engines"]]
            if clean_tools:
                record["system_tools"] = clean_tools
        catalog[name] = record
    return catalog


def community_packages():
    """Return the packages other authors publish through this archive.

    They are redistributed from their own repositories at a pinned revision, so
    the archive serves their bytes but never owns them. The registry states the
    files to ship, the dependencies this archive guarantees and the license.
    """
    path = ROOT / "scripts" / "community.json"
    if not path.exists():
        return {}
    return community_module().registry()["packages"]


def build(directory):
    """Build from the sealed root and its recorded provider combination."""
    if directory.exists():
        raise ValueError(f"Refusing to replace existing output: {directory}")
    if (ROOT / ".jj").is_dir():
        if run([change_graph_binary(ROOT), "diff", "--name-only"], cwd=ROOT)[0].strip():
            raise ValueError("Seal the workspace change before building a release")
        revision = head_revision(ROOT)
    else:
        if run(["git", "status", "--porcelain"], cwd=ROOT)[0].strip():
            raise ValueError("Commit the workspace change before building a release")
        revision = head_revision(ROOT)
    directory.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".etaf-release-", dir=directory.parent) as work:
        work = Path(work)
        root = work / "workspace"
        export(ROOT, revision, root)
        selection = json.loads((root / "release-dependencies.json").read_text())
        checkpoint = checkpoint_sources(json.loads((root / "workspace.json").read_text()))
        if selection.get("schema") != 1:
            raise ValueError("Unsupported release selection schema")
        installer_sub = subtree_of("etaf-install")
        if installer_sub:
            export(ROOT, revision, work / "etaf-install", subtree=installer_sub)
            sources = {"etaf-install": work / "etaf-install"}
        else:
            sources = {"etaf-install": root}
        resources, provenance = {}, {"etaf-install": revision}
        checkouts = {"etaf-install": ROOT}
        for name, options in selection["packages"].items():
            if name not in checkpoint:
                raise ValueError(f"{name}: not present in the integration checkpoint")
            source = package_directory(name)
            if not source.is_dir():
                raise ValueError(f"Missing provider checkout: {source}; restore the workspace first")
            # One checkout of many packages exports its own directory from the
            # shared revision; a tree of sibling checkouts exports the revision
            # of that checkout.
            entry = checkpoint[name]
            subtree = subtree_of(name)
            if subtree:
                # One checkout of many packages exports its own directory from
                # the shared revision, and history reads that directory.
                pinned = entry.get("revision") or revision
                export(ROOT, pinned, work / name, subtree=subtree)
            else:
                # Sibling checkouts each export the revision the checkpoint
                # pinned for them.
                pinned = entry["revision"]
                export(source, pinned, work / name)
            sources[name] = work / name
            resources[name] = options.get("resources", [])
            provenance[name] = pinned
            checkouts[name] = source
        community_pins = community_packages()
        # A release without community packages must not need the registry helper:
        # a checkout that carries the release tooling but not this archive's
        # community registry still builds.
        community = community_module() if community_pins else None
        paths, declared_require, git_dirs = {}, {}, {}
        for name, record in community_pins.items():
            if name in sources:
                raise ValueError(f"{name}: a community package cannot shadow a workspace package")
            repository = community.fetch(record["url"], name, record["revision"])
            community.export(repository, record["revision"], work / name)
            sources[name] = work / name
            paths[name] = record.get("paths", ())
            if record.get("requires"):
                declared_require[name] = record["requires"]
            provenance[name] = record["revision"]
            git_dirs[name] = repository
        stage = work / "archive"
        manifest = package_archive.build(stage, sources, resources, paths, declared_require)
        updated = {}
        for name in sources:
            shipped = package_archive.source_files(sources[name], name, resources.get(name, ()),
                                                  paths.get(name, ()))
            # History holds the paths of the commit. A package inside a shared
            # checkout asks about its own directory there; a package exported
            # from its own repository asks about the file names as they are.
            local = subtree_of(name)
            traced = [f"{local}/{path}" for path in shipped] if local else shipped
            history = git_dirs.get(name) or git_directory(ROOT if local else checkouts[name])
            updated[name] = last_change(history, provenance[name], traced)
        available = {item["name"]: item["version"] for item in manifest["packages"]}
        for package in manifest["packages"]:
            # A dependency outside the archive must be declared explicitly, so a
            # typo cannot silently pass and the source of every external package
            # stays reviewable in the release selection.
            external = set(selection["packages"].get(package["name"], {}).get("external", []))
            for dependency, minimum in package["requirements"]:
                if dependency == "emacs":
                    continue
                if dependency not in available:
                    if dependency in external:
                        continue
                    raise ValueError(f"{package['name']}: dependency {dependency} is absent")
                if compare_versions(available[dependency], minimum) < 0:
                    raise ValueError(f"{package['name']}: dependency {dependency} is too old")
        manifest["sources"] = provenance
        manifest["updated"] = updated
        if community_pins:
            manifest["community"] = {name: {"url": record["url"],
                                            "license": record.get("license", "unspecified"),
                                            "maintainer": record.get("maintainer", ""),
                                            "group": record.get("group", "application"),
                                            "label": record.get("label", name),
                                            "open": record.get("open", "")}
                                     for name, record in community_pins.items()}
        catalog = build_archive_catalog(root, selection, checkpoint, manifest["packages"], set(community_pins))
        if catalog:
            manifest["catalog"] = catalog
        manifest["workspace"] = revision
        (stage / "manifest.json").write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
        package_archive.verify(stage)
        stage.rename(directory)
    print(f"Built {len(manifest['packages'])} packages from sealed workspace {revision[:12]}\narchive={directory}")


def scan_diagnostics(text, names, warnings=True):
    """Return diagnostics attributable to the packages this archive publishes.

    package.el demotes reload errors to messages without failing the process, so
    both streams are scanned. Third-party dependencies are compiled by hand too:
    their own deprecation warnings and activation errors are not ours to fix and
    must not block a release. Track the package whose compilation or activation
    section is current; a diagnostic from another package is not evidence about
    this archive. Lines before any package context remain visible, so a startup
    error is not hidden. WARNINGS is false for a package another author owns:
    its byte-compiler warnings are theirs to fix, and this archive may not patch
    their code, but a real error still blocks the release.
    """
    diagnostics, current_package = [], None
    pattern = re.compile(
        r"\bWarning(?: \([^\n]*\))?:|(?:^|\s)Error(?::| in | \()|^Eager macro-expansion failure:")
    for line in text.splitlines():
        compiled = re.search(r"\bCompiling (\S+)", line)
        if compiled:
            found = re.search(r"/elpa/([a-z][a-z0-9-]*)-[0-9]", compiled[1])
            current_package = found[1] if found else None
        else:
            checked = re.search(r"\bChecking \S*/elpa/([a-z][a-z0-9-]*)-[0-9]", line)
            generated = re.search(r"\bGEN\s+([a-z][a-z0-9-]*)-autoloads\.el", line)
            if checked:
                current_package = checked[1]
            elif generated:
                current_package = generated[1]
        if not pattern.search(line):
            continue
        if not warnings and "Warning" in line and "Error" not in line:
            continue
        if current_package and current_package not in names:
            continue
        diagnostics.append(line)
    return diagnostics


def standard_archive_roots():
    """Return the external package roots declared by the release selection."""
    selection = json.loads((ROOT / "release-dependencies.json").read_text(encoding="utf-8"))
    roots = []
    for options in selection.get("packages", {}).values():
        roots.extend(options.get("external", []))
    return list(dict.fromkeys(roots))


def verify_standard_archives(directory):
    """Validate a prefetched standard-archive snapshot and return its manifest."""
    manifest_path = directory / "manifest.json"
    if not manifest_path.is_file():
        raise ValueError(f"Prefetched standard archives have no manifest: {directory}")
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    if manifest.get("schema") != 1:
        raise ValueError("Expected a schema 1 prefetched standard archive manifest")
    archives = {}
    for entry in manifest.get("archives") or []:
        name = entry.get("name")
        if name not in {"gnu", "nongnu", "melpa"} or name in archives:
            raise ValueError(f"Invalid or duplicate standard archive: {name!r}")
        index = directory / name / "archive-contents"
        expected = entry.get("sha256")
        if not index.is_file() or hashlib.sha256(index.read_bytes()).hexdigest() != expected:
            raise ValueError(f"Standard archive index checksum mismatch: {name}")
        archives[name] = entry
    missing = {"gnu", "nongnu", "melpa"} - set(archives)
    if missing:
        raise ValueError(f"Prefetched standard archives are missing: {sorted(missing)}")
    for package in manifest.get("packages") or []:
        name, version = package.get("name"), package.get("version")
        archive, filename = package.get("archive"), package.get("file")
        if (not isinstance(name, str) or not re.fullmatch(r"[a-z][a-z0-9-]*", name)
                or not isinstance(version, str) or not re.fullmatch(r"[0-9]+(?:\.[0-9]+)*", version)
                or archive not in archives or not isinstance(filename, str)
                or not re.fullmatch(r"[a-z][a-z0-9-]*-[0-9.]+\.(?:tar|el)", filename)
                or not filename.startswith(f"{name}-{version}")):
            raise ValueError(f"Invalid prefetched package record: {package!r}")
        path = directory / archive / filename
        if not path.is_file() or hashlib.sha256(path.read_bytes()).hexdigest() != package.get("sha256"):
            raise ValueError(f"Prefetched package checksum mismatch: {archive}/{filename}")
        if filename.endswith(".tar"):
            try:
                with tarfile.open(path) as stream:
                    if not stream.getmembers():
                        raise ValueError(f"Empty prefetched package archive: {archive}/{filename}")
            except tarfile.TarError as error:
                raise ValueError(f"Corrupt prefetched package archive: {archive}/{filename}: {error}") from error
    return manifest


@contextlib.contextmanager
def serve_standard_archives(directory):
    """Serve a validated prefetched snapshot on localhost for one verification."""
    verify_standard_archives(directory)

    class QuietHandler(http.server.SimpleHTTPRequestHandler):
        def log_message(self, format, *args):
            pass

    server = http.server.ThreadingHTTPServer(
        ("127.0.0.1", 0), functools.partial(QuietHandler, directory=str(directory)))
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield f"http://127.0.0.1:{server.server_port}/"
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=5)


def prefetch(directory, emacs):
    """Download one live standard-archive snapshot for the CI installation matrix.

    A third-party archive can throttle a shared CI egress address.  Fetching its
    index and the declared external dependency closure once per workflow run,
    then serving that snapshot to every target, keeps installation correctness
    independent of that archive's availability during the matrix.
    """
    roots = standard_archive_roots()
    if not roots:
        print("No external package roots are declared; nothing to prefetch")
        return
    script = ROOT / "scripts/prefetch-standard-archives.el"
    directory.mkdir(parents=True, exist_ok=True)
    env = dict(os.environ, ETAF_PREFETCH_OUTPUT=str(directory),
               ETAF_PREFETCH_ROOTS=",".join(roots))
    env.pop("EMACSLOADPATH", None)
    env.pop("ETAF_INSTALL_STANDARD_ARCHIVES", None)
    last = None
    # A 429 window clears in tens of seconds; retry a few times with jitter so
    # parallel workflow runs do not retry in lockstep.  Existing files are kept,
    # so a retry only fetches what the previous attempt did not finish.
    for attempt, delay in enumerate((0, 10, 30, 60), 1):
        if delay:
            time.sleep(delay + random.uniform(0, delay / 2))
        try:
            stdout, stderr = run([emacs, "-Q", "--batch", "-l", str(script)],
                                 cwd=ROOT, env=env, timeout=300)
            text = (stdout + b"\n" + stderr).decode(errors="replace").strip()
            if text:
                print(text)
            manifest = verify_standard_archives(directory)
            break
        except (ValueError, OSError, subprocess.TimeoutExpired) as error:
            last = error
            print(f"prefetch attempt {attempt} failed: {error}", file=sys.stderr)
    else:
        raise ValueError(
            f"Standard archive prefetch failed after 4 attempts: {last}")
    print(json.dumps({"directory": str(directory), "roots": roots,
                      "packages": len(manifest["packages"])}, indent=2))


def installation_pairs(targets, paths, community):
    """Return the (TARGET, ENTRY) installations a gate must run."""
    pairs = []
    for target in dict.fromkeys(targets):
        wanted = ("package-install",) if target in community else tuple(paths)
        pairs.extend((target, entry) for entry in wanted)
    return pairs


def check_installation(directory, emacs, target, entry, names, community, standard_base, smoke):
    """Install TARGET through ENTRY in one fresh profile and return its result."""
    with tempfile.TemporaryDirectory(prefix="etaf-install-") as profile:
        env = dict(os.environ, ETAF_INSTALL_ARCHIVE=str(directory),
                   ETAF_INSTALL_PROFILE=profile, ETAF_INSTALL_TARGET=target)
        env.pop("EMACSLOADPATH", None)
        env.pop("ETAF_INSTALL_DIRECT", None)
        env.pop("ETAF_INSTALL_STANDARD_ARCHIVES", None)
        if standard_base:
            env["ETAF_INSTALL_STANDARD_ARCHIVES"] = standard_base
            # Emacs url.el ignores NO_PROXY and routes 127.0.0.1 through system
            # proxies, causing spurious gnutls-error failures during local gates.
            for var in PROXY_ENV_VARS:
                env.pop(var, None)
        if entry == "package-install":
            env["ETAF_INSTALL_DIRECT"] = "1"
        started = time.monotonic()
        log = directory / f"installation-{target}-{entry}.log"
        stdout, stderr = run([emacs, "-Q", "--batch", "-l", str(smoke)],
                             cwd=profile, env=env,
                             timeout=INSTALL_TIMEOUT, log_file=log)
        text = (stdout + b"\n" + stderr).decode(errors="replace")
    diagnostics = scan_diagnostics(text, names, target not in community)
    if diagnostics:
        raise ValueError(f"Installation diagnostics for {target}:\n"
                         + "\n".join(diagnostics[:12]) + f"\nlog={log}")
    result = json.loads(stdout)
    if (result.get("status") != "ok" or result.get("target") != target
            or result.get("entry") != entry or not result.get("emacs")
            or not result.get("system")):
        raise ValueError(f"Installation did not verify {target} through {entry}")
    result["seconds"] = round(time.monotonic() - started, 3)
    print(f"Verified {target} through {entry}: Emacs {result['emacs']} on "
          f"{result['system']}; {result['seconds']} s", flush=True)
    return result


def standard_snapshot(explicit, emacs, refresh=False):
    """Return the snapshot verified profiles should install from.

    An explicit directory wins.  Otherwise the cached snapshot is reused, and it
    is fetched once when missing or when REFRESH asks for the current closure.
    Fetching the closure once per verification is what made the gate hit a
    rate limit rather than test the archive.
    """
    if explicit:
        return explicit
    if refresh or not (STANDARD_ARCHIVE_CACHE / "manifest.json").is_file():
        prefetch(STANDARD_ARCHIVE_CACHE, emacs)
    return STANDARD_ARCHIVE_CACHE


def verify(directory, emacs, targets, paths=("etaf-install",), standard_archives=None,
           scope="full", jobs=None, reason=None, live_url=DEFAULT_ARCHIVE_URL):
    """Exercise PATHS in separate disposable profiles.

    `etaf-install' is the documented entry, and it installs through package.el,
    so it is the whole gate by default; `package-install' joins it only for
    community packages, which ETAF does not open, and when the installer itself
    changed and its own path is what needs proving.
    Profiles are independent, so JOBS of them install at once; the work per
    profile is byte-compiling the same dependency tree, which no profile shares.
    A failed attempt invalidates earlier success evidence, including failures
    before Emacs starts. Logs are diagnostic evidence, never publication inputs.
    STANDARD_ARCHIVES serves a prefetched snapshot on localhost; without it the
    installer uses the live archives, as a developer's focused check does.
    """
    report = directory / "installation.json"
    report.unlink(missing_ok=True)
    manifest = package_archive.verify(directory)
    if scope == "auto":
        scope, targets, auto_reason = resolve_auto_scope(directory, targets, live_url)
        reason = reason or auto_reason
        if scope == "selected":
            print(f"Auto-selected {len(targets)} target(s): {', '.join(targets)} ({reason})",
                  flush=True)
    names = [item["name"] for item in manifest["packages"]]
    manifest_digest = hashlib.sha256((directory / "manifest.json").read_bytes()).hexdigest()
    standard_digest = None
    if standard_archives:
        verify_standard_archives(standard_archives)
        standard_digest = hashlib.sha256(
            (standard_archives / "manifest.json").read_bytes()).hexdigest()
    smoke = ROOT / "scripts/install-smoke.el"
    results = []
    snapshot = serve_standard_archives(standard_archives) if standard_archives else contextlib.nullcontext(None)
    with snapshot as standard_base:
        # A community package is not an ETAF target: this installer does not
        # open it and cannot check its capabilities, so it is verified through
        # package.el only, which is how a visitor installs it.
        community_only = set(manifest.get("community", {}))
        run_targets = list(targets) if scope == "selected" else [*targets, *community_only]
        pairs = installation_pairs(run_targets, paths, community_only)
        # Scale parallelism to available CPUs (capped at 8) to keep gates fast
        # without saturating the machine.
        default_jobs = min(os.cpu_count() or 4, 8)
        workers = max(1, min(jobs or default_jobs, len(pairs)))
        with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as pool:
            futures = {pool.submit(check_installation, directory, emacs, target, entry,
                                   names, community_only, standard_base, smoke): (target, entry)
                       for target, entry in pairs}
            for future in concurrent.futures.as_completed(futures):
                # The first failure stops the gate: earlier successes are not
                # evidence once one installation is known to be broken.
                results.append(future.result())
    evidence = {"schema": 1, "scope": scope, "targets": list(dict.fromkeys(targets)),
                "reason": reason,
                "paths": list(dict.fromkeys(paths)),
                "manifest_sha256": manifest_digest,
                "validator_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
                "smoke_sha256": hashlib.sha256(smoke.read_bytes()).hexdigest(),
                "installations": results}
    if standard_digest:
        evidence["standard_archives_sha256"] = standard_digest
    report.write_text(json.dumps(evidence, indent=2, sort_keys=True) + "\n")
    print(f"evidence={report}")


def package_groups():
    """Return {label: {package}} from the workspace roles plus the installer."""
    labels = {"framework": "Framework", "application": "Applications", "game": "Games"}
    groups = {label: set() for label in labels.values()}
    groups["Framework"].add("etaf-install")
    document = json.loads((ROOT / "workspace.json").read_text())
    for name, record in checkpoint_sources(document).items():
        label = labels.get(record.get("role", "application"))
        if label:
            groups[label].add(name)
    return groups


def published(url):
    """List what the live archive actually serves, grouped by role.

    The manifest, not a hand-kept list, is the answer to "what is published";
    this command exists so nobody has to curl and eyeball it.
    """
    with direct_urlopen(url.rstrip("/") + "/manifest.json", timeout=30) as response:
        manifest = json.loads(response.read())
    if manifest.get("schema") != 2 or not manifest.get("packages"):
        raise ValueError("The archive does not serve a schema 2 manifest")
    print(f"archive={url}\nworkspace={manifest.get('workspace', '')[:12]}")
    seen = set()
    # A package published for another author states its own group in the
    # manifest, so the listing places it exactly where the page does.
    groups = package_groups()
    labels = {"framework": "Framework", "application": "Applications", "game": "Games"}
    for name, record in (manifest.get("community") or {}).items():
        label = labels.get(record.get("group", "application"))
        if label:
            groups[label].add(name)
    for group, members in groups.items():
        rows = sorted((item for item in manifest["packages"] if item["name"] in members),
                      key=lambda item: item["name"])
        seen.update(item["name"] for item in rows)
        print(f"\n{group} ({len(rows)}):")
        for item in rows:
            requirements = ", ".join(f"{name} {version}" for name, version in item["requirements"]) or "Emacs"
            print(f"  {item['name']:<20} {item['version']:<8} {requirements}")
    other = sorted(item["name"] for item in manifest["packages"] if item["name"] not in seen)
    if other:
        print("\nUnclassified: " + ", ".join(other))


def stage(directory, output):
    """Export only public archive files after checking complete, current evidence.

    Evidence is local maintainer input, not a signature or a cross-platform
    certification. Partial diagnostic reports are never publication inputs.
    """
    if output.exists():
        raise ValueError(f"Refusing to replace existing output: {output}")
    manifest = package_archive.verify(directory)
    report = json.loads((directory / "installation.json").read_text())
    digests = {"manifest_sha256": directory / "manifest.json",
               "validator_sha256": Path(__file__),
               "smoke_sha256": ROOT / "scripts/install-smoke.el"}
    if report.get("schema") != 1 or any(
            report.get(key) != hashlib.sha256(path.read_bytes()).hexdigest()
            for key, path in digests.items()):
        raise ValueError("Installation evidence is stale; run the full release check again")
    revision = manifest.get("workspace", "")
    if not re.fullmatch(r"[0-9a-f]{40}", revision):
        raise ValueError("Publication requires a sealed workspace build, not a development archive")
    store = git_directory(ROOT)
    checkpoint = checkpoint_sources(json.loads(run(
        ["git", "--git-dir", store, "show", f"{revision}:workspace.json"])[0]))
    selection = json.loads(run(["git", "--git-dir", store, "show",
                                f"{revision}:release-dependencies.json"])[0])
    # The installer is the entry under test, not a target, and dependencies such
    # as ebox are not installed directly: the sealed selection names the targets.
    declare = selection.get("targets") or [item["name"] for item in manifest["packages"]]
    community_only = set(manifest.get("community", {}))
    declared = [name for name in declare if name != "etaf-install"]
    declared += sorted(community_only - set(declared))
    scope = report.get("scope", "full")
    recorded_paths = tuple(report.get("paths") or ("etaf-install",))
    if (not recorded_paths or "etaf-install" not in recorded_paths
            or any(path not in ("etaf-install", "package-install") for path in recorded_paths)):
        raise ValueError("Publication requires the recorded targets through etaf-install")
    def entries(name):
        # Community packages have no ETAF entry; only package.el installs them.
        return ("package-install",) if name in community_only else recorded_paths

    if scope == "full":
        expected = {(name, entry) for name in declared for entry in entries(name)}
    elif scope == "selected":
        # A selected gate names the targets it verified: the release tool picks
        # those whose shipped bytes changed plus the targets that install them,
        # and an unchanged tarball cannot change under its version anyway.
        scoped = report.get("targets") or []
        if not scoped or any(name not in declared for name in scoped):
            raise ValueError("Selected evidence names no declared target")
        expected = {(name, entry) for name in scoped for entry in entries(name)}
    else:
        raise ValueError(f"Unknown installation scope: {scope}")
    installations = report.get("installations", [])
    if (len(installations) != len(expected)
            or {(item.get("target"), item.get("entry")) for item in installations} != expected
            or any(item.get("status") != "ok" or not item.get("emacs")
                   or not item.get("system") for item in installations)
            or len({(item["emacs"], item["system"]) for item in installations}) != 1
            or not re.fullmatch(r"[0-9]+(?:\.[0-9]+)+", installations[0]["emacs"])
            or tuple(map(int, installations[0]["emacs"].split("."))) < (29, 1)):
        raise ValueError("Publication requires the recorded targets through etaf-install")
    # A registry that pins one revision per checkout reports it here; a single
    # checkout of many packages reports the commit they all came from.
    sources = {name: checkpoint[name].get("revision") or revision
               for name in selection["packages"]}
    sources["etaf-install"] = revision
    registry = community_packages()
    for name in manifest.get("community", {}):
        # A community package is served from the revision the registry pins, not
        # from the workspace checkpoint, so publication checks that pin.
        if name not in registry:
            raise ValueError(f"{name}: community package is missing from community.json")
        sources[name] = registry[name]["revision"]
    if (manifest.get("sources") != sources
            or set(sources) != {item["name"] for item in manifest["packages"]}):
        raise ValueError("Package provenance does not match the recorded workspace checkpoint")
    # Construct a public manifest rather than copying unknown fields, local
    # profiles, logs or future private evidence into the served directory.
    public = {"schema": 2, "workspace": revision, "sources": sources, "packages": []}
    if manifest.get("updated"):
        public["updated"] = manifest["updated"]
    if manifest.get("community"):
        public["community"] = manifest["community"]
    if manifest.get("catalog"):
        public["catalog"] = manifest["catalog"]
    for package in manifest["packages"]:
        public["packages"].append({key: package[key] for key in
                                  ("name", "version", "requirements", "summary", "file", "sha256")})
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".etaf-public-", dir=output.parent) as work:
        clean = Path(work) / "packages"
        clean.mkdir()
        for name in ("archive-contents", *(item["file"] for item in public["packages"])):
            if (directory / name).is_symlink():
                raise ValueError(f"Publication input cannot be a symlink: {name}")
            shutil.copyfile(directory / name, clean / name)
        (clean / "manifest.json").write_text(json.dumps(public, indent=2, sort_keys=True) + "\n")
        package_archive.verify(clean)
        clean.rename(output)
    print(f"Public archive prepared; Emacs {installations[0]['emacs']} on {installations[0]['system']}\narchive={output}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command")
    for name in ("build", "verify", "stage", "publish", "published", "prefetch", "sync-requires"):
        command = sub.add_parser(name)
        if name not in ("published", "sync-requires"):
            command.add_argument("--directory", type=Path, required=True)
        if name == "verify":
            command.add_argument("--emacs", default="emacs")
            command.add_argument("--jobs", type=int,
                                 help="Installations to run at once (default: 4, capped by the target count)")
            command.add_argument("--paths", choices=("etaf-install", "package-install", "both"),
                                 default="etaf-install",
                                 help="Installation paths to verify (default: etaf-install)")
            command.add_argument("--target", action="append")
            command.add_argument("--scope", choices=("full", "selected", "auto"), default="full",
                                 help="Record a full gate, a named selection, or auto-select changed targets with drift preflight")
            command.add_argument("--live-url", default=DEFAULT_ARCHIVE_URL,
                                 help="Live archive URL used by --scope auto for drift preflight and change selection")
            command.add_argument("--reason", help="Why a selected gate covers these targets")
            command.add_argument("--standard-archives", type=Path,
                                 help="Serve this prefetched snapshot instead of the cached one")
            command.add_argument("--refresh-standard-archives", action="store_true",
                                 help="Fetch the external dependency closure again")
        elif name == "prefetch":
            command.add_argument("--emacs", default="emacs")
        elif name == "stage":
            command.add_argument("--output", type=Path, required=True)
        elif name == "published":
            command.add_argument("--url", default="https://etaf.top/packages/")
        elif name == "sync-requires":
            command.add_argument("--package", action="append", default=[],
                                 help="Limit check/sync to named release package(s) (repeatable)")
            command.add_argument("--changed-only", action="store_true",
                                 help="Limit check/sync to packages whose archive bytes differ from --live-url")
            command.add_argument("--directory", type=Path,
                                 help="Optional built archive directory used with --changed-only")
            command.add_argument("--live-url", default=DEFAULT_ARCHIVE_URL,
                                 help="Live archive URL used with --changed-only")
            mode = command.add_mutually_exclusive_group()
            mode.add_argument("--check", action="store_true",
                              help="Exit non-zero if any stale internal Package-Requires bound is found")
            mode.add_argument("--write", action="store_true",
                              help="Rewrite stale internal Package-Requires bounds in package entry .el files")
            command.add_argument("--json", action="store_true",
                                 help="Emit machine-readable JSON output")
    arguments = sys.argv[1:]
    if not arguments or arguments == ["help"]:
        parser.print_help()
        return 0
    if arguments[0] == "help":
        arguments = [*arguments[1:], "--help"]
    args = parser.parse_args(arguments)
    if args.command == "build":
        build(args.directory.resolve())
    elif args.command == "prefetch":
        prefetch(args.directory.resolve(), args.emacs)
    elif args.command == "verify":
        paths = ("etaf-install", "package-install") if args.paths == "both" else (args.paths,)
        verify(args.directory.resolve(), args.emacs, args.target or release_targets(), paths,
               standard_snapshot(
                   args.standard_archives.resolve() if args.standard_archives else None,
                   args.emacs, args.refresh_standard_archives),
               args.scope, args.jobs, args.reason, args.live_url)
    elif args.command == "stage":
        stage(args.directory.resolve(), args.output.resolve())
    elif args.command == "published":
        published(args.url)
    elif args.command == "sync-requires":
        return sync_requires(
            packages=args.package or None,
            changed_only=args.changed_only,
            live_url=args.live_url,
            directory=args.directory.resolve() if args.directory else None,
            write=args.write,
            check=args.check,
            json_mode=args.json,
        )
    else:
        # The site publisher owns transport, deployment locking and rollback.
        # It invokes stage before contacting the host and never uploads reports.
        # The site publisher lives in the manual's checkout, which the package
        # container holds when every package shares one tree.
        manual = package_directory("etaf-manual")
        site = (manual if manual.is_dir() else ROOT / "etaf-manual") / "site" / "scripts" / "publish.py"
        return subprocess.call([sys.executable, str(site),
                                "--packages-only", str(args.directory.resolve())])
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (ValueError, OSError, KeyError, subprocess.TimeoutExpired, tarfile.TarError) as error:
        print(f"error=release\nhint={error}", file=sys.stderr)
        sys.exit(1)
    except KeyboardInterrupt:
        print("Release operation interrupted; temporary processes and profiles removed", file=sys.stderr)
        sys.exit(130)
