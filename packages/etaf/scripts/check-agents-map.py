#!/usr/bin/env python3
"""Keep the AGENTS.md module map in step with lisp/.

AGENTS.md names modules by responsibility. A renamed module, a new module that
never reached the map, or a stale name left behind by a merge all make the map
lie to the next reader, so check both directions.
"""
from __future__ import annotations
import re
import sys
from pathlib import Path

BARE = re.compile(r'`(etaf-[a-z0-9-]+)`')
PATCHED = re.compile(r'`lisp/(etaf-[a-z0-9-]+)\.el`')


def main() -> int:
    root = Path(__file__).resolve().parents[1]
    map_file = root / 'AGENTS.md'
    if not map_file.is_file():
        return 0
    text = map_file.read_text(encoding='utf-8')
    named = set(BARE.findall(text)) | set(PATCHED.findall(text))
    on_disk = {path.stem for path in (root / 'lisp').glob('*.el')}
    errors = [f'AGENTS.md: names {name}, but lisp/{name}.el does not exist'
              for name in sorted(named - on_disk)]
    errors += [f'lisp/{name}.el: missing from the AGENTS.md module map'
               for name in sorted(on_disk - named)]
    if errors:
        print('\n'.join(errors), file=sys.stderr)
        return 1
    print(f'AGENTS.md module map matches {len(on_disk)} lisp modules')
    return 0


if __name__ == '__main__':
    sys.exit(main())
