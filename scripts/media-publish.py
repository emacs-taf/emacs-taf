#!/usr/bin/env python3
"""Compress, stage, verify and publish showcase media to https://etaf.top/media/.

All documentation screenshots, website showcase images and demo videos live on
https://etaf.top/media/ instead of bloating Git history.  This tool converts
PNG/JPEG inputs to crisp WebP (via cwebp by default), writes a checksummed
schema-1 manifest.json and delegates atomic publication to
packages/etaf-manual/site/scripts/publish.py --media-only.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
PUBLISHER = (
    ROOT / "core/packages/etaf-manual/site/scripts/publish.py"
    if (ROOT / "core/packages/etaf-manual/site/scripts/publish.py").is_file()
    else ROOT / "packages/etaf-manual/site/scripts/publish.py"
)
BASE_URL = "https://etaf.top/media"
NAMESPACE_RE = re.compile(r"[a-z][a-z0-9-]*\Z")
SEGMENT_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]*\Z")
CONVERTIBLE_IMAGE_EXTS = frozenset({".png", ".jpg", ".jpeg"})
ALLOWED_EXTS = frozenset({
    ".webp", ".png", ".jpg", ".jpeg", ".gif", ".svg", ".avif",
    ".mp4", ".webm", ".mov", ".pdf",
})


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as fh:
        for chunk in iter(lambda: fh.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def parse_item_spec(spec: str) -> tuple[str, Path, str | None]:
    """Parse NAMESPACE:SOURCE[:DEST_REL] into (namespace, source_path, dest_rel)."""
    parts = spec.split(":", 2)
    if len(parts) < 2 or not parts[0] or not parts[1]:
        raise ValueError(f"Invalid --item {spec!r}; expected NAMESPACE:SOURCE[:DEST_NAME]")
    namespace = parts[0].strip()
    if not NAMESPACE_RE.fullmatch(namespace):
        raise ValueError(f"Invalid media namespace {namespace!r}")
    source = Path(parts[1]).expanduser().resolve()
    dest = parts[2].strip() if len(parts) == 3 and parts[2].strip() else None
    return namespace, source, dest


def convert_to_webp(source: Path, dest: Path, quality: int = 85) -> None:
    """Encode SOURCE image to WebP at DEST using cwebp (fallback: ffmpeg)."""
    cwebp = shutil.which("cwebp")
    if cwebp:
        subprocess.run(
            [cwebp, "-quiet", "-q", str(quality), "-m", "6", str(source), "-o", str(dest)],
            check=True,
            timeout=120,
        )
        return
    ffmpeg = shutil.which("ffmpeg")
    if ffmpeg:
        subprocess.run(
            [ffmpeg, "-y", "-loglevel", "error", "-i", str(source),
             "-c:v", "libwebp", "-quality", str(quality), str(dest)],
            check=True,
            timeout=120,
        )
        return
    raise ValueError("WebP conversion requires `cwebp` (brew install webp) or `ffmpeg` on PATH")


def resolve_dest_rel(namespace: str, source: Path, dest: str | None, *, keep_format: bool) -> PurePosixPath:
    """Return normalized `<namespace>/...` POSIX path for an asset."""
    src_ext = source.suffix.lower()
    if dest is None:
        if not keep_format and src_ext in CONVERTIBLE_IMAGE_EXTS:
            filename = source.stem + ".webp"
        else:
            filename = source.name
        rel = PurePosixPath(namespace) / filename
    else:
        raw = PurePosixPath(dest.lstrip("/"))
        rel = raw if raw.parts and raw.parts[0] == namespace else (PurePosixPath(namespace) / raw)
    if rel.is_absolute() or len(rel.parts) not in (2, 3) or rel.parts[0] != namespace:
        raise ValueError(f"Media path must be <namespace>/<file> or <namespace>/<dir>/<file>: {rel}")
    if any(not SEGMENT_RE.fullmatch(p) for p in rel.parts):
        raise ValueError(f"Unsafe media path segment: {rel}")
    if rel.suffix.lower() not in ALLOWED_EXTS:
        raise ValueError(f"Unsupported media file extension: {rel}")
    return rel


def stage_items(output: Path, items: list[tuple[str, Path, str | None]], *,
                quality: int = 85, keep_format: bool = False) -> dict:
    """Convert/copy ITEMS into OUTPUT and write schema-1 manifest.json."""
    if not items:
        raise ValueError("At least one --item or --spec entry is required")
    if output.exists() and any(output.iterdir()):
        raise ValueError(f"Refusing to overwrite non-empty staging directory: {output}")
    output.mkdir(parents=True, exist_ok=True)
    assets = []
    seen = set()
    total_src = 0
    total_dst = 0
    for namespace, source, dest in items:
        if not source.is_file():
            raise ValueError(f"Media source file not found: {source}")
        rel = resolve_dest_rel(namespace, source, dest, keep_format=keep_format)
        rel_str = rel.as_posix()
        if rel_str in seen:
            raise ValueError(f"Duplicate media target path: {rel_str}")
        seen.add(rel_str)
        target = output.joinpath(*rel.parts)
        target.parent.mkdir(parents=True, exist_ok=True)
        src_ext = source.suffix.lower()
        dst_ext = rel.suffix.lower()
        if src_ext in CONVERTIBLE_IMAGE_EXTS and dst_ext == ".webp":
            convert_to_webp(source, target, quality=quality)
        else:
            shutil.copyfile(source, target)
        src_size = source.stat().st_size
        dst_size = target.stat().st_size
        total_src += src_size
        total_dst += dst_size
        assets.append({
            "namespace": namespace,
            "path": rel_str,
            "sha256": sha256_file(target),
            "size": dst_size,
        })
    assets.sort(key=lambda item: item["path"])
    manifest = {"schema": 1, "assets": assets}
    (output / "manifest.json").write_text(
        json.dumps(manifest, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    return {
        "stage": str(output),
        "count": len(assets),
        "source_bytes": total_src,
        "staged_bytes": total_dst,
        "assets": assets,
    }


def verify_stage(stage: Path) -> dict:
    """Validate STAGE/manifest.json and every listed asset's size & SHA-256."""
    manifest_path = stage / "manifest.json"
    if not manifest_path.is_file():
        raise ValueError(f"Missing media manifest.json in {stage}")
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    if manifest.get("schema") != 1 or not isinstance(manifest.get("assets"), list):
        raise ValueError("Expected schema 1 media manifest")
    indexed = set()
    for item in manifest["assets"]:
        rel = PurePosixPath(item["path"])
        target = stage.joinpath(*rel.parts)
        if not target.is_file():
            raise ValueError(f"Missing staged asset: {item['path']}")
        if target.stat().st_size != item["size"] or sha256_file(target) != item["sha256"]:
            raise ValueError(f"Checksum mismatch for staged asset: {item['path']}")
        indexed.add(rel.as_posix())
    present = {
        p.relative_to(stage).as_posix()
        for p in stage.rglob("*")
        if p.is_file() and p.relative_to(stage).as_posix() != "manifest.json"
    }
    if present != indexed:
        raise ValueError(f"Staged files differ from manifest: extra={sorted(present - indexed)} missing={sorted(indexed - present)}")
    return manifest


