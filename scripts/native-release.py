#!/usr/bin/env python3
"""Build, verify and assemble prebuilt ETAF native dynamic module releases.

Each ETAF package that ships an optional Emacs C dynamic module carries a small
`native/manifest.json` declaring pinned, checksum-verified prebuilt binaries
per `(os, arch)`.  Prebuilt binaries are hosted outside ELPA `.tar` archives
(under `https://etaf.top/native/<pkg>/<ver>/` with GitHub Releases mirrors) and
downloaded into `${XDG_CACHE_HOME:-~/.cache}/emacs-taf/native/` by
`M-x etaf-install-native`.
"""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import platform
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]

NAME_RE = re.compile(r"[a-z][a-z0-9-]*\Z")
VERSION_RE = re.compile(r"[0-9]+(?:\.[0-9]+)*\Z")
SHA256_RE = re.compile(r"[0-9a-f]{64}\Z")
FILE_RE = re.compile(r"[a-z0-9][a-z0-9._-]*\.(?:dylib|so|dll)\Z")
LIB_NAME_RE = re.compile(r"[a-z0-9][a-z0-9._-]*\.(?:dylib|so(?:\.[0-9]+)*|dll)\Z")
HTTPS_RE = re.compile(r"https://[^\s\"']+\Z")
TIMESTAMP_RE = re.compile(
    r"[0-9]{4}-[0-9]{2}-[0-9]{2}(?:T[0-9]{2}:[0-9]{2}:[0-9]{2}(?:[+-][0-9]{2}:[0-9]{2}|Z))?\Z"
)

VALID_ROLES = ("module", "library")
VALID_STATUSES = ("current", "archived")
INDEX_TOP_KEYS = frozenset({"schema", "artifacts", "modules"})
INDEX_REQUIRED_ARTIFACT_KEYS = frozenset(
    {"package", "module", "version", "platform", "path", "sha256", "size"}
)
INDEX_OPTIONAL_ARTIFACT_KEYS = frozenset(
    {"role", "owner_module", "runtime_name", "note", "built_at"}
)
INDEX_MODULE_KEYS = frozenset(
    {"package", "current_version", "description", "used_by", "versions"}
)
INDEX_VERSION_KEYS = frozenset(
    {"status", "summary", "min_package_version", "max_package_version", "released"}
)

VALID_PLATFORMS = (
    "darwin-arm64",
    "darwin-x86_64",
    "linux-x86_64",
    "linux-arm64",
    "windows-x86_64",
)

PLATFORM_SUFFIX = {
    "darwin-arm64": ".dylib",
    "darwin-x86_64": ".dylib",
    "linux-x86_64": ".so",
    "linux-arm64": ".so",
    "windows-x86_64": ".dll",
}

NATIVE_PACKAGES = {
    "etaf-md": {
        "module": "etaf-md-typeset-native",
        "version": "1",
        "description": "Embedded QuickJS + Pele + MathJax worker for zero-browser Mermaid diagrams and display math SVGs (CoreText on macOS, runtime dlopen Pango on Linux).",
        "min_package_version": "0.3.0",
        "used_by": ("etaf-md", "etaf-org", "etaf-web"),
        "version_summary": "Portable CoreText (macOS) and dlopen-Pango (Linux) builds; Windows falls back cleanly.",
        "released": "2026-11-25T13:42:04Z",
        "platforms": ("darwin-arm64", "darwin-x86_64", "linux-x86_64", "linux-arm64"),
        "versions": {},
        "libraries": {},
        "smoke": (
            '(progn '
            '(unless (fboundp (quote etaf-md--native-info)) (error "etaf-md--native-info missing")) '
            '(let ((info (etaf-md--native-info))) '
            '  (unless (equal (plist-get info :engine) "quickjs") '
            '    (error "unexpected engine info: %S" info))) '
            '(when (fboundp (quote etaf-md--native-shutdown)) (etaf-md--native-shutdown)))'
        ),
    },
    "etaf": {
        "module": "etaf-video-mpv",
        "version": "2",
        "description": "Cross-platform libmpv dynamic module with native GPU video layers (macOS Metal/CAOpenGL, Windows Win32/WGL, Linux X11/Wayland EGL).",
        "min_package_version": "0.3.14",
        "used_by": ("etaf-video-player", "etaf-bili", "etaf-youtube"),
        "version_summary": "Adds Windows and Linux native GPU layers plus bundled Windows libmpv-2.dll.",
        "released": "2026-11-26T17:16:50Z",
        "platforms": ("darwin-arm64", "darwin-x86_64", "linux-x86_64", "linux-arm64", "windows-x86_64"),
        "versions": {
            "1": {
                "status": "archived",
                "max_package_version": "0.3.13",
                "summary": "Initial libmpv playback bridge retained immutably for older etaf manifests.",
                "released": "2026-11-25T13:42:04Z",
            },
        },
        "libraries": {
            "libmpv-2": {
                "runtime_name": "libmpv-2.dll",
                "note": "Bundled Windows runtime library loaded via LoadLibrary; macOS and Linux use system libmpv.",
            },
        },
        "smoke": (
            '(progn '
            '(unless (fboundp (quote etaf-video-mpv--native-available-p)) '
            '  (error "etaf-video-mpv--native-available-p missing")) '
            '(unless (fboundp (quote etaf-video-mpv--native-gpu-available-p)) '
            '  (error "etaf-video-mpv--native-gpu-available-p missing")))'
        ),
    },
    "ekp": {
        "module": "ekp",
        "version": "1.6",
        "description": "Multi-threaded C Knuth-Plass paragraph line-breaking engine for high-throughput layout.",
        "min_package_version": "1.0.5",
        "used_by": ("ekp", "ebox", "etaf"),
        "version_summary": "Portable multi-threaded C engine across macOS, Linux and Windows.",
        "released": "2026-11-25T13:42:04Z",
        "platforms": ("darwin-arm64", "darwin-x86_64", "linux-x86_64", "linux-arm64", "windows-x86_64"),
        "versions": {},
        "libraries": {},
        "smoke": (
            '(progn '
            '(ekp-c-init) '
            '(when (version< (ekp-c-version) "1.6") '
            '  (error "ekp-c-version too old: %s" (ekp-c-version))))'
        ),
    },
}


