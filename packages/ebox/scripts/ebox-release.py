#!/usr/bin/env python3
"""Build deterministic package.el archives and verify clean-room installation.

Use `make release-check RELEASE_DIR=/tmp/ebox-release EMACS=/path/to/emacs`.
Only the explicit output directory is retained; subprocesses have timeouts and
temporary checkouts/installations are removed on success, error, or interruption.
No command publishes, changes a source checkout, or installs into the user profile.
"""

import argparse
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import tempfile

import package_archive

ROOT = Path(__file__).resolve().parents[1]


def run(args, cwd=None, env=None, timeout=180):
    """Run a bounded subprocess; include its output on failure."""
    process = subprocess.Popen(args, cwd=cwd, env=env, stdout=subprocess.PIPE,
                               stderr=subprocess.PIPE, text=True,
                               start_new_session=(os.name != "nt"))
    try:
        stdout, stderr = process.communicate(timeout=timeout)
    except (subprocess.TimeoutExpired, KeyboardInterrupt):
        if os.name == "nt":
            subprocess.run(["taskkill", "/PID", str(process.pid), "/T", "/F"],
                           capture_output=True, timeout=20, check=False)
        else:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        process.communicate()
        raise
    if process.returncode:
        raise RuntimeError(f"Command failed: {args[0]}\n{stdout}{stderr}")
    return stdout


def lock_entries(lock, with_ekp=False):
    """Validate and select required dependencies and the optional KP provider."""
    if lock.get("schema") != 1 or set(lock.get("dependencies", {})) != {"ecss"}:
        raise ValueError("Expected schema 1 with pinned ecss dependencies")
    entries = dict(lock["dependencies"])
    if with_ekp:
        entries["ekp"] = lock["optional"]["ekp"]
    for name, entry in entries.items():
        if not re.fullmatch(r"[0-9a-f]{40}", entry["revision"]):
            raise ValueError(f"{name}: revision must be a full commit hash")
        if not entry["url"].startswith("https://"):
            raise ValueError(f"{name}: public dependency URL must use HTTPS")
    return entries


def checkout_dependencies(directory, entries):
    """Fetch exact commits into a new directory; never replace a checkout."""
    if directory.exists():
        raise ValueError(f"Refusing to replace existing dependency directory: {directory}")
    directory.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".ebox-deps-", dir=directory.parent) as work:
        stage = Path(work) / "deps"
        stage.mkdir()
        env = dict(os.environ, GIT_TERMINAL_PROMPT="0")
        for name, entry in entries.items():
            target = stage / name
            run(["git", "init", "-q", str(target)])
            run(["git", "fetch", "--quiet", "--depth", "1", entry["url"],
                 entry["revision"]], cwd=target, env=env)
            run(["git", "checkout", "--quiet", "--detach", "FETCH_HEAD"], cwd=target)
            if run(["git", "rev-parse", "HEAD"], cwd=target).strip() != entry["revision"]:
                raise ValueError(f"{name}: fetched revision mismatch")
        stage.rename(directory)


def checkout_state(directory):
    """Inspect either a Git checkout or a secondary jj workspace."""
    if (directory / ".jj").is_dir():
        revision = run(["jj", "log", "-r", "@-", "--no-graph", "-T", "commit_id"], cwd=directory).strip()
        dirty = run(["jj", "diff", "--name-only"], cwd=directory).strip()
    else:
        revision = run(["git", "rev-parse", "HEAD"], cwd=directory).strip()
        dirty = run(["git", "status", "--porcelain", "--untracked-files=all"], cwd=directory).strip()
    return revision, dirty


def validate_dependencies(directory, entries):
    """Reject stale or modified explicit dependency checkouts."""
    for name, entry in entries.items():
        target = directory / name
        revision, dirty = checkout_state(target)
        if revision != entry["revision"] or dirty:
            raise ValueError(f"{name}: dependency must be clean at {entry['revision']}")


def build(output, root, dependencies, entries):
    """Atomically publish a local archive directory after all packages build."""
    if output.exists():
        raise ValueError(f"Refusing to replace existing release directory: {output}")
    validate_dependencies(dependencies, entries)
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".ebox-release-", dir=output.parent) as work:
        stage = Path(work) / "archive"
        stage.mkdir()
        packages = [package_archive.write_package(
            stage, dependencies / name, name,
            ("dictionaries", "native") if name == "ekp" else ()) for name in entries]
        packages.append(package_archive.write_package(stage, root, "ebox", ("docs",)))
        manifest = package_archive.write_index(stage, packages)
        revision, dirty = checkout_state(root)
        manifest.update(dependencies=entries, source_revision=revision, source_dirty=bool(dirty))
        (stage / "manifest.json").write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
        stage.rename(output)
    return manifest


def verify(directory, emacs):
    """Install source archives in a disposable package-user-dir and exercise Ebox."""
    package_archive.verify(directory)
    with tempfile.TemporaryDirectory(prefix="ebox-install-") as work:
        env = dict(os.environ, EBOX_RELEASE_ARCHIVE=str(directory),
                   EBOX_RELEASE_PROFILE=work)
        # No repository or sibling load paths, HOME changes, network archive refresh,
        # or user package installation.  package.el compiles only this temp profile.
        result = run([emacs, "-Q", "--batch", "-l", str(ROOT / "scripts/ebox-release-smoke.el")],
                     cwd=work, env=env, timeout=600)
        print(result.strip())


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("deps", "build", "verify"))
    parser.add_argument("--directory", type=Path, required=True,
                        help="New deps/build output directory, or archive to verify")
    parser.add_argument("--dependencies", type=Path, help="Explicit pinned dependency checkout directory")
    parser.add_argument("--with-ekp", action="store_true", help="Include optional Knuth-Plass provider")
    parser.add_argument("--emacs", default="emacs", help="Emacs executable for verify")
    arguments = sys.argv[1:]
    if not arguments or arguments[0] == "help":
        parser.print_help()
        return
    args = parser.parse_args(arguments)
    directory = args.directory.resolve()
    entries = lock_entries(json.loads((ROOT / "release-dependencies.json").read_text()), args.with_ekp)
    if args.command == "deps":
        checkout_dependencies(directory, entries)
        print(f"Pinned dependencies ready: {directory}")
    elif args.command == "build":
        if args.dependencies:
            manifest = build(directory, ROOT, args.dependencies.resolve(), entries)
        else:
            with tempfile.TemporaryDirectory(prefix="ebox-release-deps-") as work:
                dependencies = Path(work) / "deps"
                checkout_dependencies(dependencies, entries)
                manifest = build(directory, ROOT, dependencies, entries)
        print(json.dumps({"archive": str(directory), "packages": manifest["packages"]}, indent=2))
    else:
        verify(directory, args.emacs)


if __name__ == "__main__":
    try:
        main()
    except (ValueError, KeyError, RuntimeError, OSError, subprocess.TimeoutExpired) as error:
        print(f"release verification failed: {error}", file=sys.stderr)
        sys.exit(1)
    except KeyboardInterrupt:
        print("release operation interrupted; temporary resources removed", file=sys.stderr)
        sys.exit(130)
