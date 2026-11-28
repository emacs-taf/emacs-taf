#!/usr/bin/env python3
"""Align a package's Commentary function signatures with its definitions.

Every `defun` and `cl-defun` in packages/<package>/*.el and
packages/<package>/lisp/*.el supplies the argument list that the root entry's
`;; Function: NAME (ARGS)` record must state.  A Commentary record occupies one
line while a definition may wrap its arguments, so the two are compared and
written as one line: every whitespace run outside a string literal becomes a
single space.

Name the packages to align, or name none to align every package under packages/.
An aligned package reports `0 signature(s) aligned` and its file is not written.
"""
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import workspace_layout

ROOT = Path(__file__).resolve().parents[1]


def balanced(text, start):
    """Return the text of the form starting at START, up to its closing paren."""
    depth = 0
    for index in range(start, len(text)):
        char = text[index]
        if char == '(':
            depth += 1
        elif char == ')':
            depth -= 1
            if depth == 0:
                return text[start:index + 1]
    return None


def one_line(text):
    """Collapse whitespace outside string literals so the arguments fit a line."""
    parts = []
    in_string = False
    escaped = False
    pending_space = False
    for char in text:
        if in_string:
            parts.append(char)
            if escaped:
                escaped = False
            elif char == '\\':
                escaped = True
            elif char == '"':
                in_string = False
        elif char.isspace():
            pending_space = True
        else:
            if pending_space and parts:
                parts.append(' ')
            pending_space = False
            parts.append(char)
            if char == '"':
                in_string = True
    return ''.join(parts)


DEFUN = re.compile(r'^\((?:cl-)?defun\s+([^\s()]+)\s+', re.M)


def definitions(root, package):
    """Map every defun name to its one-line argument list, as defined in source."""
    found = {}
    home = workspace_layout.package_path(Path(root), package)
    for path in sorted(list(home.glob('*.el')) + list((home / 'lisp').glob('*.el'))):
        text = path.read_text(encoding='utf-8', errors='replace')
        for match in DEFUN.finditer(text):
            name = match.group(1)
            start = match.end()
            if start >= len(text) or text[start] != '(':
                continue
            args = balanced(text, start)
            if args is not None:
                found.setdefault(name, one_line(args))
    return found


DECLARED = re.compile(r'^;; Function: ([^\s()]+)( \(.*\))?$', re.M)


def align(root, package):
    """Rewrite PACKAGE's Commentary signatures to its definitions."""
    entry = workspace_layout.package_path(Path(root), package) / f'{package}.el'
    with entry.open(encoding='utf-8', newline='') as handle:
        text = handle.read()
    signatures = definitions(root, package)
    changed = 0

    def replace(match):
        nonlocal changed
        name = match.group(1)
        actual = signatures.get(name)
        if actual is None:
            return match.group(0)
        current = (match.group(2) or '').strip()
        if current == actual:
            return match.group(0)
        changed += 1
        print(f'  {name}: {current or "(none)"} -> {actual}')
        return f';; Function: {name} {actual}'

    updated = DECLARED.sub(replace, text)
    if changed:
        # newline='' keeps the file's own line endings.
        with entry.open('w', encoding='utf-8', newline='') as handle:
            handle.write(updated)
    print(f'{package}: {changed} signature(s) aligned')


def main(argv):
    dirs = workspace_layout.package_dirs(ROOT)
    names = argv or sorted(name for name, path in dirs.items()
                           if (path / f'{name}.el').is_file())
    for name in names:
        if not (workspace_layout.package_path(ROOT, name) / f'{name}.el').is_file():
            sys.exit(f'align-signatures: unknown package {name}')
        align(ROOT, name)


if __name__ == '__main__':
    main(sys.argv[1:])
