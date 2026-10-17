#!/usr/bin/env python3
"""Build reproducible package.el archives from explicit source directories.

Only package entries, Lisp implementation files, license/readme files and explicit
resource directories are shipped.  No installed Emacs, Git, network or compiler
is needed by this build primitive.  Consumers install its output with package.el.
"""
from __future__ import annotations

import argparse
import hashlib
import io
import json
import os
from pathlib import Path, PurePosixPath
import re
import sys
import tarfile
import tempfile

NAME = re.compile(r"[a-z][a-z0-9-]*\Z")
VERSION = re.compile(r"[0-9]+(?:\.[0-9]+)*\Z")
GENERATED = {".elc", ".eln", ".pyc", ".o", ".so", ".dylib", ".dll", ".a"}


def metadata(root, name):
    """Read ordinary package headers without evaluating Lisp."""
    if not NAME.fullmatch(name):
        raise ValueError(f"Invalid package name: {name}")
    source = (root / f"{name}.el").read_text(encoding="utf-8")
    version = re.search(r"^;; Version: ([0-9]+(?:\.[0-9]+)*)$", source, re.M)
    requirements = re.search(r"^;; Package-Requires: (.+)$", source, re.M)
    if not version or not requirements:
        raise ValueError(f"{name}: missing Version or Package-Requires header")
    value = requirements[1]
    pairs = re.findall(r'\(([a-z][a-z0-9-]*) "([0-9]+(?:\.[0-9]+)*)"\)', value)
    normalized = "(" + " ".join(f'({key} "{minimum}")' for key, minimum in pairs) + ")"
    if normalized != " ".join(value.split()) or len({key for key, _ in pairs}) != len(pairs):
        raise ValueError(f"{name}: unsupported dependency metadata: {value}")
    summary = re.search(rf"^;;; {re.escape(name)}\.el --- (.*?)(?:\s+-\*-|$)", source, re.M)
    return {"name": name, "version": version[1], "requirements": pairs,
            "summary": summary[1].strip() if summary else name}


def source_files(root, name, resources=()):
    """Select runtime inputs, refusing symlinks and missing resource directories."""
    if (root / "lisp").is_symlink():
        raise ValueError(f"{name}: Lisp implementation directory cannot be a symlink")
    for resource in resources:
        path = PurePosixPath(resource)
        if (path.is_absolute() or not path.parts or any(part in (".", "..") for part in path.parts)
                or any(root.joinpath(*path.parts[:index + 1]).is_symlink() for index in range(len(path.parts)))
                or not (root / resource).is_dir()):
            raise ValueError(f"{name}: invalid or missing resource directory: {resource}")
    files = {}
    resource_paths = tuple(PurePosixPath(resource) for resource in resources)
    for parent, directories, names in os.walk(root):
        relative_parent = Path(parent).relative_to(root)
        directories[:] = sorted(directory for directory in directories
                                if not directory.startswith(".")
                                and directory not in ("__pycache__", "node_modules", "target"))
        if relative_parent == Path("."):
            directories[:] = [directory for directory in directories if directory == "lisp"
                              or any(path.parts[0] == directory for path in resource_paths)]
        for filename in sorted([*directories, *names]):
            path = Path(parent) / filename
            relative = path.relative_to(root)
            parts = relative.parts
            top = len(parts) == 1
            include = top and (filename == f"{name}.el" or filename.startswith(
                ("README", "LICENSE", "COPYING", "NOTICE", "CHANGELOG")))
            include = include or (parts[0] == "lisp" and path.suffix == ".el")
            include = include or any(relative == resource or resource in relative.parents
                                     for resource in resource_paths)
            if not include or filename.startswith("."):
                continue
            if path.is_symlink():
                raise ValueError(f"{name}: resource symlinks cannot be packaged: {relative}")
            if path.is_file() and path.suffix not in GENERATED and not filename.endswith("-pkg.el"):
                files[relative.as_posix()] = path.read_bytes()
    if f"{name}.el" not in files:
        raise ValueError(f"{name}: package entry missing")
    return files


def write_package(output, root, name, resources=()):
    """Write one deterministic source archive; byte compilation is installation-local."""
    info = metadata(root, name)
    version = info["version"]
    requirements = "(" + " ".join(f'({key} "{minimum}")' for key, minimum in info["requirements"]) + ")"
    files = source_files(root, name, resources)
    # JSON string escaping is also valid for these package summary strings in Lisp.
    files[f"{name}-pkg.el"] = (
        f';;; -*- lexical-binding: t; -*-\n'
        f';;; {name}-pkg.el --- Generated package metadata\n'
        f'(define-package "{name}" "{version}" {json.dumps(info["summary"], ensure_ascii=False)} '
        f"'{requirements})\n"
        ";; Local Variables:\n;; no-byte-compile: t\n;; End:\n").encode("utf-8")
    archive = output / f"{name}-{version}.tar"
    with tarfile.open(archive, "w", format=tarfile.PAX_FORMAT) as stream:
        for relative, content in sorted(files.items()):
            member = tarfile.TarInfo(f"{name}-{version}/{relative}")
            member.size, member.mode, member.mtime = len(content), 0o644, 0
            member.uid = member.gid = 0
            stream.addfile(member, io.BytesIO(content))
    return dict(info, file=archive.name, sha256=hashlib.sha256(archive.read_bytes()).hexdigest())


