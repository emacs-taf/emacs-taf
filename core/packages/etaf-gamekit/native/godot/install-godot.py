#!/usr/bin/env python3
"""Install the pinned headless Godot runtime in a user cache, without changing PATH."""
from __future__ import annotations
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import stat
import subprocess
import sys
import tempfile
import urllib.request
import zipfile

SOURCES = json.loads((Path(__file__).resolve().parent / 'engine-sources.json').read_text())


def version(program):
    result = subprocess.run([str(program), '--headless', '--version'], check=True,
                            capture_output=True, text=True, timeout=15)
    found = re.match(r'(\d+)\.(\d+)\.(\d+)', result.stdout)
    if not found or tuple(map(int, found.groups())) < (4, 7, 0):
        raise ValueError('Godot 4.7 or newer is required')
    return result.stdout.strip()


def download(source, destination):
    """Download SOURCE to DESTINATION and accept it only when its bytes match."""
    pending = destination.with_suffix('.partial')
    with urllib.request.urlopen(source['url'], timeout=60) as response, pending.open('wb') as out:
        announced = response.headers.get('Content-Length')
        written = 0
        while chunk := response.read(1 << 20):
            out.write(chunk)
            written += len(chunk)
    if announced is not None and written != int(announced):
        pending.unlink()
        raise ValueError(f'Incomplete download: {written} of {announced} bytes; retry')
    if hashlib.sha256(pending.read_bytes()).hexdigest() != source['sha256']:
        pending.unlink()
        raise ValueError('Checksum mismatch: the release download did not match the pinned SHA-256')
    pending.replace(destination)


def install(cache):
    machine = platform.machine().lower()
    key = ('macos-universal' if sys.platform == 'darwin' else
           f'linux-{"arm64" if machine in ("arm64", "aarch64") else machine}')
    if sys.platform not in ('darwin', 'linux') or key not in SOURCES['platforms']:
        raise ValueError('No pinned build for this platform; pass --godot /path/to/godot')
    source = SOURCES['platforms'][key]
    target = cache / f'godot-{SOURCES["version"]}-{key}'
    marker = target / '.archive-sha256'
    if marker.is_file() and marker.read_text().strip() == source['sha256']:
        return target / source['executable']
    if target.exists():
        raise ValueError(f'Incomplete installation exists: {target}; move it aside and retry')
    archive = cache / source['url'].rsplit('/', 1)[-1]
    # A leftover archive from an interrupted or intercepted download can never
    # pass verification, and keeping it made every retry fail the same way.
    if archive.exists() and hashlib.sha256(archive.read_bytes()).hexdigest() != source['sha256']:
        archive.unlink()
    if not archive.exists():
        download(source, archive)
    with tempfile.TemporaryDirectory(dir=cache) as temporary:
        stage = Path(temporary) / 'runtime'
        stage.mkdir()
        with zipfile.ZipFile(archive) as bundle:
            for member in bundle.infolist():
                destination = (stage / member.filename).resolve()
                mode = member.external_attr >> 16
                if not destination.is_relative_to(stage.resolve()) or stat.S_ISLNK(mode):
                    raise ValueError(f'Unsafe archive member: {member.filename}')
                bundle.extract(member, stage)
                if destination.is_file() and mode:
                    destination.chmod(stat.S_IMODE(mode))
        executable = stage / source['executable']
        executable.chmod(executable.stat().st_mode | 0o111)
        version(executable)
        (stage / '.archive-sha256').write_text(source['sha256'] + '\n')
        stage.rename(target)
    return target / source['executable']


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--cache', type=Path,
                        default=Path(os.environ.get('XDG_CACHE_HOME', Path.home() / '.cache')) / 'emacs-taf/game-engines')
    parser.add_argument('--godot', type=Path, help='Use an existing Godot 4.7+ executable.')
    parser.add_argument('--check', action='store_true', help='Check the cached command without changing files.')
    parser.add_argument('--manifest', action='store_true', help='Print pinned releases and checksums.')
    args = parser.parse_args()
    if args.manifest:
        print(json.dumps(SOURCES, indent=2))
        return 0
    cache = args.cache.expanduser().resolve()
    command = cache / 'bin/godot'
    if not args.check:
        cache.mkdir(parents=True, exist_ok=True)
        executable = args.godot.expanduser().resolve() if args.godot else install(cache)
        version(executable)
        command.parent.mkdir(exist_ok=True)
        if command.is_symlink():
            command.unlink()
        elif command.exists():
            raise ValueError(f'Refusing to replace a non-symlink executable: {command}')
        command.symlink_to(executable)
    print(json.dumps({'godot': str(command), 'version': version(command)}, indent=2))
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (OSError, ValueError, subprocess.SubprocessError, zipfile.BadZipFile) as failure:
        print(f'Engine setup failed: {failure}', file=sys.stderr)
        sys.exit(1)
