#!/usr/bin/env python3
"""Deterministic 80x24 external producer for the public GameKit wire protocol."""
import argparse
import json
import select
import sys
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--density', type=int, choices=(1, 20, 100), default=20)
    options = parser.parse_args()
    cells = ['.'] * (80 * 24)
    dirty = max(1, len(cells) * options.density // 100)
    revision = frame = 0
    rate, next_frame = 0, 0

    def reply(identifier, error=None):
        nonlocal revision
        revision += 1
        view = {'kind': 'grid', 'title': 'Live character surface',
                'status': f'Frame {frame:08d} · {options.density}% changed',
                'columns': 80, 'rows': [''.join(cells[r:r + 80])
                                      for r in range(0, len(cells), 80)],
                'frame': frame, 'dirty': dirty}
        print(json.dumps({'version': 1, 'id': identifier, 'revision': revision,
                          'capabilities': ['step', 'play', 'pause'], 'observation': view,
                          'error': error}), flush=True)

    def advance():
        nonlocal frame
        frame += 1
        # Visit every cell before wrapping, changing exactly DIRTY cells.
        for offset in range(dirty):
            index = ((frame - 1) * dirty + offset) % len(cells)
            cells[index] = chr(65 + (ord(cells[index]) - 64) % 26)

    while True:
        if rate:
            readable, _, _ = select.select([sys.stdin], [], [], max(0, next_frame - time.monotonic()))
            if not readable:
                advance()
                reply(None)
                next_frame += 1 / rate
                continue
        line = sys.stdin.readline()
        if not line:
            break
        request = json.loads(line)
        op, args = request['op'], request.get('args', {})
        if op == 'start':
            reply(request['id'])
        elif op == 'step':
            advance()
            reply(request['id'])
        elif op == 'play':
            fps = args.get('fps', 30)
            if fps not in (10, 20, 30):
                reply(request['id'], 'Expected fps 10/20/30')
                continue
            rate, next_frame = fps, time.monotonic() + 1 / fps
            reply(request['id'])
        elif op == 'pause':
            rate = 0
            reply(request['id'])
        else:
            reply(request['id'], 'Unsupported operation')


if __name__ == '__main__':
    try:
        main()
    except BrokenPipeError:
        pass
