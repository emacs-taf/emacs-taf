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
import hashlib
import json
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


def tools_directory(repository):
    """Return the directory that owns the shared archive scripts.

    A package inside a shared container borrows them from the container root; a
    standalone clone of the manual keeps its own copies.
    """
    for candidate in (repository, *repository.parents):
        if (candidate / "workspace.json").is_file():
            return candidate / "scripts"
    return repository / "scripts"


TOOLS = tools_directory(REPOSITORY)


def remote(command, **kwargs):
    host = os.environ.get("ETAF_TOP_HOST", "root@aliyun-hk")
    route = os.environ.get("ETAF_TOP_ROOT", "lightos")
    if route not in ("lightos", "direct") or not re.fullmatch(r"[A-Za-z0-9_@.:-]+", host) or host.startswith("-"):
        raise ValueError("Invalid ETAF_TOP_ROOT or ETAF_TOP_HOST")
    ssh = ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=15", host, command]
    if route == "lightos":
        ssh = ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=15", "lightos", shlex.join(ssh)]
    # The payload crosses two hops to reach the archive host: an 18 MB set of
    # tarballs made a deployment finish just after the old ten-minute limit, and
    # the timeout then reported a failure for an archive that was serving.
    return subprocess.run(ssh, check=True, timeout=1800, **kwargs)


def add_tree(archive, directory, prefix="", skip=()):
    """Send regular generated files only; never follow resource symlinks.

    SKIP names files the archive already serves byte for byte.  The deployer
    inherits untouched tarballs from the previous release, so sending them again
    only spends the upload, which is the slowest part of a publication.
    """
    for path in sorted(directory.rglob("*")):
        if path.is_symlink():
            raise ValueError(f"Publication input cannot be a symlink: {path}")
        if path.is_file():
            if path.name in skip:
                continue
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
    sys.path.insert(0, str(TOOLS))
    import package_archive
    manifest = package_archive.verify(source)
    destination.mkdir()
    for name in ("manifest.json", "archive-contents",
                 *(item["file"] for item in manifest["packages"])):
        shutil.copyfile(source / name, destination / name)


def published_digests(url="https://etaf.top/packages/manifest.json", timeout=30):
    """Return {file: sha256} for the archive URL serves, or {} when unreadable.

    An unreadable manifest means nothing is reused: the deployment then behaves
    exactly as it did before the manifest was consulted.
    """
    from urllib.request import ProxyHandler, build_opener
    try:
        opener = build_opener(ProxyHandler({}))
        with opener.open(url, timeout=timeout) as response:
            manifest = json.loads(response.read())
    except Exception:
        return {}
    return {item["file"]: item["sha256"] for item in manifest.get("packages", ())}


def published_native_manifest(url="https://etaf.top/native/manifest.json", timeout=30):
    """Return the currently published native manifest dict, or None when unreadable."""
    from urllib.request import ProxyHandler, build_opener
    try:
        opener = build_opener(ProxyHandler({}))
        with opener.open(url, timeout=timeout) as response:
            return json.loads(response.read())
    except Exception:
        return None


def published_native_digests(url="https://etaf.top/native/manifest.json", timeout=30):
    """Return {relpath: sha256} for hosted native binaries, or {} when unreadable."""
    manifest = published_native_manifest(url=url, timeout=timeout)
    if not isinstance(manifest, dict):
        return {}
    return {item["path"]: item["sha256"] for item in manifest.get("artifacts", ())}


def already_served(directory, served):
    """Return the relative POSIX paths in DIRECTORY whose bytes SERVED already carries."""
    reused = set()
    for name, digest in served.items():
        path = directory / name
        if path.is_file() and hashlib.sha256(path.read_bytes()).hexdigest() == digest:
            reused.add(name)
    return reused


