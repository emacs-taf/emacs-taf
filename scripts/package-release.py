#!/usr/bin/env python3
"""Build and verify the official ETAF package archive.

The workspace checkpoint supplies exact provider revisions.  Runtime resource
selection lives in release-dependencies.json.  Source export reads Git objects,
never uncommitted files or compiled caches.  Verification uses disposable Emacs
profiles with no source load paths.  User Emacs profiles are never touched.
"""
from __future__ import annotations

import argparse
import hashlib
import io
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import tarfile
import tempfile
import time

import package_archive

ROOT = Path(__file__).resolve().parents[1]


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
    with tempfile.TemporaryDirectory(prefix=".etaf-release-", dir=directory.parent) as work:
        work = Path(work)
        root = work / "workspace"
        export(ROOT, revision, root)
        selection = json.loads((root / "release-dependencies.json").read_text())
        checkpoint = json.loads((root / "workspace.json").read_text())["repositories"]
        if selection.get("schema") != 1:
            raise ValueError("Unsupported release selection schema")
        sources, resources, provenance = {"etaf-install": root}, {}, {"etaf-install": revision}
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
        stage = work / "archive"
        manifest = package_archive.build(stage, sources, resources)
        available = {item["name"]: item["version"] for item in manifest["packages"]}
        for package in manifest["packages"]:
            for dependency, minimum in package["requirements"]:
                if dependency == "emacs":
                    continue
                if dependency not in available:
                    raise ValueError(f"{package['name']}: dependency {dependency} is absent")
                actual = tuple(map(int, available[dependency].split(".")))
                required = tuple(map(int, minimum.split(".")))
                length = max(len(actual), len(required))
                if actual + (0,) * (length - len(actual)) < required + (0,) * (length - len(required)):
                    raise ValueError(f"{package['name']}: dependency {dependency} is too old")
        manifest["sources"] = provenance
        manifest["workspace"] = revision
        (stage / "manifest.json").write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
        stage.rename(directory)
    print(f"Built {len(manifest['packages'])} packages from sealed workspace {revision[:12]}\narchive={directory}")


def verify(directory, emacs, targets, direct=False):
    """Exercise entry and standard installs in separate disposable profiles.

    A failed attempt invalidates earlier success evidence, including failures
    before Emacs starts. Logs are diagnostic evidence, never publication inputs.
    """
    report = directory / "installation.json"
    report.unlink(missing_ok=True)
    package_archive.verify(directory)
    manifest_digest = hashlib.sha256((directory / "manifest.json").read_bytes()).hexdigest()
    smoke = ROOT / "scripts/install-smoke.el"
    results = []
    for target in dict.fromkeys(targets):
        for direct_mode in ((True,) if direct else (False, True)):
            with tempfile.TemporaryDirectory(prefix="etaf-install-") as profile:
                env = dict(os.environ, ETAF_INSTALL_ARCHIVE=str(directory),
                           ETAF_INSTALL_PROFILE=profile, ETAF_INSTALL_TARGET=target)
                env.pop("EMACSLOADPATH", None)
                env.pop("ETAF_INSTALL_DIRECT", None)
                if direct_mode:
                    env["ETAF_INSTALL_DIRECT"] = "1"
                entry = "package-install" if direct_mode else "etaf-install"
                started = time.monotonic()
                log = directory / f"installation-{target}-{'direct' if direct_mode else 'entry'}.log"
                stdout, stderr = run([emacs, "-Q", "--batch", "-l", str(smoke)],
                                     cwd=profile, env=env, timeout=180, log_file=log)
                # package.el demotes reload errors to messages without failing
                # the process. Neither output stream may hide such diagnostics.
                text = (stdout + b"\n" + stderr).decode(errors="replace")
                diagnostics = [line for line in text.splitlines() if re.search(
                    r"\bWarning(?: \([^\n]*\))?:|(?:^|\s)Error(?::| in | \()|^Eager macro-expansion failure:", line)]
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
    evidence = {"schema": 1, "manifest_sha256": manifest_digest,
                "validator_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
                "smoke_sha256": hashlib.sha256(smoke.read_bytes()).hexdigest(),
                "installations": results}
    report.write_text(json.dumps(evidence, indent=2, sort_keys=True) + "\n")
    print(f"evidence={report}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command")
    for name in ("build", "verify"):
        command = sub.add_parser(name)
        command.add_argument("--directory", type=Path, required=True)
        if name == "verify":
            command.add_argument("--emacs", default="emacs")
            command.add_argument("--direct", action="store_true", help="Only verify package-install (default: both installation paths)")
            command.add_argument("--target", action="append", choices=("etaf-ui", "etaf", "etaf-manual", "ekp", "etaf-db"))
    arguments = sys.argv[1:]
    if not arguments or arguments == ["help"]:
        parser.print_help()
        return 0
    if arguments[0] == "help":
        arguments = [*arguments[1:], "--help"]
    args = parser.parse_args(arguments)
    if args.command == "build":
        build(args.directory.resolve())
    else:
        verify(args.directory.resolve(), args.emacs, args.target or ["etaf-ui", "etaf", "etaf-manual", "ekp", "etaf-db"], args.direct)
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
