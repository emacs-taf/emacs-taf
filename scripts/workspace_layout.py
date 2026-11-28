#!/usr/bin/env python3
"""Unified monorepo layout and projection discovery for Emacs TAF.

Supports both the layered monorepo layout:
  - core/packages/<pkg>  (core framework, extensions, installer, manual)
  - apps/<pkg>           (end-user applications)
  - games/<pkg>          (games)

and the legacy flat `packages/<pkg>` layout (kept for isolated policy tests).
"""
from __future__ import annotations

import json
from pathlib import Path, PurePosixPath

LAYERED_CONTAINERS = ("core/packages", "apps", "games")
LEGACY_CONTAINER = "packages"


def load_workspace(root: Path) -> dict:
    """Return parsed workspace.json under ROOT, or {} if absent/invalid."""
    ws = Path(root) / "workspace.json"
    if not ws.is_file():
        return {}
    try:
        data = json.loads(ws.read_text(encoding="utf-8"))
        return data if isinstance(data, dict) else {}
    except (OSError, ValueError):
        return {}


def is_layered_layout(root: Path) -> bool:
    """Return True when ROOT uses the layered core/packages + apps + games layout."""
    root = Path(root)
    return any((root / rel).is_dir() for rel in LAYERED_CONTAINERS)


def package_containers(root: Path) -> list[Path]:
    """Return existing package container directories under ROOT."""
    root = Path(root)
    layered = [root / rel for rel in LAYERED_CONTAINERS if (root / rel).is_dir()]
    if layered:
        return layered
    legacy = root / LEGACY_CONTAINER
    if legacy.is_dir():
        return [legacy]
    return []


def package_dirs(root: Path) -> dict[str, Path]:
    """Return {package_name: absolute_dir} across all containers under ROOT."""
    root = Path(root).resolve()
    found: dict[str, Path] = {}
    ws = load_workspace(root)
    registered = ws.get("packages")
    if isinstance(registered, dict):
        for name, meta in registered.items():
            if isinstance(meta, dict) and isinstance(meta.get("path"), str):
                candidate = root / meta["path"]
                if candidate.is_dir():
                    found[name] = candidate
    for container in package_containers(root):
        for entry in sorted(container.iterdir()):
            if entry.is_dir() and not entry.name.startswith("."):
                found.setdefault(entry.name, entry)
    return dict(sorted(found.items()))


def package_path(root: Path, name: str) -> Path:
    """Return the directory of package NAME under ROOT (even if missing on disk)."""
    root = Path(root).resolve()
    ws = load_workspace(root)
    registered = ws.get("packages")
    if isinstance(registered, dict):
        meta = registered.get(name)
        if isinstance(meta, dict) and isinstance(meta.get("path"), str):
            return root / meta["path"]
    for container in package_containers(root):
        candidate = container / name
        if candidate.is_dir():
            return candidate
    if (root / LEGACY_CONTAINER).is_dir():
        return root / LEGACY_CONTAINER / name
    return root / name


def package_relpath(root: Path, name: str) -> str | None:
    """Return POSIX path of package NAME relative to ROOT, or None if absent."""
    root = Path(root).resolve()
    path = package_path(root, name)
    if path.is_dir():
        try:
            return path.resolve().relative_to(root).as_posix()
        except ValueError:
            return None
    return None


def container_root(pkg_root: Path) -> Path | None:
    """Return the owning monorepo root when PKG_ROOT lives inside a container.

    Matches:
      - <monorepo>/core/packages/<pkg>
      - <monorepo>/apps/<pkg>
      - <monorepo>/games/<pkg>
      - <monorepo>/packages/<pkg>
    """
    pkg = Path(pkg_root).resolve()
    if (pkg.parent.name in ("apps", "games", LEGACY_CONTAINER)
            and (pkg.parent.parent / "workspace.json").is_file()):
        return pkg.parent.parent
    if (pkg.parent.name == "packages"
            and pkg.parent.parent.name == "core"
            and (pkg.parent.parent.parent / "workspace.json").is_file()):
        return pkg.parent.parent.parent
    return None


def core_packages_dir(root: Path) -> Path:
    """Return the directory holding core framework providers under ROOT."""
    root = Path(root).resolve()
    core_pkgs = root / "core" / "packages"
    if core_pkgs.is_dir():
        return core_pkgs
    legacy = root / LEGACY_CONTAINER
    if legacy.is_dir():
        return legacy
    return root


def projection_targets(root: Path) -> list[dict]:
    """Return ordered list of projection targets declared in workspace.json.

    Each entry has keys: `id`, `prefix`, `repo`, `branch`.
    """
    ws = load_workspace(root)
    targets: list[dict] = []
    seen: set[str] = set()
    projections = ws.get("projections")
    if isinstance(projections, dict):
        for proj_id, meta in sorted(projections.items()):
            if not isinstance(meta, dict):
                continue
            prefix = meta.get("prefix")
            repo = meta.get("repo")
            if prefix and repo:
                targets.append({
                    "id": proj_id,
                    "prefix": str(prefix).strip("/"),
                    "repo": str(repo),
                    "branch": str(meta.get("branch") or "main"),
                })
                seen.add(proj_id)
    packages = ws.get("packages")
    if isinstance(packages, dict):
        for name, meta in sorted(packages.items()):
            if not isinstance(meta, dict):
                continue
            if meta.get("projection") in seen:
                continue
            repo = meta.get("repo")
            path = meta.get("path")
            if repo and path:
                targets.append({
                    "id": name,
                    "prefix": str(path).strip("/"),
                    "repo": str(repo),
                    "branch": str(meta.get("branch") or "main"),
                })
                seen.add(name)
    return targets


def affected_projections(root: Path, changed_paths: list[str]) -> list[dict]:
    """Return projection targets touched by any POSIX path in CHANGED_PATHS."""
    normalized = [PurePosixPath(p.strip()).as_posix().lstrip("./")
                  for p in changed_paths if p and p.strip()]
    matched: list[dict] = []
    for target in projection_targets(root):
        prefix = target["prefix"].rstrip("/") + "/"
        if any(p == target["prefix"] or p.startswith(prefix) for p in normalized):
            matched.append(target)
    return matched


def all_package_relpaths(root: Path) -> list[str]:
    """Return sorted POSIX relative paths of all packages under ROOT."""
    root = Path(root).resolve()
    return [p.resolve().relative_to(root).as_posix() for p in package_dirs(root).values()]


def main() -> int:
    import argparse
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="cmd", required=True)
    sub.add_parser("list-paths", help="print POSIX relative paths of all packages")
    p_path = sub.add_parser("path", help="print POSIX relative path of one package")
    p_path.add_argument("name")
    p_proj = sub.add_parser("projections", help="print JSON list of projection targets")
    p_proj.add_argument("--changed", nargs="*", default=None,
                        help="filter to projections affected by these repo-relative paths")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    if args.cmd == "list-paths":
        for rel in all_package_relpaths(root):
            print(rel)
        return 0
    if args.cmd == "path":
        rel = package_relpath(root, args.name)
        if not rel:
            raise SystemExit(f"workspace_layout: unknown package {args.name}")
        print(rel)
        return 0
    if args.cmd == "projections":
        items = (projection_targets(root) if args.changed is None
                 else affected_projections(root, args.changed))
        print(json.dumps(items, indent=2))
        return 0
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
