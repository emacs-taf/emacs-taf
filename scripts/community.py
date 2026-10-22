#!/usr/bin/env python3
"""Register and refresh packages other authors build with ETAF.

A community package is owned elsewhere: the registry pins one revision of the
author's repository, states which files to ship, which dependencies this
archive guarantees, and under which license the code is redistributed. `add`
and `update` fetch the author's repository into a cache, validate the revision
and rewrite `community.json`; the release build reads the same cache, so a
release never depends on what the remote happens to serve that day.

Refreshing refuses to move a revision whose package version did not change: the
archive may not serve different bytes for a version it already published.
"""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

import package_archive

ROOT = Path(__file__).resolve().parents[1]
REGISTRY = ROOT / "community.json"
CACHE = Path(os.environ.get("ETAF_COMMUNITY_CACHE", Path.home() / ".cache" / "etaf-community"))
COMMIT = re.compile(r"[0-9a-f]{40}\Z")
NOTICE_PATHS = ["*.el", "README*", "Readme*", "LICENSE*", "License*", "LICENCE*", "Licence*",
                "COPYING*", "NOTICE*", "CHANGELOG*", "Changelog*"]


def run(args, *, cwd=None, timeout=180, check=True):
    result = subprocess.run(args, cwd=cwd, capture_output=True, timeout=timeout)
    if result.returncode and check:
        raise ValueError(f"Command failed ({result.returncode}): {' '.join(args)}\n"
                         + result.stderr.decode(errors="replace").strip()[-800:])
    return result.stdout.decode(errors="replace")


def registry():
    """Read the community registry; an absent file means no community packages."""
    if not REGISTRY.exists():
        return {"schema": 1, "packages": {}}
    document = json.loads(REGISTRY.read_text(encoding="utf-8"))
    if document.get("schema") != 1 or not isinstance(document.get("packages"), dict):
        raise ValueError("community.json must be schema 1 with a packages object")
    return document


