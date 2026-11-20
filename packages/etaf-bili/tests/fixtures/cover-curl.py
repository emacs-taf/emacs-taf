#!/usr/bin/env python3
"""Offline curl protocol fixture for the public cover-download operation."""
import pathlib
import sys

arguments = sys.argv[1:]
url = arguments[-1]
if "fail" in url:
    print("fixture transfer failed", file=sys.stderr)
    raise SystemExit(22)
output = pathlib.Path(arguments[arguments.index("--output") + 1])
output.write_text('<svg xmlns="http://www.w3.org/2000/svg" width="160" height="90">'
                  '<rect width="160" height="90" fill="#556688"/>'
                  '<circle cx="80" cy="45" r="30" fill="#eeeeee"/></svg>')
