#!/usr/bin/env python3
"""Install the pinned OpenSpiel environment in a user cache, without changing PATH."""
from __future__ import annotations
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

HERE = Path(__file__).resolve().parent
REQUIREMENTS = HERE / 'requirements.txt'
PINNED = 'open-spiel'
MINIMUM = (3, 11)


def pinned_version():
    """Return the requirement line that pins PINNED to one version."""
    lines = [line.strip() for line in REQUIREMENTS.read_text().splitlines() if line.strip()]
    matches = [line for line in lines if line.replace('_', '-').lower().startswith(PINNED + '==')]
    if len(matches) != 1:
        raise ValueError(f'{REQUIREMENTS} must pin {PINNED} exactly once')
    return matches[0].split('==', 1)[1]


def supported(program):
    """Return PROGRAM's version when it can host the environment, else nil."""
    try:
        result = subprocess.run([str(program), '-c', 'import sys; print(".".join(map(str, sys.version_info[:3])))'],
                                check=True, capture_output=True, text=True, timeout=30)
    except (OSError, subprocess.SubprocessError):
        return None
    found = tuple(int(part) for part in result.stdout.strip().split('.'))
    return result.stdout.strip() if found >= MINIMUM else None


def interpreter(explicit=None):
    """Return a Python at least MINIMUM carries, preferring the newest known one."""
    candidates = [explicit] if explicit else ['python3.14', 'python3.13', 'python3.12', 'python3.11', 'python3']
    rejected = []
    for candidate in candidates:
        program = shutil.which(str(candidate)) if not Path(str(candidate)).is_file() else str(candidate)
        if not program:
            continue
        version = supported(program)
        if version:
            return program, version
        rejected.append(str(candidate))
    raise ValueError('Python 3.11 or newer is required; pass --python /path/to/python3.11'
                     + (f' (rejected: {", ".join(rejected)})' if rejected else ''))


def environment(cache):
    """Return the cache environment directory."""
    return cache / 'openspiel'


def version(program):
    """Return the installed OpenSpiel version, or raise when PROGRAM cannot import it."""
    result = subprocess.run([str(program), '-c',
                             'import importlib.metadata as m, pyspiel; print(m.version("open-spiel"))'],
                            check=True, capture_output=True, text=True, timeout=120)
    return result.stdout.strip()


def install(cache, explicit_python):
    """Build a verified environment at CACHE and return its interpreter."""
    python, python_version = interpreter(explicit_python)
    pinned = pinned_version()
    target = environment(cache)
    try:
        if (target / 'bin/python').is_file() and version(target / 'bin/python') == pinned:
            return target / 'bin/python'
    except (OSError, subprocess.SubprocessError):
        print('Replacing a cache environment that failed verification')
    staging = cache / f'openspiel.new-{os.getpid()}'
    shutil.rmtree(staging, ignore_errors=True)
    try:
        subprocess.run([python, '-m', 'venv', str(staging)], check=True, timeout=300)
        subprocess.run([str(staging / 'bin/python'), '-m', 'pip', 'install', '--no-cache-dir',
                        '--disable-pip-version-check', '--no-input', '-r', str(REQUIREMENTS)],
                       check=True, timeout=1800)
        found = version(staging / 'bin/python')
        if found != pinned:
            raise ValueError(f'Installed OpenSpiel {found}, but {REQUIREMENTS} pins {pinned}')
        if target.exists():
            shutil.rmtree(target)
        staging.rename(target)
    except BaseException:
        shutil.rmtree(staging, ignore_errors=True)
        raise
    print(f'Installed OpenSpiel {pinned} with Python {python_version}')
    return target / 'bin/python'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--cache', type=Path,
                        default=Path(os.environ.get('XDG_CACHE_HOME', Path.home() / '.cache')) / 'emacs-taf/game-engines')
    parser.add_argument('--python', type=Path, help=f'Python {".".join(map(str, MINIMUM))}+ used for the environment.')
    parser.add_argument('--check', action='store_true', help='Check the cached environment without changing files.')
    args = parser.parse_args()
    cache = args.cache.expanduser().resolve()
    if not args.check:
        cache.mkdir(parents=True, exist_ok=True)
        install(cache, args.python)
    program = environment(cache) / 'bin/python'
    if not program.is_file():
        raise ValueError(f'Missing environment {program}; install it with M-x etaf-gamekit-install-openspiel')
    found = version(program)
    print(json.dumps({'python': str(program), 'open-spiel': found}, indent=2))
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (OSError, ValueError, subprocess.SubprocessError) as failure:
        print(f'Engine setup failed: {failure}', file=sys.stderr)
        sys.exit(1)
