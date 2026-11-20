#!/usr/bin/env python3
"""Build/publish etaf.top, preserving installed-package download URLs.

Default: build the site and deploy it. --packages DIR combines the site with a
validated workspace package release. --packages-only DIR leaves site pages alone.
--pages-only DIR regenerates the archive pages from an already published archive.
ETAF_TOP_ROOT=lightos (default) uses the existing SSH hop; direct uses ETAF_TOP_HOST
(default root@aliyun-hk). ETAF_TOP_KEEP defaults to 5. No SSH or web-server
configuration is modified. Authentication is noninteractive.
"""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys
import tarfile
import tempfile
import uuid

SITE = Path(__file__).resolve().parents[1]
REPOSITORY = SITE.parent


def remote(command, **kwargs):
    host = os.environ.get("ETAF_TOP_HOST", "root@aliyun-hk")
    route = os.environ.get("ETAF_TOP_ROOT", "lightos")
    if route not in ("lightos", "direct") or not re.fullmatch(r"[A-Za-z0-9_@.:-]+", host) or host.startswith("-"):
        raise ValueError("Invalid ETAF_TOP_ROOT or ETAF_TOP_HOST")
    ssh = ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=15", host, command]
    if route == "lightos":
        ssh = ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=15", "lightos", shlex.join(ssh)]
    return subprocess.run(ssh, check=True, timeout=600, **kwargs)


def add_tree(archive, directory, prefix=""):
    """Send regular generated files only; never follow resource symlinks."""
    for path in sorted(directory.rglob("*")):
        if path.is_symlink():
            raise ValueError(f"Publication input cannot be a symlink: {path}")
        if path.is_file():
            archive.add(path, arcname=prefix + path.relative_to(directory).as_posix(), recursive=False)
        elif not path.is_dir():
            raise ValueError(f"Publication input is not a regular file: {path}")


# Page generation is one module so it can run without a release workspace: a
# published archive regenerates its own presentation (see --pages-only).
sys.path.insert(0, str(SITE / "scripts"))
import archive_pages


def pages_source(destination, source):
    """Copy an already public archive so archive_pages can rewrite its presentation.

    A pages-only publication cannot introduce package bytes: the manifest and
    every indexed tarball must verify first. Older tarballs stay in the previous
    release and the deployer carries them forward unchanged.
    """
    sys.path.insert(0, str(REPOSITORY / "scripts"))
    import package_archive
    manifest = package_archive.verify(source)
    destination.mkdir()
    for name in ("manifest.json", "archive-contents",
                 *(item["file"] for item in manifest["packages"])):
        shutil.copyfile(source / name, destination / name)


