#!/usr/bin/env python3
"""Build and verify the official ETAF package archive.

The workspace checkpoint supplies exact provider revisions.  Runtime resource
selection lives in release-dependencies.json.  Source export reads Git objects,
never uncommitted files or compiled caches.  Verification uses disposable Emacs
profiles with no source load paths.  User Emacs profiles are never touched.
"""
from __future__ import annotations

import argparse
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

ROOT = Path(__file__).resolve().parents[1]


# An install smoke compiles the target's dependencies from source; a large
# package (telega pulls about two hundred files from MELPA) needs more than
# five minutes on a quiet machine, and this gate decides correctness, not
# latency.
INSTALL_TIMEOUT = 900


def checkpoint_sources(document):
    """Return every pinned repository in the workspace registry.

    One workspace owns every checkout, so the release pins one section; a
    provenance entry is keyed by the package name the archive installs.
    """
    return document.get("repositories", {})
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
    except (subprocess.TimeoutExpired, KeyboardInterrupt):
        if os.name == "nt":
            subprocess.run(["taskkill", "/PID", str(process.pid), "/T", "/F"],
                           capture_output=True, timeout=20, check=False)
        else:
            os.killpg(process.pid, signal.SIGKILL)
        process.communicate()
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


def git_directory(source):
    """Locate the Git object store of either a normal checkout or a jj workspace."""
    if (source / ".jj").is_dir():
        return run(["jj", "git", "root"], cwd=source)[0].decode().strip()
    return run(["git", "rev-parse", "--absolute-git-dir"], cwd=source)[0].decode().strip()


def export(source, revision, destination):
    """Export a sealed source revision; do not compile or change its checkout."""
    if not re.fullmatch(r"[0-9a-f]{40}", revision):
        raise ValueError("Source revisions must be full Git commit IDs")
    raw, _ = run(["git", "--git-dir", git_directory(source), "archive", revision])
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
    if not re.fullmatch(r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}[+-][0-9]{2}:[0-9]{2}", value):
        raise ValueError(f"Cannot date the newest change of {revision[:12]}: {value!r}")
    return value


def community_module():
    """Import the registry helper; a release without community packages needs none."""
    import community as module
    return module


def community_packages():
    """Return the packages other authors publish through this archive.

    They are redistributed from their own repositories at a pinned revision, so
    the archive serves their bytes but never owns them. The registry states the
    files to ship, the dependencies this archive guarantees and the license.
    """
    path = ROOT / "community.json"
    if not path.exists():
        return {}
    return community_module().registry()["packages"]


def build(directory):
    """Build from the sealed root and its recorded provider combination."""
    if directory.exists():
        raise ValueError(f"Refusing to replace existing output: {directory}")
    if (ROOT / ".jj").is_dir():
        if run(["jj", "diff", "--name-only"], cwd=ROOT)[0].strip():
            raise ValueError("Seal the workspace change before building a release")
        revision = run(["jj", "log", "-r", "@-", "--no-graph", "-T", "commit_id"], cwd=ROOT)[0].decode().strip()
    else:
        if run(["git", "status", "--porcelain"], cwd=ROOT)[0].strip():
            raise ValueError("Commit the workspace change before building a release")
        revision = run(["git", "rev-parse", "HEAD"], cwd=ROOT)[0].decode().strip()
    directory.parent.mkdir(parents=True, exist_ok=True)
    community = community_module()
    with tempfile.TemporaryDirectory(prefix=".etaf-release-", dir=directory.parent) as work:
        work = Path(work)
        root = work / "workspace"
        export(ROOT, revision, root)
        selection = json.loads((root / "release-dependencies.json").read_text())
        checkpoint = checkpoint_sources(json.loads((root / "workspace.json").read_text()))
        if selection.get("schema") != 1:
            raise ValueError("Unsupported release selection schema")
        sources, resources, provenance = {"etaf-install": root}, {}, {"etaf-install": revision}
        checkouts = {"etaf-install": ROOT}
        for name, options in selection["packages"].items():
            if name not in checkpoint:
                raise ValueError(f"{name}: not present in the integration checkpoint")
            source = ROOT / name
            if not source.is_dir():
                raise ValueError(f"Missing provider checkout: {source}; restore the workspace first")
            entry = checkpoint[name]
            export(source, entry["revision"], work / name)
            sources[name] = work / name
            resources[name] = options.get("resources", [])
            provenance[name] = entry["revision"]
            checkouts[name] = source
        community_pins = community_packages()
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
            updated[name] = last_change(git_dirs.get(name) or git_directory(checkouts[name]),
                                        provenance[name], shipped)
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
                actual = tuple(map(int, available[dependency].split(".")))
                required = tuple(map(int, minimum.split(".")))
                length = max(len(actual), len(required))
                if actual + (0,) * (length - len(actual)) < required + (0,) * (length - len(required)):
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
        manifest["workspace"] = revision
        (stage / "manifest.json").write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
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