def utc_now_iso() -> str:
    """Return the current UTC timestamp in strict ISO 8601 format."""
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def version_key(version: str) -> tuple[int, ...]:
    """Return a numeric comparison tuple for a dotted native version string."""
    return tuple(int(part) for part in version.split("."))


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def host_platform(arch_override: str | None = None) -> str:
    system = sys.platform
    machine = (arch_override or platform.machine()).lower()
    if machine in ("aarch64", "arm64"):
        arch = "arm64"
    elif machine in ("x86_64", "amd64"):
        arch = "x86_64"
    else:
        raise ValueError(f"Unsupported architecture: {machine}")
    if system == "darwin":
        key = f"darwin-{arch}"
    elif system.startswith("linux"):
        key = f"linux-{arch}"
    elif system in ("win32", "cygwin", "msys"):
        key = f"windows-{arch}"
    else:
        raise ValueError(f"Unsupported operating system: {system}")
    if key not in VALID_PLATFORMS:
        raise ValueError(f"Unsupported platform key: {key}")
    return key


def artifact_filename(module: str, version: str, platform_key: str) -> str:
    return f"{module}-v{version}-{platform_key}{PLATFORM_SUFFIX[platform_key]}"


def default_urls(package: str, version: str, filename: str,
                 base_url: str = "https://etaf.top/native",
                 github_org: str = "emacs-taf") -> list[str]:
    primary = f"{base_url.rstrip('/')}/{package}/{version}/{filename}"
    mirror = f"https://github.com/{github_org}/{package}/releases/download/native-v{version}/{filename}"
    return [primary, mirror]


def validate_manifest(data: dict, expected_package: str | None = None) -> list[str]:
    """Return a list of schema/security errors for a package native/manifest.json."""
    errors: list[str] = []
    if not isinstance(data, dict):
        return ["manifest root must be a JSON object"]
    if data.get("schema") != 1:
        errors.append(f"expected schema 1, got {data.get('schema')!r}")
    package = data.get("package")
    if not isinstance(package, str) or not NAME_RE.fullmatch(package):
        errors.append(f"invalid package name: {package!r}")
    elif expected_package and package != expected_package:
        errors.append(f"manifest package {package!r} does not match directory {expected_package!r}")
    modules = data.get("modules")
    if not isinstance(modules, list) or not modules:
        errors.append("modules must be a nonempty list")
        return errors
    seen_modules: set[str] = set()
    for index, mod in enumerate(modules):
        prefix = f"modules[{index}]"
        if not isinstance(mod, dict):
            errors.append(f"{prefix}: entry must be a JSON object")
            continue
        name = mod.get("name")
        version = mod.get("version")
        description = mod.get("description")
        if not isinstance(name, str) or not NAME_RE.fullmatch(name):
            errors.append(f"{prefix}: invalid module name: {name!r}")
        elif name in seen_modules:
            errors.append(f"{prefix}: duplicate module name: {name}")
        else:
            seen_modules.add(name)
        if not isinstance(version, str) or not VERSION_RE.fullmatch(version):
            errors.append(f"{prefix}: invalid native version: {version!r}")
        if not isinstance(description, str) or not description.strip():
            errors.append(f"{prefix}: description must be a nonempty string")
        platforms = mod.get("platforms")
        if not isinstance(platforms, dict):
            errors.append(f"{prefix}: platforms must be a JSON object")
            continue
        for plat, entry in platforms.items():
            eprefix = f"{prefix}.platforms[{plat}]"
            if plat not in VALID_PLATFORMS:
                errors.append(f"{eprefix}: unsupported platform key")
                continue
            if not isinstance(entry, dict):
                errors.append(f"{eprefix}: platform record must be an object")
                continue
            filename = entry.get("file")
            if (not isinstance(filename, str) or not FILE_RE.fullmatch(filename)
                    or not filename.endswith(PLATFORM_SUFFIX[plat])):
                errors.append(f"{eprefix}: invalid artifact filename: {filename!r}")
            urls = entry.get("urls")
            if (not isinstance(urls, list) or not urls
                    or not all(isinstance(u, str) and HTTPS_RE.fullmatch(u) for u in urls)):
                errors.append(f"{eprefix}: urls must be a nonempty list of https:// URLs")
            digest = entry.get("sha256")
            if not isinstance(digest, str) or not SHA256_RE.fullmatch(digest):
                errors.append(f"{eprefix}: sha256 must be 64 lowercase hex digits")
            size = entry.get("size")
            if not isinstance(size, int) or isinstance(size, bool) or size <= 0:
                errors.append(f"{eprefix}: size must be a positive integer")
            libraries = entry.get("libraries")
            if libraries is not None:
                if not isinstance(libraries, list):
                    errors.append(f"{eprefix}: libraries must be a list")
                else:
                    seen_libs: set[str] = set()
                    for lidx, lib in enumerate(libraries):
                        lprefix = f"{eprefix}.libraries[{lidx}]"
                        if not isinstance(lib, dict):
                            errors.append(f"{lprefix}: library record must be an object")
                            continue
                        lname = lib.get("name")
                        if not isinstance(lname, str) or not LIB_NAME_RE.fullmatch(lname):
                            errors.append(f"{lprefix}: invalid library name: {lname!r}")
                        elif lname in seen_libs:
                            errors.append(f"{lprefix}: duplicate library name: {lname}")
                        else:
                            seen_libs.add(lname)
                        lfile = lib.get("file")
                        if (not isinstance(lfile, str) or not FILE_RE.fullmatch(lfile)
                                or not lfile.endswith(PLATFORM_SUFFIX[plat])):
                            errors.append(f"{lprefix}: invalid artifact filename: {lfile!r}")
                        lurls = lib.get("urls")
                        if (not isinstance(lurls, list) or not lurls
                                or not all(isinstance(u, str) and HTTPS_RE.fullmatch(u) for u in lurls)):
                            errors.append(f"{lprefix}: urls must be a nonempty list of https:// URLs")
                        ldigest = lib.get("sha256")
                        if not isinstance(ldigest, str) or not SHA256_RE.fullmatch(ldigest):
                            errors.append(f"{lprefix}: sha256 must be 64 lowercase hex digits")
                        lsize = lib.get("size")
                        if not isinstance(lsize, int) or isinstance(lsize, bool) or lsize <= 0:
                            errors.append(f"{lprefix}: size must be a positive integer")
    return errors


