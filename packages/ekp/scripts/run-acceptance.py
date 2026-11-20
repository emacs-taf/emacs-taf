#!/usr/bin/env python3
"""Run named public scenarios; reject missing or empty acceptance inventories.

Failure reports stay bounded: ERT's pretty-printer is replaced with a plain print
that respects print-level/print-length and a hard byte cap, and runs of one
checkout are serialized through an advisory lock.
"""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time


def prelude(level, length, cap):
    """Elisp that bounds ERT batch failure reports and never pretty-prints them."""
    return ' '.join([
        "(progn (require 'ert)",
        f"(setq load-prefer-newer t native-comp-jit-compilation nil ert-batch-print-level {level} ert-batch-print-length {length})",
        "(when (fboundp 'ert--pp-with-indentation-and-newline)",
        "(advice-add 'ert--pp-with-indentation-and-newline :around",
        "(lambda (orig object &rest ignored)",
        "(let* ((print-escape-newlines t) (print-circle t)",
        f"(print-level {level}) (print-length {length})",
        "(text (condition-case err (prin1-to-string object) (error (format \"#<condition error: %S>\" err)))))",
        f"(if (> (length text) {cap})",
        f"(insert (substring text 0 {cap}) (format \"\\n  ... [condition truncated: %d bytes total]\" (length text)))",
        "(insert text))",
        "(insert \"\\n\"))))))",
    ])


def acquire_lock(root, wait):
    """Take the per-checkout acceptance lock; report the holder and exit 75 when busy."""
    digest = hashlib.sha1(str(root).encode()).hexdigest()[:16]
    lockfile = Path(tempfile.gettempdir()) / f'etaf-acceptance-{digest}.lock'
    handle = os.fdopen(os.open(lockfile, os.O_RDWR | os.O_CREAT, 0o600), 'r+')
    deadline = time.monotonic() + wait
    waiting = False
    while True:
        try:
            fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
            break
        except BlockingIOError:
            handle.seek(0)
            holder = handle.read(200).strip() or 'holder unknown'
            if time.monotonic() >= deadline:
                print(f'acceptance already running for {root} ({holder}); rerun with --wait SECONDS to queue', file=sys.stderr)
                sys.exit(75)
            if not waiting:
                print(f'acceptance busy ({holder}); waiting up to {wait}s', file=sys.stderr)
                waiting = True
            time.sleep(0.5)
    handle.seek(0)
    handle.truncate()
    handle.write(f'pid={os.getpid()} started={time.strftime("%Y-%m-%d %H:%M:%S")}\n')
    handle.flush()
    return handle


def command(root, emacs, level, length, cap):
    manifest = json.loads((root / 'tests/acceptance.json').read_text())
    cases = manifest.get('cases', [])
    if not cases or len({c['name'] for c in cases}) != len(cases):
        raise ValueError('Acceptance cases must be nonempty and uniquely named')
    files = list(dict.fromkeys(manifest.get('support', []) + [c['file'] for c in cases]))
    for file in files:
        if not (root / file).is_file():raise ValueError(f'Missing acceptance source: {file}')
    names = []
    for case in cases:
        name = case['name']
        if not __import__('re').fullmatch(r'[a-zA-Z][a-zA-Z0-9-]+',name) or not case.get('purpose'):
            raise ValueError('Each case needs an ERT name and observable acceptance purpose')
        names.append(name)
    args = [emacs, '-Q', '--batch']
    for path in manifest.get('load_path', ['.']):args += ['-L', str(root / path)]
    args += ['--eval', prelude(level, length, cap)]
    entries = list(root.glob('*.el'))
    if len(entries) != 1:raise ValueError('Expected one package entry at the repository root')
    args += ['-l', str(entries[0])]
    for file in files:args += ['-l', str(root / file)]
    # ert-get-test fails if any named scenario disappears; no regex can pass with zero cases.
    symbols = ' '.join(names)
    args += ['--eval', f"(progn (mapc #'ert-get-test '({symbols})) (ert-run-tests-batch-and-exit '(member {symbols})))"]
    return args


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--emacs', default='emacs')
    parser.add_argument('--root', type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument('--print-level', type=int, default=3, help='ERT failure print depth (default: %(default)s)')
    parser.add_argument('--print-length', type=int, default=6, help='ERT failure print width (default: %(default)s)')
    parser.add_argument('--max-condition-bytes', type=int, default=8192, help='hard cap for one printed condition (default: %(default)s)')
    parser.add_argument('--wait', type=int, default=0, help='seconds to wait for a run of the same checkout before refusing (exit 75)')
    args=parser.parse_args()
    if min(args.print_level, args.print_length, args.max_condition_bytes) < 1 or args.wait < 0:
        parser.error('print level, print length and byte cap must be positive; --wait must not be negative')
    root = args.root.resolve()
    hold = acquire_lock(root, args.wait)
    try:
        return subprocess.call(command(root, args.emacs, args.print_level, args.print_length, args.max_condition_bytes), cwd=root)
    finally:
        hold.close()


if __name__ == '__main__':sys.exit(main())