def verify(directory, emacs, targets, direct=False, standard_archives=None, scope="full"):
    """Exercise entry and standard installs in separate disposable profiles.

    A failed attempt invalidates earlier success evidence, including failures
    before Emacs starts. Logs are diagnostic evidence, never publication inputs.
    STANDARD_ARCHIVES serves a prefetched snapshot on localhost; without it the
    installer uses the live archives, as a developer's focused check does.
    """
    report = directory / "installation.json"
    report.unlink(missing_ok=True)
    manifest = package_archive.verify(directory)
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
        for target in dict.fromkeys([*targets, *community_only]):
            modes = (True,) if direct or target in community_only else (False, True)
            for direct_mode in modes:
                with tempfile.TemporaryDirectory(prefix="etaf-install-") as profile:
                    env = dict(os.environ, ETAF_INSTALL_ARCHIVE=str(directory),
                               ETAF_INSTALL_PROFILE=profile, ETAF_INSTALL_TARGET=target)
                    env.pop("EMACSLOADPATH", None)
                    env.pop("ETAF_INSTALL_DIRECT", None)
                    env.pop("ETAF_INSTALL_STANDARD_ARCHIVES", None)
                    if standard_base:
                        env["ETAF_INSTALL_STANDARD_ARCHIVES"] = standard_base
                    if direct_mode:
                        env["ETAF_INSTALL_DIRECT"] = "1"
                    entry = "package-install" if direct_mode else "etaf-install"
                    started = time.monotonic()
                    log = directory / f"installation-{target}-{'direct' if direct_mode else 'entry'}.log"
                    stdout, stderr = run([emacs, "-Q", "--batch", "-l", str(smoke)],
                                         cwd=profile, env=env,
                                         timeout=INSTALL_TIMEOUT, log_file=log)
                    text = (stdout + b"\n" + stderr).decode(errors="replace")
                    diagnostics = scan_diagnostics(text, names, target not in community_only)
                    if diagnostics:
                        raise ValueError(f"Installation diagnostics for {target}:\n"
                                         + "\n".join(diagnostics[:12]) + f"\nlog={log}")
                    result = json.loads(stdout)
                    if (result.get("status") != "ok" or result.get("target") != target
                            or result.get("entry") != entry or not result.get("emacs")
                            or not result.get("system")):
                        raise ValueError(f"Installation did not verify {target} through {entry}")
                    result["seconds"] = round(time.monotonic() - started, 3)
                    results.append(result)
                    print(f"Verified {target} through {entry}: Emacs {result['emacs']} on {result['system']}; {result['seconds']} s", flush=True)
    evidence = {"schema": 1, "scope": scope, "targets": list(dict.fromkeys(targets)),
                "manifest_sha256": manifest_digest,
                "validator_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
                "smoke_sha256": hashlib.sha256(smoke.read_bytes()).hexdigest(),
                "installations": results}
    if standard_digest:
        evidence["standard_archives_sha256"] = standard_digest
    report.write_text(json.dumps(evidence, indent=2, sort_keys=True) + "\n")
    print(f"evidence={report}")


GROUPS = {
    "Framework": {"etaf-install", "etaf-ui", "etaf", "ebox", "ecss", "ekp", "etaf-db"},
    "Applications": {"etaf-md-preview", "etaf-rss", "etaf-reader", "etaf-algo-lab", "etaf-screensaver",
                     "etaf-desktop", "etaf-miniflux", "etaf-ncm", "etaf-weread", "etaf-bili",
                     "etaf-youtube", "etaf-pi", "etaf-telega", "etaf-ascii-video",
                     "etaf-video-player", "etaf-video-studio", "etaf-manual", "etaf-telega"},
    "Games": {"etaf-gamekit", "etaf-solitaire", "etaf-xiangqi", "etaf-tanks", "etaf-salvage"},
}


def published(url):
    """List what the live archive actually serves, grouped by role.

    The manifest, not a hand-kept list, is the answer to "what is published";
    this command exists so nobody has to curl and eyeball it.
    """
    from urllib.request import urlopen
    with urlopen(url.rstrip("/") + "/manifest.json", timeout=30) as response:
        manifest = json.loads(response.read())
    if manifest.get("schema") != 2 or not manifest.get("packages"):
        raise ValueError("The archive does not serve a schema 2 manifest")
    print(f"archive={url}\nworkspace={manifest.get('workspace', '')[:12]}")
    seen = set()
    for group, members in GROUPS.items():
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
    def entries(name):
        # Community packages have no ETAF entry; only package.el installs them.
        return ("package-install",) if name in community_only else ("etaf-install", "package-install")

    if scope == "full":
        expected = {(name, entry) for name in declared for entry in entries(name)}
    elif scope == "presentation":
        # A presentation-only release names the changed targets explicitly; the
        # release tool only chooses this scope after diffing the shipped files.
        scoped = report.get("targets") or []
        if not scoped or any(name not in declared for name in scoped):
            raise ValueError("Presentation evidence names no declared target")
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
        raise ValueError("Publication requires the recorded targets through both installation paths")
    sources = {name: checkpoint[name]["revision"] for name in selection["packages"]}
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
    for name in ("build", "verify", "stage", "publish", "published", "prefetch"):
        command = sub.add_parser(name)
        if name != "published":
            command.add_argument("--directory", type=Path, required=True)
        if name == "verify":
            command.add_argument("--emacs", default="emacs")
            command.add_argument("--direct", action="store_true", help="Only verify package-install (default: both installation paths)")
            command.add_argument("--target", action="append")
            command.add_argument("--scope", choices=("full", "presentation"), default="full",
                                 help="Record a full gate or a scoped presentation-only gate")
            command.add_argument("--standard-archives", type=Path,
                                 help="Serve a prefetched standard archive snapshot instead of live archives")
        elif name == "prefetch":
            command.add_argument("--emacs", default="emacs")
        elif name == "stage":
            command.add_argument("--output", type=Path, required=True)
        elif name == "published":
            command.add_argument("--url", default="https://etaf.top/packages/")
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
        verify(args.directory.resolve(), args.emacs, args.target or release_targets(), args.direct,
               args.standard_archives.resolve() if args.standard_archives else None,
               args.scope)
    elif args.command == "stage":
        stage(args.directory.resolve(), args.output.resolve())
    elif args.command == "published":
        published(args.url)
    else:
        # The site publisher owns transport, deployment locking and rollback.
        # It invokes stage before contacting the host and never uploads reports.
        return subprocess.call([sys.executable, str(ROOT / "etaf-manual/site/scripts/publish.py"),
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
