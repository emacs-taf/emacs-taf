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
HTTPS_RE = re.compile(r"https://[^\s\"']+\Z")

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
        "description": "Embedded QuickJS renderer for Mermaid diagrams and MathJax display formulas",
        "platforms": ("darwin-arm64", "darwin-x86_64", "linux-x86_64", "linux-arm64"),
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
        "version": "1",
        "description": "Cross-platform libmpv native video playback module",
        "platforms": ("darwin-arm64", "darwin-x86_64", "linux-x86_64", "linux-arm64", "windows-x86_64"),
        "smoke": (
            '(progn '
            '(unless (fboundp (quote etaf-video-mpv--native-available-p)) '
            '  (error "etaf-video-mpv--native-available-p missing")))'
        ),
    },
    "ekp": {
        "module": "ekp",
        "version": "1.6",
        "description": "Multi-threaded C Knuth-Plass line-breaking engine",
        "platforms": ("darwin-arm64", "darwin-x86_64", "linux-x86_64", "linux-arm64", "windows-x86_64"),
        "smoke": (
            '(progn '
            '(ekp-c-init) '
            '(when (version< (ekp-c-version) "1.6") '
            '  (error "ekp-c-version too old: %s" (ekp-c-version))))'
        ),
    },
}


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
    return errors


def validate_index_manifest(data: dict, directory: Path | None = None,
                            allow_missing: bool = False) -> list[str]:
    """Validate a hosted `native/manifest.json` index (schema 1) and optional bytes."""
    errors: list[str] = []
    if not isinstance(data, dict):
        return ["native index must be a JSON object"]
    if data.get("schema") != 1:
        errors.append(f"expected native index schema 1, got {data.get('schema')!r}")
    artifacts = data.get("artifacts")
    if not isinstance(artifacts, list):
        return [*errors, "artifacts must be a list"]
    seen: set[str] = set()
    for index, item in enumerate(artifacts):
        prefix = f"artifacts[{index}]"
        if not isinstance(item, dict):
            errors.append(f"{prefix}: entry must be an object")
            continue
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
        "version": version,
        "platform": plat,
        "file": out_filename,
        "path": f"{package}/{version}/{out_filename}",
        "sha256": sha256_file(dest),
        "size": dest.stat().st_size,
    }
    meta_dir = output / "records"
    meta_dir.mkdir(parents=True, exist_ok=True)
    (meta_dir / f"{package}-{module_name}-{plat}.json").write_text(
        json.dumps(record, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    return record


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
                    existing_platforms = dict(mod.get("platforms") or {})
        for rec in items:
            if rec["module"] != spec["module"] or rec["version"] != spec["version"]:
                raise ValueError(f"{pkg}: record module/version does not match registry")
            existing_platforms[rec["platform"]] = {
                "file": rec["file"],
                "urls": default_urls(pkg, rec["version"], rec["file"], base_url, github_org),
                "sha256": rec["sha256"],
                "size": rec["size"],
            }
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

    index_doc = {
        "schema": 1,
        "artifacts": sorted(
            [
                {
                    "package": r["package"],
                    "module": r["module"],
                    "version": r["version"],
                    "platform": r["platform"],
                    "path": r["path"],
                    "sha256": r["sha256"],
                    "size": r["size"],
                }
                for r in records
            ],
            key=lambda item: item["path"],
        ),
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
