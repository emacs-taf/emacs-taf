#!/usr/bin/env python3
"""Deploy a site/package payload under one lock, with HTTP verification and rollback.

Run on the web host with Python 3.10+. package_archive.py must be beside this
script. Only regular files/directories are extracted. The existing web server
configuration is not changed. A failed deployment restores the old current link.
"""
from __future__ import annotations

import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import sys
import tarfile
import tempfile
from urllib.parse import urlsplit
from urllib.request import Request, urlopen

import package_archive

RELEASE = re.compile(r"[0-9]{8}T[0-9]{6}Z(?:-[0-9a-f]{8})?\Z")
PACKAGE = re.compile(r"[a-z][a-z0-9-]*-[0-9]+(?:\.[0-9]+)*\.tar\Z")
NAME = re.compile(r"[a-z][a-z0-9-]*\Z")
SITE_PAGES = ("index.html", "zh-cn/index.html", "introduction/index.html",
              "zh-cn/introduction/index.html", "symbol-index/index.html", "zh-cn/symbol-index/index.html")


def digest(path):
    with path.open("rb") as stream:
        result = hashlib.sha256()
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            result.update(block)
        return result.hexdigest()


def extract(archive, destination):
    """Extract a bounded regular-file payload without trusting tar paths/modes."""
    seen, size = set(), 0
    with tarfile.open(archive) as stream:
        for member in stream:
            path = PurePosixPath(member.name)
            if member.isdir() and member.name in (".", "./"):
                continue
            if (not path.parts or path.is_absolute() or ".." in path.parts
                    or "\\" in member.name or path in seen
                    or not (member.isdir() or member.isfile())):
                raise ValueError(f"Unsafe or duplicate deployment member: {member.name}")
            seen.add(path)
            size += member.size
            if len(seen) > 100000 or size > 1024 ** 3:
                raise ValueError("Deployment payload exceeds the extraction limit")
            target = destination.joinpath(*path.parts)
            if member.isdir():
                target.mkdir(parents=True, exist_ok=True)
            else:
                target.parent.mkdir(parents=True, exist_ok=True)
                with stream.extractfile(member) as source, target.open("xb") as output:
                    shutil.copyfileobj(source, output)
                target.chmod(0o644)


def packages(directory, *, historical=False):
    """Validate the public allowlist; historical tarballs remain downloadable."""
    if directory.is_symlink() or not directory.is_dir():
        raise ValueError("Invalid public package directory")
    manifest = package_archive.verify(directory)
    names = {item["name"] for item in manifest["packages"]}

    def only_pages(path, children=()):
        """A generated directory holds index.html and, at one level, `children`."""
        if path.is_symlink():
            raise ValueError(f"Non-public package path: {path.name}")
        entries = list(path.iterdir())
        if any(entry.is_symlink() for entry in entries):
            raise ValueError(f"Non-public package path: {path.name}")
        top = {entry.name for entry in entries if not entry.is_dir()}
        if top != {"index.html"}:
            raise ValueError(f"Non-public package directory contents: {path.name}")
        for entry in entries:
            if entry.is_dir():
                if entry.name not in children:
                    raise ValueError(f"Non-public package directory: {entry.name}")
                if {child.name for child in entry.iterdir()} != {"index.html"} \
                        or any(child.is_symlink() for child in entry.iterdir()):
                    raise ValueError(f"Non-public package directory: {entry.name}")

    for path in directory.iterdir():
        if path.is_symlink():
            raise ValueError(f"Non-public package file: {path.name}")
        if path.is_dir():
            if path.name in names:
                only_pages(path)
            elif historical:
                # An older release may carry presentation this release dropped;
                # it is never republished, and only tarballs are carried forward.
                continue
            else:
                raise ValueError(f"Non-public package directory: {path.name}")
            continue
        if (not path.is_file()
                or path.name not in ("manifest.json", "archive-contents", "index.html")
                and not PACKAGE.fullmatch(path.name)):
            raise ValueError(f"Non-public package file: {path.name}")
    allowed = {"manifest.json", "archive-contents", "index.html",
               *(item["file"] for item in manifest["packages"])}
    required = {"manifest.json", "archive-contents",
                *(item["file"] for item in manifest["packages"])}
    optional = {"index.html"}
    present = {path.name for path in directory.iterdir()
               if not path.is_dir()}
    pages = {path.name for path in directory.iterdir() if path.is_dir()}
    if not historical and not (
            required <= present and present <= required | optional
            and pages <= names):
        raise ValueError("A new package payload may contain only its indexed files")
    if set(manifest) - {"schema", "packages", "workspace", "sources", "updated", "community"}:
        raise ValueError("Package manifest contains non-public fields")
    for item in manifest["packages"]:
        if set(item) != {"name", "version", "requirements", "summary", "file", "sha256"}:
            raise ValueError("Package metadata contains non-public fields")
    return manifest


def preserve_packages(previous, candidate, mode):
    old = previous / "packages" if previous else None
    new = candidate / "packages"
    if mode == "site":
        if new.exists():
            raise ValueError("Site-only payloads must not replace packages")
        if old and old.exists():
            packages(old, historical=True)
            shutil.copytree(old, new)
        return
    fresh = packages(new)
    if old and old.exists():
        prior = packages(old, historical=True)
        versions = {item["name"]: item["version"] for item in prior["packages"]}
        for item in fresh["packages"]:
            before = versions.get(item["name"])
            if before:
                def version(value):
                    parts = tuple(map(int, value.split(".")))
                    return parts + (0,) * (max(len(before.split(".")), len(item["version"].split("."))) - len(parts))
                if version(item["version"]) < version(before):
                    raise ValueError(f"Package version downgrade refused: {item['name']}")
        for path in old.glob("*.tar"):
            target = new / path.name
            if target.exists():
                if digest(target) != digest(path):
                    raise ValueError(f"Immutable package differs: {path.name}; increment Version")
            else:
                shutil.copyfile(path, target)
    packages(new, historical=True)