def load_spec_file(spec_path: Path) -> list[tuple[str, Path, str | None]]:
    """Load items from a JSON list of {namespace, source, dest?} objects."""
    raw = json.loads(spec_path.read_text(encoding="utf-8"))
    if not isinstance(raw, list):
        raise ValueError("Spec JSON must be a list of item objects")
    items = []
    for entry in raw:
        ns = str(entry["namespace"]).strip()
        if not NAMESPACE_RE.fullmatch(ns):
            raise ValueError(f"Invalid namespace in spec: {ns!r}")
        src = Path(entry["source"]).expanduser()
        if not src.is_absolute():
            src = (spec_path.parent / src).resolve()
        dest = entry.get("dest")
        items.append((ns, src, str(dest).strip() if dest else None))
    return items


def collect_items(args) -> list[tuple[str, Path, str | None]]:
    items = []
    if getattr(args, "spec", None):
        items.extend(load_spec_file(args.spec))
    for raw in getattr(args, "item", None) or []:
        items.append(parse_item_spec(raw))
    return items


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)

    p_stage = sub.add_parser("stage", help="Convert/copy media assets into a verified staging directory")
    p_stage.add_argument("--output", type=Path, required=True)
    p_stage.add_argument("--item", action="append", default=[],
                         help="Asset spec NAMESPACE:SOURCE[:DEST_REL] (repeatable)")
    p_stage.add_argument("--spec", type=Path, help="JSON list of {namespace, source, dest?}")
    p_stage.add_argument("--quality", type=int, default=85, help="WebP quality (default: 85)")
    p_stage.add_argument("--keep-format", action="store_true", help="Do not convert PNG/JPEG to WebP")
    p_stage.add_argument("--json", action="store_true")

    p_verify = sub.add_parser("verify", help="Verify a staged media directory")
    p_verify.add_argument("--stage", type=Path, required=True)

    p_pub = sub.add_parser("publish", help="Stage (if items given) and publish media to https://etaf.top/media/")
    p_pub.add_argument("--stage", type=Path, help="Already-staged directory to publish")
    p_pub.add_argument("--item", action="append", default=[],
                       help="Asset spec NAMESPACE:SOURCE[:DEST_REL] (repeatable)")
    p_pub.add_argument("--spec", type=Path, help="JSON list of {namespace, source, dest?}")
    p_pub.add_argument("--quality", type=int, default=85)
    p_pub.add_argument("--keep-format", action="store_true")
    p_pub.add_argument("--dry-run", action="store_true", help="Stage and verify without uploading")

    args = parser.parse_args()
    if args.command == "stage":
        report = stage_items(args.output, collect_items(args),
                             quality=args.quality, keep_format=args.keep_format)
        verify_stage(args.output)
        if args.json:
            print(json.dumps(report, indent=2))
        else:
            ratio = (100.0 * report["staged_bytes"] / report["source_bytes"]) if report["source_bytes"] else 100.0
            print(f"Staged {report['count']} media asset(s) into {args.output} "
                  f"({report['source_bytes'] // 1024} KB -> {report['staged_bytes'] // 1024} KB, {ratio:.1f}%)")
            for asset in report["assets"]:
                print(f"  {BASE_URL}/{asset['path']} ({asset['size'] // 1024} KB)")
        return 0

    if args.command == "verify":
        manifest = verify_stage(args.stage)
        print(f"Media stage OK: {len(manifest['assets'])} asset(s) verified")
        return 0

    if args.command == "publish":
        if args.stage:
            stage_dir = args.stage.resolve()
            manifest = verify_stage(stage_dir)
            if args.dry_run:
                print(f"Dry run OK: {len(manifest['assets'])} asset(s) ready in {stage_dir}")
                return 0
            subprocess.run(
                [sys.executable, str(PUBLISHER), "--media-only", str(stage_dir)],
                check=True,
                timeout=1800,
            )
            for asset in manifest["assets"]:
                print(f"{BASE_URL}/{asset['path']}")
            return 0
        items = collect_items(args)
        with tempfile.TemporaryDirectory(prefix="etaf-media-stage-") as tmp:
            stage_dir = Path(tmp) / "media"
            report = stage_items(stage_dir, items, quality=args.quality, keep_format=args.keep_format)
            verify_stage(stage_dir)
            if args.dry_run:
                print(f"Dry run OK: {report['count']} asset(s) "
                      f"({report['source_bytes'] // 1024} KB -> {report['staged_bytes'] // 1024} KB)")
                for asset in report["assets"]:
                    print(f"  {BASE_URL}/{asset['path']} ({asset['size'] // 1024} KB)")
                return 0
            subprocess.run(
                [sys.executable, str(PUBLISHER), "--media-only", str(stage_dir)],
                check=True,
                timeout=1800,
            )
            for asset in report["assets"]:
                print(f"{BASE_URL}/{asset['path']}")
        return 0
    return 1


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (ValueError, OSError, subprocess.CalledProcessError) as err:
        print(f"error=media-publish\nhint={err}", file=sys.stderr)
        sys.exit(1)
