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
VERSION = re.compile(r"[0-9]+(?:\.[0-9]+)*\Z")
SHA256 = re.compile(r"[0-9a-f]{64}\Z")
NATIVE_FILE = re.compile(r"[a-z0-9][a-z0-9._-]*\.(?:dylib|so|dll)\Z")
NATIVE_LIB_NAME = re.compile(r"[a-z0-9][a-z0-9._-]*\.(?:dylib|so(?:\.[0-9]+)*|dll)\Z")
NATIVE_TIMESTAMP = re.compile(
    r"[0-9]{4}-[0-9]{2}-[0-9]{2}(?:T[0-9]{2}:[0-9]{2}:[0-9]{2}(?:[+-][0-9]{2}:[0-9]{2}|Z))?\Z"
)
NATIVE_PLATFORMS = {"darwin-arm64", "darwin-x86_64", "linux-x86_64", "linux-arm64", "windows-x86_64"}
NATIVE_ROLES = {"module", "library"}
NATIVE_STATUSES = {"current", "archived"}
NATIVE_TOP_KEYS = {"schema", "artifacts", "modules"}
NATIVE_REQUIRED_ARTIFACT_KEYS = {"package", "module", "version", "platform", "path", "sha256", "size"}
NATIVE_OPTIONAL_ARTIFACT_KEYS = {"role", "owner_module", "runtime_name", "note", "built_at"}
NATIVE_MODULE_KEYS = {"package", "current_version", "description", "used_by", "versions"}
NATIVE_VERSION_KEYS = {"status", "summary", "min_package_version", "max_package_version", "released"}
MEDIA_TOP_KEYS = {"schema", "assets"}
MEDIA_REQUIRED_ASSET_KEYS = {"namespace", "path", "sha256", "size"}
MEDIA_OPTIONAL_ASSET_KEYS = {"content_type", "width", "height", "note"}
MEDIA_SEGMENT = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]*\Z")
MEDIA_EXTS = frozenset({
    ".webp", ".png", ".jpg", ".jpeg", ".gif", ".svg", ".avif",
    ".mp4", ".webm", ".mov", ".pdf",
})
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


def packages(directory, *, historical=False, partial=False):
    """Validate the public allowlist; historical tarballs remain downloadable.

    PARTIAL accepts a payload that carries only the files it changes: the rest
    arrive from the previous release before the archive is complete.
    """
    if directory.is_symlink() or not directory.is_dir():
        raise ValueError("Invalid public package directory")
    manifest = package_archive.verify(directory, allow_missing=partial)
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
    # An unlisted file is never acceptable; a missing indexed one is exactly what
    # a partial payload means, so completeness is the only relaxed condition.
    if not historical and not (present <= required | optional
                               and pages <= names
                               and (partial or required <= present)):
        raise ValueError("A new package payload may contain only its indexed files")
    if set(manifest) - {"schema", "packages", "workspace", "sources", "updated", "community", "catalog"}:
        raise ValueError("Package manifest contains non-public fields")
    for item in manifest["packages"]:
        if set(item) != {"name", "version", "requirements", "summary", "file", "sha256"}:
            raise ValueError("Package metadata contains non-public fields")
    return manifest