def load_native_release():
    """Load the shared workspace native-release helper for manifest enrichment."""
    import importlib.util
    tool = TOOLS / "native-release.py"
    if not tool.is_file():
        return None
    spec = importlib.util.spec_from_file_location("native_release", tool)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def publish(args):
    package_input = args.packages_only or args.packages
    pages_input = args.pages_only
    native_input = args.native_only
    native_pages_only = args.native_pages_only
    native_mode = bool(native_input or native_pages_only)
    archive_input = package_input or pages_input
    mode = ("native" if native_mode else
            "packages" if pages_input or args.packages_only else
            "combined" if args.packages else "site")
    keep = int(os.environ.get("ETAF_TOP_KEEP", "5"))
    if keep < 2:
        raise ValueError("ETAF_TOP_KEEP must retain at least two releases")
    with tempfile.TemporaryDirectory(prefix="etaf-top-") as temporary:
        work = Path(temporary)
        if native_pages_only:
            remote_manifest = published_native_manifest()
            if not isinstance(remote_manifest, dict) or not remote_manifest.get("artifacts"):
                raise ValueError("Could not read currently published https://etaf.top/native/manifest.json")
            native_release = load_native_release()
            if native_release is None:
                raise ValueError("scripts/native-release.py is required for --native-pages-only")
            enriched = native_release.enrich_index_manifest(remote_manifest)
            errs = native_release.validate_index_manifest(enriched, allow_missing=True)
            if errs:
                raise ValueError("Enriched native manifest invalid: " + "; ".join(errs))
            (work / "native").mkdir()
            (work / "native" / "manifest.json").write_text(
                json.dumps(enriched, indent=2, sort_keys=True) + "\n", encoding="utf-8")
            native_report = archive_pages.native_pages(work / "native", manifest=enriched)
            print(f"Native index page for {native_report['modules']} module(s), "
                  f"{native_report['artifacts']} artifact(s) (metadata + page only)")
        elif native_input:
            subprocess.run([sys.executable, str(TOOLS / "native-release.py"),
                            "verify", "--stage", str(native_input.resolve())],
                           check=True, timeout=120)
            shutil.copytree(native_input.resolve(), work / "native")
            local_manifest = json.loads((work / "native" / "manifest.json").read_text(encoding="utf-8"))
            remote_manifest = published_native_manifest()
            merged_artifacts = {}
            merged_modules = {}
            if isinstance(remote_manifest, dict):
                merged_modules.update(remote_manifest.get("modules") or {})
                for item in remote_manifest.get("artifacts", ()):
                    merged_artifacts[item["path"]] = dict(item)
            merged_modules.update(local_manifest.get("modules") or {})
            for item in local_manifest.get("artifacts", ()):
                prev = merged_artifacts.get(item["path"], {})
                merged_artifacts[item["path"]] = {**prev, **item}
            page_manifest = {"schema": 1, "artifacts": list(merged_artifacts.values())}
            if merged_modules:
                page_manifest["modules"] = merged_modules
            native_release = load_native_release()
            if native_release is not None:
                page_manifest = native_release.enrich_index_manifest(page_manifest)
                # Keep uploaded staged manifest enriched with module catalog metadata too.
                local_enriched = native_release.enrich_index_manifest(local_manifest)
                (work / "native" / "manifest.json").write_text(
                    json.dumps(local_enriched, indent=2, sort_keys=True) + "\n", encoding="utf-8")
            native_report = archive_pages.native_pages(work / "native", manifest=page_manifest)
            print(f"Native index page for {native_report['modules']} module(s), "
                  f"{native_report['artifacts']} artifact(s)")
        elif package_input:
            # This command rejects partial/stale evidence and developer archives,
            # then copies an explicit public allowlist. Logs stay on this host.
            subprocess.run([sys.executable, str(TOOLS / "package-release.py"),
                            "stage", "--directory", str(package_input.resolve()),
                            "--output", str(work / "packages")], check=True, timeout=120)
        elif pages_input:
            pages_source(work / "packages", pages_input.resolve())
        if not args.no_build and not (args.packages_only or pages_input or native_mode):
            subprocess.run(["npm", "run", "build"], cwd=SITE, check=True, timeout=600)
        if args.build_only:
            print(f"Built {SITE / 'dist'}")
            return
        if mode not in ("packages", "native") and not (SITE / "dist/index.html").is_file():
            raise ValueError("Site build is missing; run without --no-build")
        if mode not in ("packages", "native") and (SITE / "dist/packages").exists():
            raise ValueError("dist/packages is reserved; supply a validated --packages release instead")
        if mode not in ("packages", "native") and (SITE / "dist/native").exists():
            raise ValueError("dist/native is reserved; supply a validated --native-only directory instead")
        if archive_input:
            report = archive_pages.archive_pages(work / "packages")
            if report["unplaced"]:
                raise ValueError("no section places " + ", ".join(report["unplaced"])
                                 + ": add each one to GROUPS in site/scripts/archive_pages.py")
            print(f"Archive pages for {report['packages']} packages; newest change "
                  f"{report['updated'] or 'not recorded'}")
        payload = work / "payload.tgz"
        with tarfile.open(payload, "w:gz") as archive:
            if mode not in ("packages", "native"):
                add_tree(archive, SITE / "dist")
            if archive_input:
                served = published_digests()
                reused = already_served(work / "packages", served)
                add_tree(archive, work / "packages", "packages/", skip=reused)
                if reused:
                    total = sum(1 for item in (work / "packages").iterdir() if item.is_file())
                    print(f"Sending {total - len(reused)} of {total} file(s); "
                          f"{len(reused)} already served")
            if native_mode:
                served = published_native_digests()
                reused = already_served(work / "native", served)
                for path in sorted((work / "native").rglob("*")):
                    if path.is_symlink():
                        raise ValueError(f"Publication input cannot be a symlink: {path}")
                    if path.is_file():
                        rel = path.relative_to(work / "native").as_posix()
                        if rel in reused:
                            continue
                        archive.add(path, arcname="native/" + rel, recursive=False)
                if reused:
                    print(f"Reusing {len(reused)} native artifact(s) already served")
        stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ") + "-" + uuid.uuid4().hex[:8]
        staging = remote("mktemp -d /tmp/etaf-top.XXXXXXXX", capture_output=True, text=True).stdout.strip()
        if not re.fullmatch(r"/tmp/etaf-top\.[A-Za-z0-9]+", staging):
            raise ValueError("Remote did not return a safe upload directory")
        try:
            files = {"payload.tgz": payload,
                     "deploy-release.py": SITE / "scripts/deploy-release.py",
                     "package_archive.py": TOOLS / "package_archive.py"}
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
            if native_mode:
                checked = subprocess.run(
                    [sys.executable, str(SITE / "scripts/check-archive.py"),
                     "--native", "https://etaf.top/native/"],
                    capture_output=True, text=True, timeout=120)
                print(checked.stdout.strip())
                if checked.returncode:
                    raise ValueError(f"Published native page does not match manifest:\n{checked.stdout}")
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
    packages.add_argument("--native-only", type=Path,
                          help="Publish verified prebuilt native modules under native/ without changing site or packages")
    packages.add_argument("--native-pages-only", action="store_true",
                          help="Enrich published native/manifest.json metadata and regenerate native/index.html without re-uploading binaries")
    args = parser.parse_args()
    if args.build_only and (args.packages or args.packages_only or args.pages_only
                            or args.native_only or args.native_pages_only):
        parser.error("--build-only cannot publish packages, archive pages or native artifacts")
    publish(args)


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, subprocess.CalledProcessError, subprocess.TimeoutExpired) as error:
        print(f"error=publish\nhint={error}", file=sys.stderr)
        sys.exit(1)