def verify_http(release, url, stamp):
    """Check served bytes, not merely a successful HTTP status or a stale page."""
    paths = [Path(page) for page in SITE_PAGES]
    if (release / "packages").is_dir():
        paths.extend(path.relative_to(release)
                     for path in sorted((release / "packages").rglob("*")) if path.is_file())
    for path in paths:
        route = "/" + path.as_posix()
        if path.name == "index.html":
            route = route.removesuffix("index.html")
        request = Request(url.rstrip("/") + route + "?deployment=" + stamp,
                          headers={"Cache-Control": "no-cache"})
        with urlopen(request, timeout=30) as response:
            result = hashlib.sha256()
            for block in iter(lambda: response.read(1024 * 1024), b""):
                result.update(block)
            if response.status != 200 or result.hexdigest() != digest(release / path):
                raise ValueError(f"Published bytes differ: {route}")


def switch(base, release):
    link = base / "current.next"
    link.unlink(missing_ok=True)
    link.symlink_to(release)
    os.replace(link, base / "current")


def deploy(args):
    base = args.base.resolve()
    base.mkdir(parents=True, exist_ok=True)
    releases = base / "releases"
    if releases.is_symlink():
        raise ValueError("Release storage cannot be a symlink")
    releases.mkdir(exist_ok=True)
    with (base / ".deploy.lock").open("a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            raise ValueError("Another deployment holds the site lock; retry after it finishes") from error
        current = base / "current"
        previous = current.resolve(strict=True) if current.is_symlink() else None
        if current.exists() and not current.is_symlink():
            raise ValueError("current must be a symlink")
        if previous and (previous.parent != releases or not previous.is_dir()):
            raise ValueError("current must point to a release in this site")
        release = releases / args.release
        if release.exists() or release.is_symlink():
            raise ValueError("Release identity already exists")
        with tempfile.TemporaryDirectory(prefix=".deploy-", dir=base) as work:
            candidate = Path(work) / "site"
            candidate.mkdir()
            extract(args.archive, candidate)
            if args.mode == "packages":
                if {path.name for path in candidate.iterdir()} != {"packages"}:
                    raise ValueError("Package-only payload must contain only packages/")
                if not previous or not (previous / "index.html").is_file():
                    raise ValueError("Package-only publication requires an existing site")
                for path in previous.iterdir():
                    if path.name == "packages":
                        continue
                    if path.is_symlink() or any(child.is_symlink() for child in path.rglob("*")):
                        raise ValueError("Existing site contains a symlink")
                    if path.is_dir():
                        shutil.copytree(path, candidate / path.name)
                    else:
                        shutil.copyfile(path, candidate / path.name)
            if any(not (candidate / page).is_file() for page in SITE_PAGES):
                raise ValueError("Site payload is missing an English/Chinese entry or reference page")
            preserve_packages(previous, candidate, args.mode)
            # mkdtemp is private, but its moved child must be readable by Caddy.
            for path in [candidate, *candidate.rglob("*")]:
                path.chmod(0o755 if path.is_dir() else 0o644)
            candidate.rename(release)
        try:
            switch(base, release)
            verify_http(release, args.verify_url, args.release)
        except BaseException:
            if previous:
                switch(base, previous)
                try:
                    verify_http(previous, args.verify_url, args.release + "-rollback")
                    print("Rollback verified: previous release is served", file=sys.stderr)
                except Exception as error:
                    print(f"Previous current link restored, but HTTP recovery is unverified: {error}", file=sys.stderr)
            else:
                current.unlink(missing_ok=True)
            if current.resolve() != release:
                shutil.rmtree(release)
            raise
        # Only managed release directories are eligible for pruning. Every active
        # package tarball was carried forward before old release trees are removed.
        history = sorted((path for path in releases.iterdir()
                          if RELEASE.fullmatch(path.name) and path.is_dir() and not path.is_symlink()),
                         key=lambda path: path.stat().st_mtime_ns, reverse=True)
        retain = {release, previous, *history[:args.keep]}
        for path in history:
            if path not in retain:
                try:
                    shutil.rmtree(path)
                except OSError as error:
                    # The new release is already verified and active. Retention
                    # cleanup is maintenance, not a failed content deployment.
                    print(f"Release active; old-release cleanup failed for {path.name}: {error}", file=sys.stderr)
        print(json.dumps({"status": "ok", "release": args.release, "mode": args.mode}))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base", type=Path, default=Path("/srv/etaf.top"))
    parser.add_argument("--archive", type=Path, required=True)
    parser.add_argument("--release", required=True)
    parser.add_argument("--mode", choices=("site", "packages", "combined"), required=True)
    parser.add_argument("--keep", type=int, default=5)
    parser.add_argument("--verify-url", default="https://etaf.top")
    args = parser.parse_args()
    url = urlsplit(args.verify_url)
    if (not RELEASE.fullmatch(args.release) or args.keep < 2
            or url.scheme not in ("https", "http") or not url.netloc
            or url.scheme == "http" and url.hostname not in ("localhost", "127.0.0.1", "::1")
            or url.username or url.password or url.query or url.fragment):
        raise ValueError("Invalid release, retention (minimum 2), or HTTPS verification URL")
    deploy(args)


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, KeyError, tarfile.TarError) as error:
        print(f"error=deployment\nhint={error}", file=sys.stderr)
        sys.exit(1)
