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
import shutil
import subprocess
import sys
import tarfile
import tempfile
import time

import package_archive

ROOT = Path(__file__).resolve().parents[1]


def checkpoint_sources(document):
    """Return every pinned repository, framework providers and applications.

    Framework providers and applications live in two workspaces with their own
    checkpoints; a release pins both, so provenance is read from either section.
    """
    return {**document.get("repositories", {}), **document.get("applications", {})}
TARGETS = ("etaf-ui", "etaf", "etaf-manual", "ekp", "etaf-db",
           "etaf-md-preview", "etaf-video-player", "etaf-desktop")


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
        checkpoint = checkpoint_sources(json.loads((root / "workspace.json").read_text()))
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


GROUPS = {
    "Framework": {"etaf-install", "etaf-ui", "etaf", "ebox", "ecss", "ekp", "etaf-db", "etaf-manual"},
    "Applications": {"etaf-md-preview", "etaf-rss", "etaf-reader", "etaf-algo-lab", "etaf-screensaver",
                     "etaf-desktop", "etaf-miniflux", "etaf-ncm", "etaf-weread", "etaf-bili",
                     "etaf-youtube", "etaf-pi", "etaf-telega", "etaf-ascii-video",
                     "etaf-video-player", "etaf-video-studio"},
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
    if not set(TARGETS).issubset({item["name"] for item in manifest["packages"]}):
        raise ValueError("Publication requires the complete supported package selection")
    report = json.loads((directory / "installation.json").read_text())
    digests = {"manifest_sha256": directory / "manifest.json",
               "validator_sha256": Path(__file__),
               "smoke_sha256": ROOT / "scripts/install-smoke.el"}
    if report.get("schema") != 1 or any(
            report.get(key) != hashlib.sha256(path.read_bytes()).hexdigest()
            for key, path in digests.items()):
        raise ValueError("Installation evidence is stale; run the full release check again")
    expected = {(target, entry) for target in TARGETS
                for entry in ("etaf-install", "package-install")}
    installations = report.get("installations", [])
    if (len(installations) != len(expected)
            or {(item.get("target"), item.get("entry")) for item in installations} != expected
            or any(item.get("status") != "ok" or not item.get("emacs")
                   or not item.get("system") for item in installations)
            or len({(item["emacs"], item["system"]) for item in installations}) != 1
            or not re.fullmatch(r"[0-9]+(?:\.[0-9]+)+", installations[0]["emacs"])
            or tuple(map(int, installations[0]["emacs"].split("."))) < (29, 1)):
        raise ValueError("Publication requires every target through both installation paths")
    revision = manifest.get("workspace", "")
    if not re.fullmatch(r"[0-9a-f]{40}", revision):
        raise ValueError("Publication requires a sealed workspace build, not a development archive")
    store = git_directory(ROOT)
    checkpoint = checkpoint_sources(json.loads(run(
        ["git", "--git-dir", store, "show", f"{revision}:workspace.json"])[0]))
    selection = json.loads(run(["git", "--git-dir", store, "show",
                                f"{revision}:release-dependencies.json"])[0])
    sources = {name: checkpoint[name]["revision"] for name in selection["packages"]}
    sources["etaf-install"] = revision
    if (manifest.get("sources") != sources
            or set(sources) != {item["name"] for item in manifest["packages"]}):
        raise ValueError("Package provenance does not match the recorded workspace checkpoint")
    # Construct a public manifest rather than copying unknown fields, local
    # profiles, logs or future private evidence into the served directory.
    public = {"schema": 2, "workspace": revision, "sources": sources, "packages": []}
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
    for name in ("build", "verify", "stage", "publish", "published"):
        command = sub.add_parser(name)
        if name != "published":
            command.add_argument("--directory", type=Path, required=True)
        if name == "verify":
            command.add_argument("--emacs", default="emacs")
            command.add_argument("--direct", action="store_true", help="Only verify package-install (default: both installation paths)")
            command.add_argument("--target", action="append", choices=TARGETS)
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
    elif args.command == "verify":
        verify(args.directory.resolve(), args.emacs, args.target or TARGETS, args.direct)
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
