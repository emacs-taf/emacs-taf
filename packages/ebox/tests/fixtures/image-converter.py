#!/usr/bin/env python3
"""Deterministic chafa/ffmpeg stand-in; never opens an image or a terminal."""
import os
from pathlib import Path
import re
import sys

program = Path(sys.argv[0]).name
args = sys.argv[1:]
with open(os.environ['EBOX_IMAGE_FIXTURE_LOG'], 'a') as log:
    log.write(program + '\n')
if os.environ.get('EBOX_IMAGE_FIXTURE_FAIL') in (program, 'both'):
    sys.exit(1)
if os.environ.get('EBOX_IMAGE_FIXTURE_BAD') == program:
    print('not an image grid')
    sys.exit(0)

source = args[args.index('-i') + 1] if program == 'ffmpeg' else args[-1]
if source == '-':
    data = sys.stdin.buffer.read()
else:
    data = Path(source).read_bytes()
if data.lstrip().startswith(b'<svg'):
    data.decode('utf-8')  # Data descriptors must preserve Unicode source bytes.
red = 34 if b'blue' in data else 221

if program == 'chafa':
    cols, rows = map(int, args[args.index('--size') + 1].split('x'))
    for y in range(rows):
        print(''.join(f'\033[38;2;{red};{x % 256};{y % 256};'
                      f'48;2;17;{(x + 1) % 256};{(y + 1) % 256}m▀'
                      for x in range(cols)) + '\033[0m')
else:
    cols, height = map(int, re.match(r'scale=(\d+):(\d+):',
                                    args[args.index('-vf') + 1]).groups())
    sys.stdout.buffer.write(bytes(component for y in range(height)
                                  for x in range(cols)
                                  for component in (red, x % 256, y % 256)))