def _validate_native_modules(modules):
    if not isinstance(modules, dict):
        raise ValueError("Native manifest modules catalog must be a JSON object")
    for mod_id, info in modules.items():
        if not isinstance(mod_id, str) or not NAME.fullmatch(mod_id) or not isinstance(info, dict):
            raise ValueError(f"Invalid native module catalog entry: {mod_id!r}")
        if set(info) - NATIVE_MODULE_KEYS:
            raise ValueError(f"Native module catalog entry contains non-public fields: {mod_id}")
        if (not isinstance(info.get("package"), str) or not NAME.fullmatch(info["package"])
                or not isinstance(info.get("current_version"), str) or not VERSION.fullmatch(info["current_version"])
                or not isinstance(info.get("description"), str) or not info["description"].strip()
                or len(info["description"]) > 400):
            raise ValueError(f"Invalid native module catalog fields: {mod_id}")
        used_by = info.get("used_by")
        if used_by is not None:
            if not isinstance(used_by, list) or not all(isinstance(u, str) and NAME.fullmatch(u) for u in used_by):
                raise ValueError(f"Invalid native module used_by list: {mod_id}")
        versions = info.get("versions")
        if versions is not None:
            if not isinstance(versions, dict):
                raise ValueError(f"Invalid native module versions map: {mod_id}")
            for ver, vinfo in versions.items():
                if not isinstance(ver, str) or not VERSION.fullmatch(ver) or not isinstance(vinfo, dict):
                    raise ValueError(f"Invalid native module version entry: {mod_id}@{ver!r}")
                if set(vinfo) - NATIVE_VERSION_KEYS:
                    raise ValueError(f"Native version entry contains non-public fields: {mod_id}@{ver}")
                if vinfo.get("status") not in NATIVE_STATUSES:
                    raise ValueError(f"Invalid native version status: {mod_id}@{ver}")
                summary = vinfo.get("summary")
                if summary is not None and (not isinstance(summary, str) or not summary.strip() or len(summary) > 300):
                    raise ValueError(f"Invalid native version summary: {mod_id}@{ver}")
                for bound in ("min_package_version", "max_package_version"):
                    bval = vinfo.get(bound)
                    if bval is not None and (not isinstance(bval, str) or not VERSION.fullmatch(bval)):
                        raise ValueError(f"Invalid {bound}: {mod_id}@{ver}")
                released = vinfo.get("released")
                if released is not None and (not isinstance(released, str) or not NATIVE_TIMESTAMP.fullmatch(released)):
                    raise ValueError(f"Invalid released timestamp: {mod_id}@{ver}")


def native_artifacts(directory, *, partial=False):
    """Validate public native/ manifest and artifact allowlist."""
    if directory.is_symlink() or not directory.is_dir():
        raise ValueError("Invalid public native directory")
    manifest_path = directory / "manifest.json"
    if manifest_path.is_symlink() or not manifest_path.is_file():
        raise ValueError("Native directory is missing manifest.json")
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    if manifest.get("schema") != 1 or not isinstance(manifest.get("artifacts"), list):
        raise ValueError("Expected a schema 1 native artifact manifest")
    if set(manifest) - NATIVE_TOP_KEYS:
        raise ValueError("Native manifest contains non-public fields")
    if "modules" in manifest:
        _validate_native_modules(manifest["modules"])
    indexed = {}
    for item in manifest["artifacts"]:
        if (not isinstance(item, dict)
                or not NATIVE_REQUIRED_ARTIFACT_KEYS.issubset(item)
                or set(item) - (NATIVE_REQUIRED_ARTIFACT_KEYS | NATIVE_OPTIONAL_ARTIFACT_KEYS)
                or not NAME.fullmatch(str(item["package"]))
                or not NAME.fullmatch(str(item["module"]))
                or not VERSION.fullmatch(str(item["version"]))
                or item["platform"] not in NATIVE_PLATFORMS
                or not SHA256.fullmatch(str(item["sha256"]))
                or not isinstance(item["size"], int) or isinstance(item["size"], bool) or item["size"] <= 0):
            raise ValueError("Invalid native artifact record")
        if "role" in item and item["role"] not in NATIVE_ROLES:
            raise ValueError(f"Invalid native artifact role: {item['role']!r}")
        if "owner_module" in item and (not isinstance(item["owner_module"], str)
                                       or not NAME.fullmatch(item["owner_module"])):
            raise ValueError(f"Invalid native artifact owner_module: {item['owner_module']!r}")
        if "runtime_name" in item and (not isinstance(item["runtime_name"], str)
                                       or not NATIVE_LIB_NAME.fullmatch(item["runtime_name"])):
            raise ValueError(f"Invalid native artifact runtime_name: {item['runtime_name']!r}")
        if "note" in item and (not isinstance(item["note"], str) or not item["note"].strip()
                               or len(item["note"]) > 300):
            raise ValueError("Invalid native artifact note")
        if "built_at" in item and (not isinstance(item["built_at"], str)
                                   or not NATIVE_TIMESTAMP.fullmatch(item["built_at"])):
            raise ValueError(f"Invalid native artifact built_at: {item['built_at']!r}")
        rel = PurePosixPath(str(item["path"]))
        if (rel.is_absolute() or len(rel.parts) != 3
                or rel.parts[:2] != (item["package"], item["version"])
                or not NATIVE_FILE.fullmatch(rel.parts[2])
                or rel.as_posix() in indexed):
            raise ValueError(f"Invalid or duplicate native artifact path: {item['path']}")
        indexed[rel.as_posix()] = item
        target = directory.joinpath(*rel.parts)
        if partial and not target.exists():
            continue
        if target.is_symlink() or not target.is_file():
            raise ValueError(f"Missing or invalid native artifact: {rel.as_posix()}")
        if target.stat().st_size != item["size"] or digest(target) != item["sha256"]:
            raise ValueError(f"Native artifact checksum mismatch: {rel.as_posix()}")
    present = set()
    for path in directory.rglob("*"):
        if path.is_symlink():
            raise ValueError(f"Non-public native symlink: {path.relative_to(directory)}")
        if path.is_file():
            rel = path.relative_to(directory).as_posix()
            if rel not in ("manifest.json", "index.html"):
                present.add(rel)
    if not (present <= set(indexed)) or (not partial and set(indexed) != present):
        raise ValueError("A native payload may contain only its indexed artifacts")
    return manifest