def validate_index_modules(modules: object) -> list[str]:
    """Validate the optional top-level `modules` catalog in hosted `native/manifest.json`."""
    errors: list[str] = []
    if not isinstance(modules, dict):
        return ["modules catalog must be a JSON object"]
    for mod_id, info in modules.items():
        prefix = f"modules[{mod_id!r}]"
        if not isinstance(mod_id, str) or not NAME_RE.fullmatch(mod_id):
            errors.append(f"{prefix}: invalid module id")
            continue
        if not isinstance(info, dict):
            errors.append(f"{prefix}: entry must be a JSON object")
            continue
        extra = set(info) - INDEX_MODULE_KEYS
        if extra:
            errors.append(f"{prefix}: unexpected fields {sorted(extra)}")
        pkg = info.get("package")
        if not isinstance(pkg, str) or not NAME_RE.fullmatch(pkg):
            errors.append(f"{prefix}: invalid package {pkg!r}")
        cur = info.get("current_version")
        if not isinstance(cur, str) or not VERSION_RE.fullmatch(cur):
            errors.append(f"{prefix}: invalid current_version {cur!r}")
        desc = info.get("description")
        if not isinstance(desc, str) or not desc.strip() or len(desc) > 400:
            errors.append(f"{prefix}: description must be a nonempty string (<= 400 chars)")
        used_by = info.get("used_by")
        if used_by is not None:
            if (not isinstance(used_by, list)
                    or not all(isinstance(u, str) and NAME_RE.fullmatch(u) for u in used_by)):
                errors.append(f"{prefix}: used_by must be a list of valid package names")
        versions = info.get("versions")
        if versions is not None:
            if not isinstance(versions, dict):
                errors.append(f"{prefix}: versions must be a JSON object")
            else:
                for ver, vinfo in versions.items():
                    vprefix = f"{prefix}.versions[{ver!r}]"
                    if not isinstance(ver, str) or not VERSION_RE.fullmatch(ver):
                        errors.append(f"{vprefix}: invalid version key")
                        continue
                    if not isinstance(vinfo, dict):
                        errors.append(f"{vprefix}: entry must be a JSON object")
                        continue
                    vextra = set(vinfo) - INDEX_VERSION_KEYS
                    if vextra:
                        errors.append(f"{vprefix}: unexpected fields {sorted(vextra)}")
                    status = vinfo.get("status")
                    if status not in VALID_STATUSES:
                        errors.append(f"{vprefix}: invalid status {status!r}")
                    summary = vinfo.get("summary")
                    if summary is not None and (not isinstance(summary, str) or not summary.strip() or len(summary) > 300):
                        errors.append(f"{vprefix}: summary must be a nonempty string (<= 300 chars)")
                    for bound in ("min_package_version", "max_package_version"):
                        bval = vinfo.get(bound)
                        if bval is not None and (not isinstance(bval, str) or not VERSION_RE.fullmatch(bval)):
                            errors.append(f"{vprefix}: invalid {bound} {bval!r}")
                    released = vinfo.get("released")
                    if released is not None and (not isinstance(released, str) or not TIMESTAMP_RE.fullmatch(released)):
                        errors.append(f"{vprefix}: invalid released timestamp {released!r}")
    return errors


