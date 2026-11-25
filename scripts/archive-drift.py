#!/usr/bin/env python3
"""Report which packages a release must version-bump before it can publish.

The archive never replaces a file it already serves, so a package whose source
moved under an unchanged version cannot ship: the deployment stops with
"Immutable package differs". That verdict arrives after the whole archive was
built and uploaded, which is the most expensive possible moment to learn it.

Both manifests carry a digest per package, so the comparison needs one request
and no tarball downloads.
"""
import argparse
import json
import sys
from pathlib import Path
from urllib.request import ProxyHandler, build_opener

DEFAULT_URL = "https://etaf.top/packages/manifest.json"


def served_digests(url=DEFAULT_URL, timeout=30):
    """Return {file: sha256} for the archive URL currently serves, or {}."""
    try:
        opener = build_opener(ProxyHandler({}))
        with opener.open(url, timeout=timeout) as response:
            manifest = json.loads(response.read())
    except Exception:
        return {}
    return {item["file"]: item["sha256"] for item in manifest.get("packages", ())}


def drift(local, remote):
    """Classify LOCAL packages against the digests REMOTE serves.

    A package is `new` when no file of that name is served, `same` when the
    served bytes are the ones about to be published, and `drift` when the name
    exists with different bytes, which only a version bump can resolve.
    """
    rows = []
    for item in local.get("packages", ()):
        name, version, filename = item["name"], item["version"], item["file"]
        if filename not in remote:
            rows.append((name, version, "new", filename))
        elif remote[filename] == item["sha256"]:
            rows.append((name, version, "same", filename))
        else:
            rows.append((name, version, "drift", filename))
    return rows


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--directory", type=Path, required=True,
                        help="built or staged archive holding manifest.json")
    parser.add_argument("--url", default=DEFAULT_URL,
                        help="manifest the live archive serves")
    args = parser.parse_args()

    manifest_path = args.directory / "manifest.json"
    if not manifest_path.is_file():
        print(f"error=drift\nhint=no manifest.json in {args.directory}", file=sys.stderr)
        return 2
    local = json.loads(manifest_path.read_text(encoding="utf-8"))
    remote = served_digests(args.url)
    if not remote:
        print(f"error=drift\nhint=cannot read {args.url}", file=sys.stderr)
        return 2

    rows = drift(local, remote)
    drifting = [row for row in rows if row[2] == "drift"]
    fresh = [row for row in rows if row[2] == "new"]
    for name, version, status, filename in sorted(rows, key=lambda row: (row[2], row[0])):
        print(f"{status:6} {name:22} {version:10} {filename}")
    print()
    print(f"{len(rows)} package(s): {len(drifting)} need a version bump, {len(fresh)} unpublished")
    for name, version, _status, _filename in drifting:
        print(f"  bump {name} past {version}")
    return 1 if drifting else 0


if __name__ == "__main__":
    sys.exit(main())