def _merge_native_modules(prior_modules, incoming_modules):
    """Merge module catalogs across native releases, preserving archived version history."""
    merged = {}
    for mod_id, info in (prior_modules or {}).items():
        entry = dict(info)
        if "versions" in info:
            entry["versions"] = {ver: dict(vinfo) for ver, vinfo in info["versions"].items()}
        merged[mod_id] = entry
    for mod_id, info in (incoming_modules or {}).items():
        existing = merged.get(mod_id)
        entry = dict(info)
        versions = {}
        if existing and "versions" in existing:
            for ver, vinfo in existing["versions"].items():
                versions[ver] = dict(vinfo)
        for ver, vinfo in (info.get("versions") or {}).items():
            prev = versions.get(ver, {})
            versions[ver] = {**prev, **vinfo}
        if versions:
            cur = entry["current_version"]
            for ver, vinfo in versions.items():
                vinfo["status"] = "current" if ver == cur else "archived"
            entry["versions"] = dict(sorted(versions.items()))
        merged[mod_id] = entry
    return dict(sorted(merged.items()))


def preserve_native(previous, candidate, mode):
    """Carry immutable native artifacts across site/package deploys, or merge a native payload."""
    old = previous / "native" if previous else None
    new = candidate / "native"
    if mode != "native":
        if new.exists():
            raise ValueError(f"{mode.capitalize()} payloads must not replace native/")
        if old and old.exists():
            native_artifacts(old)
            shutil.copytree(old, new)
        return set()
    incoming = native_artifacts(new, partial=True)
    merged = {item["path"]: dict(item) for item in incoming["artifacts"]}
    merged_modules = incoming.get("modules")
    shipped = {"native/manifest.json"}
    if (new / "index.html").is_file():
        shipped.add("native/index.html")
    for item in incoming["artifacts"]:
        if (new / item["path"]).is_file():
            shipped.add("native/" + item["path"])
    if old and old.exists():
        prior = native_artifacts(old)
        if not (new / "index.html").is_file() and (old / "index.html").is_file():
            shutil.copyfile(old / "index.html", new / "index.html")
        for item in prior["artifacts"]:
            rel = item["path"]
            old_file = old / rel
            new_file = new / rel
            if rel in merged:
                if merged[rel]["sha256"] != item["sha256"] or merged[rel]["size"] != item["size"]:
                    raise ValueError(f"Immutable native artifact differs: {rel}; increment native version")
                # Allow metadata enrichment on unchanged bytes while retaining prior optional fields.
                combined = dict(item)
                combined.update(merged[rel])
                merged[rel] = combined
                if not new_file.exists():
                    new_file.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copyfile(old_file, new_file)
            else:
                merged[rel] = dict(item)
                new_file.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(old_file, new_file)
        if prior.get("modules") or incoming.get("modules"):
            merged_modules = _merge_native_modules(prior.get("modules"), incoming.get("modules"))
    final_manifest = {"schema": 1, "artifacts": sorted(merged.values(), key=lambda entry: entry["path"])}
    if merged_modules:
        final_manifest["modules"] = merged_modules
    (new / "manifest.json").write_text(json.dumps(final_manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    native_artifacts(new)
    return shipped


def media_assets(directory, *, partial=False):
    """Validate public media/ manifest and asset allowlist."""
    if directory.is_symlink() or not directory.is_dir():
        raise ValueError("Invalid public media directory")
    manifest_path = directory / "manifest.json"
    if manifest_path.is_symlink() or not manifest_path.is_file():
        raise ValueError("Media directory is missing manifest.json")
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    if manifest.get("schema") != 1 or not isinstance(manifest.get("assets"), list):
        raise ValueError("Expected a schema 1 media manifest")
    if set(manifest) - MEDIA_TOP_KEYS:
        raise ValueError("Media manifest contains non-public fields")
    indexed = {}
    for item in manifest["assets"]:
        if (not isinstance(item, dict)
                or not MEDIA_REQUIRED_ASSET_KEYS.issubset(item)
                or set(item) - (MEDIA_REQUIRED_ASSET_KEYS | MEDIA_OPTIONAL_ASSET_KEYS)
                or not NAME.fullmatch(str(item["namespace"]))
                or not SHA256.fullmatch(str(item["sha256"]))
                or not isinstance(item["size"], int) or isinstance(item["size"], bool) or item["size"] <= 0):
            raise ValueError(f"Invalid media asset record: {item!r}")
        rel = PurePosixPath(str(item["path"]))
        if (rel.is_absolute() or len(rel.parts) not in (2, 3)
                or rel.parts[0] != item["namespace"]
                or any(not MEDIA_SEGMENT.fullmatch(part) for part in rel.parts)
                or rel.suffix.lower() not in MEDIA_EXTS
                or rel.as_posix() in indexed):
            raise ValueError(f"Invalid or duplicate media asset path: {item['path']}")
        indexed[rel.as_posix()] = item
        target = directory.joinpath(*rel.parts)
        if partial and not target.exists():
            continue
        if target.is_symlink() or not target.is_file():
            raise ValueError(f"Missing or invalid media asset: {rel.as_posix()}")
        if target.stat().st_size != item["size"] or digest(target) != item["sha256"]:
            raise ValueError(f"Media asset checksum mismatch: {rel.as_posix()}")
    present = set()
    for path in directory.rglob("*"):
        if path.is_symlink():
            raise ValueError(f"Non-public media symlink: {path.relative_to(directory)}")
        if path.is_file():
            rel = path.relative_to(directory).as_posix()
            if rel not in ("manifest.json", "index.html"):
                present.add(rel)
    if not (present <= set(indexed)) or (not partial and set(indexed) != present):
        raise ValueError("A media payload may contain only its indexed assets")
    return manifest


def preserve_media(previous, candidate, mode):
    """Carry hosted media assets across site/package/native deploys, or merge a media payload."""
    old = previous / "media" if previous else None
    new = candidate / "media"
    if mode != "media":
        if new.exists():
            raise ValueError(f"{mode.capitalize()} payloads must not replace media/")
        if old and old.exists():
            media_assets(old)
            shutil.copytree(old, new)
        return set()
    incoming = media_assets(new, partial=True)
    merged = {item["path"]: dict(item) for item in incoming["assets"]}
    shipped = {"media/manifest.json"}
    if (new / "index.html").is_file():
        shipped.add("media/index.html")
    for item in incoming["assets"]:
        if (new / item["path"]).is_file():
            shipped.add("media/" + item["path"])
    if old and old.exists():
        prior = media_assets(old)
        if not (new / "index.html").is_file() and (old / "index.html").is_file():
            shutil.copyfile(old / "index.html", new / "index.html")
        for item in prior["assets"]:
            rel = item["path"]
            old_file = old / rel
            new_file = new / rel
            if rel in merged:
                if not new_file.exists():
                    if merged[rel]["sha256"] != item["sha256"] or merged[rel]["size"] != item["size"]:
                        raise ValueError(f"Media payload omitted changed asset bytes: {rel}")
                    new_file.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copyfile(old_file, new_file)
            else:
                merged[rel] = dict(item)
                new_file.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(old_file, new_file)
    final_manifest = {"schema": 1, "assets": sorted(merged.values(), key=lambda entry: entry["path"])}
    (new / "manifest.json").write_text(json.dumps(final_manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    media_assets(new)
    return shipped


def preserve_packages(previous, candidate, mode):
    old = previous / "packages" if previous else None
    new = candidate / "packages"
    if mode in ("site", "native", "media"):
        if new.exists():
            raise ValueError(f"{mode.capitalize()}-only payloads must not replace packages")
        if old and old.exists():
            packages(old, historical=True)
            shutil.copytree(old, new)
        return set()
    # Read what the payload carries before inheriting.  Afterwards NEW holds the
    # whole archive, so it can no longer describe which packages this release
    # ships and which it merely carries forward.
    # A payload may refuse itself before it is completed: nothing here reads the
    # tarballs it leaves to its predecessor.
    partial = packages(new, partial=True)
    shipped = partial
    if old and old.exists():
        prior = packages(old, historical=True)
        versions = {item["name"]: item["version"] for item in prior["packages"]}

        def comparable(value, width):
            parts = tuple(map(int, value.split(".")))
            return parts + (0,) * (max(width, len(parts)) - len(parts))

        for item in shipped["packages"]:
            before = versions.get(item["name"])
            if not before:
                continue
            width = max(len(before.split(".")), len(item["version"].split(".")))
            if comparable(item["version"], width) < comparable(before, width):
                raise ValueError(f"Package version downgrade refused: {item['name']}")
        for path in old.glob("*.tar"):
            target = new / path.name
            if target.exists():
                if digest(target) != digest(path):
                    raise ValueError(f"Immutable package differs: {path.name}; increment Version")
            else:
                shutil.copyfile(path, target)
    # Validate only once NEW is the complete archive a client would read.
    packages(new, historical=True)
    return {item["file"] for item in shipped["packages"]} | {"archive-contents",
                                                            "manifest.json"}


def verify_http(release, url, stamp, complete=()):
    """Check served bytes, not merely a successful HTTP status or a stale page.

    COMPLETE names the files this release ships.  Only they can differ from the
    release it follows, so only they are read back in full: an inherited tarball
    was already proven byte-identical before it was carried forward, and reading
    eighteen megabytes of them again is what made a publication take ten minutes.
    Every path is still requested, so a broken cascade fails here.
    """
    complete = set(complete)
    paths = [Path(page) for page in SITE_PAGES]
    if (release / "packages").is_dir():
        paths.extend(path.relative_to(release)
                     for path in sorted((release / "packages").rglob("*")) if path.is_file())
    if (release / "native").is_dir():
        paths.extend(path.relative_to(release)
                     for path in sorted((release / "native").rglob("*")) if path.is_file())
    if (release / "media").is_dir():
        paths.extend(path.relative_to(release)
                     for path in sorted((release / "media").rglob("*")) if path.is_file())
    for path in paths:
        route = "/" + path.as_posix()
        if path.name == "index.html":
            route = route.removesuffix("index.html")
        request = Request(url.rstrip("/") + route + "?deployment=" + stamp,
                          headers={"Cache-Control": "no-cache"})
        with urlopen(request, timeout=30) as response:
            if response.status != 200:
                raise ValueError(f"Published path is not served: {route}")
            if path.name not in complete and path.as_posix() not in complete:
                continue
            result = hashlib.sha256()
            for block in iter(lambda: response.read(1024 * 1024), b""):
                result.update(block)
            if result.hexdigest() != digest(release / path):
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
            if args.mode in ("packages", "native", "media"):
                expected_dir = args.mode
                if {path.name for path in candidate.iterdir()} != {expected_dir}:
                    raise ValueError(f"{expected_dir.capitalize()}-only payload must contain only {expected_dir}/")
                if not previous or not (previous / "index.html").is_file():
                    raise ValueError(f"{expected_dir.capitalize()}-only publication requires an existing site")
                for path in previous.iterdir():
                    if path.name in ("packages", "native", "media"):
                        continue
                    if path.is_symlink() or any(child.is_symlink() for child in path.rglob("*")):
                        raise ValueError("Existing site contains a symlink")
                    if path.is_dir():
                        shutil.copytree(path, candidate / path.name)
                    else:
                        shutil.copyfile(path, candidate / path.name)
            if any(not (candidate / page).is_file() for page in SITE_PAGES):
                raise ValueError("Site payload is missing an English/Chinese entry or reference page")
            shipped = preserve_packages(previous, candidate, args.mode)
            shipped |= preserve_native(previous, candidate, args.mode)
            shipped |= preserve_media(previous, candidate, args.mode)
            # mkdtemp is private, but its moved child must be readable by Caddy.
            for path in [candidate, *candidate.rglob("*")]:
                path.chmod(0o755 if path.is_dir() else 0o644)
            candidate.rename(release)
        try:
            switch(base, release)
            verify_http(release, args.verify_url, args.release, shipped)
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
    parser.add_argument("--mode", choices=("site", "packages", "combined", "native", "media"), required=True)
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