def validate_index_manifest(data: dict, directory: Path | None = None,
                            allow_missing: bool = False) -> list[str]:
    """Validate a hosted `native/manifest.json` index (schema 1) and optional bytes."""
    errors: list[str] = []
    if not isinstance(data, dict):
        return ["native index must be a JSON object"]
    extra_top = set(data) - INDEX_TOP_KEYS
    if extra_top:
        errors.append(f"native index contains unexpected top-level fields: {sorted(extra_top)}")
    if data.get("schema") != 1:
        errors.append(f"expected native index schema 1, got {data.get('schema')!r}")
    if "modules" in data:
        errors.extend(validate_index_modules(data["modules"]))
    artifacts = data.get("artifacts")
    if not isinstance(artifacts, list):
        return [*errors, "artifacts must be a list"]
    seen: set[str] = set()
    for index, item in enumerate(artifacts):
        prefix = f"artifacts[{index}]"
        if not isinstance(item, dict):
            errors.append(f"{prefix}: entry must be an object")
            continue
        extra_keys = set(item) - (INDEX_REQUIRED_ARTIFACT_KEYS | INDEX_OPTIONAL_ARTIFACT_KEYS)
        if extra_keys:
            errors.append(f"{prefix}: unexpected fields {sorted(extra_keys)}")
        pkg = item.get("package")
        mod = item.get("module")
        ver = item.get("version")
        plat = item.get("platform")
        rel = item.get("path")
        digest = item.get("sha256")
        size = item.get("size")
        if not isinstance(pkg, str) or not NAME_RE.fullmatch(pkg):
            errors.append(f"{prefix}: invalid package {pkg!r}")
        if not isinstance(mod, str) or not NAME_RE.fullmatch(mod):
            errors.append(f"{prefix}: invalid module {mod!r}")
        if not isinstance(ver, str) or not VERSION_RE.fullmatch(ver):
            errors.append(f"{prefix}: invalid version {ver!r}")
        if plat not in VALID_PLATFORMS:
            errors.append(f"{prefix}: invalid platform {plat!r}")
        if "role" in item and item["role"] not in VALID_ROLES:
            errors.append(f"{prefix}: invalid role {item['role']!r}")
        if "owner_module" in item:
            owner = item["owner_module"]
            if not isinstance(owner, str) or not NAME_RE.fullmatch(owner):
                errors.append(f"{prefix}: invalid owner_module {owner!r}")
        if "runtime_name" in item:
            rname = item["runtime_name"]
            if not isinstance(rname, str) or not LIB_NAME_RE.fullmatch(rname):
                errors.append(f"{prefix}: invalid runtime_name {rname!r}")
        if "note" in item:
            note = item["note"]
            if not isinstance(note, str) or not note.strip() or len(note) > 300:
                errors.append(f"{prefix}: invalid note {note!r}")
        if "built_at" in item:
            built_at = item["built_at"]
            if not isinstance(built_at, str) or not TIMESTAMP_RE.fullmatch(built_at):
                errors.append(f"{prefix}: invalid built_at {built_at!r}")
        if not isinstance(rel, str):
            errors.append(f"{prefix}: path must be a string")
        else:
            posix = PurePosixPath(rel)
            expected_prefix = (pkg, ver)
            if (posix.is_absolute() or len(posix.parts) != 3
                    or any(part in (".", "..") for part in posix.parts)
                    or posix.parts[:2] != expected_prefix
                    or not FILE_RE.fullmatch(posix.parts[2])
                    or (plat in PLATFORM_SUFFIX and not posix.parts[2].endswith(PLATFORM_SUFFIX[plat]))):
                errors.append(f"{prefix}: unsafe or malformed path {rel!r}")
            elif rel in seen:
                errors.append(f"{prefix}: duplicate artifact path {rel}")
            else:
                seen.add(rel)
        if not isinstance(digest, str) or not SHA256_RE.fullmatch(digest):
            errors.append(f"{prefix}: invalid sha256 {digest!r}")
        if not isinstance(size, int) or isinstance(size, bool) or size <= 0:
            errors.append(f"{prefix}: invalid size {size!r}")
        if directory is not None and isinstance(rel, str) and not errors:
            target = directory / rel
            if allow_missing and not target.exists():
                continue
            if target.is_symlink() or not target.is_file():
                errors.append(f"{prefix}: missing or non-regular artifact {rel}")
            elif target.stat().st_size != size or sha256_file(target) != digest:
                errors.append(f"{prefix}: checksum or size mismatch for {rel}")
    return errors


def smoke_verify(module_path: Path, package: str, emacs: str) -> None:
    """Load MODULE_PATH in a fresh `emacs -Q --batch` and run its smoke assertion."""
    smoke = NATIVE_PACKAGES[package]["smoke"]
    expr = f'(progn (module-load {json.dumps(str(module_path.resolve()))}) {smoke} (princ "native-smoke=ok\\n"))'
    env = dict(os.environ)
    env.pop("EMACSLOADPATH", None)
    result = subprocess.run([emacs, "-Q", "--batch", "--eval", expr],
                            capture_output=True, text=True, env=env, timeout=60)
    if result.returncode != 0 or "native-smoke=ok" not in result.stdout:
        raise ValueError(
            f"Native module smoke check failed for {package} ({module_path.name}):\n"
            f"{result.stdout}\n{result.stderr}".strip())