def write_registry(document):
    REGISTRY.write_text(json.dumps(document, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def mirror(url, name):
    """Return the cached bare repository of NAME, creating it if absent."""
    if not re.fullmatch(r"https://[A-Za-z0-9._/-]+(?:\\.git)?", url) or ".." in url:
        raise ValueError(f"{name}: invalid repository URL: {url}")
    CACHE.mkdir(parents=True, exist_ok=True)
    target = CACHE / f"{name}.git"
    if not target.exists():
        run(["git", "init", "--bare", "-q", str(target)])
        run(["git", "--git-dir", str(target), "remote", "add", "origin", url])
    return target


def fetch(url, name, revision):
    """Fetch REVISION from the author's repository, then prove it is there."""
    if not COMMIT.fullmatch(revision):
        raise ValueError(f"{name}: revision must be a full Git commit ID")
    repository = mirror(url, name)
    cached = subprocess.run(["git", "--git-dir", str(repository), "cat-file", "-e",
                             f"{revision}^{{commit}}"], capture_output=True)
    if cached.returncode:
        # A cached revision makes a rebuild work offline; only a new pin fetches.
        run(["git", "--git-dir", str(repository), "fetch", "-q", "--no-tags", "--depth=1",
             "origin", revision])
    run(["git", "--git-dir", str(repository), "rev-parse", "--verify", "--quiet",
         f"{revision}^{{commit}}"])
    return repository


def export(repository, revision, destination):
    """Write the author's tree at REVISION into DESTINATION."""
    destination.mkdir(parents=True)
    archive = subprocess.Popen(["git", "--git-dir", str(repository), "archive", revision],
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    extract = subprocess.run(["tar", "-x", "-C", str(destination)], stdin=archive.stdout,
                             capture_output=True, timeout=120)
    archive.stdout.close()
    error = archive.stderr.read().decode(errors="replace")
    archive.wait(timeout=60)
    if archive.returncode or extract.returncode:
        raise ValueError(f"Cannot export {revision[:12]}: {error.strip() or 'git archive failed'}")


def remote_head(url, name):
    """Return the commit the author's default branch points at."""
    output = run(["git", "ls-remote", url, "HEAD"])
    parts = output.split()
    if len(parts) < 1 or not COMMIT.fullmatch(parts[0]):
        raise ValueError(f"{name}: cannot resolve the default branch of {url}")
    return parts[0]


def describe(repository, revision, name):
    """Read the entry's version and summary from the pinned revision."""
    with tempfile.TemporaryDirectory(prefix="etaf-community-") as temporary:
        tree = Path(temporary) / name
        export(repository, revision, tree)
        return package_archive.metadata(tree, name)


def entry(name, options):
    """Return the registry record for NAME, or fail with the reason."""
    if not package_archive.NAME.fullmatch(name):
        raise ValueError(f"Invalid package name: {name}")
    record = dict(options)
    record.setdefault("paths", list(NOTICE_PATHS))
    record.setdefault("license", "unspecified")
    record.setdefault("maintainer", "")
    return record


def add(arguments):
    name = arguments.name or re.sub(r"\.git\Z", "", arguments.url.rstrip("/").rsplit("/", 1)[-1])
    name = re.sub(r"\.el\Z", "", name)
    document = registry()
    if name in document["packages"]:
        raise ValueError(f"{name}: already registered; use update")
    url = arguments.url
    repository = mirror(url, name)
    revision = arguments.revision or remote_head(url, name)
    fetch(url, name, revision)
    info = describe(repository, revision, name)
    record = entry(name, {"url": url, "revision": revision})
    if arguments.path:
        record["paths"] = [*NOTICE_PATHS, *arguments.path]
    if arguments.requires:
        record["requires"] = declared(arguments.requires, name)
    if arguments.license is not None:
        record["license"] = arguments.license
    if arguments.maintainer is not None:
        record["maintainer"] = arguments.maintainer
    document["packages"][name] = record
    write_registry(document)
    return {"package": name, "version": info["version"], "revision": revision,
            "summary": info["summary"]}


def update(arguments):
    document = registry()
    name = arguments.name
    if name not in document["packages"]:
        raise ValueError(f"{name}: not registered; use add")
    record = document["packages"][name]
    revision = arguments.revision or remote_head(record["url"], name)
    if revision == record["revision"]:
        return {"package": name, "revision": revision, "changed": False}
    before = describe(fetch(record["url"], name, record["revision"]), record["revision"], name)
    after = describe(fetch(record["url"], name, revision), revision, name)
    if after["version"] == before["version"] and not arguments.force:
        raise ValueError(
            f"{name}: {after['version']} is unchanged but the revision moved; the archive may not "
            "serve different bytes for a published version, so the author must bump Version "
            "(pass --force only before the first publication)")
    record["revision"] = revision
    write_registry(document)
    return {"package": name, "version": after["version"], "previous": before["version"],
            "revision": revision, "changed": True}


def declared(values, name):
    """Parse NAME=VERSION arguments into the registry's dependency list."""
    pairs = []
    for value in values:
        key, separator, minimum = value.partition("=")
        if not separator:
            raise ValueError(f"{name}: --requires expects NAME=VERSION")
        pairs.append([key.strip(), minimum.strip()])
    return package_archive.normalize_requirements(name, pairs)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    command = parser.add_subparsers(dest="command")
    add_parser = command.add_parser("add", help="Register one package from its repository")
    add_parser.add_argument("url")
    add_parser.add_argument("--name")
    add_parser.add_argument("--revision")
    add_parser.add_argument("--path", action="append", help="Extra glob to ship, repeatable")
    add_parser.add_argument("--requires", action="append", metavar="NAME=VERSION",
                            help="Replace the header's dependencies, repeatable")
    add_parser.add_argument("--license")
    add_parser.add_argument("--maintainer")
    update_parser = command.add_parser("update", help="Move a package to its current revision")
    update_parser.add_argument("name")
    update_parser.add_argument("--revision")
    update_parser.add_argument("--force", action="store_true")
    command.add_parser("list", help="Print the registered packages")
    args_list = sys.argv[1:]
    if not args_list or args_list == ["help"]:
        parser.print_help()
        return 0
    if args_list[0] == "help":
        args_list = [*args_list[1:], "--help"]
    arguments = parser.parse_args(args_list)
    if arguments.command == "add":
        result = add(arguments)
    elif arguments.command == "update":
        result = update(arguments)
    else:
        result = registry()["packages"]
    print(json.dumps(result, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (ValueError, KeyError, OSError, subprocess.SubprocessError) as error:
        print(f"error=community\nhint={error}", file=sys.stderr)
        sys.exit(1)