def write_index(output, packages):
    """Write the package.el index and a transport-independent checksum manifest."""
    records = []
    for package in sorted(packages, key=lambda item: item["name"]):
        version = "(" + package["version"].replace(".", " ") + ")"
        requirements = "(" + " ".join(
            f'({name} ({minimum.replace(".", " ")}))' for name, minimum in package["requirements"]) + ")"
        records.append(f' ({package["name"]} . [{version} {requirements} '
                       f'{json.dumps(package["summary"], ensure_ascii=False)} tar])')
    (output / "archive-contents").write_text("(1\n" + "\n".join(records) + "\n)\n", encoding="utf-8")
    manifest = {"schema": 2, "packages": packages}
    (output / "manifest.json").write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    return manifest


def verify(directory):
    """Check manifest paths and bytes before an archive is installed or published."""
    manifest = json.loads((directory / "manifest.json").read_text(encoding="utf-8"))
    if manifest.get("schema") != 2 or not manifest.get("packages"):
        raise ValueError("Expected a nonempty schema 2 package manifest; rebuild older archives")
    seen = set()
    for package in manifest["packages"]:
        name, version = package["name"], package["version"]
        if (not NAME.fullmatch(name) or not VERSION.fullmatch(version) or name in seen
                or package["file"] != f"{name}-{version}.tar"):
            raise ValueError("Invalid or duplicate package identity")
        seen.add(name)
        archive = directory / package["file"]
        if archive.is_symlink() or hashlib.sha256(archive.read_bytes()).hexdigest() != package["sha256"]:
            raise ValueError(f"Archive checksum mismatch: {archive.name}")
    with tempfile.TemporaryDirectory(prefix="package-index-") as temp:
        write_index(Path(temp), manifest["packages"])
        if (Path(temp) / "archive-contents").read_bytes() != (directory / "archive-contents").read_bytes():
            raise ValueError("Package index does not match its manifest")
    return manifest


def build(directory, sources, resources):
    """Publish a complete local archive atomically, without replacing existing output."""
    if directory.exists():
        raise ValueError(f"Refusing to replace existing output: {directory}")
    if not sources or set(resources) - set(sources):
        raise ValueError("At least one package is required; resources must name selected packages")
    directory.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".package-build-", dir=directory.parent) as work:
        stage = Path(work) / "archive"
        stage.mkdir()
        packages = [write_package(stage, source, name, resources.get(name, ()))
                    for name, source in sorted(sources.items())]
        manifest = write_index(stage, packages)
        verify(stage)
        stage.rename(directory)
    return manifest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command")
    build_parser = sub.add_parser("build", help="Create an immutable package archive")
    build_parser.add_argument("--directory", type=Path, required=True)
    build_parser.add_argument("--package", action="append", default=[], metavar="NAME=SOURCE")
    build_parser.add_argument("--resource", action="append", default=[], metavar="NAME=DIRECTORY")
    verify_parser = sub.add_parser("verify", help="Verify archive checksums and index")
    verify_parser.add_argument("--directory", type=Path, required=True)
    args_list = sys.argv[1:]
    if not args_list or args_list == ["help"]:
        parser.print_help()
        return 0
    if args_list[0] == "help":
        args_list = [*args_list[1:], "--help"]
    args = parser.parse_args(args_list)
    if args.command == "build":
        sources, resources = {}, {}
        for item in args.package:
            name, separator, value = item.partition("=")
            if not separator or name in sources:
                raise ValueError("--package expects unique NAME=SOURCE arguments")
            sources[name] = Path(value).resolve()
        for item in args.resource:
            name, separator, value = item.partition("=")
            if not separator:
                raise ValueError("--resource expects NAME=DIRECTORY")
            resources.setdefault(name, []).append(value)
        result = build(args.directory.resolve(), sources, resources)
    else:
        result = verify(args.directory.resolve())
    print(json.dumps({"archive": str(args.directory.resolve()), "packages": result["packages"]}, indent=2))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (ValueError, KeyError, OSError, tarfile.TarError) as error:
        print(f"error=archive\nhint={error}", file=sys.stderr)
        sys.exit(1)