def build_package(package: str, output: Path, emacs: str,
                  arch: str | None = None, portable: bool = True,
                  skip_smoke: bool = False) -> dict:
    """Build PACKAGE's native module into OUTPUT and return its artifact record."""
    if package not in NATIVE_PACKAGES:
        raise ValueError(f"Unknown native package: {package}; choose from {sorted(NATIVE_PACKAGES)}")
    spec = NATIVE_PACKAGES[package]
    plat = host_platform(arch)
    if plat not in spec["platforms"]:
        raise ValueError(f"{package}: platform {plat} is not in supported platforms {spec['platforms']}")
    native_plat = host_platform()
    cross = plat != native_plat
    if cross and sys.platform != "darwin":
        raise ValueError(f"Cross-compilation from {native_plat} to {plat} is only supported on macOS")

    pkg_dir = ROOT / "packages" / package
    native_src = pkg_dir / "native"
    if not native_src.is_dir():
        raise ValueError(f"Missing native source directory: {native_src}")

    suffix = PLATFORM_SUFFIX[plat]
    module_name = spec["module"]
    version = spec["version"]
    out_filename = artifact_filename(module_name, version, plat)
    dest = output / package / version / out_filename
    dest.parent.mkdir(parents=True, exist_ok=True)

    with tempfile.TemporaryDirectory(prefix=f"etaf-native-{package}-") as tmp:
        work = Path(tmp) / "native"
        shutil.copytree(native_src, work, ignore=shutil.ignore_patterns("build", "*.o", "*.so", "*.dylib", "*.dll"))
        env = dict(os.environ)
        env["EMACS"] = emacs
        if package == "etaf-md":
            cmd = ["make", "-C", str(work), f"EMACS={emacs}", f"MODULE_SUFFIX={suffix}"]
            if portable:
                cmd.append("PORTABLE=1")
            if sys.platform.startswith("linux") and portable:
                cmd.append("TEXT_BACKEND=pango-dlopen")
            if arch and sys.platform == "darwin":
                cmd.append(f"ARCH={arch}")
            built = work / f"{module_name}{suffix}"
        elif package == "etaf":
            script = work / "build-video-mpv-module.sh"
            if arch and sys.platform == "darwin":
                env["ARCH"] = arch
            if portable:
                env["PORTABLE"] = "1"
            cmd = ["sh", str(script)]
            built = work / f"{module_name}{suffix}"
        elif package == "ekp":
            cmd = ["make", "-C", str(work), "PROFILE=portable", f"EMACS={emacs}"]
            if portable:
                cmd.append("PORTABLE=1")
            if arch and sys.platform == "darwin":
                cmd.append(f"ARCH={arch}")
            built = work / f"{module_name}{suffix}"
        else:
            raise ValueError(f"No build recipe for {package}")

        result = subprocess.run(cmd, env=env, capture_output=True, text=True, timeout=300)
        if result.returncode != 0 or not built.is_file():
            raise ValueError(
                f"Native build failed for {package} ({plat}):\n{result.stdout}\n{result.stderr}".strip())
        if not skip_smoke and not cross:
            smoke_verify(built, package, emacs)
        shutil.copyfile(built, dest)
        dest.chmod(0o755)

    record = {
        "package": package,
        "module": module_name,
        "owner_module": module_name,
        "role": "module",
        "version": version,
        "platform": plat,
        "file": out_filename,
        "path": f"{package}/{version}/{out_filename}",
        "sha256": sha256_file(dest),
        "size": dest.stat().st_size,
        "built_at": utc_now_iso(),
    }
    meta_dir = output / "records"
    meta_dir.mkdir(parents=True, exist_ok=True)
    (meta_dir / f"{package}-{module_name}-{plat}.json").write_text(
        json.dumps(record, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    return record


def register_module(package: str, plat: str, source: Path, output: Path) -> dict:
    """Stage a prebuilt native module binary under OUTPUT and write its record."""
    if package not in NATIVE_PACKAGES:
        raise ValueError(f"Unknown native package: {package}; choose from {sorted(NATIVE_PACKAGES)}")
    spec = NATIVE_PACKAGES[package]
    if plat not in spec["platforms"]:
        raise ValueError(f"{package}: platform {plat} is not in supported platforms {spec['platforms']}")
    if not source.is_file():
        raise ValueError(f"Missing native module binary: {source}")
    module_name = spec["module"]
    version = spec["version"]
    out_filename = artifact_filename(module_name, version, plat)
    dest = output / package / version / out_filename
    dest.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(source, dest)
    dest.chmod(0o755)
    record = {
        "package": package,
        "module": module_name,
        "owner_module": module_name,
        "role": "module",
        "version": version,
        "platform": plat,
        "file": out_filename,
        "path": f"{package}/{version}/{out_filename}",
        "sha256": sha256_file(dest),
        "size": dest.stat().st_size,
        "built_at": utc_now_iso(),
    }
    meta_dir = output / "records"
    meta_dir.mkdir(parents=True, exist_ok=True)
    (meta_dir / f"{package}-{module_name}-{plat}.json").write_text(
        json.dumps(record, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    return record


def register_library(package: str, plat: str, name: str, module: str,
                     source: Path, output: Path, note: str | None = None) -> dict:
    """Stage a companion shared library binary under OUTPUT and write its record."""
    if package not in NATIVE_PACKAGES:
        raise ValueError(f"Unknown native package: {package}; choose from {sorted(NATIVE_PACKAGES)}")
    spec = NATIVE_PACKAGES[package]
    if plat not in spec["platforms"]:
        raise ValueError(f"{package}: platform {plat} is not in supported platforms {spec['platforms']}")
    if not LIB_NAME_RE.fullmatch(name):
        raise ValueError(f"Invalid companion library filename: {name!r}")
    if not NAME_RE.fullmatch(module):
        raise ValueError(f"Invalid companion library module id: {module!r}")
    if not source.is_file():
        raise ValueError(f"Missing companion library binary: {source}")
    version = spec["version"]
    out_filename = artifact_filename(module, version, plat)
    dest = output / package / version / out_filename
    dest.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(source, dest)
    dest.chmod(0o644)
    lib_meta = (spec.get("libraries") or {}).get(module, {})
    resolved_note = (note or lib_meta.get("note") or "").strip()
    record = {
        "kind": "library",
        "role": "library",
        "package": package,
        "module": module,
        "owner_module": spec["module"],
        "name": name,
        "runtime_name": name,
        "version": version,
        "platform": plat,
        "file": out_filename,
        "path": f"{package}/{version}/{out_filename}",
        "sha256": sha256_file(dest),
        "size": dest.stat().st_size,
        "built_at": utc_now_iso(),
    }
    if resolved_note:
        record["note"] = resolved_note
    meta_dir = output / "records"
    meta_dir.mkdir(parents=True, exist_ok=True)
    (meta_dir / f"{package}-lib-{module}-{plat}.json").write_text(
        json.dumps(record, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    return record


def _index_artifact_from_record(rec: dict) -> dict:
    """Build one validated hosted index artifact entry from a build/staging record."""
    pkg = rec["package"]
    spec = NATIVE_PACKAGES.get(pkg) or {}
    is_lib = rec.get("role") == "library" or rec.get("kind") == "library"
    if not is_lib and spec and rec["module"] != spec.get("module") and rec["module"] in (spec.get("libraries") or {}):
        is_lib = True
    role = "library" if is_lib else "module"
    owner = rec.get("owner_module") or (spec.get("module") if is_lib and spec else rec["module"])
    entry = {
        "package": pkg,
        "module": rec["module"],
        "owner_module": owner,
        "role": role,
        "version": rec["version"],
        "platform": rec["platform"],
        "path": rec["path"],
        "sha256": rec["sha256"],
        "size": rec["size"],
    }
    lib_meta = (spec.get("libraries") or {}).get(rec["module"], {}) if is_lib else {}
    runtime_name = rec.get("runtime_name") or rec.get("name") or lib_meta.get("runtime_name")
    if is_lib and runtime_name:
        entry["runtime_name"] = runtime_name
    note = rec.get("note") or lib_meta.get("note")
    if note:
        entry["note"] = note
    built_at = rec.get("built_at")
    if not built_at and spec:
        if rec["version"] == spec.get("version") and spec.get("released"):
            built_at = spec["released"]
        elif rec["version"] in (spec.get("versions") or {}):
            built_at = spec["versions"][rec["version"]].get("released")
    if built_at:
        entry["built_at"] = built_at
    return entry


def build_modules_catalog(artifacts: list[dict], existing_modules: dict | None = None) -> dict:
    """Build the hosted `modules` catalog covering every owner module in ARTIFACTS."""
    by_owner: dict[str, list[dict]] = {}
    for item in artifacts:
        owner = item.get("owner_module") or item["module"]
        by_owner.setdefault(owner, []).append(item)

    spec_by_module = {spec["module"]: (pkg, spec) for pkg, spec in NATIVE_PACKAGES.items()}
    catalog: dict[str, dict] = {}
    for owner, items in sorted(by_owner.items()):
        existing = (existing_modules or {}).get(owner) or {}
        pkg_spec = spec_by_module.get(owner)
        pkg = pkg_spec[0] if pkg_spec else items[0]["package"]
        spec = pkg_spec[1] if pkg_spec else {}
        present_versions = sorted({item["version"] for item in items}, key=version_key, reverse=True)
        # Prefer declared current version if present in artifacts, else highest numeric version.
        if spec.get("version") in present_versions:
            current_ver = spec["version"]
        elif existing.get("current_version") in present_versions:
            current_ver = existing["current_version"]
        else:
            current_ver = present_versions[0]

        description = spec.get("description") or existing.get("description") or f"Prebuilt native dynamic module for {pkg}."
        used_by = list(spec.get("used_by") or existing.get("used_by") or [pkg])

        versions_map: dict[str, dict] = {}
        for ver in present_versions:
            v_existing = dict((existing.get("versions") or {}).get(ver) or {})
            v_spec = dict((spec.get("versions") or {}).get(ver) or {})
            v_entry: dict[str, object] = {**v_existing, **v_spec}
            v_entry["status"] = "current" if ver == current_ver else "archived"
            if ver == spec.get("version"):
                if spec.get("min_package_version"):
                    v_entry["min_package_version"] = spec["min_package_version"]
                if spec.get("version_summary"):
                    v_entry["summary"] = spec["version_summary"]
                if spec.get("released") and "released" not in v_entry:
                    v_entry["released"] = spec["released"]
            if "released" not in v_entry:
                built_dates = sorted(i["built_at"] for i in items if i["version"] == ver and i.get("built_at"))
                if built_dates:
                    v_entry["released"] = built_dates[-1]
            versions_map[ver] = v_entry

        catalog[owner] = {
            "package": pkg,
            "current_version": current_ver,
            "description": description,
            "used_by": used_by,
            "versions": dict(sorted(versions_map.items(), key=lambda kv: version_key(kv[0]), reverse=True)),
        }
    return catalog


def enrich_index_manifest(manifest: dict) -> dict:
    """Enrich a hosted `native/manifest.json` with module catalog and artifact metadata.

    Preserves every artifact's exact `path`, `sha256` and `size` while adding
    data-driven `role`, `owner_module`, `runtime_name`, `note`, `built_at` and
    the top-level `modules` catalog.
    """
    if not isinstance(manifest, dict) or manifest.get("schema") != 1 or not isinstance(manifest.get("artifacts"), list):
        raise ValueError("Expected a schema 1 hosted native manifest")
    enriched_artifacts = sorted(
        [_index_artifact_from_record(item) for item in manifest["artifacts"]],
        key=lambda item: item["path"],
    )
    modules_catalog = build_modules_catalog(enriched_artifacts, manifest.get("modules"))
    result = {
        "schema": 1,
        "modules": modules_catalog,
        "artifacts": enriched_artifacts,
    }
    errs = validate_index_manifest(result, allow_missing=True)
    if errs:
        raise ValueError("Enriched native manifest invalid: " + "; ".join(errs))
    return result


def assemble_manifests(input_dir: Path, *, write_packages: bool = False,
                       stage: Path | None = None, replace: bool = False,
                       base_url: str = "https://etaf.top/native",
                       github_org: str = "emacs-taf") -> dict:
    """Validate built artifacts under INPUT_DIR, update package manifests, and stage index."""
    records_dir = input_dir / "records"
    if not records_dir.is_dir():
        raise ValueError(f"No artifact records directory found under {input_dir}")
    records = []
    for path in sorted(records_dir.glob("*.json")):
        rec = json.loads(path.read_text(encoding="utf-8"))
        binary = input_dir / rec["path"]
        if not binary.is_file():
            raise ValueError(f"Missing binary for record {path.name}: {binary}")
        actual_sha = sha256_file(binary)
        actual_size = binary.stat().st_size
        if actual_sha != rec["sha256"] or actual_size != rec["size"]:
            raise ValueError(f"Artifact checksum/size mismatch for {rec['path']}")
        records.append(rec)
    if not records:
        raise ValueError(f"No artifact records found in {records_dir}")

    by_pkg: dict[str, list[dict]] = {}
    for rec in records:
        by_pkg.setdefault(rec["package"], []).append(rec)

    package_manifests: dict[str, dict] = {}
    for pkg, items in sorted(by_pkg.items()):
        if pkg not in NATIVE_PACKAGES:
            raise ValueError(f"Unknown package in records: {pkg}")
        spec = NATIVE_PACKAGES[pkg]
        manifest_path = ROOT / "packages" / pkg / "native" / "manifest.json"
        existing_platforms: dict[str, dict] = {}
        if not replace and manifest_path.is_file():
            old = json.loads(manifest_path.read_text(encoding="utf-8"))
            for mod in old.get("modules", ()):
                if mod.get("name") == spec["module"] and mod.get("version") == spec["version"]:
                    existing_platforms = {k: dict(v) for k, v in (mod.get("platforms") or {}).items()}
        module_items = [r for r in items if r.get("kind", "module") == "module"]
        lib_items = [r for r in items if r.get("kind") == "library"]
        for rec in module_items:
            if rec["module"] != spec["module"] or rec["version"] != spec["version"]:
                raise ValueError(f"{pkg}: record module/version does not match registry")
            prev = existing_platforms.get(rec["platform"])
            entry = {
                "file": rec["file"],
                "urls": default_urls(pkg, rec["version"], rec["file"], base_url, github_org),
                "sha256": rec["sha256"],
                "size": rec["size"],
            }
            if not replace and prev and "libraries" in prev:
                entry["libraries"] = prev["libraries"]
            existing_platforms[rec["platform"]] = entry
        libs_by_plat: dict[str, dict[str, dict]] = {}
        for rec in lib_items:
            if rec["version"] != spec["version"]:
                raise ValueError(f"{pkg}: library record version does not match registry")
            plat = rec["platform"]
            if plat not in existing_platforms:
                raise ValueError(f"{pkg}: companion library for {plat} has no module entry")
            if plat not in libs_by_plat:
                libs_by_plat[plat] = {
                    lib["name"]: lib
                    for lib in existing_platforms[plat].get("libraries", ())
                } if not replace else {}
            libs_by_plat[plat][rec["name"]] = {
                "name": rec["name"],
                "file": rec["file"],
                "urls": default_urls(pkg, rec["version"], rec["file"], base_url, github_org),
                "sha256": rec["sha256"],
                "size": rec["size"],
            }
        for plat, lib_map in libs_by_plat.items():
            existing_platforms[plat]["libraries"] = [
                lib_map[name] for name in sorted(lib_map)
            ]
        doc = {
            "schema": 1,
            "package": pkg,
            "modules": [
                {
                    "name": spec["module"],
                    "version": spec["version"],
                    "description": spec["description"],
                    "platforms": dict(sorted(existing_platforms.items())),
                }
            ],
        }
        errs = validate_manifest(doc, expected_package=pkg)
        if errs:
            raise ValueError(f"{pkg}: generated manifest invalid: {'; '.join(errs)}")
        package_manifests[pkg] = doc
        if write_packages:
            manifest_path.write_text(json.dumps(doc, indent=2) + "\n", encoding="utf-8")

    index_artifacts = sorted(
        [_index_artifact_from_record(r) for r in records],
        key=lambda item: item["path"],
    )
    index_doc = {
        "schema": 1,
        "modules": build_modules_catalog(index_artifacts),
        "artifacts": index_artifacts,
    }

    if stage is not None:
        if stage.exists():
            raise ValueError(f"Refusing to replace existing stage directory: {stage}")
        stage.parent.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(prefix=".etaf-native-stage-", dir=stage.parent) as work:
            clean = Path(work) / "native"
            clean.mkdir()
            for r in records:
                dest = clean / r["path"]
                dest.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(input_dir / r["path"], dest)
                dest.chmod(0o644)
            (clean / "manifest.json").write_text(
                json.dumps(index_doc, indent=2, sort_keys=True) + "\n", encoding="utf-8")
            errs = validate_index_manifest(index_doc, clean)
            if errs:
                raise ValueError("Staged native tree invalid: " + "; ".join(errs))
            clean.rename(stage)

    return {"manifests": package_manifests, "index": index_doc}


def verify_all(root: Path = ROOT) -> list[str]:
    """Validate every package `native/manifest.json` under ROOT/packages."""
    errors: list[str] = []
    packages_dir = root / "packages"
    if not packages_dir.is_dir():
        return errors
    for manifest_path in sorted(packages_dir.glob("*/native/manifest.json")):
        pkg = manifest_path.parents[1].name
        try:
            data = json.loads(manifest_path.read_text(encoding="utf-8"))
        except (OSError, ValueError) as error:
            errors.append(f"{manifest_path.relative_to(root)}: invalid JSON: {error}")
            continue
        for err in validate_manifest(data, expected_package=pkg):
            errors.append(f"{manifest_path.relative_to(root)}: {err}")
    return errors


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command")

    p_build = sub.add_parser("build", help="Build and smoke-test native module(s)")
    p_build.add_argument("--package", action="append",
                         help="Package to build (repeatable; defaults to all registered native packages)")
    p_build.add_argument("--output", type=Path, required=True)
    p_build.add_argument("--emacs", default="emacs")
    p_build.add_argument("--arch", choices=("arm64", "x86_64"),
                         help="Target architecture (macOS supports cross-compiling arm64 and x86_64)")
    p_build.add_argument("--skip-smoke", action="store_true")

    p_register = sub.add_parser("register", help="Stage a remotely built native module binary and write its record")
    p_register.add_argument("--package", required=True)
    p_register.add_argument("--platform", required=True, choices=VALID_PLATFORMS)
    p_register.add_argument("--source", type=Path, required=True)
    p_register.add_argument("--output", type=Path, required=True)

    p_library = sub.add_parser("library", help="Stage a companion shared library binary and write its record")
    p_library.add_argument("--package", required=True)
    p_library.add_argument("--platform", required=True, choices=VALID_PLATFORMS)
    p_library.add_argument("--name", required=True, help="Runtime filename in cache directory (e.g. libmpv-2.dll)")
    p_library.add_argument("--module", required=True, help="Artifact identifier prefix (e.g. libmpv-2)")
    p_library.add_argument("--note", help="Optional human-readable companion library description")
    p_library.add_argument("--source", type=Path, required=True)
    p_library.add_argument("--output", type=Path, required=True)

    p_manifest = sub.add_parser("manifest", help="Assemble package manifests and staged native tree")
    p_manifest.add_argument("--input", type=Path, required=True)
    p_manifest.add_argument("--write-packages", action="store_true",
                            help="Write updated packages/<pkg>/native/manifest.json files")
    p_manifest.add_argument("--replace", action="store_true",
                            help="Replace existing platform entries instead of merging")
    p_manifest.add_argument("--stage", type=Path,
                            help="Write a verified deployable native/ directory here")
    p_manifest.add_argument("--base-url", default="https://etaf.top/native")
    p_manifest.add_argument("--github-org", default="emacs-taf")

    p_enrich = sub.add_parser("enrich", help="Enrich a hosted native/manifest.json with catalog and artifact metadata")
    p_enrich.add_argument("--input", type=Path, required=True, help="Input hosted native/manifest.json")
    p_enrich.add_argument("--output", type=Path, required=True, help="Output path for enriched manifest.json")

    p_verify = sub.add_parser("verify", help="Validate package or staged native manifests")
    p_verify.add_argument("--manifest", type=Path, help="Single package native/manifest.json to check")
    p_verify.add_argument("--stage", type=Path, help="Staged native/ directory to verify")
    p_verify.add_argument("--all", action="store_true", help="Verify all packages/*/native/manifest.json")

    args_list = sys.argv[1:]
    if not args_list or args_list == ["help"]:
        parser.print_help()
        return 0
    if args_list[0] == "help":
        args_list = [*args_list[1:], "--help"]
    args = parser.parse_args(args_list)

    if args.command == "build":
        targets = args.package or sorted(NATIVE_PACKAGES)
        built = [build_package(pkg, args.output.resolve(), args.emacs,
                               arch=args.arch, skip_smoke=args.skip_smoke)
                 for pkg in targets]
        print(json.dumps({"built": built}, indent=2))
        return 0
    if args.command == "register":
        record = register_module(args.package, args.platform,
                                 args.source.resolve(), args.output.resolve())
        print(json.dumps(record, indent=2))
        return 0
    if args.command == "library":
        record = register_library(args.package, args.platform, args.name,
                                  args.module, args.source.resolve(), args.output.resolve(),
                                  note=args.note)
        print(json.dumps(record, indent=2))
        return 0
    if args.command == "manifest":
        result = assemble_manifests(
            args.input.resolve(),
            write_packages=args.write_packages,
            stage=args.stage.resolve() if args.stage else None,
            replace=args.replace,
            base_url=args.base_url,
            github_org=args.github_org,
        )
        print(json.dumps({"packages": sorted(result["manifests"]),
                          "artifacts": len(result["index"]["artifacts"])}, indent=2))
        return 0
    if args.command == "enrich":
        source = json.loads(args.input.resolve().read_text(encoding="utf-8"))
        enriched = enrich_index_manifest(source)
        args.output.resolve().write_text(
            json.dumps(enriched, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        print(json.dumps({"modules": len(enriched.get("modules", {})),
                          "artifacts": len(enriched["artifacts"])}, indent=2))
        return 0
    if args.command == "verify":
        errs: list[str] = []
        if args.manifest:
            data = json.loads(args.manifest.read_text(encoding="utf-8"))
            errs.extend(validate_manifest(data))
        if args.stage:
            stage = args.stage.resolve()
            data = json.loads((stage / "manifest.json").read_text(encoding="utf-8"))
            errs.extend(validate_index_manifest(data, stage))
        if args.all or (not args.manifest and not args.stage):
            errs.extend(verify_all(ROOT))
        if errs:
            print("\n".join(errs), file=sys.stderr)
            return 1
        print("native manifests OK")
        return 0
    parser.print_help()
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (ValueError, KeyError, OSError, subprocess.SubprocessError) as error:
        print(f"error=native-release\nhint={error}", file=sys.stderr)
        sys.exit(1)
