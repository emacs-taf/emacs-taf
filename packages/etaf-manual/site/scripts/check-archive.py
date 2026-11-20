#!/usr/bin/env python3
"""Check the served archive pages against the manifest they are generated from.

A page belongs to a deterministic process, so it is checked by a command rather
than by reading it: every package must appear exactly once, in the section its
role or its community record states, and every date must be the one the manifest
publishes. The expected grouping comes from the generator itself, so the check
cannot drift from the code that writes the pages.

Exit status is 0 only when the served pages match; mismatches print one line
each and the command fails.
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path
from urllib.error import URLError
from urllib.request import urlopen

sys.path.insert(0, str(Path(__file__).resolve().parent))
import archive_pages

SECTION = re.compile(r'<section class="group" id="([a-z-]+)">')
PACKAGE = re.compile(r'<a href="([a-z][a-z0-9-]*)/"><strong>')
DATE = re.compile(r'<td class="updated"><time datetime="([^"]+)"')


def fetch(url, timeout=20):
    with urlopen(url, timeout=timeout) as response:
        return response.read().decode("utf-8", "replace")


def served_sections(page):
    """Return the packages each served section lists, in page order."""
    marks = [(match.start(), match[1]) for match in SECTION.finditer(page)]
    sections = {}
    for index, (start, name) in enumerate(marks):
        end = marks[index + 1][0] if index + 1 < len(marks) else len(page)
        sections[name] = PACKAGE.findall(page[start:end])
    return sections


ROW = re.compile(r"<tr data-search=.*?</tr>", re.S)


def served_dates(page):
    """Return the update timestamp each row renders, keyed by package name."""
    dates = {}
    for block in ROW.findall(page):
        name, date = PACKAGE.search(block), DATE.search(block)
        if name:
            dates[name[1]] = date[1] if date else None
    return dates


def expected(package_dir_manifest):
    packages = sorted(package_dir_manifest["packages"], key=lambda item: item["name"])
    community = package_dir_manifest.get("community", {})
    sections = {}
    for label, items in archive_pages.groups(packages, community):
        sections[label.lower()] = [item["name"] for item in items]
    return packages, sections


def check(base, quiet=False):
    manifest = json.loads(fetch(base.rstrip("/") + "/manifest.json"))
    packages, wanted = expected(manifest)
    page = fetch(base.rstrip("/") + "/")
    served = served_sections(page)
    problems = []
    for section in sorted(set(wanted) | set(served)):
        if wanted.get(section) != served.get(section):
            problems.append(f"{section}: served {served.get(section)} expected {wanted.get(section)}")
    named = [name for names in served.values() for name in names]
    duplicates = {name for name in named if named.count(name) > 1}
    if duplicates:
        problems.append(f"listed twice: {sorted(duplicates)}")
    missing = {item["name"] for item in packages} - set(named)
    if missing:
        problems.append(f"missing from the page: {sorted(missing)}")
    dates = served_dates(page)
    for item in packages:
        recorded = manifest.get("updated", {}).get(item["name"])
        shown = dates.get(item["name"])
        if recorded and shown != recorded:
            problems.append(f"{item['name']}: date {shown} published as {recorded}")
    counts = " ".join(f"{name}={len(names)}" for name, names in served.items())
    print(f"archive={base}\n{counts}\npackages={len(packages)}")
    for problem in problems:
        print(problem)
    print("ok=yes" if not problems else "ok=no")
    return not problems


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--archive", default="https://etaf.top/packages/")
    arguments = parser.parse_args()
    try:
        return 0 if check(arguments.archive) else 1
    except (URLError, OSError, ValueError, KeyError) as error:
        print(f"error=check\nhint={error}")
        return 1


if __name__ == "__main__":
    sys.exit(main())
