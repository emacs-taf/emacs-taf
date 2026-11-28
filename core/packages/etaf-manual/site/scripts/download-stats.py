#!/usr/bin/env python3
"""Refresh the archive download counts from Caddy's JSON access log.

The archive pages read `downloads.json` in the browser; this timer rewrites it
from the log so the counts stay current between package releases.

A count means "somebody installed this package here", not "somebody fetched a
file":

- A tarball counts only when the same client fetched its `.tar.sig` within a
  minute, which is what package.el does and what a crawler, a link checker or a
  hand-run `curl` does not.
- One client counts once per package per UTC day, so re-installing or re-running
  a test suite from the same machine does not inflate the number.
- Deployment verification appends `?deployment=<stamp>` to every archived file:
  those requests check bytes, they are not somebody installing a package, so
  they are excluded.

Rotated logs stay readable, so counts survive log rotation for as long as the
files are kept.
"""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import gzip
import json
import os
from pathlib import Path
import re
import sys

ARCHIVE = re.compile(r"/packages/([a-z][a-z0-9-]*)-[0-9]+(?:\.[0-9]+)*\.tar\Z")
SIGNATURE = re.compile(r"/packages/([a-z][a-z0-9-]*)-[0-9]+(?:\.[0-9]+)*\.tar\.sig\Z")
HOST = "etaf.top"
# package.el fetches a tarball and its signature together; the two requests may
# arrive in either order, and a retry repeats both.
PAIRING_SECONDS = 60


def lines(path):
    opener = gzip.open if path.suffix == ".gz" else open
    with opener(path, "rt", encoding="utf-8", errors="replace") as stream:
        yield from stream


def fetches(log_dir):
    """Yield (timestamp, client, package, is_signature) for each archived fetch."""
    for path in sorted(log_dir.glob(f"{HOST}.access*.log*")):
        if not path.is_file() or path.is_symlink():
            continue
        for line in lines(path):
            try:
                record = json.loads(line)
            except ValueError:
                continue
            request = record.get("request") or {}
            uri = request.get("uri") or ""
            stamp = record.get("ts")
            if (request.get("method") != "GET"
                    or request.get("host") != HOST or "deployment=" in uri
                    or not isinstance(stamp, (int, float))):
                continue
            archive = ARCHIVE.fullmatch(uri)
            signature = SIGNATURE.fullmatch(uri)
            if not archive and not signature:
                continue
            # package.el asks for a signature beside every tarball; this archive
            # signs nothing, so that request is a 404 and still proves the fetch
            # is a package installation rather than a crawler.
            if archive and record.get("status") != 200:
                continue
            found = archive or signature
            yield stamp, request.get("remote_ip") or "", found[1], bool(signature)


def count(log_dir):
    """Return per-package installs and the timestamp of the oldest counted install."""
    signatures, tarballs = {}, []
    for stamp, client, package, signature in fetches(log_dir):
        if signature:
            signatures.setdefault((client, package), []).append(stamp)
        else:
            tarballs.append((stamp, client, package))
    installs, first, counted = {}, None, set()
    for stamp, client, package in tarballs:
        if not any(abs(value - stamp) <= PAIRING_SECONDS
                   for value in signatures.get((client, package), ())):
            continue
        day = datetime.fromtimestamp(stamp, timezone.utc).date()
        if (package, client, day) in counted:
            continue
        counted.add((package, client, day))
        installs[package] = installs.get(package, 0) + 1
        first = stamp if first is None else min(first, stamp)
    return installs, first


def moment(value):
    return datetime.fromtimestamp(value, timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--log-dir", type=Path, default=Path("/var/log/caddy"))
    parser.add_argument("--output", type=Path,
                        default=Path("/srv/etaf.top/stats/packages/downloads.json"))
    args = parser.parse_args()
    counts, first = count(args.log_dir)
    payload = {
        "schema": 1,
        "as_of": moment(datetime.now(timezone.utc).timestamp()),
        "since": moment(first) if first is not None else None,
        "total": sum(counts.values()),
        "packages": dict(sorted(counts.items())),
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    temporary = args.output.with_name(args.output.name + ".tmp")
    temporary.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    os.replace(temporary, args.output)


if __name__ == "__main__":
    sys.exit(main())