def publish(args):
    package_input = args.packages_only or args.packages
    pages_input = args.pages_only
    archive_input = package_input or pages_input
    mode = "packages" if pages_input or args.packages_only else "combined" if args.packages else "site"
    keep = int(os.environ.get("ETAF_TOP_KEEP", "5"))
    if keep < 2:
        raise ValueError("ETAF_TOP_KEEP must retain at least two releases")
    with tempfile.TemporaryDirectory(prefix="etaf-top-") as temporary:
        work = Path(temporary)
        if package_input:
            # This command rejects partial/stale evidence and developer archives,
            # then copies an explicit public allowlist. Logs stay on this host.
            subprocess.run([sys.executable, str(REPOSITORY.parent / "scripts/package-release.py"),
                            "stage", "--directory", str(package_input.resolve()),
                            "--output", str(work / "packages")], check=True, timeout=120)
        elif pages_input:
            pages_source(work / "packages", pages_input.resolve())
        if not args.no_build and not (args.packages_only or pages_input):
            subprocess.run(["npm", "run", "build"], cwd=SITE, check=True, timeout=600)
        if args.build_only:
            print(f"Built {SITE / 'dist'}")
            return
        if mode != "packages" and not (SITE / "dist/index.html").is_file():
            raise ValueError("Site build is missing; run without --no-build")
        if mode != "packages" and (SITE / "dist/packages").exists():
            raise ValueError("dist/packages is reserved; supply a validated --packages release instead")
        if archive_input:
            report = archive_pages.archive_pages(work / "packages")
            if report["unplaced"]:
                raise ValueError("no section places " + ", ".join(report["unplaced"])
                                 + ": add each one to GROUPS in site/scripts/archive_pages.py")
            print(f"Archive pages for {report['packages']} packages; newest change "
                  f"{report['updated'] or 'not recorded'}")
        payload = work / "payload.tgz"
        with tarfile.open(payload, "w:gz") as archive:
            if mode != "packages":
                add_tree(archive, SITE / "dist")
            if archive_input:
                add_tree(archive, work / "packages", "packages/")
        stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ") + "-" + uuid.uuid4().hex[:8]
        staging = remote("mktemp -d /tmp/etaf-top.XXXXXXXX", capture_output=True, text=True).stdout.strip()
        if not re.fullmatch(r"/tmp/etaf-top\.[A-Za-z0-9]+", staging):
            raise ValueError("Remote did not return a safe upload directory")
        try:
            files = {"payload.tgz": payload,
                     "deploy-release.py": SITE / "scripts/deploy-release.py",
                     "package_archive.py": REPOSITORY / "scripts/package_archive.py"}
            for name, source in files.items():
                with source.open("rb") as stream:
                    remote("cat > " + shlex.quote(staging + "/" + name), stdin=stream)
            command = ["python3", staging + "/deploy-release.py", "--archive", staging + "/payload.tgz",
                       "--release", stamp, "--mode", mode, "--keep", str(keep)]
            try:
                remote(shlex.join(command))
            except (subprocess.CalledProcessError, subprocess.TimeoutExpired):
                print("Deployment did not confirm success; reading current without changing it", file=sys.stderr)
                remote("readlink /srv/etaf.top/current")
                raise
            current = remote("readlink /srv/etaf.top/current", capture_output=True, text=True).stdout.strip()
            if current != "/srv/etaf.top/releases/" + stamp:
                raise ValueError(f"A different release is current after deployment: {current}")
            if archive_input:
                # The deployer proves served bytes; this proves the pages say
                # what the manifest means, so a grouping mistake cannot ship.
                checked = subprocess.run(
                    [sys.executable, str(SITE / "scripts/check-archive.py"),
                     "--archive", "https://etaf.top/packages/"],
                    capture_output=True, text=True, timeout=120)
                print(checked.stdout.strip())
                if checked.returncode:
                    raise ValueError(f"Published pages do not match the manifest:\n{checked.stdout}")
            print(f"Published https://etaf.top ({mode}, release {stamp}); current read back")
        finally:
            try:
                remote("rm -rf -- " + shlex.quote(staging))
            except (subprocess.CalledProcessError, subprocess.TimeoutExpired) as error:
                print(f"Upload cleanup failed; private staging remains at {staging}: {error}", file=sys.stderr)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    build = parser.add_mutually_exclusive_group()
    build.add_argument("--build-only", action="store_true")
    build.add_argument("--no-build", action="store_true")
    packages = parser.add_mutually_exclusive_group()
    packages.add_argument("--packages", type=Path, help="Publish site and validated package archive together")
    packages.add_argument("--packages-only", type=Path, help="Publish packages without rebuilding/changing site pages")
    packages.add_argument("--pages-only", type=Path,
                          help="Regenerate archive pages from an already published archive; package bytes stay unchanged")
    args = parser.parse_args()
    if args.build_only and (args.packages or args.packages_only or args.pages_only):
        parser.error("--build-only cannot publish packages or archive pages")
    publish(args)


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, subprocess.CalledProcessError, subprocess.TimeoutExpired) as error:
        print(f"error=publish\nhint={error}", file=sys.stderr)
        sys.exit(1)
