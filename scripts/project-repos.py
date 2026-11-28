#!/usr/bin/env python3
"""Project layered monorepo directories to read-only GitHub repositories.

Reads projection declarations from `workspace.json` (via `scripts/workspace_layout.py`):
  - `core/`          -> `emacs-taf/etaf` (unified 15-package core framework repo)
  - `apps/<app>/`    -> `emacs-taf/<app>` (standalone application projections)
  - `games/<game>/`  -> `emacs-taf/<game>` (standalone game projections)

Uses `splitsh-lite` when available on PATH (fast in CI) and falls back to
standard `git subtree split` locally. Requires only standard Git — no `jjosh`.
"""
from __future__ import annotations

import argparse
import os
from pathlib import Path
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(Path(__file__).resolve().parent))
import workspace_layout


def git_changed_files(root: Path, base_ref: str, head_ref: str = "HEAD") -> list[str]:
    """Return repo-relative POSIX paths changed between BASE_REF and HEAD_REF."""
    if not base_ref or set(base_ref) == {"0"}:
        # Initial push or unknown base: treat every projection as affected.
        return [t["prefix"] for t in workspace_layout.projection_targets(root)]
    out = subprocess.check_output(
        ["git", "-C", str(root), "diff", "--name-only", base_ref, head_ref],
        text=True,
    )
    return [line.strip() for line in out.splitlines() if line.strip()]


def select_targets(root: Path, *, targets: list[str] | None = None,
                   changed_since: str | None = None, head_ref: str = "HEAD") -> list[dict]:
    """Select projection targets by explicit ID list, git diff range, or all."""
    all_targets = workspace_layout.projection_targets(root)
    by_id = {t["id"]: t for t in all_targets}
    if targets:
        unknown = [tid for tid in targets if tid not in by_id]
        if unknown:
            raise ValueError(f"Unknown projection target(s): {', '.join(unknown)}")
        return [by_id[tid] for tid in targets]
    if changed_since is not None:
        changed = git_changed_files(root, changed_since, head_ref)
        return workspace_layout.affected_projections(root, changed)
    return all_targets


def split_prefix(root: Path, prefix: str, *, rev: str = "HEAD",
                 engine: str = "auto") -> str:
    """Split PREFIX at REV into a standalone commit SHA and return it."""
    use_splitsh = (engine == "splitsh") or (engine == "auto" and shutil.which("splitsh-lite"))
    if use_splitsh:
        if rev != "HEAD":
            sha = subprocess.check_output(
                ["splitsh-lite", f"--prefix={prefix}", f"--origin={rev}"],
                cwd=root, text=True,
            ).strip()
        else:
            sha = subprocess.check_output(
                ["splitsh-lite", f"--prefix={prefix}"],
                cwd=root, text=True,
            ).strip()
        if not sha:
            raise RuntimeError(f"splitsh-lite produced empty SHA for {prefix}")
        return sha
    sha = subprocess.check_output(
        ["git", "-C", str(root), "subtree", "split", f"--prefix={prefix}", rev],
        text=True,
    ).strip().splitlines()[-1]
    if not sha:
        raise RuntimeError(f"git subtree split produced empty SHA for {prefix}")
    return sha


def remote_url(repo: str, token: str | None = None) -> str:
    """Return HTTPS remote URL for OWNER/REPO (embedding token if supplied)."""
    if token:
        return f"https://x-access-token:{token}@github.com/{repo}.git"
    return f"https://github.com/{repo}.git"


def push_commit(root: Path, sha: str, repo: str, branch: str, *,
                token: str | None = None, force: bool = True,
                env: dict[str, str] | None = None) -> None:
    """Push projected commit SHA to REPO's BRANCH."""
    url = remote_url(repo, token)
    cmd = ["git", "-C", str(root), "-c", "http.https://github.com.proxy=", "push"]
    if force:
        cmd.append("--force")
    cmd += [url, f"{sha}:refs/heads/{branch}"]
    proc = subprocess.run(cmd, capture_output=True, text=True, env=env, timeout=300)
    if proc.returncode != 0:
        detail = (proc.stderr or proc.stdout or "").strip()
        if token:
            detail = detail.replace(token, "***")
        raise RuntimeError(f"git push to {repo} ({branch}) failed: {detail[-300:]}")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=ROOT)
    parser.add_argument("--target", action="append", default=[],
                        help="project only this target id (repeatable, e.g. etaf, etaf-md)")
    parser.add_argument("--changed-since", default=None,
                        help="project only targets touched between this Git ref and --rev")
    parser.add_argument("--rev", default="HEAD",
                        help="monorepo Git revision to project (default: HEAD)")
    parser.add_argument("--engine", choices=("auto", "splitsh", "subtree"), default="auto")
    parser.add_argument("--no-force", action="store_true",
                        help="do not pass --force when pushing projected branches")
    parser.add_argument("--dry-run", action="store_true",
                        help="print targets without splitting or pushing")
    args = parser.parse_args(argv)

    root = args.root.resolve()
    selected = select_targets(
        root,
        targets=args.target or None,
        changed_since=args.changed_since,
        head_ref=args.rev,
    )
    if not selected:
        print("No projection targets affected.")
        return 0

    for item in selected:
        verb = "would project" if args.dry_run else "project"
        print(f"{verb} {item['id']}: {item['prefix']}/ -> {item['repo']} ({item['branch']})")
    if args.dry_run:
        return 0

    token = os.environ.get("PROJECTION_TOKEN") or os.environ.get("GH_TOKEN") or None
    env = dict(os.environ)
    if not token:
        askpass = root / "scripts" / "askpass.sh"
        if askpass.is_file():
            env.setdefault("GIT_ASKPASS", str(askpass))

    failures: list[tuple[str, str]] = []
    for item in selected:
        try:
            sha = split_prefix(root, item["prefix"], rev=args.rev, engine=args.engine)
            push_commit(
                root, sha, item["repo"], item["branch"],
                token=token, force=not args.no_force, env=env,
            )
            print(f"ok {item['id']} ({sha[:12]}) -> {item['repo']}", flush=True)
        except Exception as exc:
            failures.append((item["id"], str(exc)))
            print(f"FAIL {item['id']}: {exc}", file=sys.stderr, flush=True)

    print(f"\nprojected {len(selected) - len(failures)} of {len(selected)} target(s); "
          f"{len(failures)} failure(s)")
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
